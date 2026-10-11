import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_downloads.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/download/download_sleep_guard.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/video_source/services.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Manager extends Fake implements IDownloadManager {
  @override
  ProgressCallback? onProgress;
  final requests = <DownloadRequest>[];
  @override
  Future<void> enqueue(DownloadRequest request) async {
    requests.add(request);
  }

  @override
  Future<void> enqueuePriority(DownloadRequest request) => enqueue(request);
  @override
  void pause(String record, int episode) {}
}

class _Resolver implements IVideoSourceService {
  final pending = <Completer<VideoSource>>[];
  @override
  Future<VideoSource> resolve(
    String url, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final result = Completer<VideoSource>();
    pending.add(result);
    return result.future;
  }

  @override
  void cancel() {} // Deliberately late completion, like an in-flight WebView.
  @override
  Future<void> dispose() async {}
}

const _source = CinemaSource(
  id: 'fixture',
  name: 'Fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://fixture.invalid/api',
  requestHeaders: {'User-Agent': 'fixture-agent'},
);
CinemaTitle _title({bool html = false}) => CinemaTitle(
  id: html ? 'html' : 'direct',
  sourceId: 'fixture',
  title: 'Fixture season',
  routes: [
    CinemaRoute(
      name: html ? 'yun' : 'm3u8',
      episodes: [
        for (var i = 1; i <= 12; i++)
          CinemaEpisode(
            name: '第$i 集',
            url:
                'https://fixture.invalid/${html ? 'page' : 'video'}/$i${html ? '' : '.m3u8'}',
          ),
      ],
    ),
  ],
);
List<DownloadSelection> _selections(CinemaTitle title, Iterable<int> numbers) =>
    [
      for (final number in numbers)
        DownloadSelection(
          number: number,
          name: title.routes[0].episodes[number - 1].name,
          road: 0,
          url: title.routes[0].episodes[number - 1].url,
        ),
    ];
Future<void> _until(bool Function() ready) async {
  final limit = DateTime.now().add(const Duration(seconds: 3));
  while (!ready()) {
    if (DateTime.now().isAfter(limit)) {
      throw TimeoutException('queue did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform paths;
  late DownloadRepository repository;
  late _Manager manager;
  late DownloadController controller;
  late VideoSourceResolverPool pool;
  late _Resolver resolver;
  late DownloadSleepGuard sleepGuard;
  final powerStates = <bool>[];
  setUpAll(() async {
    Logger.level = Level.off;
    root = await Directory.systemTemp.createTemp('naku-batch-');
    paths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init(root.path);
    await GStorage.init();
    await GStorage.putSetting(SettingsKeys.downloadDanmaku, false);
    await GStorage.putSetting(SettingsKeys.downloadParallelEpisodes, 1);
  });
  setUp(() async {
    await GStorage.downloads.clear();
    repository = DownloadRepository();
    manager = _Manager();
    resolver = _Resolver();
    pool = VideoSourceResolverPool(createService: () => resolver);
    powerStates.clear();
    sleepGuard = DownloadSleepGuard(
      supported: true,
      apply: (active) async {
        powerStates.add(active);
      },
    );
    controller = DownloadController(
      repository,
      manager,
      PluginsController(),
      resolverPool: pool,
      sleepGuard: sleepGuard,
    );
  });
  tearDown(() async {
    await pool.dispose();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = paths;
    await root.delete(recursive: true);
  });
  test(
    'download lifecycle releases the sleep guard after final completion and pause',
    () async {
      await controller.init();
      final title = _title();
      final record = cinemaDownloadRecord(title, _source, 0);
      await controller.startEpisodeDownloads(
        media: record,
        selections: _selections(title, [1]),
      );
      await _until(() => manager.requests.length == 1 && sleepGuard.active);
      final episode = repository.getRecord(record.key)!.episodes[1]!;
      episode.status = DownloadStatus.completed;
      manager.onProgress!(record.key, 1, episode, 0);
      await _until(() => !sleepGuard.active);
      expect(powerStates, [true, false]);
      await controller.startEpisodeDownloads(
        media: record,
        selections: _selections(title, [2]),
      );
      await _until(() => sleepGuard.active);
      await controller.pauseAllDownloads();
      await _until(() => !sleepGuard.active);
      expect(powerStates, [true, false, true, false]);
    },
  );
  test(
    'concurrent season selections persist all episodes once and skip duplicates',
    () async {
      final title = _title();
      final media = cinemaDownloadRecord(title, _source, 0);
      final counts = await Future.wait([
        controller.startEpisodeDownloads(
          media: media,
          selections: _selections(title, [1, 2, 3, 4, 5, 6]),
        ),
        controller.startEpisodeDownloads(
          media: cinemaDownloadRecord(title, _source, 0),
          selections: _selections(title, [6, 7, 8, 9, 10, 11, 12]),
        ),
      ]);
      expect(counts, [6, 6]);
      await _until(() => manager.requests.length == 12);
      expect(repository.getRecord(media.key)!.episodes.keys.toSet(), {
        for (var i = 1; i <= 12; i++) i,
      });
      expect(manager.requests.map((r) => r.episodeNumber).toSet().length, 12);
      expect(
        manager.requests.every(
          (r) => r.httpHeaders['User-Agent'] == 'fixture-agent',
        ),
        isTrue,
      );
      expect(resolver.pending, isEmpty);
      expect(
        await controller.startEpisodeDownloads(
          media: media,
          selections: _selections(title, [1, 2]),
        ),
        0,
      );
    },
  );
  test(
    'HTML downloads resolve in background; paused late result cannot enqueue',
    () async {
      final title = _title(html: true);
      final media = cinemaDownloadRecord(title, _source, 0);
      await controller.startEpisodeDownloads(
        media: media,
        selections: _selections(title, [1]),
      );
      await _until(() => resolver.pending.length == 1);
      await controller.pauseDownload(0, media.pluginName, 1);
      resolver.pending[0].complete(
        const VideoSource(
          url: 'https://cdn.invalid/old.m3u8',
          offset: 0,
          type: VideoSourceType.online,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(manager.requests, isEmpty);
      expect(
        repository.getRecord(media.key)!.episodes[1]!.status,
        DownloadStatus.paused,
      );
      await controller.retryDownload(
        bangumiId: 0,
        pluginName: media.pluginName,
        episodeNumber: 1,
      );
      await _until(() => resolver.pending.length == 2);
      resolver.pending[1].complete(
        const VideoSource(
          url: 'https://cdn.invalid/new.m3u8',
          offset: 0,
          type: VideoSourceType.online,
        ),
      );
      await _until(() => manager.requests.isNotEmpty);
      expect(manager.requests.single.m3u8Url, endsWith('/new.m3u8'));
      expect(
        manager.requests.single.httpHeaders['Referer'],
        title.routes[0].episodes[0].url,
      );
    },
  );
  test('failed cinema task resolves a fresh URL on retry', () async {
    final title = _title(html: true);
    final media = cinemaDownloadRecord(title, _source, 0);
    await controller.startEpisodeDownloads(
      media: media,
      selections: _selections(title, [1]),
    );
    await _until(() => resolver.pending.length == 1);
    resolver.pending[0].completeError(
      const VideoSourceTimeoutException(Duration(seconds: 25)),
    );
    await _until(
      () =>
          repository.getRecord(media.key)!.episodes[1]!.status ==
          DownloadStatus.failed,
    );
    await controller.retryDownload(
      bangumiId: 0,
      pluginName: media.pluginName,
      episodeNumber: 1,
    );
    await _until(() => resolver.pending.length == 2);
    resolver.pending[1].complete(
      const VideoSource(
        url: 'https://cdn.invalid/retry.m3u8',
        offset: 0,
        type: VideoSourceType.online,
      ),
    );
    await _until(() => manager.requests.isNotEmpty);
    expect(manager.requests.single.m3u8Url, endsWith('/retry.m3u8'));
  });
  test(
    'video direct mode applies to playback/download config without changing API proxy',
    () async {
      await GStorage.putSetting(SettingsKeys.proxyEnable, true);
      await GStorage.putSetting(SettingsKeys.proxyUrl, 'http://127.0.0.1:7897');
      await GStorage.putSetting(SettingsKeys.mediaDirectConnection, false);
      final uri = Uri.parse('https://fixture.invalid/video');
      expect(NetworkConfig.forMedia().proxyForUri(uri)?.port, 7897);
      expect(NetworkConfig.forMedia().allowBadCertificates, isFalse);
      await GStorage.putSetting(SettingsKeys.mediaDirectConnection, true);
      expect(NetworkConfig.forMedia().proxyForUri(uri), isNull);
      expect(NetworkConfig.forMedia().followSystemProxy, isFalse);
      expect(NetworkConfig.fromSettings().proxyForUri(uri)?.port, 7897);
      await GStorage.putSetting(SettingsKeys.mediaDirectConnection, false);
      await GStorage.putSetting(SettingsKeys.proxyEnable, false);
    },
  );
}
