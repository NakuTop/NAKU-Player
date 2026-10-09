import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final Object Function(RequestOptions) reply;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    calls.add(options);
    return ResponseBody.fromString(
      jsonEncode(reply(options)),
      200,
      headers: {
        'content-type': ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const title = CinemaTitle(
    id: '1',
    sourceId: 'test',
    title: '怒之杀',
    aliases: 'Mutiny / 玩命航线',
    year: '2026',
    area: '美国 / 英国',
    genres: '动作,惊悚',
    actors: '杰森·斯坦森 / Jason Statham',
  );
  test('Chinese, original titles and main actor metadata are searchable', () {
    for (final q in ['怒之杀', 'MUTINY', '玩命航线', '杰森斯坦森', 'Jason Statham']) {
      expect(cinemaMatchesKeyword(title, q), isTrue, reason: q);
    }
    expect(cinemaMatchesKeyword(title, 'Brad Pitt'), isFalse);
    expect(
      const CinemaFilters(
        year: '2026',
        region: '美国',
        genre: '动作',
      ).matches(title),
      isTrue,
    );
    expect(const CinemaFilters(year: '2025').matches(title), isFalse);
    expect(
      const CinemaFilters(region: '大陆').matches(
        const CinemaTitle(id: '2', sourceId: 'test', title: '作品', area: '中国大陆'),
      ),
      isTrue,
    );
    expect(const CinemaFilters(year: '更早').matches(title), isFalse);
    expect(
      const CinemaFilters(
        year: '更早',
      ).matches(const CinemaTitle(id: '3', sourceId: 'test', title: '无年份')),
      isFalse,
    );
  });
  test(
    'source aliases duration genres survive serialization and detail copy',
    () {
      const source = CinemaSource(
        id: 'test',
        name: '测试',
        kind: CinemaSourceKind.maccms,
        url: 'https://example.test/api',
      );
      final parsed = CinemaRepository.parseMacCmsPage(source, {
        'list': [
          {
            'vod_id': 1,
            'vod_name': '怒之杀',
            'vod_sub': 'Mutiny',
            'vod_duration': '95',
            'vod_class': '动作,惊悚',
          },
        ],
      }).items.single;
      final saved = CinemaTitle.fromJson(parsed.copyWith(routes: []).toJson());
      expect(saved.aliases, 'Mutiny');
      expect(saved.durationText, '95');
      expect(saved.genres, '动作,惊悚');
    },
  );
  test(
    'original title resolves through public suggestions with bounded queries and cache',
    () async {
      final adapter = _Adapter(
        (request) => [
          {
            'id': '36889088',
            'title': '怒之杀',
            'sub_title': 'Mutiny',
            'type': 'movie',
            'year': '2026',
          },
        ],
      );
      final repo = CinemaSearchDiscoveryRepository(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final result = await repo.search('Mutiny');
      expect(result.queries, ['怒之杀']);
      expect(result.titles.single.originalTitle, 'Mutiny');
      await repo.search('mutiny');
      expect(adapter.calls.length, 1);
      expect(adapter.calls.single.queryParameters['q'], 'Mutiny');
    },
  );
  test(
    'English actor maps to acting credits and supports stable work pagination',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) {
          return [
            {
              'id': '1049484',
              'title': '杰森·斯坦森',
              'sub_title': 'Jason Statham',
              'type': 'celebrity',
            },
          ];
        }
        return {
          'total': 4,
          'works': [
            {
              'roles': ['演员 (饰角色)'],
              'work': {
                'id': '36889088',
                'title': '怒之杀',
                'year': '2026',
                'type': 'movie',
                'rating': {'value': 5.6},
              },
            },
            {
              'roles': ['导演'],
              'work': {
                'id': '12345',
                'title': '仅导演作品',
                'year': '2020',
                'type': 'movie',
              },
            },
          ],
        };
      });
      final repo = CinemaSearchDiscoveryRepository(
        dio: Dio()..httpClientAdapter = adapter,
      );
      final result = await repo.search('Jason Statham');
      expect(result.titles.map((t) => t.title), ['怒之杀']);
      expect(result.queries, isEmpty);
      expect(result.hasMore, isTrue);
      expect(result.nextStart, 2);
      await repo.actorWorks(
        result.celebrityId,
        result.celebrityName,
        start: result.nextStart,
      );
      expect(adapter.calls.last.queryParameters['start'], 2);
    },
  );
  test('malformed metadata fails explicitly, no fabricated result', () async {
    final repo = CinemaSearchDiscoveryRepository(
      dio: Dio()..httpClientAdapter = _Adapter((_) => {'error': 'blocked'}),
    );
    await expectLater(repo.search('anything'), throwsFormatException);
  });
}
