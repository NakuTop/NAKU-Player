import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_catalog_view.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';

CinemaTitle title(
  String id, {
  String source = 'source',
  String name = '电影',
  String year = '2024',
  String douban = '',
  String imdb = '',
  double? score,
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: '剧情片',
  doubanId: douban,
  imdbId: imdb,
  sourceDoubanScore: score,
  routes: [CinemaRoute(name: source, episodes: const [])],
);

void main() {
  test(
    'search ranks an exact family by season across aliases and late pages',
    () {
      final rows = [
        title('related', name: '流人行动'),
        title('12', name: '流人 第十二季'),
        title('actor', name: '另一部剧').copyWith(category: '剧集'),
        title('2', name: 'Slow Horses Season 2').copyWith(aliases: '流人'),
        title('1', name: '流人 第一季'),
        title('comment', name: '流人').copyWith(category: '影视解说'),
      ];
      expect(rankCinemaSearch(rows, '流人').map((t) => t.id).take(4), [
        '1',
        '2',
        '12',
        'related',
      ]);
      expect(rankCinemaSearch(rows, '流人第１２季').first.id, '12');
      expect(rankCinemaSearch(rows, ''), same(rows));
      final variant = title('other', name: 'Slow Horses S01');
      expect(
        rankCinemaSearch(
          [rows.first, variant],
          '流人',
          variants: {
            variant.key: [variant.copyWith(aliases: '流人 第一季')],
          },
        ).first,
        same(variant),
      );
    },
  );
  test(
    'same work shares rating IDs without changing playback source or variants',
    () {
      final primary = title('p', source: 'maccms-feifan');
      final extra = title(
        'e',
        douban: '1234567',
        imdb: 'tt1234567',
        score: 8.2,
      );
      final group = groupCinemaTitles([primary, extra]).single;
      expect(group.representative, same(primary));
      expect(group.catalogTitle.key, primary.key);
      expect(group.catalogTitle.routes, same(primary.routes));
      expect(group.catalogTitle.doubanId, '1234567');
      expect(group.catalogTitle.imdbId, 'tt1234567');
      expect(group.catalogTitle.sourceDoubanScore, 8.2);
      expect(group.variants, [primary, extra]);
      expect(primary.doubanId, isEmpty);
    },
  );
  test('conflicting provider IDs prevent shared metadata', () {
    final primary = title('p', source: 'maccms-feifan', imdb: 'tt1111111');
    final extra = title('e', douban: '1234567', imdb: 'tt2222222', score: 8.2);
    final group = groupCinemaTitles([primary, extra]).single;
    expect(group.catalogTitle, same(primary));
  });
  test(
    'unknown identity or conflicting transcription does not supply a score',
    () {
      final primary = title('p', source: 'maccms-feifan');
      expect(
        groupCinemaTitles([
          primary,
          title('e', score: 8.2),
        ]).single.catalogTitle.sourceDoubanScore,
        isNull,
      );
      expect(
        groupCinemaTitles([
          primary,
          title('e', douban: '1234567', score: 8.2),
          title('f', douban: '1234567', score: 7.2),
        ]).single.catalogTitle.sourceDoubanScore,
        isNull,
      );
    },
  );
  test(
    'unchanged destination reuses derived view and rating changes only re-sort',
    () {
      final cache = CinemaCatalogViewCache();
      final items = [title('a', name: 'A'), title('b', name: 'B')];
      final scores = {'a': 6.0, 'b': 9.0};
      CinemaCatalogView resolve(int revision, {String provider = '豆瓣'}) =>
          cache.resolve(
            items: items,
            filters: const CinemaFilters(),
            grouped: true,
            sort: CinemaCatalogSort.rating,
            provider: provider,
            ratingRevision: revision,
            scoreOf: (t) => scores[t.id],
          );
      final first = resolve(0);
      expect(first.visible.map((t) => t.id), ['b', 'a']);
      expect(resolve(0), same(first));
      scores['a'] = 10;
      final changed = resolve(1);
      expect(changed.groups, same(first.groups));
      expect(changed.representatives, same(first.representatives));
      expect(changed.visible.map((t) => t.id), ['a', 'b']);
      expect(changed.indices[items.first.key], 0);
      expect(resolve(1, provider: 'IMDb'), isNot(same(changed)));
    },
  );
  test(
    'new items and filters invalidate groups while irrelevant scores do not',
    () {
      final cache = CinemaCatalogViewCache();
      final items = [
        title('a', name: 'A'),
        title('b', name: 'B', year: '2023'),
      ];
      final first = cache.resolve(
        items: items,
        filters: const CinemaFilters(),
        grouped: true,
      );
      expect(
        cache.resolve(
          items: items,
          filters: const CinemaFilters(),
          grouped: true,
          ratingRevision: 99,
        ),
        same(first),
      );
      final filtered = cache.resolve(
        items: items,
        filters: const CinemaFilters(year: '2024'),
        grouped: true,
      );
      expect(filtered.visible.map((t) => t.id), ['a']);
      final appended = cache.resolve(
        items: [
          ...items,
          title('c', name: 'C'),
        ],
        filters: const CinemaFilters(year: '2024'),
        grouped: true,
      );
      expect(appended.visible.map((t) => t.id), ['a', 'c']);
    },
  );
}
