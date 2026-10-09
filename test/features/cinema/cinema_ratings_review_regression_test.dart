import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_rating_title_resolver.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

const _source = CinemaSource(
  id: 'fixture',
  name: 'Fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.test/api',
);
CinemaTitle _item(int index) => CinemaTitle(
  id: '$index',
  sourceId: 'fixture',
  title: '作品$index',
  year: '2020',
  category: '电影',
  doubanId: '${12345 + index}',
  imdbId: 'tt${1234567 + index}',
  rottenTomatoesId: 'm/fixture_$index',
);
CinemaTitle _edit(CinemaTitle title, Map<String, dynamic> changes) =>
    CinemaTitle.fromJson({...title.toJson(), ...changes});
CinemaTitle _withoutIds(CinemaTitle title) =>
    title.copyWith(doubanId: '', imdbId: '', rottenTomatoesId: '');
Future<List<int>> _fetch(Uri uri, int limit) async {
  if (uri.host == 'm.douban.com') {
    return utf8.encode(
      jsonEncode({
        'id': uri.pathSegments.last,
        'title': 'Fixture',
        'type': 'movie',
        'rating': {'max': 10, 'value': 8.2, 'count': 200},
      }),
    );
  }
  if (uri.host == 'datasets.imdbws.com') {
    return gzip.encode(
      utf8.encode(
        'tconst\taverageRating\tnumVotes\n${List.generate(5, (i) => 'tt${1234567 + i}\t7.3\t240\n').join()}',
      ),
    );
  }
  return utf8.encode(
    '<script type="application/ld+json">${jsonEncode({
      '@type': 'Movie',
      'url': uri.toString(),
      'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 88},
    })}</script>',
  );
}

class _SourceRepository extends CinemaRepository {
  _SourceRepository(this.result);
  final CinemaTitle result;
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async =>
      result;
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ratings-review-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'third IMDb prefetch must not queue behind first two unrelated RT requests',
    () async {
      final release = Completer<void>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          if (uri.host.contains('rottentomatoes')) await release.future;
          return _fetch(uri, limit);
        },
      );
      final full = [
        repository.loadForCard(_item(0)),
        repository.loadForCard(_item(1)),
      ];
      await Future.wait([
        repository.loadForProvider(_item(0), 'IMDb'),
        repository.loadForProvider(_item(1), 'IMDb'),
      ]);
      final third = repository.loadForProvider(_item(2), 'IMDb');
      var completedBeforeRt = true;
      try {
        await third.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        completedBeforeRt = false;
      }
      release.complete();
      await third;
      await Future.wait([...full, repository.loadForCard(_item(2))]);
      expect(
        completedBeforeRt,
        isTrue,
        reason:
            'The selected IMDb provider should progress beyond two cards without waiting for RT',
      );
    },
  );

  test(
    'direct memory lookup must reject an ID-less profile with a changed film series kind',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: _fetch,
      );
      final original = _withoutIds(_item(0));
      await repository.loadForCard(
        original,
        resolveTitle: (_) async => _item(0),
      );
      expect(repository.peek(_edit(original, {'category': '电视剧'})), isNull);
    },
  );

  test(
    'drama film source category can learn a matching movie detail identity',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: _fetch,
      );
      final original = _edit(_withoutIds(_item(0)), {'category': '剧情片'});
      await repository.loadForCard(original);
      await repository.load(_item(0));
      expect(repository.scoreFor(original, '豆瓣'), 8.2);
    },
  );

  test(
    'source resolver cannot bind a season to its series through a shared alias',
    () async {
      final original = _edit(_withoutIds(_item(0)), {
        'title': '示例剧第二季',
        'aliases': '示例剧',
        'category': '电视剧',
      });
      final detail = _edit(_item(0), {
        'title': '示例剧',
        'aliases': '',
        'category': '电视剧',
      });
      final resolver = CinemaRatingTitleResolver(
        repository: _SourceRepository(detail),
        sourceFor: (_) => _source,
      );
      final result = await resolver.resolve(original);
      resolver.dispose();
      expect(result.doubanId, isEmpty);
    },
  );
  test(
    'profile broadcasting cannot transfer a series rating to a season through aliases',
    () async {
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: _fetch,
      );
      final original = _edit(_withoutIds(_item(0)), {
        'title': '示例剧第二季',
        'aliases': '示例剧',
        'category': '电视剧',
      });
      await repository.loadForCard(original);
      for (final name in ['示例剧', '示例剧第一季']) {
        await repository.load(
          _edit(_item(0), {'title': name, 'aliases': '示例剧', 'category': '电视剧'}),
        );
        expect(repository.peek(original)?.identity.doubanId, isEmpty);
        expect(repository.scoreFor(original, '豆瓣'), isNull);
      }
    },
  );

  test(
    'two blocked RT connections leave capacity for another Douban score',
    () async {
      final release = Completer<void>();
      final bothEntered = Completer<void>();
      var rtEntered = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          if (uri.host.contains('rottentomatoes')) {
            rtEntered++;
            if (rtEntered == 2) bothEntered.complete();
            await release.future;
          }
          return _fetch(uri, limit);
        },
      );
      final blocked = [
        for (var i = 0; i < 2; i++)
          repository.loadForCard(_item(i).copyWith(doubanId: '', imdbId: '')),
      ];
      await bothEntered.future.timeout(const Duration(seconds: 2));
      final title = _item(2);
      final full = repository.loadForCard(title);
      final selected = repository.loadForProvider(title, '豆瓣');
      var completedBeforeRt = false;
      double? value;
      try {
        final result = await selected.timeout(const Duration(seconds: 1));
        value = result.ratings.firstWhere((r) => r.provider == '豆瓣').value;
        completedBeforeRt = true;
      } on TimeoutException {
        // Release blocked fixture requests before reporting the failed contract.
      } finally {
        release.complete();
        await Future.wait([...blocked, full, selected]);
      }
      expect(completedBeforeRt, isTrue);
      expect(value, 8.2);
    },
  );

  test(
    'cold IMDb dataset bypasses two unrelated blocked RT connections',
    () async {
      final release = Completer<void>();
      final bothEntered = Completer<void>();
      var rtEntered = 0, datasetCalls = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, limit) async {
          if (uri.host.contains('rottentomatoes')) {
            rtEntered++;
            if (rtEntered == 2) bothEntered.complete();
            await release.future;
          }
          if (uri.host == 'datasets.imdbws.com') datasetCalls++;
          return _fetch(uri, limit);
        },
      );
      final blocked = [
        for (var i = 0; i < 2; i++)
          repository.loadForCard(_item(i).copyWith(doubanId: '', imdbId: '')),
      ];
      await bothEntered.future.timeout(const Duration(seconds: 2));
      expect(
        datasetCalls,
        0,
      ); // The dataset really is cold when RT fills its pool.
      final title = _item(2).copyWith(doubanId: '', rottenTomatoesId: '');
      final full = repository.loadForCard(title);
      final selected = repository.loadForProvider(title, 'IMDb');
      var completedBeforeRt = false;
      double? value;
      try {
        final result = await selected.timeout(const Duration(seconds: 1));
        value = result.ratings.firstWhere((r) => r.provider == 'IMDb').value;
        completedBeforeRt = true;
      } on TimeoutException {
        // Release blocked fixture requests before reporting the failed contract.
      } finally {
        release.complete();
        await Future.wait([...blocked, full, selected]);
      }
      expect(completedBeforeRt, isTrue);
      expect(value, 7.3);
      expect(datasetCalls, 1);
    },
  );
}
