import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_douban_access.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);
  final FutureOr<Object> Function(RequestOptions) reply;
  final calls = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    calls.add(options);
    final response = await reply(options);
    return response is ResponseBody
        ? response
        : ResponseBody.fromString(
            jsonEncode(response),
            200,
            headers: {
              'content-type': ['application/json'],
            },
          );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _claim(Object value) => {
  'mainsnak': {
    'datavalue': {'value': value},
  },
};
Map<String, dynamic> _person(String name, String english, String id) => {
  'labels': {
    'zh': {'value': name},
    'en': {'value': english},
  },
  'claims': {
    'P31': [
      _claim({'id': 'Q5'}),
    ],
    'P5284': [_claim(id)],
  },
};
Map<String, dynamic> _title(String id, {String title = '参演电影'}) => {
  'id': id,
  'title': title,
  'year': '2014',
  'type': 'movie',
  'original_title': 'Interstellar',
  'aka': ['星际启示录'],
  'rating': {'value': 9.4, 'max': 10},
  'actors': [
    {'name': '主演'},
  ],
  'genres': ['科幻'],
  'card_subtitle': '2014 / 美国 / 科幻',
};
Object _restricted() => ResponseBody.fromString(
  '',
  302,
  headers: {
    'location': ['https://sec.douban.com/captcha/'],
  },
);
CinemaSearchDiscoveryRepository _repository(
  _Adapter adapter, {
  DateTime Function()? now,
}) => CinemaSearchDiscoveryRepository(
  dio: Dio()..httpClientAdapter = adapter,
  now: now,
);

void main() {
  setUp(CinemaDoubanAccess.resetForTesting);
  tearDown(CinemaDoubanAccess.resetForTesting);
  test(
    'captcha redirect uses independent ID mapping preserving score year and aliases',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          expect(r.queryParameters['limit'], 5);
          return {
            'search': [
              {'id': 'Q13417189'},
              {'id': 'Q123'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          return {
            'entities': {
              'Q13417189': {
                'labels': {
                  'zh-hans': {'value': '星际穿越'},
                  'en': {'value': 'Interstellar'},
                },
                'aliases': {
                  'zh': [
                    {'value': '星际空间'},
                  ],
                },
                'claims': {
                  'P4529': [_claim('1889243')],
                  'P577': [
                    _claim({'time': '+2014-11-01T00:00:00Z'}),
                  ],
                },
              },
              'Q123': {
                'labels': {
                  'en': {'value': 'Interstellar album'},
                },
                'claims': {},
              },
            },
          };
        }
        expect(r.uri.host, 'm.douban.com');
        return _title('1889243', title: '星际穿越');
      });
      final result = await _repository(adapter).search('Interstellar');
      expect(result.titles.single.metadata.sourceDoubanScore, 9.4);
      expect(result.titles.single.metadata.year, '2014');
      expect(result.titles.single.metadata.aliases, contains('Interstellar'));
      expect(result.titles.single.metadata.aliases, contains('星际空间'));
      expect(result.titles.single.metadata.aliases, contains('星际启示录'));
      expect(result.titles.single.metadata.actors, '主演');
      expect(result.titles.single.metadata.area, '美国');
      expect(result.queries, ['星际穿越']);
      expect(adapter.calls.every((r) => r.followRedirects == false), isTrue);
      expect(adapter.calls.length, 4);
    },
  );

  test(
    'verified actor aliases normalize spaces and middle dots with cached works',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          expect(r.queryParameters['search'], '杰森斯坦森');
          return {
            'search': [
              {'id': 'Q169963'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          return {
            'entities': {
              'Q169963': _person('杰森·斯坦森', 'Jason Statham', '1049484'),
            },
          };
        }
        return {
          'total': 1,
          'works': [
            {
              'roles': ['演员 (饰角色)'],
              'work': _title('12345'),
            },
          ],
        };
      });
      final repo = _repository(adapter);
      for (final query in [
        '杰森斯坦森',
        '杰森·斯坦森',
        'Jason Statham',
        'jasonstatham',
      ]) {
        final result = await repo.search(query);
        expect(result.celebrityId, '1049484');
        expect(result.people.single.matches(query), isTrue);
        expect(result.queries, isEmpty);
        expect(result.titles.single.score, 9.4);
      }
      expect(adapter.calls.length, 4);
    },
  );

  test(
    'ambiguous partial actors stay selectable without arbitrary first choice',
    () async {
      final adapter = _Adapter(
        (r) => [
          {
            'id': '10001',
            'title': '汤姆·汉克斯',
            'sub_title': 'Tom Hanks',
            'type': 'celebrity',
          },
          {
            'id': '10002',
            'title': '汤姆·克鲁斯',
            'sub_title': 'Tom Cruise',
            'type': 'celebrity',
          },
        ],
      );
      final result = await _repository(adapter).search('Tom');
      expect(result.people.length, 2);
      expect(result.celebrityId, isEmpty);
      expect(result.queries, isEmpty);
      expect(result.message, contains('请选择'));
      expect(adapter.calls.length, 1);
    },
  );

  test(
    'unique exact actor among multiple candidates uses only that identity',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) {
          return [
            {
              'id': '10001',
              'title': '汤姆·汉克斯',
              'sub_title': 'Tom Hanks',
              'type': 'celebrity',
            },
            {
              'id': '10002',
              'title': '汤姆',
              'sub_title': 'Tom',
              'type': 'celebrity',
            },
          ];
        }
        expect(r.path, contains('/10001/works'));
        return {
          'total': 1,
          'works': [
            {
              'roles': ['演员'],
              'work': _title('12345'),
            },
          ],
        };
      });
      final result = await _repository(adapter).search('Tom Hanks');
      expect(result.celebrityId, '10001');
      expect(result.people.length, 2);
    },
  );

  test(
    'actor page offset counts all server rows while deduplicating acting credits',
    () async {
      final adapter = _Adapter(
        (r) => {
          'total': 8,
          'works': [
            {
              'roles': ['演员'],
              'work': _title('12345'),
            },
            {
              'roles': ['导演'],
              'work': _title('12346'),
            },
            {
              'roles': ['演员'],
              'work': _title('12345'),
            },
            {
              'roles': ['演员'],
              'work': {'id': 'bad', 'title': '坏数据'},
            },
            'malformed',
          ],
        },
      );
      final result = await _repository(adapter).actorWorks('10001', '演员');
      expect(result.titles.map((t) => t.id), ['12345']);
      expect(result.nextStart, 5);
      expect(result.hasMore, isTrue);
    },
  );

  test(
    'empty actor directory falls back once and keeps Wikidata pagination mode',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q2263'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          return {
            'entities': {'Q2263': _person('汤姆·汉克斯', 'Tom Hanks', '1054450')},
          };
        }
        if (r.path.endsWith('/works')) return {'total': 0, 'works': []};
        if (r.uri.host == 'query.wikidata.org') {
          final query = r.queryParameters['query'].toString();
          expect(query, contains('wdt:P161 wd:Q2263'));
          expect(query, contains('GROUP BY ?work'));
          final offset = query.contains('OFFSET 12') ? 12 : 0;
          return {
            'results': {
              'bindings': List.generate(
                offset == 0 ? 13 : 1,
                (i) => {
                  'douban': {'value': '${20000 + offset + i}'},
                  'workLabel': {'value': '作品${offset + i}'},
                  'date': {'value': '2020-01-01T00:00:00Z'},
                  'original': {'value': 'Original ${offset + i}'},
                },
              ),
            },
          };
        }
        final id = r.uri.pathSegments.last;
        return _title(id, title: '已核实 $id');
      });
      final repo = _repository(adapter);
      final first = await repo.search('Tom Hanks');
      expect(first.celebrityId, 'wikidata:Q2263');
      expect(first.titles.length, 12);
      expect(first.nextStart, 12);
      expect(first.hasMore, isTrue);
      final next = await repo.actorWorks(
        first.celebrityId,
        first.celebrityName,
        start: first.nextStart,
      );
      expect(next.titles.single.id, '20012');
      expect(next.nextStart, 13);
      expect(next.hasMore, isFalse);
      expect(adapter.calls.where((r) => r.path.endsWith('/works')).length, 1);
      expect(
        adapter.calls.where((r) => r.uri.host == 'query.wikidata.org').length,
        2,
      );
      await repo.search('汤姆汉克斯');
      expect(
        adapter.calls.where((r) => r.uri.host == 'query.wikidata.org').length,
        2,
      );
    },
  );

  test(
    'failed Wikidata works are not immediately requested twice and actor remains selectable',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q2263'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          return {
            'entities': {'Q2263': _person('汤姆·汉克斯', 'Tom Hanks', '1054450')},
          };
        }
        if (r.path.endsWith('/works')) return {'total': 0, 'works': []};
        return ResponseBody.fromString('', 503);
      });
      final result = await _repository(adapter).search('Tom Hanks');
      expect(result.people.single.id, '1054450');
      expect(result.message, contains('暂时无法'));
      expect(
        adapter.calls.where((r) => r.uri.host == 'query.wikidata.org').length,
        1,
      );
    },
  );

  test(
    'empty results expire quickly and restricted suggest is not hammered',
    () async {
      var now = DateTime(2026);
      final adapter = _Adapter(
        (r) =>
            r.path.endsWith('subject_suggest') ? _restricted() : {'search': []},
      );
      final repo = _repository(adapter, now: () => now);
      await repo.search('Unlisted');
      await repo.search('UNLISTED');
      expect(adapter.calls.length, 2);
      now = now.add(const Duration(seconds: 31));
      await repo.search('Unlisted');
      expect(adapter.calls.length, 3);
      expect(
        adapter.calls.where((r) => r.path.endsWith('subject_suggest')).length,
        1,
      );
    },
  );

  test('cancellation never triggers external fallback', () async {
    final token = CancelToken();
    final adapter = _Adapter((r) {
      token.cancel();
      throw token.cancelError!;
    });
    await expectLater(
      _repository(adapter).search('Tom Hanks', cancelToken: token),
      throwsA(
        isA<DioException>().having(
          (e) => e.type,
          'type',
          DioExceptionType.cancel,
        ),
      ),
    );
    expect(adapter.calls.length, 1);
  });

  test(
    'invalid actor IDs and out of range cursors never issue requests',
    () async {
      final adapter = _Adapter((r) => {});
      final repo = _repository(adapter);
      await expectLater(
        repo.actorWorks('Q1 UNION', 'bad'),
        throwsFormatException,
      );
      await expectLater(
        repo.actorWorks('123', 'bad', start: -1),
        throwsFormatException,
      );
      expect(adapter.calls, isEmpty);
    },
  );

  test(
    'identity assurance rejects ambiguous mappings and unknown types',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q1'},
              {'id': 'Q2'},
              {'id': 'Q3'},
              {'id': 'Q4'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          Map<String, dynamic> entity(
            String name,
            List<String> ids,
            String type,
          ) => {
            'labels': {
              'zh': {'value': name},
            },
            'claims': {
              'P4529': ids.map(_claim).toList(),
              'P31': [
                _claim({'id': type}),
              ],
              'P577': [
                _claim({'time': '+2020-01-01T00:00:00Z'}),
              ],
            },
          };
          return {
            'entities': {
              'Q1': entity('歧义', ['12345', '12346'], 'Q11424'),
              'Q2': entity('未知类型', ['12347'], 'Q999'),
              'Q3': entity('第二季', ['12348'], 'Q3464665'),
              'Q4': entity('明确电影', ['12349'], 'Q11424'),
            },
          };
        }
        return ResponseBody.fromString('', 403);
      });
      final result = await _repository(adapter).search('候选');
      expect(result.titles.map((t) => t.id), ['12347', '12348', '12349']);
      expect(result.titles.first.kind, isEmpty);
      expect(result.titles.first.metadata.category, isEmpty);
      expect(result.titles.first.identityVerified, isFalse);
      expect(result.titles[1].kind, 'tv');
      expect(result.titles[1].identityVerified, isTrue);
      expect(result.titles[2].kind, 'movie');
      expect(result.titles[2].identityVerified, isTrue);
    },
  );

  test(
    'ambiguous celebrity mapping keeps Wikidata identity instead of choosing first Douban ID',
    () async {
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q2263'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          final person = _person('汤姆·汉克斯', 'Tom Hanks', '1054450');
          (person['claims'] as Map)['P5284'] = [
            _claim('1054450'),
            _claim('1054451'),
          ];
          return {
            'entities': {'Q2263': person},
          };
        }
        expect(r.uri.host, 'query.wikidata.org');
        return {
          'results': {'bindings': []},
        };
      });
      final result = await _repository(adapter).search('Tom Hanks');
      expect(result.people.single.id, 'wikidata:Q2263');
      expect(result.celebrityId, 'wikidata:Q2263');
      expect(
        adapter.calls.where((r) => r.path.contains('/celebrity/')),
        isEmpty,
      );
    },
  );

  test(
    'actor fallback preserves known TV types and leaves unknown types unclassified',
    () async {
      final adapter = _Adapter((r) {
        if (r.uri.host == 'query.wikidata.org') {
          expect(
            r.queryParameters['query'],
            contains('COUNT(DISTINCT ?subject) = 1'),
          );
          return {
            'results': {
              'bindings': [
                {
                  'douban': {'value': '12345'},
                  'workLabel': {'value': '第二季'},
                  'types': {'value': 'http://www.wikidata.org/entity/Q3464665'},
                },
                {
                  'douban': {'value': '12346'},
                  'workLabel': {'value': '未知'},
                  'types': {'value': 'http://www.wikidata.org/entity/Q999'},
                },
              ],
            },
          };
        }
        return ResponseBody.fromString('', 403);
      });
      final result = await _repository(
        adapter,
      ).actorWorks('wikidata:Q2263', '汤姆');
      expect(result.titles.first.kind, 'tv');
      expect(result.titles.last.kind, isEmpty);
      expect(result.titles.every((t) => !t.identityVerified), isTrue);
    },
  );

  test(
    'only exact subject metadata with type and year sets official identity assurance',
    () {
      expect(
        CinemaDiscoveryTitle.parse(_title('12345'))!.identityVerified,
        isFalse,
      );
      expect(
        CinemaDiscoveryTitle.parse(
          _title('12345'),
          verifyIdentity: true,
        )!.identityVerified,
        isTrue,
      );
      expect(
        CinemaDiscoveryTitle.parse({
          ..._title('12345'),
          'year': '',
          'card_subtitle': '',
        }, verifyIdentity: true)!.identityVerified,
        isFalse,
      );
      expect(
        CinemaDiscoveryTitle.parse({
          ..._title('12345'),
          'type': 'unknown',
        }, verifyIdentity: true)!.identityVerified,
        isFalse,
      );
    },
  );

  test(
    'subject rate limiting stops remaining hydration and retains public works',
    () async {
      final adapter = _Adapter((r) {
        if (r.uri.host == 'query.wikidata.org') {
          return {
            'results': {
              'bindings': List.generate(
                12,
                (i) => {
                  'douban': {'value': '${30000 + i}'},
                  'workLabel': {'value': '作品$i'},
                  'date': {'value': '2020-01-01T00:00:00Z'},
                  'types': {'value': 'http://www.wikidata.org/entity/Q11424'},
                },
              ),
            },
          };
        }
        return ResponseBody.fromString(
          jsonEncode({'code': 1309, 'msg': 'subject_ip_rate_limit'}),
          400,
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final repo = _repository(adapter);
      final result = await repo.actorWorks('wikidata:Q2263', '汤姆');
      expect(result.titles.length, 12);
      expect(result.titles.every((t) => t.score == null), isTrue);
      expect(result.message, contains('评分将在稍后重试'));
      expect(
        adapter.calls.where((r) => r.uri.host == 'm.douban.com').length,
        lessThanOrEqualTo(2),
      );
      final before = adapter.calls.length;
      await repo.actorWorks('wikidata:Q2263', '汤姆', start: 12);
      expect(adapter.calls.length, before + 1); // Only a new public works page.
    },
  );

  test(
    'failed known actor alias results use a short cache instead of retrying on each render',
    () async {
      var now = DateTime(2026);
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
        return ResponseBody.fromString('', 503);
      });
      final repo = _repository(adapter, now: () => now);
      await repo.search('Jason Statham');
      await repo.search('杰森斯坦森');
      final before = adapter.calls.length;
      await repo.search('杰森·斯坦森');
      expect(adapter.calls.length, before);
      now = now.add(const Duration(seconds: 31));
      await repo.search('杰森斯坦森');
      expect(adapter.calls.length, before + 1);
    },
  );

  test(
    'search respects cooldown from another caller while actor directory remains independent',
    () async {
      CinemaDoubanAccess.noteResponse(400, {'code': 1309});
      final adapter = _Adapter((r) {
        if (r.path.endsWith('subject_suggest')) return _restricted();
        if (r.queryParameters['action'] == 'wbsearchentities') {
          return {
            'search': [
              {'id': 'Q1'},
            ],
          };
        }
        if (r.queryParameters['action'] == 'wbgetentities') {
          return {
            'entities': {
              'Q1': {
                'labels': {
                  'zh': {'value': '星际穿越'},
                  'en': {'value': 'Interstellar'},
                },
                'claims': {
                  'P4529': [_claim('1889243')],
                  'P31': [
                    _claim({'id': 'Q11424'}),
                  ],
                  'P577': [
                    _claim({'time': '+2014-01-01T00:00:00Z'}),
                  ],
                },
              },
            },
          };
        }
        expect(r.path, contains('/celebrity/1049484/works'));
        return {
          'total': 1,
          'works': [
            {
              'roles': ['演员'],
              'work': _title('12345'),
            },
          ],
        };
      });
      final result = await _repository(adapter).search('Interstellar');
      expect(result.titles.single.id, '1889243');
      expect(result.message, contains('评分将在稍后重试'));
      final works = await _repository(adapter).actorWorks('1049484', '杰森·斯坦森');
      expect(works.titles.single.score, 9.4);
      expect(
        adapter.calls.where((r) => r.path.contains('/api/v2/movie/')),
        isEmpty,
      );
    },
  );

  test(
    'ratings retain their ten point scale and reject wrong scale or nonfinite values',
    () {
      for (final rating in [
        {'value': 11},
        {'value': 'NaN'},
        {'value': 4, 'max': 5},
      ]) {
        expect(
          CinemaDiscoveryTitle.parse({
            ..._title('12345'),
            'rating': rating,
          })!.metadata.sourceDoubanScore,
          isNull,
        );
      }
      expect(
        CinemaDiscoveryTitle.parse(_title('12345'))!.metadata.sourceDoubanScore,
        9.4,
      );
    },
  );
  test(
    'punctuation-distinct movie names keep separate query cache entries',
    () async {
      final adapter = _Adapter((r) {
        final query = r.queryParameters['q'];
        expect(r.path, endsWith('subject_suggest'));
        return [
          {
            'id': query == 'A-B' ? '12345' : '12346',
            'title': query,
            'type': 'movie',
            'year': '2020',
          },
        ];
      });
      final repository = _repository(adapter);
      expect((await repository.search('A-B')).titles.single.id, '12345');
      expect((await repository.search('AB')).titles.single.id, '12346');
      expect((await repository.search('a-b')).titles.single.id, '12345');
      expect((await repository.search('ab')).titles.single.id, '12346');
      expect(adapter.calls.length, 2);
    },
  );
}
