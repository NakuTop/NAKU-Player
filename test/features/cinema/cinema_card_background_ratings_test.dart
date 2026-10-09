import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const _item = CinemaTitle(
  id: 'movie',
  sourceId: 'fixture',
  title: 'Fixture',
  year: '2020',
  doubanId: '12345',
  imdbId: 'tt1234567',
  rottenTomatoesId: 'm/fixture',
);
List<int> _json(Object data) => utf8.encode(jsonEncode(data));
List<int> _subject(Uri uri) => _json({
  'id': uri.pathSegments.last,
  'title': 'Fixture',
  'type': 'movie',
  'rating': {'max': 10, 'value': 8.2, 'count': 200},
});
List<int> _tomatoes(Uri uri, {int score = 88}) => utf8.encode(
  '<script type="application/ld+json">${jsonEncode({
    '@type': 'Movie',
    'url': uri.toString(),
    'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': score},
  })}</script>',
);
List<int> _dataset() => gzip.encode(
  utf8.encode('tconst\taverageRating\tnumVotes\ntt1234567\t7.6\t240\n'),
);

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('card-background-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test(
    'initial card publishes Douban before secondary scores and completes all providers',
    () async {
      final secondaryStarted = Completer<void>(), release = Completer<void>();
      final seen = <String>[];
      late CinemaRatingsRepository repository;
      repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          seen.add(uri.host);
          if (uri.host == 'm.douban.com') return _subject(uri);
          if (!secondaryStarted.isCompleted) secondaryStarted.complete();
          await release.future;
          if (uri.host == 'datasets.imdbws.com') return _dataset();
          return _tomatoes(uri);
        },
      );
      final pending = repository.loadForCard(_item);
      await secondaryStarted.future;
      expect(repository.scoreFor(_item, '豆瓣'), 8.2);
      expect(repository.scoreFor(_item, 'IMDb'), isNull);
      release.complete();
      final result = await pending;
      expect(result.ratings.map((r) => r.value), [8.2, 7.6, 88]);
      expect(result.ratings.every((r) => r.verified), isTrue);
      expect(repository.scoreFor(_item, '烂番茄'), 88);
      expect(seen.where((host) => host == 'datasets.imdbws.com'), hasLength(1));
      final count = seen.length;
      await repository.loadForCard(_item);
      expect(
        seen.length,
        count,
        reason: 'Finished visible cards do not repeat work on rebuild',
      );
    },
  );

  test(
    'ID-less card hydrates once and publishes under the original catalogue key',
    () async {
      const empty = CinemaTitle(
        id: 'movie',
        sourceId: 'fixture',
        title: 'Fixture',
        year: '2020',
      );
      var hydrated = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          if (uri.host == 'm.douban.com') return _subject(uri);
          if (uri.host == 'datasets.imdbws.com') return _dataset();
          return _tomatoes(uri);
        },
      );
      Future<CinemaTitle> resolve(CinemaTitle title) async {
        hydrated++;
        return _item;
      }

      final calls = [
        repository.loadForCard(empty, resolveTitle: resolve),
        repository.loadForCard(empty, resolveTitle: resolve),
      ];
      await Future.wait(calls);
      expect(hydrated, 1);
      expect(repository.peek(empty)?.identity.doubanId, '12345');
      expect(repository.scoreFor(empty, 'IMDb'), 7.6);
    },
  );

  test(
    'exact crosswalk resolves all card providers without opening details',
    () async {
      const movie = CinemaTitle(
        id: 'mapped',
        sourceId: 'fixture',
        title: 'Fixture',
        year: '2020',
        doubanId: '12345',
      );
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          if (uri.host == 'm.douban.com') return _subject(uri);
          if (uri.host == 'query.wikidata.org') {
            return _json({
              'results': {
                'bindings': [
                  {
                    'item': {'value': 'http://www.wikidata.org/entity/Q12345'},
                  },
                ],
              },
            });
          }
          if (uri.host == 'www.wikidata.org') {
            return _json({
              'entities': {
                'Q12345': {
                  'labels': {
                    'en': {'value': 'Fixture'},
                  },
                  'claims': {
                    for (final field in <String, Object>{
                      'P4529': '12345',
                      'P345': 'tt1234567',
                      'P1258': 'm/fixture',
                      'P31': {'id': 'Q11424'},
                      'P577': {'time': '+2020-01-01T00:00:00Z'},
                    }.entries)
                      field.key: [
                        {
                          'mainsnak': {
                            'datavalue': {'value': field.value},
                          },
                        },
                      ],
                  },
                },
              },
            });
          }
          if (uri.host == 'datasets.imdbws.com') return _dataset();
          return _tomatoes(uri);
        },
      );
      final result = await repository.loadForCard(movie);
      expect(result.ratings.map((r) => r.value), [8.2, 7.6, 88]);
      expect(result.identity.wikidataId, 'Q12345');
    },
  );

  test(
    'all card network traffic is capped at three and identical provider IDs coalesce',
    () async {
      var active = 0, peak = 0, calls = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          active++;
          calls++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          active--;
          if (uri.host == 'm.douban.com') return _subject(uri);
          return _json({
            'results': {'bindings': []},
          });
        },
      );
      await Future.wait([
        for (var i = 0; i < 8; i++)
          repository.loadForCard(
            CinemaTitle(
              id: '$i',
              sourceId: 'fixture',
              title: 'Fixture',
              year: '2020',
              doubanId: '12345',
            ),
          ),
      ]);
      expect(peak, lessThanOrEqualTo(3));
      expect(
        calls,
        2,
        reason:
            'One exact subject and one failed crosswalk, reused by all sources',
      );
    },
  );

  test(
    'independent subjects keep all provider traffic under the global network cap',
    () async {
      var active = 0, peak = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 8));
          active--;
          if (uri.host == 'm.douban.com') return _subject(uri);
          return _json({
            'results': {'bindings': []},
          });
        },
      );
      await Future.wait([
        for (var i = 0; i < 8; i++)
          repository.loadForCard(
            CinemaTitle(
              id: '$i',
              sourceId: 'fixture',
              title: 'Fixture $i',
              year: '2020',
              doubanId: '${12350 + i}',
            ),
          ),
      ]);
      expect(peak, 3);
    },
  );

  test(
    'a live consumer keeps a coalesced request after another card is disposed',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      var visible = true, calls = 0;
      const movie = CinemaTitle(
        id: 'a',
        sourceId: 'fixture',
        title: 'Fixture',
        rottenTomatoesId: 'm/fixture',
      );
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          calls++;
          if (!started.isCompleted) started.complete();
          await release.future;
          return _tomatoes(uri);
        },
      );
      final first = repository.loadForCard(movie, isCurrent: () => visible);
      await started.future;
      final second = repository.loadForCard(movie, isCurrent: () => true);
      visible = false;
      release.complete();
      final results = await Future.wait([first, second]);
      expect(results.last.ratings.last.value, 88);
      expect(calls, 1);
    },
  );

  test(
    'failed dataset downloads have a shared cooldown across different IMDb IDs',
    () async {
      var downloads = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          downloads++;
          throw const HttpException('IMDb temporarily unavailable');
        },
      );
      for (final id in ['tt1234567', 'tt7654321']) {
        final result = await repository.loadForCard(
          CinemaTitle(id: id, sourceId: 'fixture', title: id, imdbId: id),
        );
        expect(
          result.ratings.singleWhere((r) => r.provider == 'IMDb').value,
          isNull,
        );
      }
      expect(downloads, 1);
    },
  );

  test(
    'a later detail refresh updates another source card via shared provider cache',
    () async {
      var score = 88;
      const movie = CinemaTitle(
        id: 'a',
        sourceId: 'fixture',
        title: 'Fixture',
        rottenTomatoesId: 'm/fixture',
      );
      const other = CinemaTitle(
        id: 'b',
        sourceId: 'other',
        title: 'Fixture',
        rottenTomatoesId: 'm/fixture',
      );
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async => _tomatoes(uri, score: score),
      );
      await repository.loadForCard(movie);
      var changes = 0;
      repository.changes.addListener(() => changes++);
      score = 90;
      await repository.load(other, force: true);
      expect(repository.scoreFor(movie, '烂番茄'), 90);
      expect(changes, greaterThan(0));
    },
  );
}
