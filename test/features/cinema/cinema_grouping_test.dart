import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';

CinemaTitle _title(
  String id, {
  String source = 'first',
  String name = '星际穿越',
  String year = '2014',
  String category = '科幻片',
  String doubanId = '',
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: category,
  doubanId: doubanId,
);

void main() {
  test(
    'same work keeps all source variants and prefers Modu as representative',
    () {
      final first = _title('a', source: 'maccms-360', doubanId: '1889243');
      final preferred = CinemaTitle(
        id: 'b',
        sourceId: 'maccms-modu',
        title: '星际穿越（原声版）',
        year: '2014',
        category: '剧情片',
        doubanId: '1889243',
        poster: 'https://example.com/poster.jpg',
        description: '来源自己的简介',
        remarks: '正片',
        sourceHits: 100,
        sourceDoubanScore: 9.4,
        sourceUpdatedAt: DateTime.utc(2026, 10, 8),
        releaseDateText: '2014-11-07(美国)',
        imdbId: 'tt0816692',
        rottenTomatoesId: 'm/interstellar_2014',
        routes: const [
          CinemaRoute(
            name: 'source-route',
            episodes: [
              CinemaEpisode(name: '正片', url: 'https://example.com/movie.m3u8'),
            ],
          ),
        ],
      );
      final input = [first, preferred];
      final group = groupCinemaTitles(input).single;
      expect(group.variants, orderedEquals(input));
      expect(identical(group.variants[1], preferred), isTrue);
      expect(group.representative.toJson(), preferred.toJson());
      expect(group.key, first.key);
      expect(input, [first, preferred]);
      expect(
        groupCinemaTitles(
          input,
          preferredSourceId: 'maccms-360',
        ).single.representative,
        same(first),
      );
      expect(
        groupCinemaTitles(
          input,
          preferredSourceId: 'absent',
        ).single.representative,
        same(first),
      );
    },
  );

  test(
    'without shared IDs only exact normalized name year and kind can merge',
    () {
      final groups = groupCinemaTitles([
        _title('a', name: 'Interstellar', category: '科幻片'),
        _title(
          'b',
          source: 'second',
          name: ' interstellar （英语版） ',
          category: '剧情片',
        ),
        _title('c', source: 'third', name: 'Interstellar', doubanId: '1889243'),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.variants, hasLength(3));
    },
  );

  test('only explicit trailing language editions are removed', () {
    final suffixes = ['（原声版）', '(普通话版)', '【国语版】', '[英语版]', ' 原声版', '英语版'];
    final input = [
      _title('base'),
      for (var i = 0; i < suffixes.length; i++)
        _title('language-$i', name: '星际穿越${suffixes[i]}'),
      _title('cut', name: '星际穿越（导演剪辑版）'),
      _title('inside', name: '星际穿越（国语版）幕后'),
      _title('punctuation', name: '星际：穿越'),
    ];
    final groups = groupCinemaTitles(input);
    expect(groups, hasLength(4));
    expect(groups.first.variants, hasLength(1 + suffixes.length));
    expect(groups.skip(1).map((group) => group.representative.id), [
      'cut',
      'inside',
      'punctuation',
    ]);
  });

  test(
    'conflicting nonempty Douban IDs never share a group through an ID-less item',
    () {
      for (final order in [
        [
          _title('id-a', doubanId: '1001'),
          _title('unknown'),
          _title('id-b', doubanId: '2002'),
        ],
        [
          _title('unknown'),
          _title('id-a', doubanId: '1001'),
          _title('id-b', doubanId: '2002'),
        ],
        [
          _title('id-a', doubanId: '1001'),
          _title('id-b', doubanId: '2002'),
          _title('unknown'),
        ],
      ]) {
        final groups = groupCinemaTitles(order);
        expect(groups.length, greaterThanOrEqualTo(2));
        for (final group in groups) {
          final ids = group.variants
              .map((title) => title.doubanId)
              .where((id) => id.isNotEmpty)
              .toSet();
          expect(ids.length, lessThanOrEqualTo(1));
        }
        expect(groups.expand((group) => group.variants), hasLength(3));
      }
      final ambiguous = groupCinemaTitles([
        _title('a', doubanId: '1001'),
        _title('b', doubanId: '2002'),
        _title('unknown'),
        _title('same-a', doubanId: '1001'),
      ]);
      expect(ambiguous, hasLength(3));
      expect(ambiguous.first.variants.map((title) => title.id), [
        'a',
        'same-a',
      ]);
      expect(ambiguous.last.variants.single.id, 'unknown');
    },
  );

  test(
    'shared ID permits missing metadata but never conflicting known metadata',
    () {
      final groups = groupCinemaTitles([
        _title('unknown', year: '', category: '', doubanId: '1889243'),
        _title('known', doubanId: '1889243'),
        _title('remake', year: '2026', doubanId: '1889243'),
        _title('series', category: '欧美剧', doubanId: '1889243'),
        _title('wrong-name', name: '另一部电影', doubanId: '1889243'),
      ]);
      expect(groups, hasLength(4));
      expect(groups.first.variants.map((title) => title.id), [
        'unknown',
        'known',
      ]);
    },
  );

  test('missing years or unknown kinds stay separate without a shared ID', () {
    for (final fields in [
      (year: '', category: '电影'),
      (year: '未知', category: '电影'),
      (year: '2014/2015', category: '电影'),
      (year: '2014', category: ''),
      (year: '2014', category: '其他'),
    ]) {
      expect(
        groupCinemaTitles([
          _title('a', year: fields.year, category: fields.category),
          _title('b', year: fields.year, category: fields.category),
        ]),
        hasLength(2),
      );
    }
  });

  test('movies series anime commentary and documentaries cannot be mixed', () {
    for (final id in ['', '1889243']) {
      final groups = groupCinemaTitles([
        _title('movie', category: '科幻片', doubanId: id),
        _title('series', category: '欧美剧', doubanId: id),
        _title('anime', category: '日韩动漫', doubanId: id),
        _title('commentary', category: '电影解说', doubanId: id),
        _title('documentary', category: '纪录片', doubanId: id),
      ]);
      expect(groups, hasLength(5));
    }
  });

  test(
    'season numbers remain distinct while exact 1 through 99 forms normalize',
    () {
      for (final pair in [
        ('一', '1'),
        ('六', '6'),
        ('十', '10'),
        ('十九', '19'),
        ('二十', '20'),
        ('九十九', '99'),
      ]) {
        expect(
          groupCinemaTitles([
            _title(
              'chinese',
              name: '流人 第${pair.$1}季',
              year: '2026',
              category: '欧美剧',
            ),
            _title(
              'arabic',
              name: '流人第${pair.$2}季',
              year: '2026',
              category: '美国剧',
            ),
          ]),
          hasLength(1),
        );
      }
      expect(
        groupCinemaTitles([
          _title(
            'five',
            name: '流人第五季',
            year: '2026',
            category: '欧美剧',
            doubanId: '1001',
          ),
          _title(
            'six',
            name: '流人第六季',
            year: '2026',
            category: '欧美剧',
            doubanId: '1001',
          ),
          _title(
            'series',
            name: '流人',
            year: '2026',
            category: '欧美剧',
            doubanId: '1001',
          ),
        ]),
        hasLength(3),
      );
      expect(
        groupCinemaTitles([
          _title('hundred-chinese', name: '长剧第一百季', category: '欧美剧'),
          _title('hundred-arabic', name: '长剧第100季', category: '欧美剧'),
        ]),
        hasLength(2),
      );
    },
  );

  test('only series and anime recognize an explicit series-year range', () {
    for (final category in ['欧美剧', '日韩动漫']) {
      final groups = groupCinemaTitles([
        _title('plain', name: '流人第一季', year: '2022', category: category),
        _title('open', name: '流人 第一季', year: '2022–', category: category),
        _title('closed', name: '流人第1季', year: '2022-2026', category: category),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.variants, hasLength(3));
    }
    for (final year in ['2022–', '2022-2026', '2022/2026']) {
      expect(
        groupCinemaTitles([
          _title('plain', year: '2022'),
          _title('range', year: year),
        ]),
        hasLength(2),
      );
    }
    expect(
      groupCinemaTitles([
        _title('plain', category: '欧美剧', year: '2022'),
        _title('reversed', category: '欧美剧', year: '2022-2020'),
      ]),
      hasLength(2),
    );
  });

  test(
    'appending pages preserves group keys order duplicates and language variants',
    () {
      final first = _title('first', source: 'fast', doubanId: '1889243');
      final other = _title('other', source: 'fast', name: '另一部电影');
      final preferred = _title(
        'preferred',
        source: 'maccms-modu',
        doubanId: '1889243',
      );
      final language = _title(
        'language',
        source: 'fast',
        name: '星际穿越国语版',
        doubanId: '1889243',
      );
      final newWork = _title('new-work', source: 'later', name: '新增电影');
      final pageOne = [first, other];
      final originalGroups = groupCinemaTitles(pageOne);
      final appended = [first, other, first, preferred, language, newWork];
      final recomputed = groupCinemaTitles(appended);
      expect(
        recomputed.take(2).map((group) => group.key),
        originalGroups.map((group) => group.key),
      );
      expect(recomputed.map((group) => group.key), [
        first.key,
        other.key,
        newWork.key,
      ]);
      expect(recomputed.first.variants, [first, preferred, language]);
      expect(recomputed.first.representative, same(preferred));
      expect(recomputed.expand((group) => group.variants), hasLength(5));
      expect(pageOne, [first, other]);
      expect(appended, hasLength(6));
    },
  );

  test(
    'the same provider ID is deduplicated but matching IDs on other sources remain',
    () {
      final first = _title('same-id', source: 'a');
      final second = _title('same-id', source: 'b');
      final group = groupCinemaTitles([first, first, second, second]).single;
      expect(group.variants, [first, second]);
      expect(groupCinemaTitles(const []), isEmpty);
    },
  );
}
