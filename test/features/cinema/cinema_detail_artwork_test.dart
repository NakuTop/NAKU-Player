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
        var inspected = 0;
        final repository = CinemaDetailArtworkRepository(
          fetch: (uri, headers, limit, cancel) async => _bytes(data),
          inspect: (url, headers, cancel) async {
            inspected++;
            return (320, 480);
          },
        );
        final result = await repository.resolve(_movie);
        expect(result.highResolution, isFalse);
        expect(result.url, _movie.poster);
        if ((data['meta'] as Map)['id'] != 'tt0120338' ||
            (data['meta'] as Map)['type'] != 'movie') {
          expect(inspected, 0);
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
        inspect: (url, headers, cancel) async => (1920, 1080),
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
      expect(urls, ['https://movie.douban.com/photos/photo/457760035/']);
    },
  );

  test(
    'late metadata from a replaced title never inspects or publishes artwork',
    () async {
      final pending = Completer<Uint8List>();
      var current = true;
      var inspected = 0;
      final repository = CinemaDetailArtworkRepository(
        fetch: (uri, headers, limit, cancel) => pending.future,
        inspect: (url, headers, cancel) async {
          inspected++;
          return (1920, 1080);
        },
      );
      final result = repository.resolve(_movie, isCurrent: () => current);
      final check = expectLater(result, throwsStateError);
      current = false;
      pending.complete(_bytes(_meta()));
      await check;
      expect(inspected, 0);
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
