import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_aggregate_catalog.dart';
import 'package:kazumi/features/cinema/cinema_catalog_view.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_identity.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_seasons.dart';

void main() {
  test(
    'variety projections keep main episodes and only specials attributed to that season',
    () {
      const t = CinemaTitle(
        id: '99',
        sourceId: 'provider',
        title: '节目（加更版）',
        category: '大陆综艺',
        routes: [
          CinemaRoute(
            name: 'line',
            episodes: [
              CinemaEpisode(
                name: '第 0 季 第 2 集 第3季 第1期加更',
                url: 'https://example.org/a',
              ),
              CinemaEpisode(
                name: '第 3 季 第 1 集 20251018上',
                url: 'https://example.org/b',
              ),
              CinemaEpisode(
                name: '第 4 季 第 1 集 20261018上',
                url: 'https://example.org/c',
              ),
            ],
          ),
        ],
      );
      final groups = cinemaSplitSeasons(t);
      expect(groups.map((x) => x.id), ['99~s3', '99~s4']);
      expect(groups[0].routes.single.episodes.map((e) => e.url), [
        'https://example.org/b',
        'https://example.org/a',
      ]);
      expect(
        groups[1].routes.single.episodes.single.url,
        'https://example.org/c',
      );
      expect(groups.map((x) => x.year), ['2025', '2026']);
    },
  );
  CinemaTitle series(
    String provider,
    String id,
    String title,
    String year,
    String subject, {
    String poster = '',
    List<CinemaRoute> routes = const [],
  }) => CinemaTitle(
    sourceId: provider,
    id: id,
    title: title,
    year: year,
    doubanId: subject,
    category: '欧美剧',
    poster: poster,
    routes: routes,
  );
  test(
    'explicit Chinese, full-width and Sxx.Exx episode labels share season boundaries',
    () {
      final title = series(
        'asia',
        '81',
        '异名动画',
        '2025',
        '12345',
        routes: [
          CinemaRoute(
            name: '片源',
            episodes: [
              CinemaEpisode(name: '第一季 第十二话', url: 'https://show.invalid/a'),
              CinemaEpisode(name: 'Ｓ０２.Ｅ０３', url: 'https://show.invalid/b'),
              CinemaEpisode(name: '第２季 第４集', url: 'https://show.invalid/c'),
            ],
          ),
        ],
      ).copyWith(category: '日本動漫');
      final seasons = cinemaSplitSeasons(title);
      expect(seasons.map((s) => s.id), ['81~s1', '81~s2']);
      expect(seasons.first.routes.single.episodes.single.name, '第12集');
      expect(seasons.last.routes.single.episodes.map((e) => e.name), [
        '第03集',
        '第04集',
      ]);
    },
  );
  test(
    'explicit season merges across missing dates and TV/anime classifications with the same subject',
    () {
      final seriesRow = series('tv', '5', '群星第十二季', '2020', '44550');
      final withoutYear = series('regional', '82', '群星 S12', '', '');
      final animated = series(
        'animation',
        '3',
        '群星第１２季',
        '2020',
        '44550',
      ).copyWith(category: '日本動漫');
      expect(
        groupCinemaTitles([animated, withoutYear, seriesRow]).single.variants,
        hasLength(3),
      );
      final film = seriesRow.copyWith(
        category: '动画电影',
        doubanId: '99881',
        id: '92',
      );
      expect(groupCinemaTitles([film, seriesRow]), hasLength(2));
    },
  );
  test(
    'public suggestions, cached cards and catalogues share one card per season',
    () {
      final source = series('a', '1', '西部世界第1季', '2016', '2338055');
      final alternate = series('b', '9', '西部世界 第一季', '2016', '2338055');
      final film = series(
        'a',
        '3',
        '西部世界',
        '1973',
        '1297907',
      ).copyWith(category: '科幻片');
      final next = series('a', '2', '西部世界第二季', '2018', '26887174');
      final raw = {
        'type': 'movie',
        'id': '2338055',
        'title': '西部世界 第一季',
        'year': '2016',
        'episode': '10',
      };
      final suggestion = CinemaDiscoveryTitle.parse(
        raw,
        subjectSuggestion: true,
      )!;
      expect((suggestion.kind, suggestion.episodeCount), ('tv', 10));
      expect(
        CinemaDiscoveryTitle.parse({
          ...raw,
          'subtype': 'movie',
        }, subjectSuggestion: true)!.kind,
        'movie',
      );
      final old = suggestion.metadata.copyWith(category: '电影');
      final cache = CinemaCatalogViewCache();
      for (final query in ['西部世界', '西部世界第一季', '西部世界第1季']) {
        for (final metadata in [
          <CinemaTitle>[],
          [suggestion.metadata],
        ]) {
          final view = cache.resolve(
            items: [old, film, alternate, source, next],
            discovery: metadata,
            filters: const CinemaFilters(),
            search: query,
            grouped: true,
            sourcePriority: ['a', 'b'],
          );
          expect(view.visible, hasLength(3));
          final season = view.visible.singleWhere(
            (v) => v.doubanId == '2338055',
          );
          expect(season.sourceId, 'a');
          expect(view.variants[season.key]!.map((v) => v.sourceId).toSet(), {
            'a',
            'b',
            'douban-discovery',
          });
        }
      }
      expect(
        groupCinemaTitles([old, source.copyWith(doubanId: '1234567')]),
        hasLength(2),
      );
      expect(
        groupCinemaTitles([source, alternate.copyWith(category: '电影')]),
        hasLength(2),
      );
    },
  );
  test(
    'classic movie, later series, modern short drama and commentary remain separate',
    () {
      const title = '茶馆';
      final film = series(
        'a',
        '1',
        title,
        '1982',
        '1461403',
      ).copyWith(category: '剧情片');
      final ruyi = series(
        'ruyi',
        '10228',
        '茶馆1982',
        '1982(中国大陆)',
        '1461403',
      ).copyWith(category: '剧情片');
      final parsed = CinemaTitle.fromJson({
        ...ruyi.toJson(),
        'year': '１９８２（中国大陆）',
      });
      expect(parsed.year, '1982');
      expect(cinemaCatalogYear('1982-08-12'), '1982');
      expect(cinemaCatalogYear('1982–1990'), '1982–1990');
      expect(cinemaCleanWorkTitle('茶馆1982', '1982(中国大陆)'), title);
      final meta = CinemaDiscoveryTitle.parse({
        'id': '3271273',
        'title': title,
        'year': '2010',
        'type': 'movie',
        'episode': '39',
      }, subjectSuggestion: true)!.metadata;
      expect(meta.category, '电视剧');
      final tv = series(
        'a',
        '2',
        title,
        '2010',
        '3271273',
        routes: const [
          CinemaRoute(
            name: '剧集',
            episodes: [
              CinemaEpisode(name: '第1集', url: 'https://video.invalid/1'),
              CinemaEpisode(name: '第2集', url: 'https://video.invalid/2'),
            ],
          ),
        ],
      ).copyWith(category: '国产剧');
      final short = series(
        'b',
        '3',
        title,
        '2024',
        '',
      ).copyWith(category: '现代都市');
      final commentary = film.copyWith(id: '4', category: '电影解说');
      final items = [
        meta.copyWith(category: '电影'),
        tv,
        short,
        short.copyWith(sourceId: 'c', id: '33'),
        ruyi,
        film,
        commentary,
      ];
      final view = CinemaCatalogViewCache().resolve(
        items: items,
        filters: const CinemaFilters(),
        search: title,
        grouped: true,
        sourcePriority: ['a', 'ruyi'],
        preferredKind: CinemaAggregateKind.movies,
      );
      expect(view.visible, hasLength(4));
      expect(view.visible.first.key, film.key);
      expect(
        view.variants[film.key]!.map((t) => t.sourceId),
        containsAll(['a', 'ruyi']),
      );
      expect(view.visible.where((v) => v.year == '2010'), hasLength(1));
      expect(view.visible.where((v) => v.year == '2024'), hasLength(1));
      expect(view.visible.last.category, '电影解说');
      expect(
        rankCinemaSearch(
          view.visible,
          title,
          preferredKind: CinemaAggregateKind.series,
        ).first.year,
        '2010',
      );
    },
  );
  for (final legacy in [false, true]) {
    test(
      'box set and discovery converge for all season spellings, legacy=$legacy',
      () {
        final bundle = series(
          'bundle',
          '629557180206415877',
          '流人',
          '2026',
          '36689816',
          poster: 'last.jpg',
          routes: [
            CinemaRoute(
              name: 'HLS',
              episodes: [
                for (final n in [1, 2, 6])
                  CinemaEpisode(
                    name: '第 $n 季 第 1 集',
                    url: 'https://video.example/s$n.m3u8',
                  ),
              ],
            ),
          ],
        );
        final split = cinemaSplitSeasons(bundle);
        expect(split.first.year, isEmpty);
        expect(split.first.doubanId, isEmpty);
        final one = series(
          'seasons',
          '1',
          '流人 第一季',
          '2022',
          '34890017',
          poster: 'one.jpg',
        );
        final two = series(
          'seasons',
          '2',
          '流人 第二季',
          '2022',
          '35356697',
          poster: 'two.jpg',
        );
        final six = series(
          'seasons',
          '6',
          '流人 第六季',
          '2026',
          '36689816',
          poster: 'six.jpg',
        );
        final oldFirst = split.first.copyWith(
          year: '2026',
          doubanId: '36689816',
        );
        final view = CinemaCatalogViewCache().resolve(
          items: [
            if (legacy) oldFirst else split.first,
            ...split.skip(1),
            one,
            two,
            six,
          ],
          discovery: [
            series('douban-discovery', '34890017', '流人第１季', '2022', '34890017'),
          ],
          search: '流人',
          grouped: true,
          filters: const CinemaFilters(),
          sourcePriority: ['bundle', 'seasons'],
        );
        expect(view.visible.map((v) => v.doubanId), [
          '34890017',
          '35356697',
          '36689816',
        ]);
        final first = view.visible.first;
        expect(
          [first.poster, first.year, first.sourceId],
          ['one.jpg', '2022', 'bundle'],
        );
        expect(first.routes.single.episodes.single.url, endsWith('/s1.m3u8'));
        expect(
          view.variants[first.key]!.map((v) => v.sourceId),
          containsAll(['bundle', 'seasons']),
        );
        final filtered = CinemaCatalogViewCache().resolve(
          items: [...split, one, two, six],
          search: '流人第一季',
          grouped: true,
          filters: const CinemaFilters(year: '2022'),
          sourcePriority: ['bundle', 'seasons'],
        );
        expect(filtered.visible, hasLength(2));
        expect(
          filtered.variants[filtered.visible.first.key]!.map((t) => t.sourceId),
          contains('bundle'),
        );
      },
    );
  }
  test(
    'identical season spellings from one catalogue coalesce without merging a remake or another season',
    () {
      final one = series('a', '1', '示例第十二季', '2021', '15');
      final old = series('a', '2', '示例 第12季', '', '');
      final other = series('a', '3', '示例 S12', '2000', '16');
      expect(groupCinemaTitles([old, one]), hasLength(1));
      expect(groupCinemaTitles([old, one, other]), hasLength(2 + 1));
      expect(
        groupCinemaTitles([one, series('a', '99', '示例第十一季', '2021', '15')]),
        hasLength(2),
      );
    },
  );
}
