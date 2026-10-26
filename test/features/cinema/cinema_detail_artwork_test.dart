import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const _movie = CinemaTitle(
  id: 'source-film',
  sourceId: 'fixture',
  title: '同名作品',
  category: '电影',
  year: '1997',
  imdbId: 'tt0120338',
  poster: 'https://thumb.invalid/small.jpg',
);
const _background =
    'https://images.metahub.space/background/medium/tt0120338/img';
const _poster = 'https://images.metahub.space/poster/small/tt0120338/img';
Uint8List _bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Map<String, dynamic> _meta({
  String id = 'tt0120338',
  String type = 'movie',
  String background = _background,
}) => {
  'meta': {'id': id, 'type': type, 'background': background, 'poster': _poster},
};

void main() {
  setUp(CinemaDoubanAccess.resetForTesting);

  for (final (id, category, fixture) in [
    ('37116446', '电影', 'film'),
    ('36675942', '电视剧', 'series'),
  ]) {
    test(
      'real $fixture stills select a wide original without an IMDb ID',
      () async {
        final data =
            jsonDecode(
                  await File(
                    'test/features/cinema/fixtures/douban-$fixture-photos.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        final sizes = <String, (int, int)>{};
        for (final photo in data['photos']) {
          final large = photo['image']['large'];
          sizes[large['url']] = (large['width'], large['height']);
        }
        final requested = <Uri>[];
        final inspected = <String>[];
        final repository = CinemaDetailArtworkRepository(
          fetch: (uri, headers, limit, cancel) async {
            requested.add(uri);
            return _bytes(data);
          },
          inspect: (url, headers, cancel) async {
            inspected.add(url);
            return sizes[url]!;
          },
        );
        final result = await repository.resolveLandscape(
          CinemaTitle(
            id: id,
            sourceId: 'douban-discovery',
            title: '实际首页条目',
            category: category,
            doubanId: id,
          ),
        );
        expect(
          requested.single.path,
          '/rexxar/api/v2/${fixture == 'series' ? 'tv' : 'movie'}/$id/photos',
        );
        expect(requested.single.queryParameters, {
          'type': 'S',
          'start': '0',
          'count': '8',
        });
        expect(
          (result.width, result.height, result.highResolution),
          (1600, 900, true),
        );
        expect(inspected, [result.url]);
        if (fixture == 'series') {
          expect(
            result.url,
            isNot(data['photos'][0]['image']['large']['url']),
            reason: 'The first 4:3 still must not beat available 16:9 stills.',
          );
        }
      },
    );
  }

  for (final category in ['电影', '电视剧']) {
    test(
      'a $category portrait-only prefix gets one bounded contiguous still segment',
      () async {
        const subject = '14567890';
        final kind = category == '电影' ? 'movie' : 'tv';
        Map<String, dynamic> photo(int index, {bool wide = false}) => {
          'id': '${2900000000 + index}',
          'owner_uri': 'douban://douban.com/$kind/$subject',
          'type': 'photo',
          'image': {
            'large': {
              'url':
                  'https://img3.doubanio.com/view/photo/l/public/p${2900000000 + index}.jpg',
              'width': 1600,
              'height': wide ? 900 : 2400,
            },
          },
        };
        final requested = <(String?, String?)>[];
        final inspected = <String>[];
        final repository = CinemaDetailArtworkRepository(
          fetch: (uri, headers, limit, cancel) async {
            final start = uri.queryParameters['start'];
            requested.add((start, uri.queryParameters['count']));
            return _bytes({
              'total': 605,
              'photos': start == '0'
                  ? [for (var i = 0; i < 8; i++) photo(i)]
                  : [for (var i = 8; i < 48; i++) photo(i, wide: i == 16)],
            });
          },
          inspect: (url, headers, cancel) async {
            inspected.add(url);
            return (1920, 1080);
          },
        );
        final result = await repository.resolveLandscape(
          CinemaTitle(
            id: 'generic',
            sourceId: 'fixture',
            title: '普通条目',
            category: category,
            doubanId: subject,
          ),
        );
        expect(requested, [('0', '8'), ('8', '40')]);
        expect(inspected, [
          'https://img3.doubanio.com/view/photo/l/public/p2900000016.jpg',
        ]);
        expect(
          (result.width, result.height, result.highResolution),
          (1920, 1080, true),
        );
      },
    );
  }

  test(
    'a portrait-only gallery never turns into an unbounded metadata scan',
    () async {
      var requests = 0;
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          requests++;
          return _bytes({'total': 605, 'photos': []});
        },
        inspect: (url, headers, cancel) async =>
            fail('No usable candidate should be downloaded.'),
      );
      expect(
        (await repository.resolveLandscape(
          const CinemaTitle(
            id: 'generic',
            sourceId: 'fixture',
            title: '普通条目',
            category: '电影',
            doubanId: '14567890',
          ),
        )).url,
        isEmpty,
      );
      expect(requests, 2);
    },
  );

  test('stills never cross subject ownership or CDN photo identity', () async {
    for (final (owner, photoId) in [
      ('douban://douban.com/movie/37116445', '2931939488'),
      ('https://douban.com/movie/37116446', '2931939488'),
      ('douban://douban.com/movie/37116446', '2931939489'),
      ('douban://douban.com/movie/37116446?other=1', '2931939488'),
    ]) {
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes({
          'photos': [
            {
              'id': '2931939488',
              'type': 'photo',
              'owner_uri': owner,
              'image': {
                'large': {
                  'url':
                      'https://img3.doubanio.com/view/photo/l/public/p$photoId.jpg',
                  'width': 1600,
                  'height': 900,
                },
              },
            },
          ],
        }),
        inspect: (url, headers, cancel) async =>
            fail('An unrelated photo must never be downloaded.'),
      );
      final result = await repository.resolveLandscape(
        const CinemaTitle(
          id: 'stills',
          sourceId: 'fixture',
          title: '给阿嬷的情书',
          category: '电影',
          doubanId: '37116446',
        ),
      );
      expect(result.url, isEmpty);
    }
  });

  test(
    'advertised still dimensions are rechecked and image requests stay bounded',
    () async {
      final data = jsonDecode(
        await File(
          'test/features/cinema/fixtures/douban-film-photos.json',
        ).readAsString(),
      );
      final inspected = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes(data),
        inspect: (url, headers, cancel) async {
          inspected.add(url);
          return inspected.length == 1 ? (1600, 2400) : (960, 540);
        },
      );
      final result = await repository.resolveLandscape(
        const CinemaTitle(
          id: 'stills',
          sourceId: 'fixture',
          title: '给阿嬷的情书',
          category: '电影',
          doubanId: '37116446',
        ),
      );
      expect(inspected, hasLength(3));
      expect(result.url, isNot(inspected.first));
      expect(
        (result.width, result.height, result.highResolution),
        (960, 540, false),
      );
    },
  );

  test(
    'a subject-detail cooldown cannot suppress real subject stills',
    () async {
      final data = jsonDecode(
        await File(
          'test/features/cinema/fixtures/douban-film-photos.json',
        ).readAsString(),
      );
      CinemaDoubanAccess.noteResponse(200, {'code': 1309});
      expect(CinemaDoubanAccess.canRequestSubject(), isFalse);
      final requested = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          requested.add(uri.path);
          return _bytes(data);
        },
        inspect: (url, headers, cancel) async => (1600, 900),
      );
      final result = await repository.resolveLandscape(
        const CinemaTitle(
          id: 'stills',
          sourceId: 'fixture',
          title: '给阿嬷的情书',
          category: '电影',
          doubanId: '37116446',
        ),
      );
      expect(result.usableLandscape, isTrue);
      expect(requested, ['/rexxar/api/v2/movie/37116446/photos']);
    },
  );

  test(
    'stills limit suppresses repeated requests without limiting subject details',
    () async {
      var now = DateTime.utc(2026, 10, 26);
      final requested = <String>[];
      const portrait = 'https://images.invalid/portrait.jpg';
      const title = CinemaTitle(
        id: 'stills',
        sourceId: 'fixture',
        title: '给阿嬷的情书',
        category: '电影',
        doubanId: '37116446',
      );
      final repository = CinemaDetailArtworkRepository(
        now: () => now,
        fetch: (uri, headers, limit, cancel) async {
          requested.add(uri.path);
          return _bytes(
            uri.path.endsWith('/photos')
                ? {'code': 1309, 'msg': 'subject_ip_rate_limit'}
                : {
                    'id': '37116446',
                    'type': 'movie',
                    'pic': {'original': portrait},
                  },
          );
        },
        inspect: (url, headers, cancel) async => (1600, 2400),
      );
      expect((await repository.resolveLandscape(title)).url, isEmpty);
      expect(CinemaDoubanAccess.canRequestSubject(), isTrue);
      expect(
        (await repository.resolveLandscape(title, force: true)).url,
        isEmpty,
      );
      expect((await repository.resolve(title)).url, portrait);
      expect(requested, [
        '/rexxar/api/v2/movie/37116446/photos',
        '/rexxar/api/v2/movie/37116446',
      ]);
      now = now.add(CinemaDoubanAccess.cooldown + const Duration(seconds: 1));
      await repository.resolveLandscape(title, force: true);
      expect(requested.last, '/rexxar/api/v2/movie/37116446/photos');
      expect(requested, hasLength(3));
    },
  );

  test(
    'a stills cooldown keeps successful metadata available from cache',
    () async {
      final data = jsonDecode(
        await File(
          'test/features/cinema/fixtures/douban-film-photos.json',
        ).readAsString(),
      );
      final requested = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          requested.add(uri.path);
          return _bytes(
            uri.path.contains('/37116446/') ? data : {'code': 1309},
          );
        },
        inspect: (url, headers, cancel) async => (1600, 900),
      );
      const title = CinemaTitle(
        id: 'stills',
        sourceId: 'fixture',
        title: '给阿嬷的情书',
        category: '电影',
        doubanId: '37116446',
      );
      expect((await repository.resolveLandscape(title)).highResolution, isTrue);
      await repository.resolveLandscape(
        const CinemaTitle(
          id: 'other',
          sourceId: 'fixture',
          title: '另一作品',
          category: '电影',
          doubanId: '37116445',
        ),
      );
      expect(
        (await repository.resolveLandscape(title, force: true)).highResolution,
        isTrue,
      );
      expect(requested, hasLength(2));
      expect(CinemaDoubanAccess.canRequestSubject(), isTrue);
    },
  );

  test(
    'requests exact movie ID and selects verified wide HD before portrait',
    () async {
      final requested = <Uri>[];
      final inspected = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          requested.add(uri);
          return _bytes(_meta());
        },
        inspect: (url, headers, cancel) async {
          inspected.add(url);
          return (1920, 1080);
        },
      );
      final result = await repository.resolve(_movie);
      expect(
        requested.single.toString(),
        'https://v3-cinemeta.strem.io/meta/movie/tt0120338.json',
      );
      expect(inspected, [_background]);
      expect(
        (result.url, result.width, result.height, result.highResolution),
        (_background, 1920, 1080, true),
      );
      expect(_movie.poster, 'https://thumb.invalid/small.jpg');
      await repository.resolve(_movie);
      expect(requested, hasLength(1));
      expect(inspected, hasLength(1));
    },
  );

  test(
    'real high-resolution portrait is used when the wide file is low resolution',
    () async {
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes(_meta()),
        inspect: (url, headers, cancel) async =>
            url == _background ? (480, 270) : (1600, 2400),
      );
      final result = await repository.resolve(_movie);
      expect(result.url, _poster);
      expect(result.highResolution, isTrue);
    },
  );

  test(
    'landscape waits for the real background even when a cached HD portrait wins detail',
    () async {
      const portrait = 'https://images.invalid/portrait-original.jpg';
      CinemaDoubanAccess.rememberFeedSubject({
        'id': '1292722',
        'type': 'movie',
        'pic': {'original': portrait},
      });
      final metadata = Completer<Uint8List>();
      final inspected = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) =>
            uri.host == 'v3-cinemeta.strem.io'
            ? metadata.future
            : Future.value(
                _bytes({
                  'id': '1292722',
                  'type': 'movie',
                  'pic': {'original': portrait},
                }),
              ),
        inspect: (url, headers, cancel) async {
          inspected.add(url);
          return url == _background ? (3840, 2160) : (1600, 2400);
        },
      );
      final title = _movie.copyWith(doubanId: '1292722');
      expect((await repository.resolve(title)).url, portrait);
      var settled = false;
      final landscape = repository.resolveLandscape(title).then((result) {
        settled = true;
        return result;
      });
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);
      metadata.complete(_bytes(_meta()));
      final result = await landscape;
      expect(
        (result.url, result.width, result.height),
        (_background, 3840, 2160),
      );
      expect(result.highResolution, isTrue);
      expect(inspected, contains(portrait));
      expect(
        (await repository.resolve(title)).url,
        portrait,
        reason: 'The detail portrait cache keeps its established behaviour.',
      );
    },
  );

  test('a landscape miss does not poison the detail portrait cache', () async {
    const title = CinemaTitle(
      id: 'portrait-only',
      sourceId: 'fixture',
      title: '仅海报',
      poster: 'https://images.invalid/portrait.jpg',
    );
    final repository = CinemaDetailArtworkRepository(
      fetch: (uri, headers, limit, cancel) async =>
          fail('No ID-based request.'),
      inspect: (url, headers, cancel) async => (1600, 2400),
    );
    expect((await repository.resolveLandscape(title)).url, isEmpty);
    final detail = await repository.resolve(title);
    expect((detail.url, detail.highResolution), (title.poster, true));
  });

  test(
    'wide URL names cannot substitute for actual encoded dimensions',
    () async {
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes(_meta()),
        inspect: (url, headers, cancel) async => (1600, 2400),
      );
      final result = await repository.resolveLandscape(_movie);
      expect((result.url, result.highResolution), ('', false));
    },
  );

  test(
    'real 960 wide frames remain provisional and can retry for HD',
    () async {
      var now = DateTime.utc(2026, 10, 26);
      var inspected = 0;
      var fullSize = false;
      const title = CinemaTitle(
        id: 'wide-without-ids',
        sourceId: 'fixture',
        title: '真实横图',
        poster: 'https://images.invalid/source-wide.jpg',
      );
      final repository = CinemaDetailArtworkRepository(
        now: () => now,
        fetch: (uri, headers, limit, cancel) async =>
            fail('No ID-based request.'),
        inspect: (url, headers, cancel) async {
          inspected++;
          return fullSize ? (1920, 1080) : (960, 540);
        },
      );
      final preview = await repository.resolveLandscape(title);
      expect(
        (preview.url, preview.width, preview.highResolution),
        (title.poster, 960, false),
      );
      expect(preview.usableLandscape, isTrue);
      await repository.resolveLandscape(title);
      expect(inspected, 1);
      fullSize = true;
      now = now.add(const Duration(seconds: 31));
      final upgraded = await repository.resolveLandscape(title);
      expect((upgraded.width, upgraded.highResolution), (1920, true));
      expect(inspected, 2);
    },
  );

  test(
    'landscape movie and series caches keep their exact provider type',
    () async {
      final requested = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          requested.add(uri.path);
          return _bytes(_meta(type: uri.pathSegments[1]));
        },
        inspect: (url, headers, cancel) async => (1920, 1080),
      );
      await repository.resolveLandscape(_movie);
      await repository.resolveLandscape(
        const CinemaTitle(
          id: 'series',
          sourceId: 'fixture',
          title: '剧集',
          category: '电视剧',
          imdbId: 'tt0120338',
        ),
      );
      expect(requested, [
        '/meta/movie/tt0120338.json',
        '/meta/series/tt0120338.json',
      ]);
    },
  );

  test(
    'small files advertised as large never become HD by a decode target',
    () async {
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes(_meta()),
        inspect: (url, headers, cancel) async => (540, 803),
      );
      final result = await repository.resolve(_movie);
      expect(result.url, _movie.poster);
      expect(result.highResolution, isFalse);
    },
  );

  test(
    'missing provider identity never triggers a title search or changes fallback',
    () async {
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async =>
            fail('No name-based network lookup permitted'),
        inspect: (url, headers, cancel) async => (450, 675),
      );
      const title = CinemaTitle(
        id: 'no-id',
        sourceId: 'fixture',
        title: '同名作品',
        category: '电影',
        poster: 'https://thumb.invalid/original.jpg',
      );
      expect((await repository.resolve(title)).url, title.poster);
    },
  );

  for (final data in [
    _meta(id: 'tt1111111'),
    _meta(type: 'series'),
    _meta(
      background:
          'https://images.metahub.space/background/medium/tt1111111/img',
    ),
  ]) {
    test(
      'provider identity/type mismatch cannot select unrelated artwork: $data',
      () async {
        final inspected = <String>[];
        final repository = CinemaDetailArtworkRepository(
          fetch: (uri, headers, limit, cancel) async => _bytes(data),
          inspect: (url, headers, cancel) async {
            inspected.add(url);
            return (320, 480);
          },
        );
        final result = await repository.resolve(_movie);
        expect(result.highResolution, isFalse);
        expect(result.url, _movie.poster);
        if ((data['meta'] as Map)['id'] != 'tt0120338' ||
            (data['meta'] as Map)['type'] != 'movie') {
          expect(
            inspected,
            [_movie.poster],
            reason:
                'Only the source original may be checked after invalid metadata.',
          );
        }
      },
    );
  }

  test(
    'TV requests the series endpoint and keeps movie/series identity separate',
    () async {
      final uris = <Uri>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          uris.add(uri);
          return _bytes(_meta(type: 'series'));
        },
        inspect: (url, headers, cancel) async =>
            url == _background ? (1920, 1080) : (320, 480),
      );
      const series = CinemaTitle(
        id: 'series',
        sourceId: 'fixture',
        title: '同名作品',
        category: '欧美剧',
        imdbId: 'tt0120338',
        poster: 'https://thumb.invalid/series.jpg',
      );
      expect((await repository.resolve(series)).highResolution, isTrue);
      expect(uris.single.path, '/meta/series/tt0120338.json');
      expect((await repository.resolve(_movie)).highResolution, isFalse);
      expect(uris, hasLength(2));
    },
  );

  test('conflicting confirmed IDs do not issue provider requests', () async {
    final repository = CinemaDetailArtworkRepository(
      fetch: (uri, headers, limit, cancel) async =>
          fail('Conflicting identity must not fetch'),
    );
    expect(
      (await repository.resolve(
        _movie,
        identity: const RatingIdentity(imdbId: 'tt1111111'),
      )).url,
      _movie.poster,
    );
  });

  test(
    'official photo page supplies literal original URL for the exact subject photo',
    () async {
      const large =
          'https://img9.doubanio.com/view/photo/m_ratio_poster/public/p457760035.jpg';
      const original =
          'https://img9.doubanio.com/view/photo/l/public/p457760035.jpg';
      CinemaDoubanAccess.rememberFeedSubject({
        'id': '1292722',
        'type': 'movie',
        'pic': {'large': large},
      });
      final urls = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async {
          urls.add(uri.toString());
          if (uri.host == 'm.douban.com') {
            return _bytes({
              'id': '1292722',
              'type': 'movie',
              'pic': {'large': large},
            });
          }
          return Uint8List.fromList(
            utf8.encode(
              '<link rel="canonical" href="https://movie.douban.com/photos/photo/457760035/"><img src="$original"><img src="https://img9.doubanio.com/view/photo/l/public/p999999.jpg">',
            ),
          );
        },
        inspect: (url, headers, cancel) async {
          expect(headers['Referer'], isNotEmpty);
          return url == large ? (540, 803) : (2000, 2974);
        },
      );
      const title = CinemaTitle(
        id: 'same',
        sourceId: 'fixture',
        title: '影片',
        category: '电影',
        doubanId: '1292722',
        poster: large,
      );
      final result = await repository.resolve(title);
      expect(result.url, original);
      expect(result.width, 2000);
      expect(urls, [
        'https://m.douban.com/rexxar/api/v2/movie/1292722',
        'https://movie.douban.com/photos/photo/457760035/',
      ]);
    },
  );

  test(
    'late metadata from a replaced title never inspects or publishes artwork',
    () async {
      final pending = Completer<Uint8List>();
      var current = true;
      final inspected = <String>[];
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) => pending.future,
        inspect: (url, headers, cancel) async {
          inspected.add(url);
          return (1920, 1080);
        },
      );
      final result = repository.resolve(_movie, isCurrent: () => current);
      final check = expectLater(result, throwsStateError);
      current = false;
      pending.complete(_bytes(_meta()));
      await check;
      expect(inspected, isEmpty);
    },
  );

  test(
    'closing a slow request cancels immediately without awaiting the provider',
    () async {
      final cancel = CancelToken();
      final pending = Completer<Uint8List>();
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, token) => pending.future,
      );
      final result = repository.resolve(_movie, cancelToken: cancel);
      final check = expectLater(result, throwsA(isA<DioException>()));
      cancel.cancel('Detail closed');
      await check.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'one slow optional provider cannot discard another verified HD result',
    () async {
      final pending = Completer<Uint8List>();
      final repository = CinemaDetailArtworkRepository(
        deadline: const Duration(milliseconds: 100),
        fetch: (uri, headers, limit, cancel) => uri.host == 'm.douban.com'
            ? pending.future
            : Future.value(_bytes(_meta())),
        inspect: (url, headers, cancel) async => (1920, 1080),
      );
      const title = CinemaTitle(
        id: 'both',
        sourceId: 'fixture',
        title: '电影',
        category: '电影',
        imdbId: 'tt0120338',
        doubanId: '1292722',
        poster: 'https://thumb.invalid/card.jpg',
      );
      final result = await repository.resolve(title);
      expect(result.url, _background);
      expect(result.highResolution, isTrue);
      expect(pending.isCompleted, isFalse);
    },
  );

  for (final category in ['纪录片', '动画片']) {
    test(
      'exact TV feed type wins over a genre-only $category category',
      () async {
        const image = 'https://images.invalid/series-original.jpg';
        CinemaDoubanAccess.rememberFeedSubject({
          'id': '1234567',
          'type': 'tv',
          'pic': {'large': image},
        });
        final paths = <String>[];
        final repository = CinemaDetailArtworkRepository(
          fetch: (uri, headers, limit, cancel) async {
            paths.add(uri.path);
            return _bytes({
              'id': '1234567',
              'type': 'tv',
              'pic': {'large': image},
            });
          },
          inspect: (url, headers, cancel) async => (1920, 1080),
        );
        final result = await repository.resolve(
          CinemaTitle(
            id: 'series',
            sourceId: 'fixture',
            title: '剧集',
            category: category,
            doubanId: '1234567',
          ),
        );
        expect(result.url, image);
        expect(paths, ['/rexxar/api/v2/tv/1234567']);
      },
    );
  }

  test(
    'a small catalogue feed does not suppress full exact-ID HD metadata',
    () async {
      const small = 'https://images.invalid/card.jpg';
      const original = 'https://images.invalid/original.jpg';
      CinemaDoubanAccess.rememberFeedSubject({
        'id': '1292722',
        'type': 'movie',
        'pic': {'large': small},
      });
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async => _bytes({
          'id': '1292722',
          'type': 'movie',
          'pic': {'original': original, 'large': small},
        }),
        inspect: (url, headers, cancel) async =>
            url == original ? (2400, 1600) : (450, 675),
      );
      final result = await repository.resolve(
        const CinemaTitle(
          id: 'movie',
          sourceId: 'fixture',
          title: '电影',
          category: '电影',
          doubanId: '1292722',
          poster: small,
        ),
      );
      expect(result.url, original);
      expect(result.highResolution, isTrue);
    },
  );

  test(
    'an existing original without external IDs is verified by its encoded size',
    () async {
      const original = 'https://images.invalid/already-original.jpg';
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) async =>
            fail('No title search is needed.'),
        inspect: (url, headers, cancel) async {
          expect(url, original);
          return (3840, 2160);
        },
      );
      final result = await repository.resolve(
        const CinemaTitle(
          id: 'original',
          sourceId: 'fixture',
          title: '本身高清',
          poster: original,
        ),
      );
      expect(
        (result.width, result.height, result.highResolution),
        (3840, 2160, true),
      );
    },
  );

  test('force retry bypasses a terminal low-resolution result', () async {
    var fullSize = false;
    final repository = CinemaDetailArtworkRepository(
      fetch: (uri, headers, limit, cancel) async => _bytes(_meta()),
      inspect: (url, headers, cancel) async =>
          fullSize ? (1920, 1080) : (450, 675),
    );
    expect((await repository.resolve(_movie)).highResolution, isFalse);
    fullSize = true;
    expect((await repository.resolve(_movie)).highResolution, isFalse);
    expect(
      (await repository.resolve(_movie, force: true)).highResolution,
      isTrue,
    );
  });

  test(
    'deadline is a terminal lookup failure with the existing poster retained',
    () async {
      final pending = Completer<Uint8List>();
      final repository = CinemaDetailArtworkRepository(
        deadline: const Duration(milliseconds: 10),
        fetch: (uri, headers, limit, cancel) => pending.future,
      );
      final result = await repository
          .resolve(_movie)
          .timeout(const Duration(seconds: 1));
      expect(result.url, _movie.poster);
      expect(result.highResolution, isFalse);
    },
  );

  testWidgets(
    'original encoded file dimensions are read before any resized decode',
    (tester) async {
      await tester.runAsync(() async {
        final directory = await Directory.systemTemp.createTemp(
          'naku-artwork-pixels-',
        );
        try {
          final recorder = ui.PictureRecorder();
          ui.Canvas(
            recorder,
          ).drawRect(const ui.Rect.fromLTWH(0, 0, 300, 450), ui.Paint());
          final picture = recorder.endRecording();
          final image = await picture.toImage(300, 450);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = await File(
            '${directory.path}/low-original.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          expect(
            await CinemaDetailArtworkRepository.readOriginalDimensions(file),
            (300, 450),
          );
          image.dispose();
          picture.dispose();
        } finally {
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
