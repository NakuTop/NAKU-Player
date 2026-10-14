// ignore_for_file: library_private_types_in_public_api

import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/utils/danmaku.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'package:kazumi/services/player/bilibili_anime_matcher.dart';
import 'package:kazumi/services/platform/dandan_credential_store.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';

part 'player_danmaku_controller.g.dart';

class PlayerDanmakuController = _PlayerDanmakuController
    with _$PlayerDanmakuController;

enum DanmakuLoadStatus { success, empty, failed }

class DanmakuLoadResult {
  const DanmakuLoadResult({
    required this.danmakus,
    required this.bangumiID,
    required this.status,
    this.failureMessage,
  });

  factory DanmakuLoadResult.success({
    required List<DanmakuEntry> danmakus,
    required int bangumiID,
  }) {
    return DanmakuLoadResult(
      danmakus: danmakus,
      bangumiID: bangumiID,
      status: danmakus.isEmpty
          ? DanmakuLoadStatus.empty
          : DanmakuLoadStatus.success,
    );
  }

  factory DanmakuLoadResult.failed({
    required int bangumiID,
    Object? error,
    String? message,
  }) {
    return DanmakuLoadResult(
      danmakus: const [],
      bangumiID: bangumiID,
      status: DanmakuLoadStatus.failed,
      failureMessage: message ?? danmakuFailureMessage(error),
    );
  }

  final List<DanmakuEntry> danmakus;
  final int bangumiID;
  final DanmakuLoadStatus status;
  final String? failureMessage;

  bool get hasDanmakus => status == DanmakuLoadStatus.success;

  bool get isFailed => status == DanmakuLoadStatus.failed;
}

class DanmakuTimeline {
  static int? resolveSourceSecond(
    Duration playbackPosition,
    double timelineOffsetSeconds,
  ) {
    final sourceMilliseconds =
        playbackPosition.inMilliseconds -
        (timelineOffsetSeconds * 1000).round();
    if (sourceMilliseconds < 0) {
      return null;
    }
    return Duration(milliseconds: sourceMilliseconds).inSeconds;
  }

  static int staggerDelayMilliseconds({
    required int index,
    required int total,
  }) {
    if (total <= 0) {
      return 0;
    }
    return index * 1000 ~/ total;
  }
}

abstract class _PlayerDanmakuController with Store {
  _PlayerDanmakuController({
    required this.isLocalPlayback,
    required this.downloadController,
    LocalDanmakuStore? localStore,
    BilibiliAnimeMatcher? bilibiliMatcher,
  }) : localStore = localStore ?? LocalDanmakuStore.instance,
       bilibiliMatcher = bilibiliMatcher ?? BilibiliAnimeMatcher.instance;

  final LocalDanmakuStore localStore;
  final BilibiliAnimeMatcher bilibiliMatcher;

  final bool Function() isLocalPlayback;
  final DownloadController downloadController;

  canvas.DanmakuController? _canvasController;
  bool? _canvasPlaying;

  canvas.DanmakuController get canvasController =>
      _canvasController ?? (throw StateError('弹幕画布尚未连接'));

  set canvasController(canvas.DanmakuController value) {
    _canvasController = value;
    if (_canvasPlaying == false) value.pause();
    if (_canvasPlaying == true) value.resume();
  }

  void pauseCanvas() {
    _canvasPlaying = false;
    _canvasController?.pause();
  }

  void resumeCanvas() {
    _canvasPlaying = true;
    _canvasController?.resume();
  }

  void clearCanvas() => _canvasController?.clear();

  final Map<int, List<DanmakuEntry>> danDanmakus = {};
  @observable
  bool danmakuOn = false;
  @observable
  bool danmakuLoading = false;

  int bangumiID = 0;
  int _scheduledDanmakuGeneration = 0;

  int get scheduledDanmakuGeneration => _scheduledDanmakuGeneration;

  double get timelineOffsetSeconds {
    final offset = GStorage.getSetting(SettingsKeys.danmakuTimeOffset);
    return offset;
  }

  int? resolveDanmakuSecond(Duration playbackPosition) {
    return DanmakuTimeline.resolveSourceSecond(
      playbackPosition,
      timelineOffsetSeconds,
    );
  }

  List<DanmakuEntry> danmakusForPlaybackPosition(Duration playbackPosition) {
    final danmakuSecond = resolveDanmakuSecond(playbackPosition);
    if (danmakuSecond == null) {
      return const [];
    }
    return danDanmakus[danmakuSecond] ?? const [];
  }

  @action
  void setDanmakuEnabled(bool value) {
    danmakuOn = value;
  }

  void clearAndInvalidateScheduledDanmakus() {
    _scheduledDanmakuGeneration++;
    clearCanvas();
  }

  // Apply fetched data only after VideoPageController validates the session.
  Future<DanmakuLoadResult> fetchDanmaku(
    int bangumiId,
    String pluginName,
    int episode, {
    BangumiItem? subject,
  }) async {
    final local = await localStore.read(bangumiId, episode);
    if (local != null && local.isNotEmpty) {
      return DanmakuLoadResult.success(danmakus: local, bangumiID: 0);
    }
    if (subject != null && subject.id == bangumiId) {
      if (isLocalPlayback()) {
        final cached = await downloadController.getCachedDanmakus(
          bangumiId,
          pluginName,
          episode,
        );
        if (cached != null && cached.isNotEmpty) {
          return DanmakuLoadResult.success(danmakus: cached, bangumiID: 0);
        }
      }
      // Preserve a configured aggregation service; Bilibili works on its own
      // when credentials are absent or that service cannot find the episode.
      try {
        if ((await DandanCredentialStore.instance.read()).isConfigured) {
          final aggregated = await _fetchDanDanmakuByBgmBangumiID(
            bangumiId,
            episode,
          );
          if (aggregated.hasDanmakus) return aggregated;
        }
      } catch (_) {
        /* Public Bilibili matching does not depend on Keychain. */
      }
      if (!GStorage.getSetting(SettingsKeys.danmakuBiliBiliSource)) {
        return DanmakuLoadResult.failed(
          bangumiID: 0,
          message: '请在弹幕设置开启 Bilibili 来源，或配置弹弹play',
        );
      }
      try {
        final entries = await bilibiliMatcher.load(
          subject,
          episode,
          persist: !GStorage.getSetting(SettingsKeys.privateMode),
        );
        return DanmakuLoadResult.success(danmakus: entries, bangumiID: 0);
      } on FormatException catch (e) {
        return DanmakuLoadResult.failed(bangumiID: 0, message: e.message);
      } catch (_) {
        return DanmakuLoadResult.failed(
          bangumiID: 0,
          message: '自动弹幕暂时无法加载，可在弹幕切换中重试',
        );
      }
    }
    if (isLocalPlayback()) {
      return await _fetchCachedDanmaku(bangumiId, pluginName, episode);
    }
    return await _fetchDanDanmakuByBgmBangumiID(bangumiId, episode);
  }

  @action
  void beginDanmakuLoad() {
    danDanmakus.clear();
    danmakuLoading = true;
  }

  @action
  void applyDanmakuLoad(
    DanmakuLoadResult result, {
    required bool enableDanmaku,
  }) {
    bangumiID = result.bangumiID;
    addDanmakus(result.danmakus);
    danmakuOn = enableDanmaku;
    danmakuLoading = false;
  }

  @action
  void applyUnavailableDanmakuLoad(DanmakuLoadResult result) {
    bangumiID = result.bangumiID;
    danDanmakus.clear();
    danmakuOn = false;
    danmakuLoading = false;
  }

  @action
  void finishDanmakuLoad({bool disableDanmaku = false}) {
    if (disableDanmaku) {
      danDanmakus.clear();
      danmakuOn = false;
    }
    danmakuLoading = false;
  }

  Future<DanmakuLoadResult> _fetchCachedDanmaku(
    int bangumiId,
    String pluginName,
    int episode,
  ) async {
    KazumiLogger().i(
      'PlayerController: attempting to load cached danmaku for episode $episode',
    );
    var nextBangumiID = bangumiID;
    try {
      final cachedDanmakus = await downloadController.getCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
      );

      if (cachedDanmakus != null && cachedDanmakus.isNotEmpty) {
        KazumiLogger().i(
          'PlayerController: loaded ${cachedDanmakus.length} cached danmakus',
        );
        return DanmakuLoadResult.success(
          danmakus: cachedDanmakus,
          bangumiID: nextBangumiID,
        );
      } else {
        KazumiLogger().i(
          'PlayerController: no cached danmaku, attempting online fetch',
        );
        try {
          nextBangumiID = await DanmakuApi.getDanDanBangumiIDByBgmBangumiID(
            bangumiId,
          );
          if (nextBangumiID != 0) {
            var res = await DanmakuApi.getDanDanmaku(nextBangumiID, episode);
            if (res.isNotEmpty) {
              KazumiLogger().i(
                'PlayerController: fetched ${res.length} danmakus online',
              );
              _saveDanmakuToCache(
                downloadController,
                bangumiId,
                pluginName,
                episode,
                res,
                nextBangumiID,
              );
            }
            return DanmakuLoadResult.success(
              danmakus: res,
              bangumiID: nextBangumiID,
            );
          }
        } catch (e) {
          KazumiLogger().w(
            'PlayerController: failed to fetch danmaku online (may be offline)',
            error: e,
          );
          return DanmakuLoadResult.failed(bangumiID: nextBangumiID, error: e);
        }
      }
    } catch (e) {
      KazumiLogger().w(
        'PlayerController: failed to load cached danmaku',
        error: e,
      );
      return DanmakuLoadResult.failed(bangumiID: nextBangumiID, error: e);
    }
    return DanmakuLoadResult.success(
      danmakus: const [],
      bangumiID: nextBangumiID,
    );
  }

  void _saveDanmakuToCache(
    DownloadController downloadController,
    int bangumiId,
    String pluginName,
    int episode,
    List<DanmakuEntry> danmakus,
    int danDanID,
  ) {
    try {
      downloadController.updateCachedDanmakus(
        bangumiId,
        pluginName,
        episode,
        danmakus,
        danDanID,
      );
      KazumiLogger().i(
        'PlayerController: saved ${danmakus.length} danmakus to cache',
      );
    } catch (e) {
      KazumiLogger().w(
        'PlayerController: failed to save danmaku to cache',
        error: e,
      );
    }
  }

  Future<DanmakuLoadResult> _fetchDanDanmakuByBgmBangumiID(
    int bgmBangumiID,
    int episode,
  ) async {
    KazumiLogger().i(
      'PlayerController: attempting to get danmaku [BgmBangumiID] $bgmBangumiID',
    );
    var nextBangumiID = bangumiID;
    try {
      nextBangumiID = await DanmakuApi.getDanDanBangumiIDByBgmBangumiID(
        bgmBangumiID,
      );
      if (nextBangumiID == 0) {
        return DanmakuLoadResult.success(
          danmakus: const [],
          bangumiID: nextBangumiID,
        );
      }
      var res = await DanmakuApi.getDanDanmaku(nextBangumiID, episode);
      return DanmakuLoadResult.success(danmakus: res, bangumiID: nextBangumiID);
    } catch (e) {
      KazumiLogger().w(
        'PlayerController: failed to get danmaku [BgmBangumiID] $bgmBangumiID',
        error: e,
      );
      return DanmakuLoadResult.failed(bangumiID: nextBangumiID, error: e);
    }
  }

  @action
  Future<bool> getDanDanmakuByEpisodeID(int episodeID) async {
    KazumiLogger().i('PlayerController: attempting to get danmaku $episodeID');
    danmakuLoading = true;
    try {
      danDanmakus.clear();
      var res = await DanmakuApi.getDanDanmakuByEpisodeID(episodeID);
      addDanmakus(res);
      return res.isNotEmpty;
    } catch (e) {
      KazumiLogger().w('PlayerController: failed to get danmaku', error: e);
      rethrow;
    } finally {
      danmakuLoading = false;
    }
  }

  void addDanmakus(List<DanmakuEntry> danmakus) {
    final bool danmakuDeduplicationEnable = GStorage.getSetting(
      SettingsKeys.danmakuDeduplication,
    );

    final List<DanmakuEntry> listToAdd = danmakuDeduplicationEnable
        ? mergeDuplicateDanmakus(danmakus, timeWindowSeconds: 5)
        : danmakus;

    for (final element in listToAdd) {
      final danmakuSecond = element.time.toInt();
      (danDanmakus[danmakuSecond] ??= <DanmakuEntry>[]).add(element);
    }
  }

  void updateDanmakuSpeed(double playerSpeed) {
    final controller = _canvasController;
    if (controller == null) return;
    final baseDuration = GStorage.getSetting(SettingsKeys.danmakuDuration);
    final followSpeed = GStorage.getSetting(SettingsKeys.danmakuFollowSpeed);

    final duration = followSpeed ? (baseDuration / playerSpeed) : baseDuration;
    controller.updateOption(controller.option.copyWith(duration: duration));
  }
}
