import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const _timeout = Duration(seconds: 10);
const _allIdsTitle = CinemaTitle(
  id: 'all-ids',
  sourceId: 'regression',
  title: 'Fixture movie',
  doubanId: '1889243',
  imdbId: 'tt0816692',
  rottenTomatoesId: 'm/fixture_movie',
);

Map<String, Object?> _ratingNode({
  String? url,
  String? id,
  num value = 88,
  num scale = 100,
}) => {
  '@type': 'Movie',
  'url': ?url,
  '@id': ?id,
  'aggregateRating': {
    'name': scale == 100 ? 'Tomatometer' : 'AggregateRating',
    'bestRating': scale,
    'ratingValue': value,
    'ratingCount': 147,
  },
};

String _page(Object json) =>
    '<script type="application/ld+json">${jsonEncode(json)}</script>';

List<int> _imdbDataset() => gzip.encode(
  utf8.encode('tconst\taverageRating\tnumVotes\ntt0816692\t8.7\t2617420\n'),
);

CinemaRating _provider(CinemaRatings result, String name) =>
    result.ratings.singleWhere((rating) => rating.provider == name);

Map<String, Object?> _seasonEntity({
  required String name,
  required String instanceOf,
}) => {
  'labels': {
    'en': {'value': name},
  },
  'claims': {
    for (final entry in <String, Object>{
      'P4529': '12345678',
      'P345': 'tt1234567',
      'P1258': 'tv/fixture_show',
      'P31': {'id': instanceOf},
      'P577': {'time': '+2025-01-01T00:00:00Z'},
    }.entries)
      entry.key: [
        {
          'rank': 'normal',
          'mainsnak': {
            'datavalue': {'value': entry.value},
          },
        },
      ],
  },
};

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ratings-regression-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'JSON-LD without identity or with the wrong host cannot be verified',
    () {
      const url = 'https://www.rottentomatoes.com/m/fixture_movie';
      for (final node in [
        _ratingNode(),
        _ratingNode(url: 'https://other.example/m/fixture_movie'),
        _ratingNode(id: 'https://other.example/m/fixture_movie'),
      ]) {
        expect(
          () =>
              CinemaRatingsRepository.parseRatingPage('烂番茄', url, _page(node)),
          throwsFormatException,
        );
      }
      // An unrelated first node must not mask the later exact-ID node.
      final rating = CinemaRatingsRepository.parseRatingPage(
        '烂番茄',
        url,
        _page({
          '@graph': [_ratingNode(value: 99), _ratingNode(id: url, value: 88)],
        }),
      );
      expect(rating.verified, isTrue);
      expect(rating.value, 88);
      expect(rating.url, url);
    },
  );

  test(
    'exact-name exact-year seasons cannot auto-inherit a whole-series ID',
    () {
      for (final sample in [
        (name: 'Fixture Show', instanceOf: 'Q3464665'),
        (name: 'Fixture Show 第五季', instanceOf: 'Q5398426'),
      ]) {
        expect(
          () => CinemaRatingsRepository.identityFromEntity(
            CinemaTitle(
              id: 'season',
              sourceId: 'regression',
              title: sample.name,
              year: '2025',
            ),
            const RatingIdentity(doubanId: '12345678'),
            'Q123456',
            _seasonEntity(name: sample.name, instanceOf: sample.instanceOf),
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'reason',
              contains('季度条目需手动确认'),
            ),
          ),
        );
      }
    },
  );

  for (final badField in ['string value', 'missing scale']) {
    test(
      'one $badField cache entry does not break the other providers',
      () async {
        final now = DateTime.now();
        final identity = const RatingIdentity(
          doubanId: '1889243',
          imdbId: 'tt0816692',
          rottenTomatoesId: 'm/fixture_movie',
          confirmed: true,
        ).toJson();
        final badCache = CinemaRating(
          provider: '豆瓣',
          value: 9.4,
          url: 'https://movie.douban.com/subject/1889243/',
          note: 'Fixture cached value',
          verified: true,
          fetchedAt: now,
        ).toJson();
        if (badField == 'string value') {
          badCache['value'] = '9.4';
        } else {
          badCache.remove('scale');
        }
        final cacheFile = File('${directory.path}/ratings-v1.json');
        await cacheFile.writeAsString(
          jsonEncode({
            'version': 1,
            'bindings': {_allIdsTitle.key: identity},
            'mappings': <String, Object?>{},
            'cache': {
              '豆瓣:1889243': badCache,
              'IMDb:tt0816692': CinemaRating(
                provider: 'IMDb',
                value: 8.7,
                count: 2617420,
                url: 'https://www.imdb.com/title/tt0816692/',
                note: 'Fixture healthy cache',
                verified: true,
                fetchedAt: now,
              ).toJson(),
            },
          }),
        );
        final requests = <String>[];
        final repository = CinemaRatingsRepository(
          directory: directory,
          fetch: (uri, _) async {
            requests.add(uri.host);
            if (uri.host == 'movie.douban.com') {
              return utf8.encode(
                _page(_ratingNode(url: uri.toString(), value: 9.1, scale: 10)),
              );
            }
            if (uri.host == 'www.rottentomatoes.com') {
              return utf8.encode(_page(_ratingNode(url: uri.toString())));
            }
            throw StateError('Unexpected fixture request: $uri');
          },
        );
        final result = await repository.load(_allIdsTitle).timeout(_timeout);
        expect(result.ratings.map((rating) => rating.value), [9.1, 8.7, 88]);
        expect(result.ratings.every((rating) => rating.verified), isTrue);
        expect(
          requests,
          unorderedEquals(['movie.douban.com', 'www.rottentomatoes.com']),
        );
        final saved = jsonDecode(await cacheFile.readAsString()) as Map;
        expect(saved['bindings'], {_allIdsTitle.key: identity});
        expect(saved['cache']['豆瓣:1889243']['value'], 9.1);
      },
    );
  }

  test(
    'a newly modified corrupt IMDb gzip is repaired with one download',
    () async {
      final file = File('${directory.path}/title.ratings.tsv.gz');
      await file.writeAsString('not a gzip');
      await file.setLastModified(DateTime.now());
      var downloads = 0;
      final replacement = _imdbDataset();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          expect(
            uri.toString(),
            'https://datasets.imdbws.com/title.ratings.tsv.gz',
          );
          downloads++;
          return replacement;
        },
      );
      const title = CinemaTitle(
        id: 'imdb-only',
        sourceId: 'regression',
        title: 'Fixture movie',
        imdbId: 'tt0816692',
      );
      // No force flag: the test exercises automatic repair of a fresh local file.
      final result = await repository.load(title).timeout(_timeout);
      expect(_provider(result, 'IMDb').value, 8.7);
      expect(_provider(result, 'IMDb').verified, isTrue);
      expect(downloads, 1);
      expect(await file.readAsBytes(), replacement);
      await repository.load(title).timeout(_timeout);
      expect(downloads, 1, reason: 'The repaired cache should remain usable');
    },
  );

  test(
    'a failed IMDb repair remains bounded and does not replace the old file',
    () async {
      final file = File('${directory.path}/title.ratings.tsv.gz');
      await file.writeAsString('local corrupt fixture');
      await file.setLastModified(DateTime.now());
      var downloads = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          expect(uri.host, 'datasets.imdbws.com');
          downloads++;
          return utf8.encode('also not a gzip');
        },
      );
      final result = await repository
          .load(
            const CinemaTitle(
              id: 'imdb-failed-repair',
              sourceId: 'regression',
              title: 'Fixture movie',
              imdbId: 'tt0816692',
            ),
          )
          .timeout(_timeout);
      expect(_provider(result, 'IMDb').value, isNull);
      expect(_provider(result, 'IMDb').verified, isFalse);
      expect(downloads, 1);
      expect(await file.readAsString(), 'local corrupt fixture');
    },
  );

  test('manual binding changes do not reuse an in-flight forced lookup', () async {
    const oldUrl = 'https://www.rottentomatoes.com/m/old_movie';
    const newUrl = 'https://www.rottentomatoes.com/m/new_movie';
    const title = CinemaTitle(
      id: 'changing-binding',
      sourceId: 'regression',
      title: 'Fixture movie',
      rottenTomatoesId: 'm/old_movie',
    );
    final oldStarted = Completer<void>();
    final newStarted = Completer<void>();
    final oldResponse = Completer<List<int>>();
    final newResponse = Completer<List<int>>();
    final calls = <String>[];
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (uri, _) {
        calls.add(uri.toString());
        if (uri.toString() == oldUrl) {
          if (!oldStarted.isCompleted) oldStarted.complete();
          return oldResponse.future;
        }
        if (uri.toString() == newUrl) {
          if (!newStarted.isCompleted) newStarted.complete();
          return newResponse.future;
        }
        throw StateError('Unexpected fixture request: $uri');
      },
    );
    Future<CinemaRatings>? oldLookup;
    Future<CinemaRatings>? newLookup;
    void finishResponses() {
      if (!oldResponse.isCompleted) {
        oldResponse.complete(
          utf8.encode(_page(_ratingNode(url: oldUrl, value: 40))),
        );
      }
      if (!newResponse.isCompleted) {
        newResponse.complete(
          utf8.encode(_page(_ratingNode(url: newUrl, value: 93))),
        );
      }
    }

    try {
      oldLookup = repository.load(title, force: true);
      await oldStarted.future.timeout(_timeout);
      await repository.setIdentity(
        title,
        const RatingIdentity(rottenTomatoesId: 'm/new_movie', confirmed: true),
      );
      newLookup = repository.load(title, force: true);
      expect(identical(oldLookup, newLookup), isFalse);
      await newStarted.future.timeout(_timeout);
      newResponse.complete(
        utf8.encode(_page(_ratingNode(url: newUrl, value: 93))),
      );
      final current = await newLookup.timeout(_timeout);
      expect(current.identity.rottenTomatoesId, 'm/new_movie');
      expect(_provider(current, '烂番茄').value, 93);
      expect(_provider(current, '烂番茄').url, newUrl);

      // The old network response arrives after the new binding is already shown.
      oldResponse.complete(
        utf8.encode(_page(_ratingNode(url: oldUrl, value: 40))),
      );
      final previous = await oldLookup.timeout(_timeout);
      expect(previous.identity.rottenTomatoesId, 'm/old_movie');
      final later = await repository.load(title).timeout(_timeout);
      expect(later.identity.rottenTomatoesId, 'm/new_movie');
      expect(_provider(later, '烂番茄').value, 93);
      expect(calls, [oldUrl, newUrl]);
    } finally {
      // Always settle controlled requests before deleting their cache directory.
      finishResponses();
      await Future.wait([
        ?oldLookup,
        ?newLookup,
      ]).timeout(_timeout);
    }
  });
}
