import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_library_backup.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

BangumiItem _subject() => BangumiItem(
  id: 1,
  type: 2,
  name: 'Anime',
  nameCn: '动漫',
  summary: '',
  airDate: '2026-01-01',
  airWeekday: 1,
  rank: 1,
  images: {},
  tags: [],
  alias: [],
  ratingScore: 8,
  votes: 1,
  votesCount: [],
  info: '',
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late PathProviderPlatform originalPaths;
  late CinemaStore store;
  const source = CinemaSource(
    id: 'a',
    name: 'User source',
    kind: CinemaSourceKind.maccms,
    url: 'https://a.example/api.php/provide/vod',
  );
  const title = CinemaTitle(
    id: '1',
    sourceId: 'a',
    title: '电影',
    year: '2020',
    category: '电影',
  );
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('naku-backup-hive-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    Hive.init('${root.path}/hive');
    await GStorage.init();
  });
  setUp(() async {
    await GStorage.histories.clear();
    await GStorage.collectibles.clear();
    await GStorage.shieldList.clear();
    await GStorage.downloads.clear();
    await GStorage.putSetting(SettingsKeys.downloadDirectory, '');
    store = CinemaStore(
      file: File(
        '${root.path}/library-${DateTime.now().microsecondsSinceEpoch}.json',
      ),
      defaults: [source],
    );
    await store.load();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });
  test(
    'download migration rebases copied files, pauses missing files and preserves active local tasks',
    () async {
      final backup = CinemaLibraryBackup(store, support: root);
      final data = await backup.snapshot();
      final record = DownloadRecord(9, '下载作品', '', 'Rule', {
        for (var i = 1; i <= 3; i++)
          i: DownloadEpisode(
            i,
            '第$i集',
            0,
            DownloadStatus.completed,
            1,
            2,
            2,
            '/old-computer/downloads/9_Rule/$i/local.m3u8',
            '/old-computer/downloads/9_Rule/$i',
            'https://video.example/$i.m3u8',
            DateTime.utc(2026),
            '',
            100,
            'https://video.example/$i',
          ),
      }, DateTime.utc(2026));
      await GStorage.downloads.put(record.key, record);
      final text = await backup.export();
      expect(text, isNot(contains('/old-computer')));
      await GStorage.downloads.clear();
      final copied = File('${root.path}/downloads/9_Rule/1/local.m3u8');
      await copied.parent.create(recursive: true);
      await copied.writeAsString('#EXTM3U\n#EXT-X-ENDLIST');
      final active = DownloadEpisode(
        3,
        '第3集',
        0,
        DownloadStatus.downloading,
        .5,
        2,
        1,
        '',
        '${root.path}/active',
        'https://video.example/3.m3u8',
        null,
        '',
        50,
        'https://video.example/3',
      );
      await GStorage.downloads.put(
        record.key,
        DownloadRecord(9, '下载作品', '', 'Rule', {3: active}, DateTime.utc(2026)),
      );
      await backup.restore(text);
      final restored = GStorage.downloads.get(record.key)!;
      expect(restored.episodes[1]!.status, DownloadStatus.completed);
      expect(restored.episodes[1]!.localM3u8Path, copied.path);
      expect(restored.episodes[2]!.status, DownloadStatus.paused);
      expect(restored.episodes[3]!.status, DownloadStatus.downloading);
      expect(restored.episodes[3]!.downloadDirectory, active.downloadDirectory);
      expect((data['downloads'] as List), isEmpty);
    },
  );
  test(
    'download backup rejects path escape and symlink adoption before modifying records',
    () async {
      final backup = CinemaLibraryBackup(store, support: root);
      final record = DownloadRecord(12, '下载作品', '', 'Rule', {
        1: DownloadEpisode(
          1,
          '一',
          0,
          DownloadStatus.completed,
          1,
          1,
          1,
          'local.m3u8',
          '',
          'https://video.example/a.m3u8',
          null,
          '',
          50,
          '',
        ),
      }, DateTime.utc(2026));
      await GStorage.downloads.put(record.key, record);
      final data = CinemaLibraryBackup.decode(await backup.export());
      (data['downloads'] as List).first['episodes'][0]['file'] =
          '../../outside';
      expect(
        () => CinemaLibraryBackup.decode(CinemaLibraryBackup.encode(data)),
        throwsFormatException,
      );
      final text = await backup.export();
      await GStorage.downloads.clear();
      final outside = await Directory('${root.path}/outside').create();
      final link = Link('${root.path}/downloads/12_Rule');
      await link.parent.create(recursive: true);
      await link.create(outside.path);
      await expectLater(backup.restore(text), throwsFormatException);
      expect(GStorage.downloads.values, isEmpty);
      expect(await outside.exists(), isTrue);
      await link.delete();
      await GStorage.putSetting(
        SettingsKeys.downloadDirectory,
        '/local-picked',
      );
      await GStorage.putSetting(
        SettingsKeys.downloadDirectoryBookmark,
        'local-bookmark',
      );
      final settings = GStorage.exportPortableSettings(credentials: true);
      expect(
        settings.containsKey(SettingsKeys.downloadDirectory.name),
        isFalse,
      );
      expect(
        settings.containsKey(SettingsKeys.downloadDirectoryBookmark.name),
        isFalse,
      );
      await GStorage.importPortableSettings({
        SettingsKeys.downloadDirectory.name: '/untrusted',
        SettingsKeys.downloadDirectoryBookmark.name: 'foreign-bookmark',
      });
      expect(
        GStorage.getSetting(SettingsKeys.downloadDirectory),
        '/local-picked',
      );
    },
  );
  test(
    'portable backup round trips movies, anime, rules, settings and themes without credentials by default',
    () async {
      await store.toggleFavorite(title);
      await store.recordProgress(
        title: title,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 40,
      );
      await store.setExtra('subscriptions', [
        {'url': 'https://config.example/sources.json', 'name': 'test'},
      ]);
      await GStorage.putSetting(SettingsKeys.defaultPlaySpeed, 1.5);
      await GStorage.putSetting(
        SettingsKeys.bangumiAccessToken,
        'private-test-token',
      );
      final history = History(
        _subject(),
        1,
        'Rule',
        DateTime.utc(2026, 1, 1),
        '/anime',
        '第一集',
      )..progresses = {1: Progress(1, 0, 12000, updatedAtMs: 100)};
      await GStorage.histories.put(history.key, history);
      await GStorage.putCollectible(
        CollectedBangumi(_subject(), DateTime.utc(2026, 1, 1), 2),
      );
      await GStorage.shieldList.put(0, 'filter');
      await Directory('${root.path}/plugins/v2').create(recursive: true);
      await File('${root.path}/plugins/v2/plugins.json').writeAsString(
        jsonEncode([
          {'name': 'Rule', 'version': '1', 'baseURL': 'https://anime.example'},
        ]),
      );
      await Directory('${root.path}/cinema').create(recursive: true);
      await File(
        '${root.path}/cinema/appearance-v1.json',
      ).writeAsString('{"version":1,"backgroundOpacity":0.6}');
      await File(
        '${root.path}/cinema/douban-themes-v1.json',
      ).writeAsString('{"version":1,"topics":{"movie":["科幻","公路"]}}');
      final backup = CinemaLibraryBackup(store, support: root);
      final text = await backup.export();
      expect(text, isNot(contains('private-test-token')));
      expect(
        await backup.export(credentials: true),
        contains('private-test-token'),
      );
      final data = CinemaLibraryBackup.decode(text);
      expect((data['rules'] as List).length, 1);
      expect(data['auxiliary'], contains('cinema/douban-themes-v1.json'));
      await store.removeFavorite(title);
      await GStorage.histories.clear();
      await GStorage.collectibles.clear();
      await GStorage.shieldList.clear();
      await GStorage.putSetting(SettingsKeys.defaultPlaySpeed, 1.0);
      final recovery = await backup.restore(text);
      expect(await recovery.exists(), true);
      expect(store.favorites.single.title, '电影');
      expect(store.history.single.positionSeconds, 40);
      expect(
        GStorage.histories.get(history.key)!.progresses[1]!.progress.inSeconds,
        12,
      );
      expect(GStorage.collectibles.get(1)!.type, 2);
      expect(GStorage.shieldList.values, ['filter']);
      expect(GStorage.getSetting(SettingsKeys.defaultPlaySpeed), 1.5);
      expect(
        GStorage.getSetting(SettingsKeys.bangumiAccessToken),
        'private-test-token',
      );
      expect(store.extras['subscriptions'], isNotEmpty);
    },
  );
  test(
    'merging old anime records preserves newer whole history and per-episode progress',
    () async {
      final old = History(
        _subject(),
        1,
        'Rule',
        DateTime.utc(2026, 1, 1),
        '/old',
        '第一集',
      )..progresses = {1: Progress(1, 0, 10000, updatedAtMs: 100)};
      await GStorage.histories.put(old.key, old);
      final backup = CinemaLibraryBackup(store, support: root);
      final text = await backup.export();
      final recent =
          History(
              _subject(),
              2,
              'Rule',
              DateTime.utc(2026, 2, 1),
              '/new',
              '第二集',
            )
            ..progresses = {
              1: Progress(1, 0, 25000, updatedAtMs: 200),
              2: Progress(2, 1, 30000, updatedAtMs: 300),
            };
      await GStorage.histories.put(recent.key, recent);
      await GStorage.putCollectible(
        CollectedBangumi(_subject(), DateTime.utc(2026, 2, 1), 1),
      );
      await backup.restore(text);
      final merged = GStorage.histories.get(recent.key)!;
      expect(merged.lastWatchEpisode, 2);
      expect(merged.lastSrc, '/new');
      expect(merged.progresses[1]!.progress.inSeconds, 25);
      expect(merged.progresses[2]!.progress.inSeconds, 30);
      expect(GStorage.collectibles.get(1)!.type, 1);
    },
  );
  test(
    'invalid auxiliary settings are rejected before any library mutation',
    () async {
      await store.toggleFavorite(title);
      final backup = CinemaLibraryBackup(store, support: root);
      final data = await backup.snapshot();
      data['auxiliary'] = {
        'cinema/appearance-v1.json': {'version': 1, 'backgroundOpacity': 7},
      };
      await expectLater(
        backup.restore(CinemaLibraryBackup.encode(data)),
        throwsFormatException,
      );
      expect(store.favorites.single.title, '电影');
    },
  );
  test(
    'a progress update arriving during import survives the queued restoration',
    () async {
      final data = await store.exportLibrary();
      final restore = store.restoreLibrary(data);
      final progress = store.recordProgress(
        title: title,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 80,
      );
      await Future.wait([restore, progress]);
      expect(store.history.single.positionSeconds, 80);
    },
  );
}
