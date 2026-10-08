import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

const customSource = CinemaSource(
  id: 'my-source',
  name: '我的来源',
  kind: CinemaSourceKind.maccms,
  url: 'https://personal.example/api.php/provide/vod/',
  enabled: false,
  requestHeaders: {'Referer': 'https://personal.example/'},
);

const favorite = CinemaTitle(
  id: 'film-8',
  sourceId: 'my-source',
  title: '保留的影片',
  year: '2014',
  routes: [
    CinemaRoute(
      name: '原始线路',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://media.example/movie.m3u8'),
      ],
    ),
  ],
);

Map<String, dynamic> legacyLibrary(List<CinemaSource> sources) => {
  'version': 1,
  'sources': sources.map((source) => source.toJson()).toList(),
  'favorites': [favorite.toJson()],
  'history': [
    CinemaHistory(
      title: favorite,
      routeIndex: 0,
      episodeIndex: 0,
      positionSeconds: 123,
      durationSeconds: 10144,
      updatedAt: DateTime.utc(2026, 10, 7, 8, 9),
    ).toJson(),
  ],
  'userLibraryNote': {'keep': true},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File file;
  late File backup;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-source-upgrade-');
    file = File('${directory.path}/library-v1.json');
    backup = File('${file.path}.pre-0.3.0.bak');
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  Future<String> writeLegacy(Map<String, dynamic> raw) async {
    final encoded = const JsonEncoder.withIndent('    ').convert(raw);
    await file.writeAsString(encoded);
    return encoded;
  }

  test('0.3.0 adds only the three researched sources before anime presets', () {
    final sources = bundledCinemaSources;
    expect(sources.take(7).map((source) => source.id), [
      'maccms-guangsu',
      'maccms-modu',
      'maccms-haohua',
      'maccms-wujin',
      'maccms-jisu',
      'maccms-ruyi',
      'maccms-360',
    ]);
    expect(
      sources.skip(7).every((s) => s.kind == CinemaSourceKind.kazumi),
      true,
    );
    expect(cinema030SourcePack.sources.map((source) => source.url), [
      'https://jszyapi.com/api.php/provide/vod/',
      'https://cj.rycjapi.com/api.php/provide/vod',
      'https://360zy.com/api.php/provide/vod',
    ]);
    expect(cinema030SourcePack.sources.every((source) => source.enabled), true);
    expect(
      sources.firstWhere((source) => source.id == 'maccms-wujin').url,
      'https://api.wujinapi.me/api.php/provide/vod/',
    );
    for (final source in sources) {
      source.validate();
    }
  });

  test(
    'legacy upgrade backs up exact bytes and preserves all old data',
    () async {
      final oldSources = bundledCinemaSources
          .where((source) => !cinema030SourcePack.sources.contains(source))
          .toList();
      oldSources[0] = oldSources[0].copyWith(
        name: '我改过的光速',
        url: 'https://custom.example/my-api',
        enabled: false,
        requestHeaders: {'Referer': 'https://custom.example/'},
      );
      final raw = legacyLibrary(oldSources);
      (raw['sources'] as List).first['userNote'] = '原样保留';
      final before = await writeLegacy(raw);
      final store = CinemaStore(file: file);
      addTearDown(store.dispose);

      await Future.wait([store.load(), store.load()]);

      expect(await backup.readAsString(), before);
      expect(
        store.sources.take(4).map((source) => source.toJson()),
        oldSources.take(4).map((source) => source.toJson()),
      );
      expect(
        store.sources.skip(4).take(3).map((source) => source.id),
        cinema030SourcePack.sources.map((source) => source.id),
      );
      expect(
        store.sources.skip(7).map((source) => source.id),
        oldSources.skip(4).map((source) => source.id),
      );
      expect(store.favorites.single.toJson(), favorite.toJson());
      expect(store.history.single.positionSeconds, 123);
      expect(store.history.single.durationSeconds, 10144);
      final after = jsonDecode(await file.readAsString()) as Map;
      expect(after['favorites'], raw['favorites']);
      expect(after['history'], raw['history']);
      expect(after['userLibraryNote'], raw['userLibraryNote']);
      final oldIds = oldSources.map((source) => source.id).toSet();
      expect(
        (after['sources'] as List).where(
          (source) => oldIds.contains(source['id']),
        ),
        raw['sources'],
      );
      expect(after['appliedSourcePacks'], [cinema030SourcePack.id]);
    },
  );

  test(
    'same ID and canonical URL preserve disabled or edited user sources',
    () async {
      final sameId = cinema030SourcePack.sources[0].copyWith(
        name: '我禁用并改址的极速',
        url: 'https://different.example/custom',
        enabled: false,
        requestHeaders: {'User-Agent': 'my-browser'},
      );
      final sameUrl = customSource.copyWith(
        id: 'my-360',
        url: 'https://360ZY.COM:443/api.php/provide/vod/#bookmark',
      );
      final raw = legacyLibrary([sameId, sameUrl]);
      await writeLegacy(raw);
      final store = CinemaStore(file: file);
      addTearDown(store.dispose);
      await store.load();

      expect(store.sources.map((source) => source.id), [
        sameId.id,
        sameUrl.id,
        'maccms-ruyi',
      ]);
      expect(store.sources[0].toJson(), sameId.toJson());
      expect(store.sources[1].toJson(), sameUrl.toJson());
      expect(store.sourceById('maccms-360'), isNull);
      await store.removeSource(sameId.id);
      await store.removeSource(sameUrl.id);
      final restarted = CinemaStore(file: file);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.sources.map((source) => source.id), ['maccms-ruyi']);
    },
  );

  test(
    'canonical query order is deduplicated without merging different hosts',
    () async {
      const existing = CinemaSource(
        id: 'mine',
        name: 'existing',
        kind: CinemaSourceKind.maccms,
        url: 'https://API.EXAMPLE:443/vod/?b=2&a=1#view',
      );
      const pack = CinemaSourcePack(
        id: 'test-query-pack',
        sources: [
          CinemaSource(
            id: 'duplicate',
            name: 'duplicate',
            kind: CinemaSourceKind.maccms,
            url: 'https://api.example/vod?a=1&b=2',
          ),
          CinemaSource(
            id: 'other-host',
            name: 'different host',
            kind: CinemaSourceKind.maccms,
            url: 'https://api.example.net/vod?a=1&b=2',
          ),
        ],
      );
      await writeLegacy(legacyLibrary([existing]));
      final store = CinemaStore(
        file: file,
        defaults: const [],
        sourcePacks: [pack],
      );
      addTearDown(store.dispose);
      await store.load();
      expect(store.sources.map((source) => source.id), ['mine', 'other-host']);
    },
  );

  test(
    'repeated loads do not rewrite or replace the original backup',
    () async {
      final original = await writeLegacy(legacyLibrary([customSource]));
      final first = CinemaStore(file: file);
      addTearDown(first.dispose);
      await first.load();
      final migrated = await file.readAsString();
      final fileModified = await file.lastModified();
      final backupModified = await backup.lastModified();

      final second = CinemaStore(file: file);
      addTearDown(second.dispose);
      await second.load();
      await second.load();
      expect(await file.readAsString(), migrated);
      expect(await file.lastModified(), fileModified);
      expect(await backup.readAsString(), original);
      expect(await backup.lastModified(), backupModified);
      expect(second.sources, hasLength(4));
    },
  );

  test(
    'removed new sources never return and the pack marker survives edits',
    () async {
      final before = await writeLegacy(legacyLibrary([customSource]));
      final store = CinemaStore(file: file);
      addTearDown(store.dispose);
      await store.load();
      for (final source in cinema030SourcePack.sources) {
        await store.removeSource(source.id);
      }
      await store.saveSource(customSource.copyWith(name: '再次编辑'));
      await store.toggleFavorite(favorite);
      await store.flush();
      final restarted = CinemaStore(file: file);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.sources.single.name, '再次编辑');
      expect(restarted.favorites, isEmpty);
      expect(restarted.history.single.positionSeconds, 123);
      expect(await backup.readAsString(), before);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['appliedSourcePacks'],
        [cinema030SourcePack.id],
      );
    },
  );

  test(
    'custom defaults stay isolated, including a later normal reopening',
    () async {
      final store = CinemaStore(file: file, defaults: [customSource]);
      addTearDown(store.dispose);
      await store.load();
      expect(store.sources.single.id, customSource.id);
      await store.toggleFavorite(favorite);
      final restarted = CinemaStore(file: file);
      addTearDown(restarted.dispose);
      await restarted.load();
      expect(restarted.sources.single.id, customSource.id);
      expect(await backup.exists(), isFalse);
    },
  );

  test(
    'custom defaults do not migrate a legacy file without explicit packs',
    () async {
      final before = await writeLegacy(legacyLibrary([customSource]));
      final store = CinemaStore(file: file, defaults: [customSource]);
      addTearDown(store.dispose);
      await store.load();
      expect(store.sources.single.id, customSource.id);
      expect(await file.readAsString(), before);
      expect(await backup.exists(), isFalse);
    },
  );

  test(
    'an existing backup is never replaced when a pack is first recorded',
    () async {
      await writeLegacy(legacyLibrary([customSource]));
      await backup.writeAsString('first upgrade backup');
      final store = CinemaStore(file: file);
      addTearDown(store.dispose);
      await store.load();
      expect(await backup.readAsString(), 'first upgrade backup');
      expect(store.sources, hasLength(4));
    },
  );

  test(
    'failed atomic upgrade leaves old file and state intact, and can retry',
    () async {
      final before = await writeLegacy(legacyLibrary([customSource]));
      final blockedTemporary = Directory('${file.path}.tmp');
      await blockedTemporary.create();
      final store = CinemaStore(file: file);
      addTearDown(store.dispose);
      await expectLater(store.load(), throwsA(isA<FileSystemException>()));
      expect(store.loaded, isFalse);
      expect(store.sources, isEmpty);
      expect(await file.readAsString(), before);
      expect(await backup.readAsString(), before);
      await blockedTemporary.delete();
      await store.load();
      expect(store.loaded, isTrue);
      expect(store.sources, hasLength(4));
      expect(await backup.readAsString(), before);
    },
  );

  test(
    'corrupt syntax and nested data remain byte-identical with no backup',
    () async {
      final invalidDocuments = <Object>[
        '{broken',
        {
          ...legacyLibrary([customSource]),
          'sources': [null],
        },
        {
          ...legacyLibrary([customSource]),
          'sources': [customSource.toJson(), customSource.toJson()],
        },
        {
          ...legacyLibrary([customSource]),
          'favorites': ['not a title'],
        },
        {
          ...legacyLibrary([customSource]),
          'favorites': [
            {...favorite.toJson(), 'id': ''},
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'favorites': [
            {...favorite.toJson(), 'routes': null},
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'favorites': [
            {
              ...favorite.toJson(),
              'routes': [
                {
                  'name': 'bad',
                  'episodes': [null],
                },
              ],
            },
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'history': [
            {
              ...(legacyLibrary([customSource])['history'] as List).single,
              'positionSeconds': -1,
            },
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'history': [
            {
              ...(legacyLibrary([customSource])['history'] as List).single,
              'updatedAt': 'not a date',
            },
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'sources': [
            {...customSource.toJson(), 'enabled': 'false'},
          ],
        },
        {
          ...legacyLibrary([customSource]),
          'appliedSourcePacks': 'wrong type',
        },
        {
          ...legacyLibrary([customSource]),
          'appliedSourcePacks': ['', cinema030SourcePack.id],
        },
      ];
      for (final raw in invalidDocuments) {
        final before = raw is String ? raw : jsonEncode(raw);
        await file.writeAsString(before);
        final store = CinemaStore(file: file);
        await expectLater(store.load(), throwsFormatException);
        await expectLater(
          store.saveSource(customSource),
          throwsFormatException,
        );
        expect(store.loaded, isFalse);
        expect(store.sources, isEmpty);
        expect(await file.readAsString(), before);
        expect(await backup.exists(), isFalse);
        expect(await File('${file.path}.tmp').exists(), isFalse);
        store.dispose();
      }
    },
  );
}
