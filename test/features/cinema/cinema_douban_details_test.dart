import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_details_view.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

const _id = '36889088';
const _title = CinemaTitle(
  id: '176316',
  sourceId: 'fixture',
  title: '怒之杀',
  year: '2026',
  doubanId: _id,
);
Map<String, dynamic> _subject({String id = _id, Object? score = 5.6}) => {
  'id': id,
  'type': 'movie',
  'title': '怒之杀',
  'year': '2026',
  'url': 'https://movie.douban.com/subject/$id/',
  'original_title': 'Mutiny',
  'pubdate': ['2026-09-04(中国大陆)'],
  'durations': ['95分钟'],
  'aka': ['反叛', '玩命航线(台)'],
  'rating': {'value': score, 'max': 10, 'count': 12934},
};
const _stats = {
  'stats': [.05, .28, .5, .11, .06],
  'done_count': 14496,
};
String _page({String id = _id}) =>
    '''
<meta property="og:url" content="https://m.douban.com/movie/subject/$id/">
<link rel="canonical" href="
https://m.douban.com/movie/subject/$id/">
<meta itemprop="ratingValue" content="5.6"><meta itemprop="reviewCount" content="12934">
<div class="sub-title">怒之杀</div><div class="sub-original-title">Mutiny（2026）</div>
<div class="sub-meta">英国 / 美国 / 动作 / 2026-08-19(中国台湾)上映 / 片长95分钟</div>
<section class="subject-rec"><ul><li><a href="/movie/subject/36892468?from=rec">
<img alt="庇护之地"><h3>庇护之地</h3></a></li>
<li><a href="https://evil.invalid/movie/subject/11111"><h3>External injection</h3></a></li>
<li><a href="/movie/subject/$id"><h3>Self recommendation</h3></a></li></ul></section>
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-douban-details-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'mobile metadata without JSON-LD fixes exact movie score and metadata',
    () {
      final result = parseDoubanSubjectHtml(_id, _page());
      expect(result.score, 5.6);
      expect(result.ratingCount, 12934);
      expect(result.year, '2026');
      expect(result.originalTitle, 'Mutiny');
      expect(result.releaseDates, ['2026-08-19(中国台湾)']);
      expect(result.durations, ['95分钟']);
      expect(result.recommendations.single.doubanId, '36892468');
      expect(result.recommendations.single.title, '庇护之地');
      final rating = CinemaRatingsRepository.parseRatingPage(
        '豆瓣',
        'https://movie.douban.com/subject/$_id/',
        _page(),
      );
      expect(rating.verified, isTrue);
      expect(rating.scale, 10);
      expect(rating.value, 5.6);
    },
  );

  test('public subject JSON checks exact ID, source URL and rating scale', () {
    final result = parseDoubanSubjectJson(_id, _subject());
    expect(result.releaseDates, ['2026-09-04(中国大陆)']);
    expect(result.aliases, ['反叛', '玩命航线(台)']);
    expect(result.ratingCount, 12934);
    for (final sample in [
      _subject(id: '1889243'),
      {..._subject(), 'url': 'https://other.invalid/subject/$_id/'},
      {..._subject(), 'type': 'book'},
    ]) {
      expect(() => parseDoubanSubjectJson(_id, sample), throwsFormatException);
    }
    for (final score in [0, 11, double.nan, 'not rated']) {
      expect(parseDoubanSubjectJson(_id, _subject(score: score)).score, isNull);
    }
    expect(
      parseDoubanSubjectJson(_id, {
        ..._subject(),
        'rating': {'value': 5, 'max': 5},
      }).score,
      isNull,
    );
  });

  test(
    'challenge, wrong canonical and mixed identity are never official ratings',
    () {
      for (final body in [
        '<h1>验证码</h1>',
        _page(id: '1889243'),
        '${_page()}<link rel="canonical" href="https://evil.invalid/subject/$_id/">',
      ]) {
        expect(() => parseDoubanSubjectHtml(_id, body), throwsFormatException);
      }
    },
  );

  test(
    'desktop fields and exact star percentage parse without inspecting user reviews',
    () {
      final body =
          '''<link rel="canonical" href="https://movie.douban.com/subject/$_id/">
      <span property="v:itemreviewed">怒之杀</span><span class="year">(2026)</span>
      <span property="v:initialReleaseDate">2026-09-04(中国大陆)</span>
      <span property="v:runtime">95分钟</span><div id="info"><span class="pl">又名:</span> 反叛 / 玩命航线(台)<br>无关信息</div>
      <div class="ratings-on-weight">${[5, 4, 3, 2, 1].map((s) => '<div class="item"><span class="starstop">$s星</span><span class="rating_per">20.0%</span></div>').join()}</div>
      <span class="rating-stars" data-rating="100">unrelated user review</span>''';
      final result = parseDoubanSubjectHtml(_id, body);
      expect(result.aliases, ['反叛', '玩命航线(台)']);
      expect(result.stars.map((e) => e.share), everyElement(.2));
      expect(result.score, isNull);
    },
  );

  test(
    'five star proportions reverse 1-to-5 schema; watched count never becomes voters',
    () {
      final shares = parseDoubanStarShares(_stats);
      expect(shares.map((s) => s.stars), [5, 4, 3, 2, 1]);
      expect(shares.map((s) => s.share), [.06, .11, .5, .28, .05]);
      for (final stats in [
        [],
        [0, 0, 0, 0, 0],
        [1, 1, 1, 1, 1],
        [-.1, .1, .2, .3, .5],
        [0, 0, 0, 0, double.nan],
        ['0.2', .2, .2, .2, .2],
      ]) {
        expect(
          () => parseDoubanStarShares({'stats': stats}),
          throwsFormatException,
        );
      }
    },
  );

  Future<List<int>> fetch(Uri uri, int _) async {
    if (uri.host == 'query.wikidata.org') {
      return utf8.encode('{"results":{"bindings":[]}}');
    }
    if (uri.path.endsWith('/rating')) return utf8.encode(jsonEncode(_stats));
    if (uri.path.contains('/rexxar/')) {
      return utf8.encode(jsonEncode(_subject()));
    }
    if (uri.host == 'm.douban.com') return utf8.encode(_page());
    throw StateError('Unexpected request $uri');
  }

  test(
    'card score requests no recommendations or distribution and replaces legacy null cache',
    () async {
      await File('${directory.path}/ratings-v1.json').writeAsString(
        jsonEncode({
          'version': 1,
          'bindings': {},
          'mappings': {},
          'cache': {
            '豆瓣:$_id': CinemaRating(
              provider: '豆瓣',
              note: 'Old desktop parser failed',
              fetchedAt: DateTime.now(),
            ).toJson(),
          },
        }),
      );
      final urls = <Uri>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) {
          urls.add(uri);
          return fetch(uri, max);
        },
      );
      final result = await repository.loadForCard(_title);
      expect(result.ratings.first.value, 5.6);
      expect(result.ratings.first.verified, isTrue);
      expect(urls.where((u) => u.host == 'm.douban.com').map((u) => u.path), [
        '/rexxar/api/v2/movie/$_id',
      ]);
      expect(
        urls.any(
          (u) =>
              u.path.endsWith('/rating') || u.path.startsWith('/movie/subject'),
        ),
        isFalse,
      );
    },
  );

  test(
    'details coalesce, cache across restart, share subject and preserve good data on failure',
    () async {
      final urls = <Uri>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) {
          urls.add(uri);
          return fetch(uri, max);
        },
      );
      await repository.loadForCard(_title);
      final results = await Future.wait([
        repository.loadDoubanDetails(_title),
        repository.loadDoubanDetails(_title),
      ]);
      expect(results.first.score, 5.6);
      expect(results.first.stars.first.share, .06);
      expect(results.first.ratingCount, 12934);
      expect(results.first.ratingCount, isNot(14496));
      expect(results.first.releaseDates, [
        '2026-09-04(中国大陆)',
        '2026-08-19(中国台湾)',
      ]);
      expect(
        urls.where((u) => u.path == '/rexxar/api/v2/movie/$_id'),
        hasLength(1),
      );
      expect(urls.where((u) => u.path.endsWith('/rating')), hasLength(1));
      var failures = 0;
      final offline = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) async {
          failures++;
          throw const SocketException('Offline');
        },
      );
      final restored = await offline.loadDoubanDetails(_title);
      expect(restored.recommendations, hasLength(1));
      expect(failures, 0);
      final fallback = await offline.loadDoubanDetails(_title, force: true);
      expect(fallback.score, 5.6);
      expect(fallback.stale, isTrue);
      expect(fallback.recommendations, hasLength(1));
      expect(fallback.fetchedAt, restored.fetchedAt);
      expect(fallback.note, contains('保留上次'));
      final count = failures;
      await offline.loadDoubanDetails(_title);
      expect(failures, count);
      final scores = await offline.load(_title, force: true);
      expect(scores.ratings.first.value, 5.6);
      expect(scores.ratings.first.verified, isTrue);
      expect(scores.ratings.first.note, contains('保留上次'));
    },
  );

  test(
    'manual identity controls metadata without inheriting original source ID',
    () async {
      final urls = <Uri>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) async {
          urls.add(uri);
          throw const HttpException('unavailable');
        },
      );
      await repository.setIdentity(
        _title,
        const RatingIdentity(doubanId: '1889243', confirmed: true),
      );
      final details = await repository.loadDoubanDetails(_title);
      expect(details.doubanId, '1889243');
      expect(urls.every((u) => u.path.contains('1889243')), isTrue);
      await repository.setIdentity(
        _title,
        const RatingIdentity(confirmed: true),
      );
      final n = urls.length;
      expect((await repository.loadDoubanDetails(_title)).hasContent, isFalse);
      expect(urls.length, n);
    },
  );

  test(
    'detail cache is bounded and invalid cached star data is reloaded',
    () async {
      final initial = {
        for (var i = 0; i < 70; i++)
          '${10000 + i}': {
            'at': DateTime.now().toIso8601String(),
            'data': {'doubanId': '${10000 + i}', 'title': 'Fixture $i'},
          },
      };
      initial[_id] = {
        'at': DateTime.now().toIso8601String(),
        'data': {
          'doubanId': _id,
          'stars': [
            {'stars': 5, 'share': 10},
          ],
        },
      };
      await File('${directory.path}/ratings-v1.json').writeAsString(
        jsonEncode({
          'version': 1,
          'bindings': {},
          'cache': {},
          'mappings': {},
          'doubanDetails': initial,
        }),
      );
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: fetch,
      );
      expect((await repository.loadDoubanDetails(_title)).score, 5.6);
      final stored = jsonDecode(
        await File('${directory.path}/ratings-v1.json').readAsString(),
      );
      expect((stored['doubanDetails'] as Map).length, lessThanOrEqualTo(64));
    },
  );

  test(
    'posters never wait for crosswalk or secondary providers and retain cached scores',
    () async {
      final imdb = CinemaRating(
        provider: 'IMDb',
        value: 5.7,
        count: 800,
        url: 'https://www.imdb.com/title/tt32338669/',
        note: 'IMDb official fixture',
        verified: true,
        fetchedAt: DateTime.now(),
      );
      final rt = CinemaRating(
        provider: '烂番茄',
        value: 60,
        scale: 100,
        url: 'https://www.rottentomatoes.com/m/fixture',
        note: 'Critic fixture',
        verified: true,
        fetchedAt: DateTime.now(),
      );
      await File('${directory.path}/ratings-v1.json').writeAsString(
        jsonEncode({
          'version': 1,
          'bindings': {
            _title.key: const RatingIdentity(
              doubanId: _id,
              imdbId: 'tt32338669',
              rottenTomatoesId: 'm/fixture',
              confirmed: true,
            ).toJson(),
          },
          'mappings': {},
          'cache': {
            'IMDb:tt32338669': imdb.toJson(),
            '烂番茄:m/fixture': rt.toJson(),
          },
        }),
      );
      final urls = <Uri>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) {
          urls.add(uri);
          if (uri.host != 'm.douban.com') {
            throw StateError('Posters must never request $uri');
          }
          return fetch(uri, max);
        },
      );
      final result = await repository
          .loadForCard(_title)
          .timeout(const Duration(seconds: 2));
      expect(result.ratings.map((r) => r.value), [5.6, 5.7, 60]);
      expect(urls.map((u) => u.path), ['/rexxar/api/v2/movie/$_id']);
      expect(repository.peek(_title), same(result));
      const unbound = CinemaTitle(
        id: 'blank',
        sourceId: 'fixture',
        title: 'No IDs',
      );
      final count = urls.length;
      final missing = await repository.loadForCard(unbound);
      expect(missing.ratings.every((r) => r.value == null), isTrue);
      expect(urls.length, count);
    },
  );

  test(
    'partial refresh preserves known subfields with original timestamps and retries after 30 minutes',
    () async {
      final first = CinemaRatingsRepository(directory: directory, fetch: fetch);
      final original = await first.loadDoubanDetails(_title);
      final partial = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) async {
          if (uri.path == '/rexxar/api/v2/movie/$_id') {
            return utf8.encode(jsonEncode(_subject()));
          }
          throw const HttpException('Temporary outage');
        },
      );
      final updated = await partial.loadDoubanDetails(_title, force: true);
      expect(updated.stars.first.share, original.stars.first.share);
      expect(
        updated.recommendations.single.doubanId,
        original.recommendations.single.doubanId,
      );
      expect(updated.starsFetchedAt, original.starsFetchedAt);
      expect(
        updated.recommendationsFetchedAt,
        original.recommendationsFetchedAt,
      );
      expect(updated.note, contains('星级分布沿用'));
      expect(updated.note, contains('推荐列表沿用'));
      final file = File('${directory.path}/ratings-v1.json');
      final persisted = jsonDecode(await file.readAsString());
      expect(persisted['doubanDetails'][_id]['partial'], true);
      persisted['doubanDetails'][_id]['at'] = DateTime.now()
          .subtract(const Duration(minutes: 31))
          .toIso8601String();
      await file.writeAsString(jsonEncode(persisted));
      final calls = <Uri>[];
      final recovered = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, max) {
          calls.add(uri);
          return fetch(uri, max);
        },
      );
      expect((await recovered.loadDoubanDetails(_title)).note, '豆瓣官网公开资料');
      expect(calls, hasLength(3));
    },
  );

  test('official HTML supplies original title when JSON omits it', () async {
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (uri, max) async {
        if (uri.path == '/rexxar/api/v2/movie/$_id') {
          return utf8.encode(jsonEncode({..._subject(), 'original_title': ''}));
        }
        return fetch(uri, max);
      },
    );
    expect(
      (await repository.loadDoubanDetails(_title)).originalTitle,
      'Mutiny',
    );
  });

  testWidgets(
    'narrow detail view uses correct bar values and passes exact recommendation identity',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final details = parseDoubanSubjectJson(_id, _subject()).copyWith(
        stars: parseDoubanStarShares(_stats),
        recommendations: parseDoubanSubjectHtml(_id, _page()).recommendations,
      );
      DoubanRecommendation? selected;
      await tester.pumpWidget(
        MaterialApp(
          theme: CinemaTheme.data,
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: DoubanDetailsView(
                  details: details,
                  onRecommendationSelected: (value) => selected = value,
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const ValueKey('douban-star-5')),
            )
            .value,
        .06,
      );
      expect(find.text('6.0%'), findsOneWidget);
      expect(find.textContaining('12934 人评价'), findsOneWidget);
      expect(find.textContaining('14496'), findsNothing);
      expect(find.text('反叛 / 玩命航线(台)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('douban-rec-36892468')));
      expect(selected?.doubanId, '36892468');
      expect(tester.takeException(), isNull);
    },
  );
}
