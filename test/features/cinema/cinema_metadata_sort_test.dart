import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

const _source = CinemaSource(
  id: 'metadata-fixture',
  name: 'Metadata fixture',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.com/api.php/provide/vod/',
);

CinemaTitle _parse(Map<String, Object?> metadata) =>
    CinemaRepository.parseMacCmsPage(_source, {
      'list': [
        {'vod_id': 1, 'vod_name': 'Fixture title', ...metadata},
      ],
    }).items.single;

CinemaTitle _title(String id, {int? hits, DateTime? updatedAt}) => CinemaTitle(
  id: id,
  sourceId: _source.id,
  title: id,
  sourceHits: hits,
  sourceUpdatedAt: updatedAt,
);

void main() {
  test('parses source metadata without rewriting the release-date text', () {
    final title = _parse({
      'vod_hits': '1204',
      'vod_time': '2026-10-08 16:56:04',
      'vod_pubdate': ' 2026-09-28(韩国) / 2026-10-01(其他地区) ',
      'vod_douban_id': 1292052,
      'vod_douban_score': '9.7',
      'vod_imdb_id': 'tt0111161',
      'vod_rotten_tomatoes_id': 'm/shawshank_redemption',
    });
    expect(title.sourceHits, 1204);
    expect(title.sourceUpdatedAt, DateTime(2026, 10, 8, 16, 56, 4));
    expect(title.releaseDateText, ' 2026-09-28(韩国) / 2026-10-01(其他地区) ');
    expect(title.doubanId, '1292052');
    expect(title.sourceDoubanScore, 9.7);
    expect(title.imdbId, 'tt0111161');
    expect(title.rottenTomatoesId, 'm/shawshank_redemption');
  });

  test(
    'counts accept integers while missing, fractional and bad values stay null',
    () {
      for (final value in [0, '0', 42, ' 42 ', 42.0]) {
        expect(
          _parse({'vod_hits': value}).sourceHits,
          value.toString().contains('42') ? 42 : 0,
        );
      }
      for (final value in [
        null,
        '',
        -1,
        '-1',
        1.5,
        '1.5',
        true,
        'unavailable',
        double.nan,
        double.infinity,
        1e30,
      ]) {
        expect(
          _parse({'vod_hits': value}).sourceHits,
          isNull,
          reason: '$value',
        );
      }
    },
  );

  test(
    'update time accepts Unix seconds and ISO values, not release dates',
    () {
      final expected = DateTime.fromMillisecondsSinceEpoch(
        1700000000000,
        isUtc: true,
      );
      for (final value in [1700000000, '1700000000', 1700000000.0]) {
        expect(_parse({'vod_time': value}).sourceUpdatedAt, expected);
      }
      expect(
        _parse({'vod_time': '2026-10-08T12:30:45.123456Z'}).sourceUpdatedAt,
        DateTime.utc(2026, 10, 8, 12, 30, 45, 123, 456),
      );
      expect(
        _parse({'vod_time': '2026-10-08T12:30:45+08:00'}).sourceUpdatedAt,
        DateTime.utc(2026, 10, 8, 4, 30, 45),
      );
      expect(
        _parse({'vod_time': '2024-02-29'}).sourceUpdatedAt,
        DateTime(2024, 2, 29),
      );
      for (final value in [
        null,
        '',
        'not a date',
        '2026-02-30',
        '2026-13-01',
        '2026-01-01 25:00:00',
        -1,
        1.5,
        1700000000000,
        true,
      ]) {
        expect(
          _parse({'vod_time': value}).sourceUpdatedAt,
          isNull,
          reason: '$value',
        );
      }
      final releaseOnly = _parse({
        'vod_pubdate': '2026-10-08',
        'vod_time_add': 1700000000,
        'vod_year': '2026',
      });
      expect(releaseOnly.sourceUpdatedAt, isNull);
    },
  );

  test(
    'Douban ID and provider-reported Douban score have separate contracts',
    () {
      for (final value in ['1', '1292052', 1292052]) {
        expect(_parse({'vod_douban_id': value}).doubanId, value.toString());
      }
      for (final value in [
        null,
        '',
        0,
        '0',
        -1,
        '0123',
        1.5,
        true,
        'subject/1292052',
      ]) {
        expect(
          _parse({'vod_douban_id': value}).doubanId,
          isEmpty,
          reason: '$value',
        );
      }
      for (final value in [0.1, '8.4', 10, '10.0']) {
        expect(
          _parse({'vod_douban_score': value}).sourceDoubanScore,
          double.parse(value.toString()),
        );
      }
      for (final value in [
        null,
        '',
        0,
        '0.0',
        -1,
        10.1,
        true,
        'NaN',
        double.infinity,
      ]) {
        expect(
          _parse({'vod_douban_score': value}).sourceDoubanScore,
          isNull,
          reason: '$value',
        );
      }
      expect(_parse({'vod_score': '9.9'}).sourceDoubanScore, isNull);
    },
  );

  test(
    'IMDb and Rotten Tomatoes require explicit fields and canonical IDs',
    () {
      for (final id in ['tt1234567', 'tt1234567890']) {
        expect(_parse({'imdb_id': id}).imdbId, id);
      }
      for (final id in [
        'm/alien',
        'm/2001_a_space_odyssey',
        'tv/the_bear',
        'tv/the_bear/s03',
      ]) {
        expect(_parse({'rotten_tomatoes_id': id}).rottenTomatoesId, id);
      }
      for (final id in [
        '',
        'tt123456',
        'tt12345678901',
        'TT1234567',
        1234567,
        'https://www.imdb.com/title/tt1234567/',
        'tt1234567?redirect=other',
      ]) {
        expect(_parse({'vod_imdb_id': id}).imdbId, isEmpty, reason: '$id');
      }
      for (final id in [
        '',
        'alien',
        '/m/alien',
        'm/../alien',
        'm/alien?x=1',
        'https://www.rottentomatoes.com/m/alien',
        'm/alien/s01',
        'tv/alien/s1',
        'tv/alien/s001',
        'tv/alien/s01/episodes',
        'm/alien#reviews',
      ]) {
        expect(
        _parse({'vod_rotten_tomatoes_id': id}).rottenTomatoesId,
        isEmpty,
        reason: id,
        );
      }
      final textOnly = _parse({
        'vod_name': 'tt1234567 m/alien',
        'vod_content': 'IMDb tt1234567 Rotten Tomatoes m/alien 豆瓣 1292052',
        'vod_remarks': '评分 9.9',
        'vod_reurl': 'https://www.imdb.com/title/tt1234567/',
        'vod_score': '9.9',
      });
      expect(textOnly.imdbId, isEmpty);
      expect(textOnly.rottenTomatoesId, isEmpty);
      expect(textOnly.doubanId, isEmpty);
      expect(textOnly.sourceDoubanScore, isNull);
    },
  );

  test(
    'new metadata survives JSON and route replacement; old JSON still loads',
    () {
      final title = _parse({
        'vod_hits': 22,
        'vod_time': 1700000000,
        'vod_pubdate': '2014-11-07(美国)',
        'vod_douban_id': '1889243',
        'vod_douban_score': 9.4,
        'vod_imdb_id': 'tt0816692',
        'vod_rotten_tomatoes_id': 'm/interstellar_2014',
      });
      final json = title.toJson();
      final restored = CinemaTitle.fromJson(jsonDecode(jsonEncode(json)));
      expect(restored.toJson(), json);
      final replaced = restored.copyWith(
        routes: const [
          CinemaRoute(
            name: 'A',
            episodes: [
              CinemaEpisode(name: '电影', url: 'https://example.com/movie.mp4'),
            ],
          ),
        ],
      );
      expect({...replaced.toJson(), 'routes': json['routes']}, json);
      expect(replaced.routes, hasLength(1));
      final legacy = CinemaTitle.fromJson({
        'id': '1',
        'sourceId': 'old',
        'title': 'Old favourite',
      });
      expect(legacy.sourceHits, isNull);
      expect(legacy.sourceUpdatedAt, isNull);
      expect(legacy.releaseDateText, isEmpty);
      expect(legacy.doubanId, isEmpty);
      expect(legacy.sourceDoubanScore, isNull);
      expect(legacy.imdbId, isEmpty);
      expect(legacy.rottenTomatoesId, isEmpty);
    },
  );

  test(
    'popular sorts only supplied items stably and never mutates its input',
    () {
      final input = [
        _title('missing-first'),
        _title('low', hits: 0),
        _title('high-first', hits: 50),
        _title('high-second', hits: 50),
        _title('missing-last'),
      ];
      final original = List<CinemaTitle>.of(input);
      final result = sortCinemaTitles(input, CinemaCatalogSort.popular);
      expect(result.map((item) => item.id), [
        'high-first',
        'high-second',
        'low',
        'missing-first',
        'missing-last',
      ]);
      expect(input, original);
      expect(identical(result, input), isFalse);
      result.removeLast();
      expect(input, original);
    },
  );

  test(
    'latest uses update time rather than release year and has stable ties',
    () {
      final input = [
        _title('missing-first'),
        _title('old', updatedAt: DateTime.utc(2025)),
        _title('new-first', updatedAt: DateTime.utc(2026)),
        _title('new-second', updatedAt: DateTime.utc(2026)),
        const CinemaTitle(
          id: 'future-release',
          sourceId: 'fixture',
          title: 'Future',
          year: '2030',
          releaseDateText: '2030-01-01',
        ),
      ];
      final result = sortCinemaTitles(
        input.where((_) => true),
        CinemaCatalogSort.latest,
      );
      expect(result.map((item) => item.id), [
        'new-first',
        'new-second',
        'old',
        'missing-first',
        'future-release',
      ]);
      expect(input.first.id, 'missing-first');
      expect(sortCinemaTitles(const [], CinemaCatalogSort.latest), isEmpty);
    },
  );
}
