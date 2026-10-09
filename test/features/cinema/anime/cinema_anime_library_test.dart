import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/features/cinema/anime/cinema_anime_library.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_unified_library.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

BangumiItem _item(int id) => BangumiItem.fromJson({
  'id': id,
  'type': 2,
  'rating': {
    'rank': 0,
    'score': 8.0,
    'total': 0,
    'count': {for (var i = 1; i <= 10; i++) '$i': 0},
  },
  'summary': '',
  'name': 'Anime $id',
  'name_cn': '动漫 $id',
  'date': '2022-01-01',
  'images': <String, String>{},
});
History _record(
  int id,
  String source,
  int day, {
  String kind = HistoryEntryKind.online,
}) => History(
  _item(id),
  2,
  source,
  DateTime(2026, 10, day),
  'https://fixture.invalid/$id',
  '第二话',
  entryKind: kind,
)..progresses[2] = Progress(2, 0, day * 60000);

void main() {
  late Directory dir;
  late PathProviderPlatform oldPaths;
  late CinemaAnimeLibrary anime;
  setUpAll(() async {
    Logger.level = Level.off;
    dir = await Directory.systemTemp.createTemp('naku-anime-library-');
    oldPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    Hive.init(dir.path);
    await GStorage.init();
  });
  setUp(() async {
    await GStorage.collectibles.clear();
    await GStorage.histories.clear();
    await GStorage.collectChanges.clear();
    anime = CinemaAnimeLibrary();
  });
  tearDown(() => anime.dispose());
  tearDownAll(() async {
    await Hive.close();
    PathProviderPlatform.instance = oldPaths;
    await dir.delete(recursive: true);
  });

  test(
    'all old collection statuses are retained as simple favorites',
    () async {
      for (var type = 1; type <= 5; type++) {
        await GStorage.putCollectible(
          CollectedBangumi(_item(type), DateTime(2026, 10, type), type),
        );
      }
      expect(anime.favorites.map((entry) => entry.bangumiItem.id), [
        5,
        4,
        3,
        2,
        1,
      ]);
      expect(GStorage.collectibles.values.map((entry) => entry.type), [
        1,
        2,
        3,
        4,
        5,
      ]);
      final undo = await anime.removeFavorite(_item(3));
      expect(anime.favorites.length, 4);
      expect(await undo!.restore(), isTrue);
      expect(GStorage.collectibles.get(3)!.type, 3);
      expect(GStorage.collectibles.get(3)!.time, DateTime(2026, 10, 3));
      expect(await undo.restore(), isFalse);
    },
  );

  test(
    'favorite undo never overwrites a newer favorite or sync change',
    () async {
      await GStorage.putCollectible(
        CollectedBangumi(_item(1), DateTime(2026, 10, 1), 4),
      );
      final undo = await anime.removeFavorite(_item(1));
      await GStorage.putCollectible(
        CollectedBangumi(_item(1), DateTime(2026, 10, 9), 1),
      );
      expect(await undo!.restore(), isFalse);
      expect(GStorage.collectibles.get(1)!.type, 1);
      expect(GStorage.collectibles.get(1)!.time, DateTime(2026, 10, 9));
    },
  );

  test(
    'one history entry per subject keeps newest source, progress and offline identity',
    () async {
      for (final record in [
        _record(1, 'a', 1),
        _record(1, 'b', 5),
        _record(2, 'c', 3),
        _record(1, 'b', 7, kind: HistoryEntryKind.offline),
      ]) {
        await GStorage.histories.put(record.key, record);
      }
      expect(anime.history.length, 2);
      expect(anime.history.first.entryKind, HistoryEntryKind.offline);
      expect(anime.history.first.progresses[2]!.progress.inMinutes, 7);
      final undo = await anime.removeHistory(_item(1));
      expect(GStorage.histories.values.map((h) => h.bangumiItem.id), [2]);
      expect(await undo!.restore(), isTrue);
      expect(GStorage.histories.length, 4);
      expect(anime.history.first.entryKind, HistoryEntryKind.offline);
      final stale = await anime.removeHistory(_item(1));
      final newer = _record(1, 'new source', 9);
      await GStorage.histories.put(newer.key, newer);
      expect(await stale!.restore(), isFalse);
      expect(anime.history.first.adapterName, 'new source');
      expect(GStorage.histories.length, 2);
    },
  );

  testWidgets(
    'main history interleaves movie and anime and resumes the original anime record',
    (tester) async {
      late CinemaStore store;
      addTearDown(() => store.dispose());
      final older = _record(1, 'source a', 1),
          latest = _record(1, 'source b', 9);
      await tester.runAsync(() async {
        store = CinemaStore(
          file: File('${dir.path}/ui-library.json'),
          defaults: const [],
        );
        await store.load();
        const movie = CinemaTitle(
          id: 'movie',
          sourceId: 'fixture',
          title: '电影记录',
          category: '电影',
        );
        await GStorage.histories.put(older.key, older);
        await GStorage.histories.put(latest.key, latest);
        await store.recordProgress(
          title: movie,
          routeIndex: 0,
          episodeIndex: 0,
          positionSeconds: 300,
        );
      });
      History? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaUnifiedLibrary(
              store: store,
              anime: anime,
              history: true,
              filters: const CinemaFilters(),
              onFilters: (_) {},
              titleCard: (title) => Text(title.title),
              poster: (_, _, _) => const SizedBox(),
              onCinemaPlay: (_) {},
              onAnimePlay: (record) => selected = record,
              sourceName: (_) => 'fixture',
            ),
          ),
        ),
      );
      expect(find.text('电影记录'), findsOneWidget);
      expect(find.text('动漫 1'), findsOneWidget);
      expect(find.textContaining('source b'), findsOneWidget);
      await tester.tap(find.text('动漫 1'));
      expect(selected!.key, latest.key);
      expect(selected!.progresses[2]!.progress.inMinutes, 9);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}
