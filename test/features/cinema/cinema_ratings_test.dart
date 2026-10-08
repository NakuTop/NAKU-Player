import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const title = CinemaTitle(
  id: '1',
  sourceId: 'fixture',
  title: '星际穿越',
  year: '2014',
  doubanId: '1889243',
  sourceDoubanScore: 9.4,
);
Map<String, dynamic> entity({String imdb = 'tt0816692'}) => {
  'labels': {
    'zh-hans': {'value': '星际穿越'},
  },
  'claims': {
    for (final entry in {
      'P4529': ['1889243'],
      'P345': [imdb],
      'P1258': ['m/interstellar_2014'],
      'P31': [
        {'id': 'Q11424'},
      ],
      'P577': [
        {'time': '+2025-01-01T00:00:00Z'},
        {'time': '+2014-01-01T00:00:00Z'},
      ],
    }.entries)
      entry.key: entry.value
          .map(
            (v) => {
              'rank': 'normal',
              'mainsnak': {
                'datavalue': {'value': v},
              },
            },
          )
          .toList(),
  },
};
String page({
  String provider = 'RT',
  String name = 'Tomatometer',
  Object value = 89,
  Object scale = 100,
  String path = '/m/interstellar_2014',
}) =>
    '<script type="application/ld+json">${jsonEncode({
      '@type': 'Movie',
      'url': 'https://${provider == 'RT' ? 'www.rottentomatoes.com' : 'movie.douban.com'}$path',
      'aggregateRating': {'name': name, 'bestRating': scale, 'ratingValue': value, 'ratingCount': 147},
    })}</script>';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-ratings-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'IDs reject arbitrary URLs, path traversal, person IDs and query injection',
    () {
      for (final value in [
        'https://evil.test/m/movie',
        'm/../private',
        'm/movie?x=1',
        'celebrity/person',
      ]) {
        expect(
          () => RatingIdentity(rottenTomatoesId: value).validate(),
          throwsFormatException,
        );
      }
      expect(
        () => const RatingIdentity(doubanId: '1" }').validate(),
        throwsFormatException,
      );
      expect(
        () => const RatingIdentity(imdbId: 'nm1234567').validate(),
        throwsFormatException,
      );
      const RatingIdentity(
        doubanId: '1889243',
        imdbId: 'tt0816692',
        rottenTomatoesId: 'tv/stranger_things/s05',
      ).validate();
    },
  );
  test('exact crosswalk checks aliases and all documented release years', () {
    final result = CinemaRatingsRepository.identityFromEntity(
      title,
      const RatingIdentity(doubanId: '1889243'),
      'Q13417189',
      entity(),
    );
    expect(result.imdbId, 'tt0816692');
    expect(result.rottenTomatoesId, 'm/interstellar_2014');
    expect(result.label, '星际穿越');
  });
  test('same-name remake and season mismatch are not silently bound', () {
    for (final sample in [
      const CinemaTitle(
        id: '2',
        sourceId: 'fixture',
        title: '星际穿越',
        year: '2026',
      ),
      const CinemaTitle(
        id: '2',
        sourceId: 'fixture',
        title: '星际穿越 第二季',
        year: '2014',
      ),
    ]) {
      expect(
        () => CinemaRatingsRepository.identityFromEntity(
          sample,
          const RatingIdentity(doubanId: '1889243'),
          'Q13417189',
          entity(),
        ),
        throwsFormatException,
      );
    }
  });
  test('conflicting explicit IDs stay unresolved', () {
    expect(
      () => CinemaRatingsRepository.identityFromEntity(
        title,
        const RatingIdentity(doubanId: '1889243', imdbId: 'tt0111161'),
        'Q13417189',
        entity(),
      ),
      throwsFormatException,
    );
  });
  test('RT displays critic percentage; audience score never substitutes', () {
    const url = 'https://www.rottentomatoes.com/m/interstellar_2014';
    final rating = CinemaRatingsRepository.parseRatingPage('烂番茄', url, page());
    expect(rating.value, 89);
    expect(rating.scale, 100);
    expect(rating.count, 147);
    expect(rating.verified, isTrue);
    for (final body in [
      page(name: 'Popcornmeter'),
      page(value: 101),
      page(scale: 10),
      page(path: '/m/wrong_movie'),
      '<html>captcha</html>',
    ]) {
      expect(
        () => CinemaRatingsRepository.parseRatingPage('烂番茄', url, body),
        throwsFormatException,
      );
    }
  });
  test('Douban JSON-LD uses its original /10 scale', () {
    final rating = CinemaRatingsRepository.parseRatingPage(
      '豆瓣',
      'https://movie.douban.com/subject/1889243/',
      page(
        provider: 'Douban',
        value: '9.4',
        scale: '10',
        path: '/subject/1889243/',
      ),
    );
    expect(rating.value, 9.4);
    expect(rating.verified, isTrue);
  });
  test('IMDb matches the exact tconst and rejects invalid values', () async {
    final file = File('${directory.path}/test.gz');
    await file.writeAsBytes(
      gzip.encode(
        utf8.encode(
          'tconst\taverageRating\tnumVotes\ntt08166920\t1.0\t1\ntt0816692\t8.7\t2617420\ntt0111161\t99\t2\n',
        ),
      ),
    );
    expect(CinemaRatingsRepository.readImdbRating(file.path, 'tt0816692'), (
      8.7,
      2617420,
    ));
    expect(
      CinemaRatingsRepository.readImdbRating(file.path, 'tt0111161'),
      isNull,
    );
    expect(
      CinemaRatingsRepository.readImdbRating(file.path, 'tt1234567'),
      isNull,
    );
  });
  test(
    'provider failures remain independent and source score stays unverified',
    () async {
      final calls = <String>[];
      Future<List<int>> fetch(Uri uri, int _) async {
        calls.add(uri.host);
        if (uri.host == 'query.wikidata.org') {
          return utf8.encode(
            jsonEncode({
              'results': {
                'bindings': [
                  {
                    'item': {
                      'value': 'http://www.wikidata.org/entity/Q13417189',
                    },
                  },
                ],
              },
            }),
          );
        }
        if (uri.host == 'www.wikidata.org') {
          return utf8.encode(
            jsonEncode({
              'entities': {'Q13417189': entity()},
            }),
          );
        }
        if (uri.host == 'datasets.imdbws.com') {
          return gzip.encode(
            utf8.encode(
              'tconst\taverageRating\tnumVotes\ntt0816692\t8.7\t2617420\n',
            ),
          );
        }
        if (uri.host == 'www.rottentomatoes.com') return utf8.encode(page());
        return utf8.encode('<html>请完成验证</html>');
      }

      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      final result = await repository.load(title);
      expect(result.ratings.map((v) => v.value), [9.4, 8.7, 89]);
      expect(result.ratings.map((v) => v.verified), [false, true, true]);
      expect(result.ratings[0].note, contains('片源转述'));
      final count = calls.length;
      final cached = await repository.load(title);
      expect(cached.ratings[1].value, 8.7);
      expect(
        calls.length,
        count,
        reason: 'Positive mapping and provider cache avoid repeated network',
      );
      final restored = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      await restored.load(title);
      expect(calls.length, count, reason: 'Cache persists across app launches');
    },
  );
  test(
    'manual IDs persist and cannot inherit another Douban source score',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (_, _) async => utf8.encode('{}'),
      );
      await repository.setIdentity(
        title,
        const RatingIdentity(
          doubanId: '1292052',
          imdbId: 'tt0111161',
          rottenTomatoesId: 'm/shawshank_redemption',
          confirmed: true,
        ),
      );
      final restored = CinemaRatingsRepository(
        directory: directory,
        fetch: (_, _) async => utf8.encode('{}'),
      );
      final result = await restored.load(title);
      expect(result.identity.imdbId, 'tt0111161');
      expect(result.ratings[0].value, isNull);
    },
  );
  test('malformed user bindings are never overwritten', () async {
    final file = File('${directory.path}/ratings-v1.json');
    await file.writeAsString('unreadable');
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (_, _) async => utf8.encode('{}'),
    );
    final result = await repository.load(
      const CinemaTitle(id: 'empty', sourceId: 'test', title: 'No ID'),
    );
    expect(result.message, contains('已保留原文件'));
    expect(await file.readAsString(), 'unreadable');
    await expectLater(
      repository.setIdentity(title, const RatingIdentity()),
      throwsStateError,
    );
  });
}
