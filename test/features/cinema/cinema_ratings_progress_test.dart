import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const item = CinemaTitle(
  id: 'one',
  sourceId: 'fixture',
  title: 'Fixture',
  year: '2020',
  category: '电影',
  doubanId: '12345',
  imdbId: 'tt1234567',
  rottenTomatoesId: 'm/fixture',
);
List<int> subject(Uri uri) => utf8.encode(
  jsonEncode({
    'id': uri.pathSegments.last,
    'title': 'Fixture',
    'type': 'movie',
    'rating': {'max': 10, 'value': 8.2, 'count': 200},
  }),
);
List<int> dataset() => gzip.encode(
  utf8.encode('tconst\taverageRating\tnumVotes\ntt1234567\t7.6\t240\n'),
);
List<int> tomatoes(Uri uri) => utf8.encode(
  '<script type="application/ld+json">${jsonEncode({
    '@type': 'Movie',
    'url': uri.toString(),
    'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 88},
  })}</script>',
);
Future<List<int>> fetch(Uri uri, int _) async {
  if (uri.host == 'm.douban.com') return subject(uri);
  if (uri.host == 'datasets.imdbws.com') return dataset();
  return tomatoes(uri);
}

class Stub extends CinemaRatingsRepository {
  int requests = 0;
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    requests++;
    return const CinemaRatings(
      identity: RatingIdentity(),
      ratings: [],
      message: 'offline',
    );
  }
}

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('ratings-progress-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  test('chosen Douban provider completes while RT is still blocked', () async {
    final release = Completer<void>();
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (uri, limit) async {
        if (uri.host.contains('rottentomatoes')) await release.future;
        return fetch(uri, limit);
      },
    );
    final full = repository.loadForCard(item);
    final selected = await repository
        .loadForProvider(item, '豆瓣')
        .timeout(const Duration(seconds: 2));
    expect(selected.ratings.first.value, 8.2);
    expect(release.isCompleted, isFalse);
    release.complete();
    await full;
  });

  test(
    'explicit IMDb does not wait for unrelated missing RT crosswalk',
    () async {
      final release = Completer<void>();
      final crosswalk = Completer<void>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          if (uri.host == 'query.wikidata.org') {
            crosswalk.complete();
            await release.future;
            return utf8.encode('{"results":{"bindings":[]}}');
          }
          return fetch(uri, limit);
        },
      );
      final title = item.copyWith(rottenTomatoesId: '');
      final full = repository.loadForCard(title);
      await crosswalk.future;
      final selected = await repository
          .loadForProvider(title, 'IMDb')
          .timeout(const Duration(seconds: 2));
      expect(
        selected.ratings.firstWhere((r) => r.provider == 'IMDb').value,
        7.6,
      );
      expect(release.isCompleted, isFalse);
      release.complete();
      await full;
    },
  );

  test(
    'partial IDs still request missing source Douban metadata once',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      var calls = 0;
      final partial = item.copyWith(doubanId: '');
      final result = await repository.loadForCard(
        partial,
        resolveTitle: (title) async {
          calls++;
          return item;
        },
      );
      expect(calls, 1);
      expect(result.identity.doubanId, '12345');
      expect(repository.scoreFor(partial, '豆瓣'), 8.2);
    },
  );

  test(
    'same source work detail identity refresh reaches original ID-less profile',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      final empty = item.copyWith(
        doubanId: '',
        imdbId: '',
        rottenTomatoesId: '',
      );
      await repository.loadForCard(empty);
      expect(repository.scoreFor(empty, '豆瓣'), isNull);
      await repository.load(item);
      expect(repository.peek(empty)?.identity.doubanId, '12345');
      expect(repository.scoreFor(empty, 'IMDb'), 7.6);
      // Another old metadata request cannot replace the learned identity with blanks.
      await repository.load(empty);
      expect(repository.scoreFor(empty, '烂番茄'), 88);
    },
  );

  test(
    'profile sharing rejects title/year/type or explicit ID conflicts',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      await repository.load(item);
      final empty = item.copyWith(
        doubanId: '',
        imdbId: '',
        rottenTomatoesId: '',
      );
      for (final changed in [
        CinemaTitle.fromJson({...empty.toJson(), 'title': 'Different'}),
        CinemaTitle.fromJson({...empty.toJson(), 'year': '2021'}),
        CinemaTitle.fromJson({...empty.toJson(), 'category': '电视剧'}),
        empty.copyWith(doubanId: '98765'),
        empty.copyWith(imdbId: 'tt9999999'),
      ]) {
        expect(repository.peek(changed), isNull);
      }
    },
  );

  test(
    'manual correction clears learned profiles and provider readiness',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      await repository.loadForCard(item);
      final empty = item.copyWith(
        doubanId: '',
        imdbId: '',
        rottenTomatoesId: '',
      );
      await repository.setIdentity(
        empty,
        const RatingIdentity(confirmed: true),
      );
      final result = await repository.loadForProvider(empty, 'IMDb');
      expect(result.identity.imdbId, isEmpty);
      expect(result.ratings.every((r) => r.value == null), isTrue);
      await repository.loadForCard(empty);
    },
  );

  test(
    'known IMDb publishes while the Douban response is still pending',
    () async {
      final release = Completer<void>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          if (uri.host == 'm.douban.com') await release.future;
          return fetch(uri, limit);
        },
      );
      final full = repository.loadForCard(item);
      final result = await repository
          .loadForProvider(item, 'IMDb')
          .timeout(const Duration(seconds: 2));
      expect(result.ratings.firstWhere((r) => r.provider == 'IMDb').value, 7.6);
      expect(release.isCompleted, isFalse);
      release.complete();
      await full;
    },
  );

  test(
    'a slow missing-ID resolver cannot occupy known-ID provider slots',
    () async {
      final release = Completer<CinemaTitle>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      final unknown = item.copyWith(
        doubanId: '',
        imdbId: '',
        rottenTomatoesId: '',
      );
      final blocked = [
        for (var i = 0; i < 3; i++)
          repository.loadForCard(
            CinemaTitle.fromJson({...unknown.toJson(), 'id': 'waiting$i'}),
            resolveTitle: (_) => release.future,
          ),
      ];
      final known = await repository
          .loadForProvider(item, '豆瓣')
          .timeout(const Duration(seconds: 2));
      expect(known.ratings.first.value, 8.2);
      release.complete(unknown);
      await Future.wait(blocked);
      await repository.loadForCard(item);
    },
  );

  test(
    'known IMDb publishes before slow missing-Douban discovery completes',
    () async {
      final release = Completer<CinemaTitle>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      final partial = item.copyWith(doubanId: '', rottenTomatoesId: '');
      final full = repository.loadForCard(
        partial,
        resolveTitle: (_) => release.future,
      );
      var doubanReady = false;
      final douban = repository
          .loadForProvider(partial, '豆瓣', resolveTitle: (_) => release.future)
          .then((result) {
            doubanReady = true;
            return result;
          });
      final result = await repository
          .loadForProvider(partial, 'IMDb', resolveTitle: (_) => release.future)
          .timeout(const Duration(seconds: 2));
      expect(result.ratings.firstWhere((r) => r.provider == 'IMDb').value, 7.6);
      expect(doubanReady, isFalse);
      expect(release.isCompleted, isFalse);
      release.complete(item);
      await Future.wait([full, douban]);
      expect(repository.scoreFor(partial, '豆瓣'), 8.2);
    },
  );

  test(
    'shared subject cooldown suppresses JSON requests while preserving HTML fallback',
    () async {
      CinemaDoubanAccess.resetForTesting();
      addTearDown(CinemaDoubanAccess.resetForTesting);
      var subjectCalls = 0, htmlCalls = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          if (uri.path.contains('/rexxar/')) {
            subjectCalls++;
            return utf8.encode('{"code":1309,"msg":"subject_ip_rate_limit"}');
          }
          htmlCalls++;
          throw const HttpException('豆瓣暂时限制访问或要求验证，请在官网查看');
        },
      );
      for (final id in ['12345', '12346', '12347']) {
        await repository.loadQuickRatings(item.copyWith(doubanId: id));
      }
      expect(subjectCalls, 1);
      expect(htmlCalls, 3);
      expect(CinemaDoubanAccess.canRequestSubject(), isFalse);
    },
  );

  test('provider API preserves virtual card-only offline stubs', () async {
    final repository = Stub();
    final result = await repository.loadForProvider(item, 'IMDb');
    expect(result.message, 'offline');
    expect(repository.requests, 1);
  });
}
