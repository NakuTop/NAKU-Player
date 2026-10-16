import 'dart:convert';
import 'package:kazumi/pages/settings/sync/sync_settings_page.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/features/cinema/cinema_nas_page.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_nas_sync.dart';
import 'package:kazumi/features/cinema/cinema_nas_sync_model.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const account =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const deviceA = '00000000-0000-4000-8000-000000000001';
const deviceB = '00000000-0000-4000-8000-000000000002';
const movie = CinemaTitle(
  id: '1',
  sourceId: 'a',
  title: '电影',
  year: '2020',
  category: '电影',
);
const other = CinemaTitle(
  id: '2',
  sourceId: 'a',
  title: '剧集',
  year: '2021',
  category: '剧集',
);

class Paths extends PathProviderPlatform {
  Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class Cloud extends CinemaNASClient {
  final Map<String, Map<String, dynamic>> revisions = {};
  bool fail = false, corrupt = false, loseAck = false;
  int pushes = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    if (method == 'savedLogin') return {};
    if (method == 'login') return {'namespace': account, 'name': 'Test NAS'};
    if (method == 'connectionInfo') return {};
    if (method == 'libraries') return {'media_lib_set_arr': []};
    if (method == 'catalog') return {'video_arr': [], 'is_last_page': true};
    if (fail) throw const SocketException('offline');
    if (method == 'syncPull') {
      return {
        'path': '/home/test/NakuPlayer',
        'documents': corrupt
            ? ['bad-json']
            : [for (final v in revisions.values) v['document']],
      };
    }
    if (method == 'syncPush') {
      pushes++;
      final id = '${args!['device']}-${args['sequence']}';
      if (revisions.containsKey(id)) {
        expect(revisions[id]!['document'], args['document']);
      }
      revisions[id] = Map.from(args);
      if (loseAck) {
        loseAck = false;
        throw const SocketException("lost acknowledgment");
      }
      return {};
    }
    throw StateError(method);
  }
}

Future<void> settled(CinemaNASSync sync) async {
  for (var i = 0; i < 2000 && sync.busy; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(sync.busy, isFalse);
}

BangumiItem subject() => BangumiItem(
  id: 101,
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
  test(
    'two writers converge, deletions survive a stale third installation and wrong accounts fail',
    () {
      final a = CinemaNASSyncState(account, deviceA),
          b = CinemaNASSyncState(account, deviceB);
      a.observe({'cf:${movie.key}': movie.toJson()});
      b.observe({'cf:${other.key}': other.toJson()});
      a.merge(a.decode(b.encode()));
      b.merge(b.decode(a.encode()));
      expect(a.visible.length, 2);
      expect(b.visible, a.visible);
      a.baseline = Map.from(a.visible);
      a.observe({'cf:${other.key}': other.toJson()}, now: 100);
      b.merge(b.decode(a.encode()));
      expect(b.visible.containsKey('cf:${movie.key}'), isFalse);
      final stale = CinemaNASSyncState(
        account,
        '00000000-0000-4000-8000-000000000003',
      );
      stale.observe({'cf:${movie.key}': movie.toJson()});
      b.merge(b.decode(stale.encode()));
      expect(b.visible.containsKey('cf:${movie.key}'), isFalse);
      expect(
        () => CinemaNASSyncState('other', deviceB).decode(a.encode()),
        throwsFormatException,
      );
    },
  );
  test(
    'progress takes a complete latest episode snapshot and equal clocks converge',
    () {
      Map<String, dynamic> record(int ep, int pos) => CinemaHistory(
        title: movie,
        routeIndex: 0,
        episodeIndex: ep,
        positionSeconds: pos,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(10),
      ).toJson();
      final a = CinemaNASSyncState(account, deviceA),
          b = CinemaNASSyncState(account, deviceB);
      a.observe({'ch:${movie.key}': record(1, 300)});
      b.observe({'ch:${movie.key}': record(2, 20)});
      a.merge(a.decode(b.encode()));
      b.merge(b.decode(a.encode()));
      expect(a.visible, b.visible);
      expect(a.visible['ch:${movie.key}']['episodeIndex'], 2);
      expect(a.visible['ch:${movie.key}']['positionSeconds'], 20);
    },
  );

  late Directory root;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('naku-nas-sync-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = Paths(root.path);
    Hive.init('${root.path}/hive');
    await GStorage.init();
  });
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
  });
  test(
    'account sync uploads cinema and anime, restores another device, propagates removals, retries offline',
    () async {
      await GStorage.histories.clear();
      await GStorage.collectibles.clear();
      final cloud = Cloud();
      final a = CinemaStore(file: File('${root.path}/a.json'), defaults: []);
      await a.load();
      await a.toggleFavorite(movie);
      await a.recordProgress(
        title: movie,
        routeIndex: 0,
        episodeIndex: 2,
        positionSeconds: 123,
      );
      await GStorage.putCollectible(
        CollectedBangumi(
          subject(),
          DateTime.fromMillisecondsSinceEpoch(1234),
          2,
        ),
      );
      final anime = History(
        subject(),
        0,
        'test',
        DateTime.fromMillisecondsSinceEpoch(5678),
        '',
        '第1集',
      );
      await GStorage.histories.put(anime.key, anime);
      final sa = CinemaNASSync(
        a,
        client: cloud,
        file: File('${root.path}/sa.json'),
      );
      await sa.bind(account);
      await settled(sa);
      expect(sa.status, '全部历史和收藏已同步至 NAS');
      final documents = cloud.revisions.values
          .map((r) => r['document'] as String)
          .join();
      expect(documents, contains('af:101'));
      expect(documents, contains('ah:'));
      expect(documents, isNot(contains('password')));
      sa.pause();
      await GStorage.histories.clear();
      await GStorage.collectibles.clear();
      final b = CinemaStore(file: File('${root.path}/b.json'), defaults: []);
      await b.load();
      final sb = CinemaNASSync(
        b,
        client: cloud,
        file: File('${root.path}/sb.json'),
      );
      await sb.bind(account);
      await settled(sb);
      expect(b.favorites.single.key, movie.key);
      expect(b.history.single.positionSeconds, 123);
      expect(GStorage.collectibles.get(101)?.type, 2);
      expect(GStorage.histories.length, 1);
      await b.toggleFavorite(movie);
      await GStorage.deleteCollectible(101);
      cloud.fail = true;
      await sb.sync();
      expect(sb.status, contains('待同步'));
      expect(await File('${root.path}/sb.json').exists(), isTrue);
      cloud.fail = false;
      await sb.sync();
      await sa.bind(account);
      await settled(sa);
      expect(a.favorites, isEmpty);
      expect(GStorage.collectibles.isEmpty, isTrue);
      final before = cloud.pushes;
      await sa.bind(
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      );
      await sa.sync();
      expect(cloud.pushes, before);
      expect(sa.status, contains('另一个'));
      sa.dispose();
      sb.dispose();
      await a.flush();
      await b.flush();
      a.dispose();
      b.dispose();
    },
  );
  testWidgets('NAS login exposes account sync status and disable control', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cloud = Cloud();
    final store = CinemaStore(
      file: File('${root.path}/panel-library.json'),
      defaults: [],
    );
    await tester.runAsync(() => store.load());
    final sync = CinemaNASSync(
      store,
      client: cloud,
      file: File('${root.path}/panel-sync.json'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaNASPage(client: cloud, store: store, sync: sync),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'NAS 账号'), 'viewer');
    await tester.enterText(find.widgetWithText(TextField, 'NAS 密码'), 'fixture');
    await tester.ensureVisible(find.text('连接影视中心'));
    await tester.runAsync(() async {
      await tester.tap(find.text('连接影视中心'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    for (var i = 0; i < 100 && (sync.lastSuccess == null || sync.busy); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('账号与统一同步设置'), findsOneWidget);
    expect(find.byType(SwitchListTile), findsNothing);
    await tester.pumpWidget(MaterialApp(home: SyncSettingsPage(sync: sync)));
    await tester.pumpAndSettle();
    expect(find.text('自动同步全部历史和收藏'), findsOneWidget);
    expect(find.text('全部历史和收藏已同步至 NAS'), findsOneWidget, reason: sync.status);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(sync.enabled, isFalse);
    await tester.pumpWidget(const SizedBox());
    sync.dispose();
    await tester.runAsync(() => store.flush());
    store.dispose();
  });
  test('restart retries the exact unacknowledged immutable revision', () async {
    final cloud = Cloud()..loseAck = true;
    final store = CinemaStore(
      file: File('${root.path}/restart-library.json'),
      defaults: [],
    );
    await store.load();
    await store.toggleFavorite(movie);
    final file = File('${root.path}/restart-sync.json');
    final first = CinemaNASSync(store, client: cloud, file: file);
    await first.bind(account);
    await settled(first);
    expect(first.status, contains('待同步'));
    final durable = jsonDecode(await file.readAsString()) as Map;
    expect(durable['pending'], isNotNull);
    final before = cloud.revisions.length;
    first.dispose();
    final restarted = CinemaNASSync(store, client: cloud, file: file);
    await restarted.start();
    await settled(restarted);
    expect(restarted.status, '全部历史和收藏已同步至 NAS');
    expect(cloud.revisions.length, before);
    expect((jsonDecode(await file.readAsString()) as Map)['pending'], isNull);
    restarted.dispose();
    await store.flush();
    store.dispose();
  });
  test(
    'corrupt remote does not erase local records; conditional apply preserves a racing edit',
    () async {
      final store = CinemaStore(
        file: File('${root.path}/race.json'),
        defaults: [],
      );
      await store.load();
      await store.toggleFavorite(movie);
      final cloud = Cloud()..corrupt = true;
      final sync = CinemaNASSync(
        store,
        client: cloud,
        file: File('${root.path}/race-sync.json'),
      );
      await sync.bind(account);
      await settled(sync);
      expect(sync.status, contains('校验失败'));
      expect(store.favorites.single.key, movie.key);
      final old = {'cf:${movie.key}': movie.toJson()};
      await store.toggleFavorite(movie);
      await store.toggleFavorite(other);
      final skipped = await store.applyAccountSync(old, {});
      expect(skipped, contains('cf:${movie.key}'));
      expect(store.favorites.single.key, other.key);
      sync.dispose();
      await store.flush();
      store.dispose();
    },
  );
}
