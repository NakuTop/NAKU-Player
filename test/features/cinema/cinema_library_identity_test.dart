import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';

CinemaTitle _title(
  String source, {
  String id = '42',
  String name = '星际穿越',
  String year = '2014',
  String category = '科幻片',
  String douban = '1889243',
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: category,
  doubanId: douban,
  routes: [
    CinemaRoute(
      name: '$source-route',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://$source.example/movie.m3u8'),
      ],
    ),
  ],
);

CinemaSource _source(String id, {bool enabled = true}) => CinemaSource(
  id: id,
  name: 'source-$id',
  kind: CinemaSourceKind.maccms,
  url: 'https://$id.example/api',
  enabled: enabled,
  requestHeaders: {'Referer': 'https://$id.example/custom'},
);

Map<String, dynamic> _history(CinemaTitle title, int day, int progress) =>
    CinemaHistory(
      title: title,
      routeIndex: 0,
      episodeIndex: 0,
      positionSeconds: progress,
      durationSeconds: 10000,
      updatedAt: DateTime.utc(2026, 10, day),
    ).toJson();

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-work-library-');
    file = File('${directory.path}/library-v1.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  CinemaStore store({List<CinemaSourcePack> packs = const []}) {
    final value = CinemaStore(
      file: file,
      defaults: [_source('a'), _source('b')],
      sourcePacks: packs,
    );
    addTearDown(value.dispose);
    return value;
  }

  Future<String> write({
    List<Map<String, dynamic>> favorites = const [],
    List<Map<String, dynamic>> history = const [],
    List<Map<String, dynamic>>? sources,
  }) async {
    final text =
        '${const JsonEncoder.withIndent('    ').convert({
          'version': 1,
          'sources': sources ?? [_source('a', enabled: false).toJson(), _source('b').toJson()],
          'favorites': favorites,
          'history': history,
          'customPreference': {'selectedSource': 'b', 'remember': true},
        })}\n';
    await file.writeAsString(text);
    return text;
  }

  Future<Map<String, dynamic>> saved() async =>
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map);

  test(
    'legacy duplicates consolidate with exact backup and latest complete progress',
    () async {
      final a = _title('a');
      final b = _title('b', name: '星际穿越（英语版）');
      final favoriteA = {...a.toJson(), 'myNote': 'favorite A'};
      final favoriteB = {
        ...b.toJson(),
        'otherNote': {'keep': true},
      };
      final oldProgress = {..._history(a, 1, 9900), 'customProgress': 'older'};
      final latestProgress = {
        ..._history(b, 3, 123),
        'customProgress': 'latest',
      };
      final sourceA = {
        ..._source('a', enabled: false).toJson(),
        'customSourceOption': 9,
      };
      final original = await write(
        favorites: [favoriteA, favoriteB],
        history: [oldProgress, latestProgress],
        sources: [sourceA, _source('b').toJson()],
      );
      final library = store();
      await Future.wait([library.load(), library.load()]);
      expect(library.favorites, hasLength(1));
      expect(library.history, hasLength(1));
      expect(library.history.single.title.key, b.key);
      expect(
        library.history.single.positionSeconds,
        123,
        reason: 'Use latest watch, not largest position.',
      );
      expect(library.history.single.title.routes.single.name, 'b-route');
      expect(library.isFavorite(a), isTrue);
      expect(library.isFavorite(b), isTrue);
      expect(
        await File('${file.path}.pre-work-dedup-v1.bak').readAsString(),
        original,
      );
      final raw = await saved();
      expect((raw['favorites'] as List).single['myNote'], 'favorite A');
      expect((raw['favorites'] as List).single['nakuWorkEntriesV1'], [
        favoriteB,
      ]);
      expect((raw['history'] as List).single['customProgress'], 'latest');
      expect((raw['history'] as List).single['nakuWorkEntriesV1'], [
        oldProgress,
      ]);
      expect((raw['sources'] as List).first, sourceA);
      expect(raw['customPreference'], {
        'selectedSource': 'b',
        'remember': true,
      });
      final timestamp = await file.lastModified();
      final encoded = await file.readAsString();
      final reopened = store();
      await reopened.load();
      expect(await file.readAsString(), encoded);
      expect(await file.lastModified(), timestamp);
      expect(reopened.history.single.positionSeconds, 123);
    },
  );

  test(
    'favorite state and removal apply to a different source variant',
    () async {
      final library = store();
      await library.load();
      final a = _title('a'), b = _title('b');
      await library.toggleFavorite(a);
      expect(library.isFavorite(b), isTrue);
      await library.toggleFavorite(b);
      expect(library.favorites, isEmpty);
      final reopened = store();
      await reopened.load();
      expect(reopened.isFavorite(a), isFalse);
      await reopened.toggleFavorite(b);
      expect(reopened.favorites.single.key, b.key);
      expect(reopened.isFavorite(a), isTrue);
    },
  );

  test(
    'switching source keeps only latest history and cannot resume wrong source',
    () async {
      final library = store();
      await library.load();
      final a = _title('a'), b = _title('b');
      await library.recordProgress(
        title: a,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 456,
      );
      await library.recordProgress(
        title: b,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 12,
      );
      expect(library.history, hasLength(1));
      expect(library.historyFor(a), isNull);
      expect(library.historyFor(b)?.positionSeconds, 12);
      final workHistory = library.historyForWork(a)!;
      expect(workHistory.title.key, b.key);
      expect(cinemaResumeSelection(a, workHistory), isNull);
      expect(cinemaResumeSelection(b, workHistory), (
        routeIndex: 0,
        episodeIndex: 0,
      ));
      final reopened = store();
      await reopened.load();
      expect(reopened.historyFor(a), isNull);
      expect(reopened.historyForWork(a)?.title.key, b.key);
      await reopened.removeHistory(a);
      expect(reopened.history, isEmpty);
    },
  );

  test(
    'years, seasons and film versus series never collapse even with copied IDs',
    () async {
      final works = [
        _title('a', name: '流人第一季', year: '2022', category: '欧美剧'),
        _title('b', name: '流人第二季', year: '2022', category: '欧美剧'),
        _title('c', name: '流人第一季', year: '2023', category: '欧美剧'),
        _title('d', name: '流人第一季', year: '2022', category: '剧情片'),
      ];
      final original = await write(
        favorites: works.map((t) => t.toJson()).toList(),
        history: works.indexed
            .map((t) => _history(t.$2, t.$1 + 1, 100))
            .toList(),
      );
      final library = store();
      await library.load();
      expect(library.favorites, hasLength(4));
      expect(library.history, hasLength(4));
      expect(await file.readAsString(), original);
      expect(
        await File('${file.path}.pre-work-dedup-v1.bak').exists(),
        isFalse,
      );
      await library.toggleFavorite(works.first);
      expect(library.favorites, hasLength(3));
      expect(library.isFavorite(works.last), isTrue);
    },
  );

  test(
    'an early no-ID record cannot bridge two conflicting identified works',
    () async {
      final unknown = _title('a', douban: '');
      final first = _title('b', douban: '111');
      final second = _title('c', douban: '222');
      await write(
        favorites: [unknown.toJson(), first.toJson(), second.toJson()],
        history: [
          _history(unknown, 3, 30),
          _history(first, 2, 20),
          _history(second, 1, 10),
        ],
      );
      final library = store();
      await library.load();
      expect(library.favorites, hasLength(3));
      expect(library.history, hasLength(3));
      final ambiguous = _title('d', douban: '');
      expect(library.isFavorite(ambiguous), isFalse);
      expect(library.historyForWork(ambiguous), isNull);
      await library.toggleFavorite(_title('e', douban: '111'));
      expect(library.isFavorite(first), isFalse);
      expect(library.isFavorite(second), isTrue);
      expect(library.isFavorite(unknown), isTrue);
    },
  );

  test(
    'missing year/category does not merge unrelated same-name source IDs',
    () async {
      final a = _title('a', year: '', category: '', douban: '');
      final b = _title('b', year: '', category: '', douban: '');
      await write(favorites: [a.toJson(), b.toJson()]);
      final library = store();
      await library.load();
      expect(library.favorites, hasLength(2));
      await library.toggleFavorite(a);
      expect(library.favorites.single.key, b.key);
    },
  );

  test(
    'source upgrade and consolidation preserve preferences and unknown fields after later writes',
    () async {
      final a = _title('a'), b = _title('b');
      final sourceMap = {
        ..._source('a', enabled: false).toJson(),
        'pluginSettings': {'privateChoice': 5},
      };
      final original = await write(
        favorites: [a.toJson(), b.toJson()],
        sources: [sourceMap],
      );
      final pack = CinemaSourcePack(
        id: 'fixture-pack',
        sources: [_source('b'), _source('c')],
      );
      final library = store(packs: [pack]);
      await library.load();
      expect(await File('${file.path}.pre-0.3.0.bak').readAsString(), original);
      expect(
        await File('${file.path}.pre-work-dedup-v1.bak').readAsString(),
        original,
      );
      expect(library.sources.map((s) => s.id), ['a', 'b', 'c']);
      await library.recordProgress(
        title: a,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 90,
      );
      var raw = await saved();
      expect((raw['sources'] as List).first, sourceMap);
      expect(raw['appliedSourcePacks'], ['fixture-pack']);
      await library.saveSource(
        _source('a', enabled: false).copyWith(requestHeaders: {}),
      );
      raw = await saved();
      expect(
        (raw['sources'] as List).first.containsKey('headers'),
        isFalse,
        reason: 'Preservation must not resurrect an explicitly removed header.',
      );
      expect((raw['sources'] as List).first['pluginSettings'], {
        'privateChoice': 5,
      });
      await library.removeSource('b');
      final reopened = store(packs: [pack]);
      await reopened.load();
      expect(reopened.sourceById('b'), isNull);
      expect(reopened.sources.first.enabled, isFalse);
      expect(reopened.favorites, hasLength(1));
    },
  );

  test(
    'source switching bounds archived variants and preserves nested custom metadata',
    () async {
      final a = _title('a'), b = _title('b');
      final record = _history(a, 1, 10);
      record['myHistoryFlag'] = true;
      (record['title'] as Map)['customTitle'] = 'keep title';
      ((record['title'] as Map)['routes'] as List).first['customRoute'] =
          'keep route';
      ((((record['title'] as Map)['routes'] as List).first['episodes'] as List)
                  .first
              as Map)['customEpisode'] =
          'keep episode';
      await write(history: [record]);
      final library = store();
      await library.load();
      for (var i = 0; i < 6; i++) {
        await library.recordProgress(
          title: i.isEven ? b : a,
          routeIndex: 0,
          episodeIndex: 0,
          positionSeconds: i + 20,
        );
      }
      final raw = await saved();
      final visible = (raw['history'] as List).single as Map;
      expect(visible['myHistoryFlag'], isTrue);
      expect(visible['title']['customTitle'], 'keep title');
      expect(visible['title']['routes'].single['customRoute'], 'keep route');
      expect(
        visible['title']['routes'].single['episodes'].single['customEpisode'],
        'keep episode',
      );
      expect(visible['nakuWorkEntriesV1'], hasLength(1));
      expect(library.history.single.positionSeconds, 25);
      expect(visible['positionSeconds'], 25);
    },
  );

  test(
    'a fresh migration never overwrites a different previous backup',
    () async {
      final oldBackup = File('${file.path}.pre-work-dedup-v1.bak');
      await oldBackup.writeAsString('earlier document');
      final original = await write(
        favorites: [_title('a').toJson(), _title('b').toJson()],
      );
      final library = store();
      await library.load();
      expect(await oldBackup.readAsString(), 'earlier document');
      final backups = directory
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.contains('.pre-work-dedup-v1.') &&
                f.path != oldBackup.path,
          )
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), original);
    },
  );

  test(
    'backup failure prevents persistent migration and leaves original bytes intact',
    () async {
      final original = await write(
        favorites: [_title('a').toJson(), _title('b').toJson()],
      );
      await Directory('${file.path}.pre-work-dedup-v1.bak').create();
      final library = store();
      await expectLater(library.load(), throwsA(isA<FileSystemException>()));
      expect(library.loaded, isFalse);
      expect(await file.readAsString(), original);
    },
  );
  test(
    '200 saved titles consolidate once and repeated identity reads remain stable',
    () async {
      final titles = [
        for (var i = 0; i < 100; i++)
          for (final source in ['a', 'b'])
            _title(source, id: '$i', name: 'fixture-$i', douban: '${1000 + i}'),
      ];
      await write(
        favorites: titles.map((t) => t.toJson()).toList(),
        history: titles
            .map(
              (t) => _history(
                t,
                t.sourceId == 'a' ? 1 : 2,
                t.sourceId == 'a' ? 99 : 20,
              ),
            )
            .toList(),
      );
      final watch = Stopwatch()..start();
      final library = store();
      await library.load();
      final loadMs = watch.elapsedMilliseconds;
      expect(library.favorites, hasLength(100));
      expect(library.history, hasLength(100));
      final query = titles.first;
      expect(library.isFavorite(query), isTrue);
      expect(library.historyForWork(query)?.title.sourceId, 'b');
      watch.reset();
      for (var i = 0; i < 1000; i++) {
        expect(library.isFavorite(query), isTrue);
        expect(library.historyForWork(query)?.positionSeconds, 20);
      }
      final lookupMs = watch.elapsedMilliseconds;
      final current = library.historyForWork(query)!.title;
      await library.recordProgress(
        title: current,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 77,
      );
      expect(library.historyForWork(query)?.positionSeconds, 77);
      expect(library.isFavorite(query), isTrue);
      // Observed diagnostic only: no fragile platform-dependent timing threshold.
      // ignore: avoid_print
      print(
        'Library fixture: 200 source titles -> 100 works; migration=${loadMs}ms; 2000 cached reads=${lookupMs}ms',
      );
    },
  );
}
