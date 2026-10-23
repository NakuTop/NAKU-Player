import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'package:canvas_danmaku/canvas_danmaku.dart' as canvas;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'cinema_store.dart';
import 'cinema_media_identity.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'cinema_logvar_client.dart';
import 'cinema_direct_danmaku.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';

/// Only public platform page URLs can leave the player. Private playback URLs,
/// NAS paths, signed query strings and arbitrary hosts are not source IDs.
Uri cinemaPublicDanmakuLink(String value) {
  final uri = Uri.tryParse(value.trim());
  const hosts = {
    'www.bilibili.com',
    'bilibili.com',
    'm.bilibili.com',
    'v.qq.com',
    'm.v.qq.com',
    'www.iqiyi.com',
    'm.iqiyi.com',
    'www.mgtv.com',
    'm.mgtv.com',
    'v.youku.com',
    'm.youku.com',
  };
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort ||
      !hosts.contains(uri.host.toLowerCase()) ||
      uri.path.length > 512 ||
      uri.path.isEmpty ||
      uri.path == '/') {
    throw const FormatException('请输入 B 站、腾讯、爱奇艺、芒果或优酷的公开视频页面链接');
  }
  return Uri(
    scheme: 'https',
    host: uri.host.toLowerCase(),
    path: uri.path,
    queryParameters: uri.queryParameters.containsKey('p')
        ? {'p': uri.queryParameters['p']!}
        : null,
  );
}

class CinemaPublicDanmakuClient {
  CinemaPublicDanmakuClient({Dio? dio}) : _dio = dio;
  Dio? _dio;
  Dio get _http => _dio ??= DioFactory.createForConfig(
    NetworkConfig.fromSettings().copyWith(
      receiveTimeout: const Duration(seconds: 20),
    ),
  );
  Future<List<DanmakuEntry>> load(
    String link, {
    CancelToken? cancelToken,
  }) async {
    final publicLink = cinemaPublicDanmakuLink(link);
    final response = await _http.get<ResponseBody>(
      'https://danmu.zxz.ee/',
      queryParameters: {'type': 'xml', 'id': publicLink.toString()},
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
      ),
      cancelToken: cancelToken,
    );
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (body.length + chunk.length > maxDanmakuImportBytes) {
        throw const FormatException('弹幕超过 8 MB');
      }
      body.add(chunk);
    }
    final entries = await compute(
      parseLocalDanmaku,
      utf8.decode(body.takeBytes()),
    );
    for (final entry in entries) {
      entry.source = '[公共弹幕库]';
    }
    return entries;
  }

  void close() => _dio?.close(force: true);
}

/// A clock-driven bounded cursor: no queued delayed callbacks survive a seek.
class CinemaDanmakuClock {
  int index = 0;
  double? previous;
  bool reset = false;
  void clear() {
    index = 0;
    previous = null;
    reset = true;
  }

  void replaceWindow(List<DanmakuEntry> entries, double position) {
    var low = 0, high = entries.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (entries[mid].time <= position) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    index = low;
    previous = position;
    reset = false;
  }

  List<DanmakuEntry> advance(
    List<DanmakuEntry> entries,
    double time, {
    double rate = 1,
  }) {
    reset = false;
    final before = previous;
    previous = time;
    if (before == null ||
        time < before ||
        time - before > (2 * rate).clamp(2, 8)) {
      reset = true;
      var low = 0, high = entries.length;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (entries[mid].time < time) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      index = low;
      return const [];
    }
    final emitted = <DanmakuEntry>[];
    final seen = <String>{};
    while (index < entries.length && entries[index].time <= time) {
      final item = entries[index++];
      if (item.time > before &&
          item.message.length <= 120 &&
          seen.add(item.message) &&
          emitted.length < 4) {
        emitted.add(item);
      }
    }
    return emitted;
  }
}

class CinemaDanmakuController extends ChangeNotifier {
  CinemaDanmakuController(
    this.player,
    this.store,
    String mediaIdentity, {
    this.autoQuery,
    this.readLogvarConfiguration,
    this.logvarClientFactory,
    this.directClientFactory,
  }) : _key = sha256.convert(utf8.encode(mediaIdentity)).toString() {
    enabled = store.extras['cinemaDanmakuEnabled'] is bool
        ? store.extras['cinemaDanmakuEnabled'] == true
        : store.extras['danmakuAutoMatch'] != false;
    final style = store.extras['cinemaDanmakuStyle'];
    if (style is Map) {
      double read(String key, double fallback, double min, double max) {
        final value = style[key];
        return value is num && value.isFinite
            ? value.toDouble().clamp(min, max)
            : fallback;
      }

      opacity = read('opacity', .75, .2, 1);
      fontSize = read('fontSize', 20, 14, 36);
      area = read('area', .5, .25, .75);
      duration = read('duration', 8, 4, 16);
    }
    _subscriptions.addAll([
      player.stream.position.listen(_tick),
      player.stream.playing.listen((_) => _syncPlaying()),
      player.stream.buffering.listen((_) => _syncPlaying()),
      player.stream.rate.listen((_) {
        _canvas?.clear();
        _canvas?.updateOption(option);
      }),
    ]);
    ready = _restore();
  }
  final Player player;
  final CinemaStore store;
  final CinemaLogvarQuery? autoQuery;
  final Future<LogvarConfiguration?> Function()? readLogvarConfiguration;
  final CinemaLogvarClient Function(LogvarConfiguration)? logvarClientFactory;
  final CinemaDanmakuMatcher Function()? directClientFactory;
  String? get _matchKey {
    final q = autoQuery;
    return q == null
        ? null
        : sha256
              .convert(
                utf8.encode(
                  '${cinemaMediaTitleKey(q.title)}|${q.year}|${q.series}|${q.series ? q.season : 0}',
                ),
              )
              .toString();
  }

  bool get hasMatchOverride {
    final raw = store.extras['danmakuMatchOverridesV1'];
    return raw is Map && raw[_matchKey] is Map;
  }

  CinemaLogvarQuery? get matchQuery {
    final original = autoQuery;
    if (original == null) return null;
    final raw = store.extras['danmakuMatchOverridesV1'];
    final row = raw is Map ? raw[_matchKey] : null;
    if (row is! Map || row['title'] is! String || row['year'] is! String) {
      return original;
    }
    final title = row['title'] as String, year = row['year'] as String;
    if (!_validMatchTitle(title) ||
        (year.isNotEmpty && !RegExp(r'^(19|20)\d{2}$').hasMatch(year))) {
      return original;
    }
    return CinemaLogvarQuery(
      title: title,
      year: year,
      series: original.series,
      season: original.season,
      episode: original.episode,
    );
  }

  static bool _validMatchTitle(String title) =>
      title.trim().length >= 2 &&
      title.length <= 160 &&
      !title.contains('://') &&
      !RegExp(r'[/\\\r\n]').hasMatch(title);

  /// Store the correction by work/year, so switching source or episode does
  /// not require editing again. Playback addresses never enter this setting.
  Future<void> changeMatchQuery(CinemaLogvarQuery? query) async {
    final key = _matchKey;
    if (_closed || key == null) return;
    if (query != null &&
        (!_validMatchTitle(query.title) ||
            (query.year.isNotEmpty &&
                !RegExp(r'^(19|20)\d{2}$').hasMatch(query.year)))) {
      throw const FormatException('请输入片名及正确的四位年份');
    }
    await ready;
    if (_closed) return;
    final raw = store.extras['danmakuMatchOverridesV1'];
    final rows = raw is Map
        ? Map<String, dynamic>.from(raw)
        : <String, dynamic>{};
    rows.remove(key);
    if (query != null) {
      rows[key] = {'title': query.title.trim(), 'year': query.year};
    }
    while (rows.length > 64) {
      rows.remove(rows.keys.first);
    }
    await store.setExtra('danmakuMatchOverridesV1', rows);
    if (_closed) return;
    cancelMatching(notify: false);
    entries = [];
    source = '正在重新匹配弹幕';
    _windowed = false;
    clock.clear();
    _canvas?.clear();
    notifyListeners();
    await _save();
    await loadAutomatic(force: true);
  }

  bool matching = false;
  String matchMessage = '';
  bool get automaticMatching => enabled;
  int _matchRevision = 0;
  CancelToken? _matchCancel;
  CinemaDanmakuMatcher? _matchClient;
  CinemaDanmakuMatcher? _timelineClient;
  CinemaDanmakuTimeline? _timeline;
  CancelToken? _windowCancel;
  int _windowRevision = 0;
  bool _windowed = false;
  double _windowStart = 0, _windowEnd = 0;
  double? _loadingAt;
  DateTime? _windowRetryAfter;
  final String _key;
  final clock = CinemaDanmakuClock();
  final _subscriptions = <StreamSubscription<dynamic>>[];
  late final Future<void> ready;
  List<DanmakuEntry> entries = [];
  canvas.DanmakuController? _canvas;
  bool enabled = false, _closed = false;
  double offset = 0, opacity = .75, fontSize = 20, area = .5, duration = 8;
  String source = '尚未加载弹幕';
  Future<void> _writes = Future<void>.value();
  canvas.DanmakuOption get option => canvas.DanmakuOption(
    area: area,
    fontSize: fontSize,
    opacity: opacity,
    duration: duration / player.state.rate.clamp(.25, 4),
    staticDuration: duration / 2 / player.state.rate.clamp(.25, 4),
    hideBottom: true,
    safeArea: true,
    massiveMode: false,
  );
  void attach(canvas.DanmakuController value) {
    _canvas = value;
    _syncPlaying();
  }

  void _syncPlaying() {
    if (enabled && player.state.playing && !player.state.buffering) {
      _canvas?.resume();
    } else {
      _canvas?.pause();
    }
  }

  void _tick(Duration position) {
    if (enabled) {
      unawaited(_ensureWindow(position.inMilliseconds / 1000 - offset));
    }
    if (!enabled || !player.state.playing || player.state.buffering) return;
    final batch = clock.advance(
      entries,
      position.inMilliseconds / 1000 - offset,
      rate: player.state.rate,
    );
    if (clock.reset) _canvas?.clear();
    for (final entry in batch) {
      if (entry.type == 4) continue;
      _canvas?.addDanmaku(
        canvas.DanmakuContentItem(
          entry.message,
          color: entry.color,
          type: entry.type == 5
              ? canvas.DanmakuItemType.top
              : canvas.DanmakuItemType.scroll,
        ),
      );
    }
  }

  Future<File> _file() async => File(
    '${(await store.subtitleCacheDirectory()).parent.path}/danmaku-v1/$_key.json',
  );
  Future<void> _restore() async {
    try {
      final file = await _file();
      if (!await file.exists() || await file.length() > maxDanmakuImportBytes) {
        return;
      }
      final text = await file.readAsString();
      final data = jsonDecode(text);
      final loaded =
          data is Map &&
              data['comments'] is List &&
              (data['comments'] as List).isEmpty
          ? <DanmakuEntry>[]
          : await compute(parseLocalDanmaku, text);
      if (_closed || entries.isNotEmpty) return;
      entries = loaded;
      _windowed = data is Map && data['windowed'] == true;
      source = data is Map && data['source'] is String
          ? '${data['source']}'
          : '已保存弹幕';
      // Migrate the previous whole-episode NAS cache to bounded direct loading.
      if (autoQuery != null && source.startsWith('NAS ·')) _windowed = true;
      if (_windowed) {
        final at = player.state.position.inMilliseconds / 1000;
        entries = loaded
            .where((e) => e.time >= at - 30 && e.time <= at + 180)
            .take(6000)
            .toList();
      }
      offset =
          data is Map &&
              data['offset'] is num &&
              (data['offset'] as num).isFinite
          ? (data['offset'] as num).toDouble().clamp(-3600, 3600)
          : 0;
      // A display preference applies to subsequent episodes too. Respect old
      // per-video opt-outs until the user makes a new global choice.
      enabled = store.extras['cinemaDanmakuEnabled'] is bool
          ? store.extras['cinemaDanmakuEnabled'] == true
          : data is Map &&
                data['enabled'] == true &&
                store.extras['danmakuAutoMatch'] != false;
      _syncPlaying();
      notifyListeners();
    } catch (_) {
      /* Malformed cache should never interrupt playback. */
    }
  }

  Future<void> setEntries(
    List<DanmakuEntry> value,
    String label, {
    bool fromAutomaticMatch = false,
  }) async {
    if (!fromAutomaticMatch) {
      cancelMatching(notify: false);
      _windowed = false;
    }
    await ready;
    if (_closed) return;
    entries = List.of(value)..sort((a, b) => a.time.compareTo(b.time));
    source = label;
    enabled = store.extras['cinemaDanmakuEnabled'] != false;
    offset = 0;
    clock.clear();
    _canvas?.clear();
    _syncPlaying();
    notifyListeners();
    await _save();
  }

  Future<void> setEnabled(bool value) async {
    if (!value) cancelMatching(notify: false);
    await ready;
    if (_closed) return;
    enabled = value;
    if (!value) cancelMatching(notify: false);
    // The visible switch controls automatic loading too; a legacy hidden
    // preference must not make an enabled switch ineffective.
    if (value) await store.setExtra('danmakuAutoMatch', true);
    await store.setExtra('cinemaDanmakuEnabled', value);
    if (_closed) return;
    clock.clear();
    _canvas?.clear();
    _syncPlaying();
    notifyListeners();
    await _save();
    if (value && (entries.isEmpty || (_windowed && _timeline == null))) {
      unawaited(loadAutomatic());
    }
  }

  void setOffset(double value) {
    if (!value.isFinite || value.abs() > 3600) return;
    offset = value;
    clock.clear();
    _canvas?.clear();
    notifyListeners();
    unawaited(_save());
  }

  void setOpacity(double value) {
    opacity = value.clamp(.2, 1);
    _styleChanged();
  }

  void setFontSize(double value) {
    fontSize = value.clamp(14, 36);
    _styleChanged();
  }

  void setArea(double value) {
    area = value.clamp(.25, .75);
    _styleChanged();
  }

  void setDuration(double value) {
    duration = value.clamp(4, 16);
    _styleChanged();
  }

  void _styleChanged() {
    _canvas?.updateOption(option);
    notifyListeners();
    unawaited(
      store.setExtra('cinemaDanmakuStyle', {
        'opacity': opacity,
        'fontSize': fontSize,
        'area': area,
        'duration': duration,
      }),
    );
  }

  Future<void> _save() {
    final text = jsonEncode({
      'source': source,
      'enabled': enabled,
      'offset': offset,
      'comments': entries.map((e) => e.toJson()).toList(),
      'windowed': _windowed,
    });
    _writes = _writes.catchError((Object _) {}).then((_) async {
      if (utf8.encode(text).length > maxDanmakuImportBytes) return;
      final file = await _file();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(file.path);
      final files = await file.parent
          .list()
          .where((f) => f is File && f.path.endsWith('.json'))
          .cast<File>()
          .toList();
      final dated = await Future.wait(
        files.map((f) async => (f, await f.stat())),
      );
      dated.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      var total = dated.fold(0, (int n, e) => n + e.$2.size),
          count = dated.length;
      for (final entry in dated) {
        if (total <= 64 * 1024 * 1024 && count <= 32) break;
        if (entry.$1.path != file.path) {
          await entry.$1.delete();
          total -= entry.$2.size;
          count--;
        }
      }
    });
    return _writes;
  }

  void cancelMatching({bool notify = true}) {
    _matchRevision++;
    _matchCancel?.cancel('danmaku matching cancelled');
    _matchCancel = null;
    _matchClient?.close();
    _matchClient = null;
    _stopTimeline();
    if (matching) {
      matching = false;
      matchMessage = '已取消自动匹配';
      if (notify && !_closed) notifyListeners();
    }
  }

  Future<void> setAutomaticMatching(bool value) => setEnabled(value);

  Future<void> loadAutomatic({bool force = false}) async {
    await ready;
    final query = matchQuery;
    if (_closed ||
        matching ||
        query == null ||
        !enabled ||
        !automaticMatching ||
        (!force && entries.isNotEmpty && (!_windowed || _timeline != null))) {
      return;
    }
    final revision = ++_matchRevision;
    final cancel = CancelToken();
    _matchCancel = cancel;
    matching = true;
    matchMessage = '正在查找平台弹幕';
    notifyListeners();
    bool current() =>
        !_closed && revision == _matchRevision && !cancel.isCancelled;
    CinemaDanmakuMatcher? client;
    try {
      if (readLogvarConfiguration != null && logvarClientFactory != null) {
        // Explicit legacy transport injection; normal playback never reads NAS
        // credentials, including on a new Mac or under a different NAS account.
        final configuration = await readLogvarConfiguration!().timeout(
          const Duration(seconds: 8),
        );
        if (!current()) return;
        if (configuration == null) {
          matchMessage = '未提供可用弹幕服务';
          return;
        }
        client = logvarClientFactory!(configuration);
      } else {
        client =
            directClientFactory?.call() ??
            CinemaDirectDanmakuClient(
              initialPosition: player.state.position.inMilliseconds / 1000,
            );
      }
      _matchClient = client;
      final result = await client
          .match(
            query,
            cancelToken: cancel,
            onProgress: (message) {
              if (current()) {
                matchMessage = message;
                notifyListeners();
              }
            },
          )
          .timeout(const Duration(seconds: 90));
      if (!current()) return;
      if (result == null) {
        matchMessage = query.series ? '本集暂无可确认的弹幕' : '暂未找到该电影的正片弹幕，已排除预告和影评';
      } else {
        _stopTimeline();
        _timeline = result.timeline;
        _timelineClient = result.timeline == null ? null : client;
        _windowed = result.timeline != null;
        _windowStart = result.windowStart;
        _windowEnd = result.windowEnd;
        await setEntries(
          result.entries,
          result.label,
          fromAutomaticMatch: true,
        );
        if (current()) {
          matchMessage = result.entries.isEmpty
              ? '当前时段暂无弹幕，将随播放进度自动获取'
              : '已加载 ${result.entries.length} 条${_windowed ? '当前时段弹幕' : ''}${result.partial ? '（部分分片暂不可用）' : ''} · ${result.episode.title}';
          unawaited(
            _ensureWindow(player.state.position.inMilliseconds / 1000 - offset),
          );
        }
      }
    } on TimeoutException {
      if (current()) matchMessage = '弹幕匹配超时，将在下次播放时重试';
      cancel.cancel('danmaku matching timed out');
    } on FormatException catch (e) {
      if (current()) matchMessage = e.message;
    } on DioException catch (e) {
      if (current()) {
        matchMessage =
            e.response?.statusCode == 401 || e.response?.statusCode == 403
            ? '平台暂时限制弹幕访问，稍后会重试'
            : e.response?.statusCode == 429
            ? '弹幕服务请求较多，请稍后重试'
            : '暂时无法连接弹幕服务';
      }
    } catch (_) {
      if (current()) matchMessage = '弹幕暂时不可用';
    } finally {
      if (!identical(_timelineClient, client)) client?.close();
      if (!_closed && revision == _matchRevision) {
        matching = false;
        _matchClient = null;
        _matchCancel = null;
        notifyListeners();
      }
    }
  }

  void _stopTimeline() {
    _windowRevision++;
    _windowCancel?.cancel('danmaku window replaced');
    _windowCancel = null;
    _loadingAt = null;
    _windowRetryAfter = null;
    _timeline?.close();
    _timeline = null;
    _timelineClient?.close();
    _timelineClient = null;
  }

  Future<void> _ensureWindow(double position) async {
    final timeline = _timeline;
    if (_closed ||
        !enabled ||
        timeline == null ||
        (_windowRetryAfter != null &&
            DateTime.now().isBefore(_windowRetryAfter!)) ||
        (position >= _windowStart && position < _windowEnd - 45) ||
        (position >= _windowStart && _windowEnd >= timeline.endSeconds)) {
      return;
    }
    if (_loadingAt != null && (position - _loadingAt!).abs() < 30) return;
    _windowCancel?.cancel('new playback position');
    final cancel = _windowCancel = CancelToken();
    final revision = ++_windowRevision;
    _loadingAt = position;
    bool current() =>
        !_closed &&
        enabled &&
        identical(_timeline, timeline) &&
        revision == _windowRevision &&
        !cancel.isCancelled;
    try {
      final next = await timeline
          .window(position, cancelToken: cancel)
          .timeout(const Duration(seconds: 25));
      if (!current()) return;
      entries = next.entries;
      _windowStart = next.start;
      _windowEnd = next.end;
      _windowRetryAfter = null;
      clock.replaceWindow(
        entries,
        player.state.position.inMilliseconds / 1000 - offset,
      );
      matchMessage = next.entries.isEmpty
          ? '当前时段暂无弹幕，将随播放进度自动获取'
          : '已加载 ${entries.length} 条当前时段弹幕${next.partial ? '（部分分片暂不可用）' : ''}';
      notifyListeners();
      unawaited(_save().catchError((Object _) {}));
    } catch (_) {
      if (current()) {
        _windowRetryAfter = DateTime.now().add(const Duration(seconds: 20));
        matchMessage = '当前时段弹幕暂不可用，稍后自动重试';
        notifyListeners();
      }
    } finally {
      if (revision == _windowRevision) {
        _loadingAt = null;
        _windowCancel = null;
        cancel.cancel('window request finished');
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    cancelMatching(notify: false);
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _canvas = null;
    entries = [];
    await _writes.catchError((Object _) {});
    super.dispose();
  }
}

class CinemaDanmakuOverlay extends StatelessWidget {
  const CinemaDanmakuOverlay({super.key, required this.controller});
  final CinemaDanmakuController controller;
  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ListenableBuilder(
      listenable: controller,
      builder: (_, _) => Visibility(
        visible: controller.enabled,
        maintainState: true,
        child: canvas.DanmakuScreen(
          key: ObjectKey(controller),
          option: controller.option,
          createdController: controller.attach,
        ),
      ),
    ),
  );
}

Future<void> showCinemaDanmakuSheet(
  BuildContext context,
  CinemaDanmakuController controller, {
  String title = '',
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 480),
  builder: (_) => SizedBox(
    height: (MediaQuery.sizeOf(context).height * .8).clamp(0, 510),
    child: CinemaDanmakuStylePanel(controller: controller),
  ),
);

/// Display controls stay compact; correcting a match opens a separate dialog.
class CinemaDanmakuStylePanel extends StatelessWidget {
  const CinemaDanmakuStylePanel({super.key, required this.controller});
  final CinemaDanmakuController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      Widget slider(
        String label,
        String value,
        double setting,
        double min,
        double max,
        int divisions,
        ValueChanged<double> change,
      ) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value),
            ],
          ),
          Slider(
            semanticFormatterCallback: (_) => value,
            value: setting,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: c.enabled ? change : null,
          ),
        ],
      );
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 12, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '弹幕',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: '完成',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              children: [
                SwitchListTile.adaptive(
                  key: const ValueKey('cinema-danmaku-enabled'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('显示弹幕'),
                  subtitle: Text(
                    c.matching
                        ? c.matchMessage
                        : c.entries.isNotEmpty
                        ? '已自动加载 ${c.entries.length} 条'
                        : c.matchMessage.isNotEmpty
                        ? c.matchMessage
                        : '有可用弹幕时自动加载',
                  ),
                  value: c.enabled,
                  onChanged: (value) => unawaited(c.setEnabled(value)),
                ),
                if (c.matching) const LinearProgressIndicator(minHeight: 2),
                if (c.matchQuery case final query?)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '匹配词：${cinemaMediaBaseTitle(query.title)}${query.year.isEmpty ? '' : ' · ${query.year}'}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      TextButton.icon(
                        key: const ValueKey('danmaku-correct-match'),
                        onPressed: c.enabled
                            ? () => showCinemaDanmakuMatchDialog(context, c)
                            : null,
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('更正匹配'),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                slider(
                  '字号',
                  '${c.fontSize.round()}',
                  c.fontSize,
                  14,
                  36,
                  22,
                  c.setFontSize,
                ),
                slider(
                  '不透明度',
                  '${(c.opacity * 100).round()}%',
                  c.opacity,
                  .2,
                  1,
                  16,
                  c.setOpacity,
                ),
                slider(
                  '显示区域',
                  '上方 ${(c.area * 100).round()}%',
                  c.area,
                  .25,
                  .75,
                  2,
                  c.setArea,
                ),
                slider(
                  '滚动时长',
                  '${c.duration.round()} 秒',
                  c.duration,
                  4,
                  16,
                  12,
                  c.setDuration,
                ),
                Text(
                  '设置会用于后续影片；底部留给字幕。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

Future<void> showCinemaDanmakuMatchDialog(
  BuildContext context,
  CinemaDanmakuController controller,
) async {
  final query = controller.matchQuery;
  if (query == null) return;
  final edit = await showDialog<({CinemaLogvarQuery? query})>(
    context: context,
    builder: (_) => _DanmakuMatchDialog(
      query: query,
      originalTitle: controller.autoQuery!.title,
      canReset: controller.hasMatchOverride,
    ),
  );
  if (edit == null) return;
  try {
    await controller.changeMatchQuery(edit.query);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('弹幕匹配设置未能保存，请重试')));
    }
  }
}

class _DanmakuMatchDialog extends StatefulWidget {
  const _DanmakuMatchDialog({
    required this.query,
    required this.originalTitle,
    required this.canReset,
  });
  final CinemaLogvarQuery query;
  final String originalTitle;
  final bool canReset;
  @override
  State<_DanmakuMatchDialog> createState() => _DanmakuMatchDialogState();
}

class _DanmakuMatchDialogState extends State<_DanmakuMatchDialog> {
  late final _title = TextEditingController(
    text: cinemaMediaBaseTitle(widget.query.title),
  );
  late final _year = TextEditingController(text: widget.query.year);
  String? _error;
  @override
  void dispose() {
    _title.dispose();
    _year.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim(), year = _year.text.trim();
    if (!CinemaDanmakuController._validMatchTitle(title) ||
        (year.isNotEmpty && !RegExp(r'^(19|20)\d{2}$').hasMatch(year))) {
      setState(() => _error = '请输入至少两个字的片名，年份可留空或填写四位数字');
      return;
    }
    final q = widget.query;
    Navigator.pop(context, (
      query: CinemaLogvarQuery(
        title: title,
        year: year,
        series: q.series,
        season: q.season,
        episode: q.episode,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('更正弹幕匹配'),
    content: SizedBox(
      width: 400,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '当前影片：${widget.originalTitle}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('danmaku-match-title'),
              controller: _title,
              autofocus: true,
              maxLength: 160,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: '搜索片名',
                hintText: '例如：泰坦尼克号',
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('danmaku-match-year'),
              controller: _year,
              keyboardType: TextInputType.number,
              maxLength: 4,
              decoration: const InputDecoration(labelText: '上映年份（可选）'),
              onSubmitted: (_) => _submit(),
            ),
            if (widget.query.series)
              Text('第 ${widget.query.season} 季 · 第 ${widget.query.episode} 集'),
            const Text('更正会记住，并用于同名、同年份的其他片源。'),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
    ),
    actions: [
      if (widget.canReset)
        TextButton(
          onPressed: () => Navigator.pop(context, (query: null)),
          child: const Text('恢复自动'),
        ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('danmaku-match-submit'),
        onPressed: _submit,
        child: const Text('搜索并加载'),
      ),
    ],
  );
}
