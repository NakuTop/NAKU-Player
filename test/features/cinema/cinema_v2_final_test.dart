import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_rating_identity_search.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

void main() {
  for (final ambiguous in [false, true]) {
    test(
      'same-name TV remakes require one canonical season/year match: ambiguous=$ambiguous',
      () async {
        final directory = await Directory.systemTemp.createTemp('v2-remake-');
        addTearDown(() => directory.delete(recursive: true));
        final repository = CinemaRatingsRepository(
          directory: directory,
          fetch: (uri, _) async {
            if (uri.host == 'm.douban.com') {
              return utf8.encode(
                jsonEncode({
                  'id': '12345',
                  'type': 'tv',
                  'title': '同名剧 第四季',
                  'original_title': 'Original Show Season 4',
                  'year': '2024',
                  'rating': {'max': 10, 'value': 8.1},
                }),
              );
            }
            if (uri.host == 'datasets.imdbws.com') {
              return gzip.encode(
                utf8.encode(
                  'tconst\taverageRating\tnumVotes\ntt1234567\t8.6\t200\n',
                ),
              );
            }
            if (uri.host == 'v3.sg.media-imdb.com') {
              return utf8.encode(
                jsonEncode({
                  'd': [
                    {
                      'id': 'tt1234567',
                      'l': 'Original Show',
                      'y': 2019,
                      'qid': 'tvSeries',
                    },
                  ],
                }),
              );
            }
            if (uri.host == 'www.rottentomatoes.com' && uri.path == '/search') {
              return utf8.encode(
                [
                  for (final (slug, year) in [
                    ('original_show', 1993),
                    ('original_show_2019', 2019),
                  ])
                    '<search-page-media-row startyear="$year"><a slot="title" href="https://www.rottentomatoes.com/tv/$slug">Original Show</a></search-page-media-row>',
                ].join(),
              );
            }
            if (uri.host == 'www.rottentomatoes.com') {
              final current = uri.path.contains('_2019');
              final season = uri.path.endsWith('/s04');
              final canonical = !current && !ambiguous
                  ? '/tv/original_show'
                  : uri.path;
              return utf8.encode(
                '<script type="application/ld+json">${jsonEncode({
                  '@type': season && (current || ambiguous) ? 'TVSeason' : 'TVSeries',
                  'url': 'https://www.rottentomatoes.com$canonical',
                  'dateCreated': season && (current || ambiguous)
                      ? '2024-01-01'
                      : current
                      ? '2019-01-01'
                      : '1993-01-01',
                  'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 91},
                })}</script>',
              );
            }
            return utf8.encode('{}');
          },
        );
        final result = await repository.load(
          const CinemaTitle(
            id: 'x',
            sourceId: 'fixture',
            title: '同名剧 第四季',
            year: '2024',
            category: '欧美剧',
            doubanId: '12345',
          ),
        );
        expect(
          result.ratings.map((r) => r.value),
          ambiguous ? [8.1, null, null] : [8.1, 8.6, 91],
        );
      },
    );
  }
  test(
    'TV review/rating redirects retain exact subject, resource and pagination',
    () {
      final from = Uri.parse(
        'https://m.douban.com/rexxar/api/v2/movie/1393859/reviews?start=0&count=6',
      );
      expect(
        CinemaDoubanAccess.subjectRedirect(
          from,
          '/rexxar/api/v2/tv/1393859/reviews?start=0&count=6',
          resource: 'reviews',
        )?.host,
        'm.douban.com',
      );
      for (final destination in [
        '/rexxar/api/v2/tv/9999999/reviews?start=0&count=6',
        '/rexxar/api/v2/tv/1393859/reviews?start=0&count=60',
        '/rexxar/api/v2/tv/1393859/interests?start=0&count=6',
        'https://sec.douban.com/rexxar/api/v2/tv/1393859/reviews?start=0&count=6',
      ]) {
        expect(
          CinemaDoubanAccess.subjectRedirect(
            from,
            destination,
            resource: 'reviews',
          ),
          isNull,
        );
      }
      expect(
        CinemaDoubanAccess.subjectRedirect(
          Uri.parse('https://m.douban.com/rexxar/api/v2/movie/1393859/rating'),
          '/rexxar/api/v2/tv/1393859/rating',
          resource: 'rating',
        ),
        isNotNull,
      );
    },
  );
  test(
    'whole-series source matches only a unique verified premiere season',
    () {
      const title = CinemaTitle(
        id: 's',
        sourceId: 'fixture',
        title: '老友记',
        year: '1994',
        category: '欧美剧',
      );
      CinemaDiscoveryTitle candidate({
        String id = '1393859',
        String name = '老友记 第一季',
        String year = '1994',
      }) => CinemaDiscoveryTitle(
        id: id,
        title: name,
        year: year,
        kind: 'tv',
        identityVerified: true,
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [candidate()])?.doubanId,
        '1393859',
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [candidate(name: '老友记 第二季')]),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [
          const CinemaDiscoveryTitle(
            id: '3286528',
            title: '老友记 第二季',
            originalTitle: '老友记',
            year: '1994',
            kind: 'tv',
            identityVerified: true,
          ),
        ]),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [candidate(year: '2004')]),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [
          candidate(),
          candidate(id: '99999'),
        ]),
        isNull,
      );
      expect(
        CinemaRatingIdentitySearch.match(title, [candidate(name: '老友记2 第一季')]),
        isNull,
      );
    },
  );
  for (final sourceName in ['原名剧集', '原名剧集 第一季', '原名剧集：特别篇 第一季']) {
    test(
      'source label $sourceName completes all providers with explicit season scopes',
      () async {
        final directory = await Directory.systemTemp.createTemp('v2-series-');
        addTearDown(() => directory.delete(recursive: true));
        final repository = CinemaRatingsRepository(
          directory: directory,
          fetch: (uri, _) async {
            if (uri.host == 'm.douban.com') {
              return utf8.encode(
                jsonEncode({
                  'id': '12345',
                  'type': 'tv',
                  'title': '原名剧集 第一季',
                  'original_title': 'Original Show Season 1',
                  'year': '2026',
                  'rating': {'max': 10, 'value': 8.3},
                }),
              );
            }
            if (uri.host == 'datasets.imdbws.com') {
              return gzip.encode(
                utf8.encode(
                  'tconst\taverageRating\tnumVotes\ntt1234567\t8.6\t200\n',
                ),
              );
            }
            if (uri.host == 'v3.sg.media-imdb.com') {
              return utf8.encode(
                jsonEncode({
                  'd': [
                    {
                      'id': 'tt1234567',
                      'l': 'Original Show',
                      'y': 2026,
                      'qid': 'tvSeries',
                    },
                  ],
                }),
              );
            }
            if (uri.host == 'www.rottentomatoes.com' && uri.path == '/search') {
              return utf8.encode(
                '<search-page-media-row startyear="2026"><a slot="title" href="https://www.rottentomatoes.com/tv/original_show">Original Show</a></search-page-media-row>',
              );
            }
            if (uri.host == 'www.rottentomatoes.com') {
              return utf8.encode(
                '<script type="application/ld+json">${jsonEncode({
                  '@type': 'TVSeason',
                  'url': 'https://www.rottentomatoes.com/tv/original_show/s01',
                  'dateCreated': '2026-01-01',
                  'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 91},
                })}</script>',
              );
            }
            return utf8.encode('{}');
          },
        );
        final result = await repository.load(
          CinemaTitle(
            id: 's',
            sourceId: 'fixture',
            title: sourceName,
            year: '2026',
            category: '欧美剧',
            doubanId: '12345',
          ),
        );
        expect(result.ratings.map((r) => r.value), [8.3, 8.6, 91]);
        expect(result.ratings.map((r) => r.scope), ['第1季', '整剧', '第1季']);
      },
    );
  }
  test('large provider HTML parsing yields to the UI event loop', () async {
    final directory = await Directory.systemTemp.createTemp('v2-parsing-');
    addTearDown(() => directory.delete(recursive: true));
    const url = 'https://www.rottentomatoes.com/m/fixture';
    final body =
        '${'<div><span>recommendation</span></div>' * 50000}<script type="application/ld+json">${jsonEncode({
          '@type': 'Movie',
          'url': url,
          'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 88},
        })}</script>';
    final repository = CinemaRatingsRepository(
      directory: directory,
      fetch: (_, _) async => utf8.encode(body),
    );
    var ticks = 0;
    var maxGap = 0;
    final watch = Stopwatch()..start();
    var previous = 0;
    final timer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      ticks++;
      final now = watch.elapsedMilliseconds;
      if (now - previous > maxGap) maxGap = now - previous;
      previous = now;
    });
    final result = await repository.load(
      const CinemaTitle(
        id: 'p',
        sourceId: 'fixture',
        title: 'Fixture',
        rottenTomatoesId: 'm/fixture',
      ),
    );
    timer.cancel();
    expect(result.ratings[2].value, 88);
    expect(ticks, greaterThan(3));
    expect(
      maxGap,
      lessThan(250),
      reason: 'Large HTML must not monopolize the UI isolate',
    );
    debugPrint(
      'PARSING_PERF: bytes=${body.length} elapsed_ms=${watch.elapsedMilliseconds} heartbeat_max_gap_ms=$maxGap ticks=$ticks',
    );
  });
}
