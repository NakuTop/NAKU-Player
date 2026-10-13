import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_source_health.dart';
import 'package:kazumi/features/cinema/cinema_source_subscriptions.dart';
import 'package:kazumi/features/cinema/cinema_library_backup.dart';
import 'package:kazumi/features/cinema/cinema_invitation.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';

void main() {
  const source = CinemaSource(
    id: 'a',
    name: 'A',
    kind: CinemaSourceKind.maccms,
    url: 'https://a.example/api.php/provide/vod',
  );
  const title = CinemaTitle(
    id: '12',
    sourceId: 'a',
    title: 'Movie',
    year: '2020',
    category: '电影',
    doubanId: '12',
    routes: [
      CinemaRoute(
        name: 'hls',
        episodes: [
          CinemaEpisode(name: '正片', url: 'https://media.example/movie.m3u8'),
        ],
      ),
    ],
  );
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('naku-v2-test-');
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'catalogue cooldown is temporary, persistent and separate from media health',
    () async {
      var now = DateTime.utc(2026, 10, 13);
      final file = File('${temp.path}/health.json');
      final health = CinemaSourceHealth(file: file, now: () => now);
      await health.load();
      health.observe(source, ok: false, media: true);
      health.observe(source, ok: false, media: true);
      expect(health.cooling(source), false);
      health.observe(source, ok: false);
      health.observe(source, ok: false);
      expect(health.cooling(source), true);
      expect(health.available([source]), isEmpty);
      await health.flush();
      health.dispose();
      final restored = CinemaSourceHealth(file: file, now: () => now);
      await restored.load();
      expect(restored.cooling(source), true);
      expect(restored.history(source).length, 2);
      expect(restored.history(source, media: true).length, 2);
      now = now.add(const Duration(minutes: 3));
      expect(restored.available([source]), [source]);
      restored.observe(source, ok: true, latencyMs: 80);
      expect(restored.record(source)!.failures, 0);
      expect(restored.record(source)!.latencyMs, 80);
      await restored.flush();
      restored.dispose();
      expect(await file.readAsString(), isNot(contains('a.example')));
    },
  );
  test(
    'bounded source probes stop starting new requests after cancellation',
    () async {
      final health = CinemaSourceHealth(file: File('${temp.path}/h.json'));
      await health.load();
      var calls = 0;
      final pending = health.probeAll(
        List.generate(20, (i) => source.copyWith(id: '$i')),
        (s) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          health.cancelProbes();
        },
      );
      await pending;
      expect(calls, lessThanOrEqualTo(3));
      expect(health.probing, false);
      health.dispose();
    },
  );
  test(
    'imports NAKU, LibreTV maps and direct TVBox APIs, skips executable engines',
    () {
      final json = jsonEncode({
        'sites': [
          {'key': 'a', 'name': 'A', 'type': 1, 'api': source.url},
          {'name': 'duplicate', 'type': 1, 'api': '${source.url}?ac=detail'},
          {'name': 'spider', 'type': 3, 'api': 'csp_Spider'},
          {'name': 'invalid', 'api': 'file:///tmp/x'},
        ],
      });
      final parsed = parseCinemaSourceImport(json);
      expect(parsed.sources.length, 1);
      expect(parsed.skipped, 3);
      expect(
        parseCinemaSourceImport(
          jsonEncode({
            'sources': {
              'B': {'api': 'https://b.example/api/provide/vod/'},
            },
          }),
        ).sources.single.name,
        'B',
      );
      expect(
        () => parseCinemaSourceImport(
          '{"sources":[{"name":"x","url":"https://x.example/a.js"}]}',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'bulk import is idempotent and preserves user name, state and priority',
    () async {
      final store = CinemaStore(
        file: File('${temp.path}/lib.json'),
        defaults: [source.copyWith(name: 'My source', enabled: false)],
      );
      await store.load();
      final subscriptions = CinemaSourceSubscriptions(store);
      final list = parseCinemaSourceImport(
        jsonEncode({
          'sources': [
            source.toJson(),
            source
                .copyWith(
                  id: 'b',
                  name: 'B',
                  url: 'https://b.example/api.php/provide/vod',
                )
                .toJson(),
          ],
        }),
      );
      expect(await subscriptions.import(list), 1);
      expect(await subscriptions.import(list), 0);
      expect(store.sources.first.name, 'My source');
      expect(store.sources.first.enabled, false);
      expect(store.sources.last.name, 'B');
      store.dispose();
    },
  );
  test(
    'backup restores latest whole progress and keeps source ordering and unknown fields',
    () async {
      final store = CinemaStore(
        file: File('${temp.path}/lib.json'),
        defaults: [source],
      );
      await store.load();
      await store.toggleFavorite(title);
      await store.recordProgress(
        title: title,
        routeIndex: 0,
        episodeIndex: 0,
        positionSeconds: 99,
      );
      await store.setExtra('mediaCache', {'quotaMB': 512});
      final backup = await store.exportLibrary();
      final imported = jsonDecode(jsonEncode(backup)) as Map<String, dynamic>;
      (imported['history'][0] as Map)['positionSeconds'] = 150;
      (imported['history'][0] as Map)['updatedAt'] = DateTime.now()
          .add(const Duration(days: 1))
          .toIso8601String();
      await store.restoreLibrary(imported);
      expect(store.favorites.length, 1);
      expect(store.history.single.positionSeconds, 150);
      expect(store.sources.map((s) => s.id), ['a']);
      expect(store.extras['mediaCache'], {'quotaMB': 512});
      expect(
        await temp.list().where((f) => f.path.contains('pre-restore')).length,
        1,
      );
      final before = await store.exportLibrary();
      expect(
        () => store.restoreLibrary({'version': 999}),
        throwsFormatException,
      );
      expect(await store.exportLibrary(), before);
      store.dispose();
    },
  );
  test(
    'merging conflicting source IDs remaps imported work to its actual source',
    () async {
      final store = CinemaStore(
        file: File('${temp.path}/lib.json'),
        defaults: [source],
      );
      await store.load();
      await store.restoreLibrary({
        'version': 1,
        'sources': [
          source
              .copyWith(url: 'https://other.example/api.php/provide/vod')
              .toJson(),
        ],
        'favorites': [title.toJson()],
        'history': [],
      });
      expect(store.sources.length, 2);
      expect(store.favorites.single.sourceId, 'a-import');
      expect(store.sourceById('a-import')!.url, contains('other.example'));
      store.dispose();
    },
  );
  test(
    'backup envelope rejects changed payload and invalid sections before restore',
    () async {
      final store = CinemaStore(
        file: File('${temp.path}/lib.json'),
        defaults: [source],
      );
      final data = {
        'cinema': await store.exportLibrary(),
        'settings': <String, dynamic>{},
        'animeHistory': [],
        'animeFavorites': [],
        'rules': [],
        'auxiliary': {},
      };
      final text = CinemaLibraryBackup.encode(data);
      expect(CinemaLibraryBackup.decode(text)['cinema'], data['cinema']);
      expect(
        () => CinemaLibraryBackup.decode(
          text.replaceAll('"name": "A"', '"name": "B"'),
        ),
        throwsFormatException,
      );
      expect(
        () => CinemaLibraryBackup.decode(
          CinemaLibraryBackup.encode({
            ...data,
            'auxiliary': {'../../x': {}},
          }),
        ),
        throwsFormatException,
      );
      expect(
        () => CinemaLibraryBackup.decode(
          CinemaLibraryBackup.encode({
            ...data,
            'animeHistory': [42],
          }),
        ),
        throwsFormatException,
      );
      store.dispose();
    },
  );
  test('work invitations round trip without media URLs or credentials', () {
    final invitation = CinemaInvitation(
      media: CinemaSyncMedia.fromSelection(
        title,
        title.routes.first.episodes.first,
      ),
      positionSeconds: 125,
      endpoint: 'syncplay.pl:8996',
      room: 'Couple',
    );
    final link = invitation.encode(), parsed = CinemaInvitation.parse(link);
    expect(parsed.media!.title, 'Movie');
    expect(parsed.positionSeconds, 125);
    expect(parsed.room, 'Couple');
    final payload = utf8.decode(
      base64Url.decode(
        base64Url.normalize(Uri.parse(link).queryParameters['data']!),
      ),
    );
    expect(payload, isNot(contains('media.example')));
    expect(payload, isNot(contains('headers')));
    expect(
      () => CinemaInvitation.parse('https://example.org'),
      throwsFormatException,
    );
    expect(
      () => CinemaInvitation.parse(
        CinemaInvitation(media: invitation.media, positionSeconds: -1).encode(),
      ),
      throwsFormatException,
    );
    expect(
      () => CinemaInvitation.parse(
        CinemaInvitation(
          media: invitation.media,
          endpoint: 'invalid://x',
          room: 'x',
        ).encode(),
      ),
      throwsFormatException,
    );
  });
}
