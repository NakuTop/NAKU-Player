import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_identity.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_seasons.dart';

CinemaTitle work(
  String name, {
  String source = 'one',
  String year = '2026',
  String category = '恐怖片',
  String douban = '',
}) => CinemaTitle(
  id: '1',
  sourceId: source,
  title: name,
  year: year,
  category: category,
  doubanId: douban,
);
void main() {
  const spellings = [
    '验收作品：黎明',
    '验收作品:黎明',
    '验收作品： 黎明',
    '验收作品：黎明2026',
    '验收作品：黎明 2026',
    '验收作品：黎明（2026）',
    '验收作品：黎明【2026】',
    '验收作品：黎明 [2026]',
    '验收作品：黎明 - 2026',
    '验收作品：黎明（２０２６）',
    '验收作品：黎明2026年版',
    '[2026] 验收作品：黎明',
    '验收作品：黎明2026（国语版）',
    '验收作品：黎明（4K）2026',
    '验收作品：黎明2026 1080P',
    '验收作品：黎明（2026 4K）',
    '验收作品：黎明\u200e',
    '验收作品：黎明（ＨＤＲ）',
    '验收作品：黎明2026（中英双字）',
  ];
  for (final name in spellings) {
    test('equivalent provider label: $name', () {
      expect(
        cinemaWorkTitleKey(name, '2026'),
        cinemaWorkTitleKey(spellings.first, '2026'),
      );
      final a = work(spellings.first), b = work(name, source: 'two');
      final groups = groupCinemaTitles([a, b]);
      expect(groups, hasLength(1));
      expect(groups.single.variants.map((v) => v.key), [a.key, b.key]);
    });
  }
  final separate = [
    (work('验收作品2026', year: '2025'), work('验收作品', source: 'two', year: '2025')),
    (work('验收作品', year: '2006'), work('验收作品', source: 'two')),
    (
      work('验收作品', douban: '123'),
      work('验收作品2026', source: 'two', douban: '456'),
    ),
    (work('验收作品2'), work('验收作品', source: 'two')),
    (work('验收作品22026'), work('验收作品2', source: 'two')),
    (work('1917', year: '1917'), work('1917年', source: 'two', year: '1917')),
    (work('银翼杀手2049', year: '2017'), work('银翼杀手', source: 'two', year: '2017')),
    (
      work('作品第十一季', category: '欧美剧'),
      work('作品第十二季', source: 'two', category: '欧美剧'),
    ),
    (work('作品'), work('作品', source: 'two', category: '欧美剧')),
    (work('作品'), work('作品', source: 'two', year: '')),
    (work('作品（导演剪辑版）'), work('作品', source: 'two')),
  ];
  for (final (index, pair) in separate.indexed) {
    test(
      'distinct work boundary $index',
      () => expect(groupCinemaTitles([pair.$1, pair.$2]), hasLength(2)),
    );
  }
  test('explicit sequel year and fullwidth season metadata match', () {
    expect(
      cinemaWorkTitleKey('作品2（2026）', '2026'),
      cinemaWorkTitleKey('作品2', '2026'),
    );
    expect(
      groupCinemaTitles([
        work('作品第１２季2026', category: '欧美剧', year: '２０２６'),
        work('作品第十二季', source: 'two', category: '欧美剧'),
      ]),
      hasLength(1),
    );
  });
  test(
    'queries preserve both colon spellings without exceeding three requests',
    () {
      expect(
        cinemaWorkSearchQueries('生化危机：爆发夜2026'),
        containsAll(['生化危机：爆发夜', '生化危机:爆发夜']),
      );
      expect(
        cinemaWorkSearchQueries('生化危机：爆发夜2026').length,
        lessThanOrEqualTo(3),
      );
      expect(
        cinemaWorkQueries(work('生化危机：爆发夜2026')),
        containsAll(['生化危机：爆发夜', '生化危机:爆发夜']),
      );
    },
  );
  test(
    'incomplete identity cannot attach to one of two conflicting IDs due to order',
    () {
      final unknown = work('作品2026'),
          a = work('作品', source: 'a', douban: '123'),
          b = work('作品', source: 'b', douban: '456');
      for (final values in [
        [unknown, a, b],
        [a, unknown, b],
        [b, a, unknown],
      ]) {
        expect(groupCinemaTitles(values), hasLength(3));
      }
    },
  );
}
