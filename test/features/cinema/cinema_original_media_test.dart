import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_original_match.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_video_metadata.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_playback_recovery.dart';

const pack = OriginalEdition(
  hash: 'a',
  name: 'Foundation S02 2160p',
  size: 1000,
  seeds: 1,
  pack: true,
  magnet: '',
);
void main() {
  test(
    'Chinese subtitle hints outrank a larger audio-only swarm and survive aggregation',
    () async {
      const movie = CinemaTitle(
        id: '7',
        sourceId: 'test',
        title: 'Bright River',
        year: '2025',
        category: '电影',
      );
      final queries = <String>[];
      final lookup = CinemaOriginalSearch(
        identity: (_) async => [],
        get: (uri) async {
          final query = uri.queryParameters['q'] ?? '';
          queries.add(query);
          if (uri.host != 'torrents-csv.com') return {'hits': []};
          return {
            'torrents': [
              {
                'name': 'Bright.River.2025.2160p.Mandarin.Audio',
                'infohash': 'a' * 40,
                'seeders': 160,
                'size_bytes': 800000,
              },
              if (query.contains('CHS'))
                {
                  'name': 'Bright.River.2025.2160p.CHS.ENG',
                  'infohash': 'b' * 40,
                  'seeders': 2,
                  'size_bytes': 800000,
                },
            ],
          };
        },
      ).find(movie, '正片');
      await lookup.finished;
      final m = lookup.matches!, engine = CinemaOriginalEngine();
      expect(queries.any((q) => q.contains('CHS')), isTrue);
      final sub = m.editions.first, audio = m.editions.last;
      expect(sub.hash, 'b' * 40);
      expect(originalChineseSubtitles('国语配音 MULTI Chinese Audio 无中字'), isFalse);
      expect(originalChineseSubtitles('雙語 中文字幕'), isTrue);
      expect(
        originalChineseSubtitles('Subtitles: English, Chinese (Traditional)'),
        isTrue,
      );
      expect(
        originalChineseSubtitles('Subtitles: English | Audio: Chinese'),
        isFalse,
      );
      expect(originalChineseSubtitles('無繁體中文字幕'), isFalse);
      expect(
        originalChineseSubtitles('Audio: CHS | Subtitles: English'),
        isFalse,
      );
      engine.record(m, audio, const CinemaVideoMetadata(3840, 2160, 'hevc'));
      expect(engine.preferred(m)?.edition, same(sub));
      expect(engine.preferred(m, preferredHash: sub.hash)?.edition, same(sub));
      expect(
        engine.preferred(m, preferredHash: audio.hash)?.edition,
        same(audio),
      );
      engine.record(m, sub, const CinemaVideoMetadata(1920, 1080, 'h264'));
      expect(engine.preferred(m)?.edition, same(audio));
    },
  );
  test(
    'a duplicate hash keeps both the strongest swarm report and the Chinese subtitle hint',
    () {
      OriginalEdition edition(String name, int count, String tracker) =>
          OriginalEdition(
            hash: 'same',
            name: name,
            size: 1500,
            seeds: count,
            pack: true,
            magnet: Uri(
              scheme: 'magnet',
              queryParameters: {'xt': 'urn:btih:same', 'tr': tracker},
            ).toString(),
          );
      final one = edition(
        'A.Show.S01.2160p.WEB',
        100,
        'https://one.invalid/announce',
      );
      final two = edition(
        'A.Show.S01.2160p.CHS',
        2,
        'https://two.invalid/announce',
      );
      for (final merged in [
        one.mergeIndexEvidence(two),
        two.mergeIndexEvidence(one),
      ]) {
        expect(merged.seeds, 100);
        expect(merged.chineseSubtitles, isTrue);
        expect(
          Uri.parse(merged.magnet).queryParametersAll['tr'],
          unorderedEquals([
            'https://one.invalid/announce',
            'https://two.invalid/announce',
          ]),
        );
      }
    },
  );

  test(
    'subtitle group single files retain the work and episode boundaries',
    () {
      const name = '[Fixture]Glass Signal [05][Side story][2160p][CHS_JAP].mp4';
      OriginalWork show(int season, int ep) => OriginalWork(
        names: ['Glass Signal'],
        years: {'2025'},
        season: season,
        episode: ep,
      );
      expect(show(1, 5).matchRelease(name), false);
      expect(show(1, 6).matchRelease(name), isNull);
      expect(show(2, 5).matchRelease(name), isNull);
      expect(
        show(
          1,
          5,
        ).matchRelease(name.replaceFirst('Glass Signal', 'Glass Signals')),
        isNull,
      );
      expect(
        show(1, 5).matchRelease(name.replaceFirst('[05]', '[05-06]')),
        isNull,
      );
      final edition = OriginalEdition(
        hash: 'fixture',
        name: name,
        size: 100,
        seeds: 1,
        pack: false,
        magnet: '',
      );
      expect(
        originalMainFile(show(1, 5), edition, [OriginalFile(0, name, 100)])?.id,
        0,
      );
      expect(
        originalMainFile(show(1, 5), edition, [
          OriginalFile(0, name.replaceFirst('[05]', '[06]'), 100),
        ]),
        isNull,
      );
      final film = OriginalWork(names: ['Glass Signal'], years: {'2025'});
      expect(
        film.matchRelease('[Fixture] Glass Signal (2025) 2160p.CHS.mkv'),
        false,
      );
      expect(
        film.matchRelease('[Fixture] Glass Signals (2025) 2160p.CHS.mkv'),
        isNull,
      );
    },
  );

  test(
    'title and verified-ID releases merge without depending on a parent category',
    () async {
      const subject = CinemaTitle(
        id: '1',
        sourceId: 'film',
        title: 'Bright River!',
        year: '2025',
        category: '电影',
      );
      final paths = <Uri>[];
      final search = CinemaOriginalSearch(
        identity: (_) async => [
          const CinemaDiscoveryTitle(
            id: '301',
            title: 'Bright River!',
            originalTitle: 'Bright River!',
            year: '2025',
            imdbId: 'tt12345678',
            identityVerified: true,
          ),
        ],
        get: (uri) async {
          paths.add(uri);
          if (uri.host == 'api.knaben.org') {
            if (uri.queryParameters.containsKey('c')) return {'hits': []};
            return {
              'hits': [
                {
                  'title': 'Bright.River.2025.2160p',
                  'hash': 'a' * 40,
                  'category': 'Movies / HD',
                  'categoryId': [2000000, 3001000],
                  'bytes': 40000000,
                },
                {
                  'title': 'Bright.River.2025.2160p',
                  'hash': 'd' * 40,
                  'category': 'Applications',
                  'bytes': 40000000,
                },
              ],
            };
          }
          if (uri.host == 'torrents-csv.com') return {'torrents': []};
          Map row(String hash, String filename) => {
            'infoHash': hash * 40,
            'fileIdx': 0,
            'behaviorHints': {'filename': filename},
            'name': '4K',
            'title': 'release\n👤 3 💾 6.25 GB',
          };
          return {
            'streams': [
              row('a', 'Bright.River.2025.2160p.mkv'),
              row('b', 'Bright.River.2025.2160p.BluRay.mkv'),
              row('c', 'Bright.River.2025.UHD.BluRay.1080p.mkv'),
              row('d', 'Bright.River.2025.2160p.AI.Up-scaled.mkv'),
              row('e', 'Bright.River.1995.2160p.mkv'),
              {
                ...row('f', 'Bright.River.2025.2160p.mkv'),
                'url': 'https://example.org/watch',
              },
            ],
          };
        },
      );
      final lookup = search.find(subject, '正片');
      await lookup.finished;
      expect(lookup.matches!.editions.map((v) => v.hash).toSet(), {
        'a' * 40,
        'b' * 40,
      });
      expect(
        paths.where((u) => u.path == '/stream/movie/tt12345678.json'),
        hasLength(1),
      );
      expect(
        paths.every((u) => !(u.queryParameters['q'] ?? '').contains('!')),
        isTrue,
      );
    },
  );

  test(
    'one completed index resolves the result even if an optional index stalls',
    () async {
      const subject = CinemaTitle(
        id: '1',
        sourceId: 'film',
        title: '远山',
        category: '电影',
        year: '2025',
      );
      final late = Completer<Object?>();
      final service = CinemaOriginalSearch(
        lookupBudget: const Duration(milliseconds: 100),
        identity: (_) async => [],
        get: (u) async =>
            u.host == 'api.knaben.org' ? {'hits': []} : late.future,
      );
      final lookup = service.find(subject, '正片');
      await lookup.finished.timeout(const Duration(seconds: 2));
      expect(lookup.incomplete, isFalse);
      expect(lookup.matches, isNull);
      late.complete({
        'torrents': [
          {'name': '远山.2025.2160p', 'infohash': 'a' * 40, 'size_bytes': 1024},
        ],
      });
      await Future<void>.delayed(Duration.zero);
      expect(lookup.done, isTrue);
      expect(lookup.matches, isNull);
      final offline = CinemaOriginalSearch(
        identity: (_) async => [],
        get: (_) async => null,
      ).find(subject, '正片');
      await offline.finished;
      expect(offline.incomplete, isTrue);
    },
  );

  test(
    'same open lookup retries a disconnected index and keeps its verified name after a slower local query',
    () async {
      final slowLocal = Completer<Object?>();
      var attempts = 0;
      final search = CinemaOriginalSearch(
        identity: (_) async => [
          const CinemaDiscoveryTitle(
            id: '123',
            title: '星河',
            originalTitle: 'Bright River',
            year: '2025',
            kind: 'movie',
            identityVerified: true,
          ),
        ],
        get: (uri) async {
          final query = uri.queryParameters['q'];
          if (query == '星河 2160p' && uri.host == 'api.knaben.org') {
            return slowLocal.future;
          }
          if (query == 'Bright River 2160p' && uri.host == 'torrents-csv.com') {
            if (++attempts == 1) {
              throw const SocketException('connection reset');
            }
            return {
              'torrents': [
                {
                  'name': 'Bright.River.2025.2160p.WEB',
                  'infohash': 'a' * 40,
                  'size_bytes': 100000,
                  'seeders': 4,
                },
              ],
            };
          }
          return {'hits': [], 'torrents': []};
        },
      );
      final lookup = search.find(
        const CinemaTitle(
          id: '1',
          sourceId: 'film',
          title: '星河',
          year: '2025',
          category: '电影',
        ),
        '正片',
      );
      await lookup.ready.timeout(const Duration(seconds: 4));
      expect(lookup.matches?.editions.single.hash, 'a' * 40);
      expect(lookup.done, isFalse);
      slowLocal.complete({'hits': []});
      await lookup.finished;
      expect(lookup.matches?.work.names, contains('Bright River'));
      expect(lookup.incomplete, isFalse);
      expect(attempts, 2);
    },
  );
  test(
    'late official alias publishes on the initial lookup while other index is pending',
    () async {
      final identity = Completer<List<CinemaDiscoveryTitle>>();
      final slow = Completer<Object?>();
      final search = CinemaOriginalSearch(
        identity: (_) => identity.future,
        get: (uri) async {
          if (!uri.queryParameters['q']!.startsWith('Bright River')) {
            return {'hits': [], 'torrents': []};
          }
          if (uri.host == 'api.knaben.org') return slow.future;
          return {
            'torrents': [
              {
                'name': 'Bright.River.2025.2160p.WEB',
                'infohash': 'a' * 40,
                'size_bytes': 100000,
                'seeders': 4,
              },
            ],
          };
        },
      );
      const title = CinemaTitle(
        id: '1',
        sourceId: 'movie',
        title: '奔流吧星河',
        year: '2025',
        category: '电影',
      );
      final result = search.find(title, '正片');
      final changes = <int>[];
      result.addListener(
        () => changes.add(result.matches?.editions.length ?? 0),
      );
      await Future<void>.delayed(Duration.zero);
      expect(result.done, isFalse);
      identity.complete([
        const CinemaDiscoveryTitle(
          id: '123',
          title: '奔流吧！星河',
          originalTitle: 'Bright River',
          year: '2025',
          identityVerified: true,
        ),
      ]);
      await result.ready.timeout(const Duration(seconds: 2));
      expect(changes, contains(1));
      expect(result.done, isFalse);
      expect(identical(search.find(title, 'HD'), result), isTrue);
      slow.complete({'hits': []});
      await result.finished;
      expect(result.incomplete, isFalse);
    },
  );
  test(
    'a series ID queries and accepts only the requested season and episode',
    () async {
      final paths = <String>[];
      final service = CinemaOriginalSearch(
        identity: (_) async => [
          const CinemaDiscoveryTitle(
            id: '100',
            title: '星河',
            originalTitle: 'Bright River',
            year: '2025',
            kind: 'tv',
            imdbId: 'tt12345678',
            identityVerified: true,
          ),
        ],
        get: (uri) async {
          if (uri.host != 'torrentio.strem.fun') {
            return {'hits': [], 'torrents': []};
          }
          paths.add(uri.path);
          Map stream(String season, String episode, String hash) => {
            'infoHash': hash * 40,
            'behaviorHints': {
              'filename': 'Bright.River.S${season}E$episode.2160p.mkv',
              'videoSize': 600000000,
            },
          };
          return {
            'streams': [
              stream('01', '03', 'a'),
              stream('01', '04', 'b'),
              stream('02', '03', 'c'),
            ],
          };
        },
      );
      final lookup = service.find(
        const CinemaTitle(
          id: '1',
          sourceId: 'film',
          title: '星河',
          year: '2025',
          category: '电视剧',
        ),
        '第3集',
      );
      await lookup.finished;
      expect(paths, ['/stream/series/tt12345678:1:3.json']);
      expect(lookup.matches!.editions.single.hash, 'a' * 40);
    },
  );
  test('release identity and exact season pack member', () {
    final movie = OriginalWork(names: ['Dune'], years: {'2021'});
    expect(movie.matchRelease('Dune.2021.2160p.BluRay'), false);
    final bilingual = OriginalWork(names: ['沙丘', 'Dune'], years: {'2021'});
    expect(bilingual.matchRelease('沙丘.Dune.2021.2160p.BluRay'), false);
    expect(bilingual.matchRelease('沙丘2.Dune.2021.2160p.BluRay'), isNull);
    for (final n in [
      'Dune.1984.2160p',
      'Dune.Part.Two.2021.2160p',
      'Dune.2021.1080p',
      'Dune.2021.2160p.Sample',
      'Dune.S01E01.2021.2160p',
    ]) {
      expect(movie.matchRelease(n), isNull);
    }
    final show = OriginalWork(
      names: ['Foundation', '基地'],
      years: {'2021', '2023'},
      season: 2,
      episode: 3,
    );
    expect(show.matchRelease('Foundation.2021.S02.2160p.WEB'), true);
    expect(show.matchRelease('Foundation.S02E03.2160p'), false);
    for (final n in [
      'Foundation S01E03 2160p',
      'Foundation S02E04 2160p',
      'Foundation S02E03-E04 2160p',
      'Foundation S02E03E04 2160p',
      'Foundation 1988 S02E03 2160p',
    ]) {
      expect(show.matchRelease(n), isNull);
    }
    final manifest = [
      const OriginalFile(5, 'Foundation.S02/第03集.mkv', 100),
      const OriginalFile(1, 'Foundation.S02/S02E02.mkv', 105),
      const OriginalFile(2, 'Foundation.S02/S02E03E04.mkv', 105),
      const OriginalFile(3, 'Foundation.S02/sample/S02E03.mkv', 105),
    ];
    expect(originalMainFile(show, pack, manifest)?.id, 5);
    expect(
      originalMainFile(show, pack, [
        ...manifest,
        const OriginalFile(6, 'Foundation.S02/E03.mp4', 129),
      ]),
      isNull,
    );
    expect(
      originalMainFile(show, pack, [
        const OriginalFile(2, 'Foundation.S01/S01E03.mkv', 90),
      ]),
      isNull,
    );
    expect(
      originalMainFile(show, pack, [
        const OriginalFile(1, 'Foundation.S02/not-identified.mkv', 100),
      ]),
      isNull,
    );
  });

  test(
    'series pack labels, numbered files and multi-season folders keep the exact episode',
    () {
      final work = OriginalWork(
        names: ['The Series'],
        years: {'2022'},
        season: 2,
        episode: 3,
      );
      const name = 'The.Series.S01-S04.2160p.WEB';
      expect(work.matchRelease(name), true);
      const multi = OriginalEdition(
        hash: 'a',
        name: name,
        size: 1,
        seeds: 1,
        pack: true,
        magnet: '',
      );
      expect(
        originalMainFile(work, multi, [
          const OriginalFile(1, 'The.Series.S01-S04/S01/03.mkv', 100),
          const OriginalFile(2, 'The.Series.S01-S04/S02/03.mkv', 100),
          const OriginalFile(3, 'The.Series.S01-S04/S02/04.mkv', 100),
        ])?.id,
        2,
      );
      expect(
        originalMainFile(work, multi, [const OriginalFile(1, '03.mkv', 100)]),
        isNull,
      );
      Map row(String path) => {
        'infoHash': 'b' * 40,
        'behaviorHints': {'filename': path, 'videoSize': 10000},
        'title': 'The.Series.S02.2160p.WEB',
      };
      expect(parseOriginalStream(work, row('S02/03.mkv'))?.pack, true);
      expect(parseOriginalStream(work, row('S02/04.mkv')), isNull);
      expect(parseOriginalStream(work, row('S01/03.mkv')), isNull);
      expect(parseOriginalStream(work, row('Other.Series.S02E03.mkv')), isNull);
      expect(parseOriginalStream(work, row('S02E03.1080p.mkv')), isNull);
    },
  );
  test('Matroska dimensions must belong to an enabled video track', () {
    List<int> tag(List<int> id, List<int> body) => [
      ...id,
      128 + body.length,
      ...body,
    ];
    List<int> entry(int type, int enabled) => tag(
      [0xae],
      [
        ...tag([0x83], [type]),
        ...tag([0xb9], [enabled]),
        ...tag([0x86], ascii.encode('V_MPEGH/ISO/HEVC')),
        ...tag(
          [0xe0],
          [
            ...tag([0xb0], [0x0f, 0x00]),
            ...tag([0xba], [0x05, 0xe0]),
          ],
        ),
      ],
    );
    Uint8List header(List<int> tracks) => Uint8List.fromList([
      ...tag([0x1a, 0x45, 0xdf, 0xa3], []),
      0x18,
      0x53,
      0x80,
      0x67,
      0xff,
      ...tag([0x16, 0x54, 0xae, 0x6b], tracks),
    ]);
    expect(cinemaVideoMetadata(header(entry(2, 1))), isNull);
    expect(cinemaVideoMetadata(header(entry(1, 0))), isNull);
    final v = cinemaVideoMetadata(header([...entry(2, 1), ...entry(1, 1)]));
    expect((v?.width, v?.height, v?.codec), (3840, 1504, 'HEVC'));
    final bytes = header(entry(1, 1));
    expect(cinemaVideoMetadata(bytes.sublist(0, bytes.length - 3)), isNull);
  });

  test(
    'two index responses deduplicate and changing episode changes its match',
    () async {
      final requests = <Uri>[];
      final service = CinemaOriginalSearch(
        identity: (q) async => [
          const CinemaDiscoveryTitle(
            id: '123',
            title: '星城 第二季',
            originalTitle: 'Star City Season 2',
            year: '2024',
            kind: 'tv',
            identityVerified: true,
          ),
        ],
        get: (uri) async {
          requests.add(uri);
          final s3 = 'a' * 40, s4 = 'b' * 40;
          return {
            'hits': [],
            'torrents': [
              for (final e in [(3, s3), (4, s4)])
                {
                  'name': 'Star.City.S02E0${e.$1}.2160p.WEB',
                  'infohash': e.$2,
                  'size_bytes': 10000,
                  'seeders': 12,
                },
            ],
          };
        },
      );
      final title = const CinemaTitle(
        id: '123',
        sourceId: 'demo',
        title: '星城 第二季',
        year: '2024',
        category: '美剧',
      );
      final l3 = service.find(title, '第三集'), l4 = service.find(title, '第4集');
      expect(identical(l3, service.find(title, '第三集')), true);
      await Future.wait([l3.ready, l4.ready]);
      expect(l3.matches!.editions.single.hash, 'a' * 40);
      expect(l4.matches!.editions.single.hash, 'b' * 40);
      expect(
        requests.any(
          (u) => u.queryParameters['q']?.contains('Star City S02E03') ?? false,
        ),
        true,
      );
    },
  );

  test(
    'root refusal survives the HLS cache and bypasses transient retry',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final root = Uri.parse('http://127.0.0.1:${origin.port}');
      origin.listen((q) async {
        if (q.uri.path == '/ok.m3u8') {
          q.response.write(
            '#EXTM3U\n#EXTINF:10,\nmissing.ts\n#EXT-X-ENDLIST\n',
          );
        } else if (q.uri.path == '/master.m3u8' ||
            q.uri.path == '/multi.m3u8') {
          q.response.write(
            '#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI="subs.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000\n/403/video.m3u8\n',
          );
          if (q.uri.path == '/multi.m3u8') {
            q.response.write('#EXT-X-STREAM-INF:BANDWIDTH=2000\n/ok.m3u8\n');
          }
        } else {
          q.response.statusCode = int.tryParse(q.uri.pathSegments.first) ?? 403;
        }
        await q.response.close();
      });
      final dir = await Directory.systemTemp.createTemp('naku-refusal-test-');
      final transport = CinemaMediaTransport(dio: Dio());
      final cache = CinemaMediaCache(directory: dir, transport: transport);
      final client = HttpClient();
      try {
        for (final single in [true, false]) {
          final session = (await cache.open(
            root.resolve(single ? '/master.m3u8' : '/multi.m3u8').toString(),
            {},
            hls: true,
          ))!;
          int? seen;
          session.session.onRootManifestRefused = (s) => seen = s;
          final master = await (await client.getUrl(
            Uri.parse(session.url),
          )).close();
          final text = await utf8.decodeStream(master);
          final sub = RegExp(r'URI="([^"]+)"').firstMatch(text)![1]!;
          await (await (await client.getUrl(
            Uri.parse(sub),
          )).close()).drain<void>();
          expect(seen, isNull);
          final video = text
              .split('\n')
              .firstWhere((s) => s.startsWith('http'));
          await (await (await client.getUrl(
            Uri.parse(video),
          )).close()).drain<void>();
          expect(seen, single ? 403 : null);
          await session.session.close();
        }
        for (final code in [403, 444, 451]) {
          final session = (await cache.open(
            root.resolve('/$code/main.m3u8').toString(),
            {},
            hls: true,
          ))!;
          int? seen;
          session.session.onRootManifestRefused = (s) => seen = s;
          final res = await (await client.getUrl(
            Uri.parse(session.url),
          )).close();
          await res.drain<void>();
          expect(res.statusCode, code);
          expect(seen, code);
          expect(
            CinemaPlaybackRecovery().retry(
              'same',
              cinemaPlaybackFailure('HTTP error $code'),
            ),
            isNull,
          );
          await session.session.close();
        }
        final session = (await cache.open(
          root.resolve('/ok.m3u8').toString(),
          {},
          hls: true,
        ))!;
        int? seen;
        session.session.onRootManifestRefused = (s) => seen = s;
        final res = await (await client.getUrl(Uri.parse(session.url))).close();
        final manifest = await utf8.decodeStream(res);
        final segment = manifest
            .split('\n')
            .firstWhere((s) => s.startsWith('http'));
        final refused = await (await client.getUrl(Uri.parse(segment))).close();
        await refused.drain<void>();
        expect(refused.statusCode, 403);
        expect(seen, isNull);
        await session.session.close();
      } finally {
        client.close(force: true);
        await cache.shutdown();
        cache.dispose();
        transport.dio.close(force: true);
        await origin.close(force: true);
        await dir.delete(recursive: true);
      }
    },
  );
}
