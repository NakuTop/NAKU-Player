import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

const _source = CinemaSource(
  id: 'search-cache',
  name: '搜索缓存测试',
  kind: CinemaSourceKind.maccms,
  url: 'https://search.invalid/api.php/provide/vod',
);

class _Adapter implements HttpClientAdapter {
  _Adapter([this.respond]);
  final FutureOr<ResponseBody> Function(RequestOptions, int)? respond;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await (respond?.call(options, requests.length) ??
        _response(options));
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(
  RequestOptions options, {
  String? label,
  bool empty = false,
}) => ResponseBody.fromString(
  jsonEncode({
    'code': 1,
    'page': options.uri.queryParameters['pg'],
    'pagecount': 100,
    'list': empty
        ? []
        : [
            {
              'vod_id': 1,
              'vod_name': label ?? options.uri.queryParameters['wd'],
              'type_name': '剧情片',
              'vod_year': '2020',
            },
          ],
  }),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json'],
  },
);
CinemaRepository _repository(_Adapter adapter, {DateTime Function()? now}) =>
    CinemaRepository(dio: Dio()..httpClientAdapter = adapter, now: now);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'an incomplete category index still finds older exact films on the oldest search page',
    () async {
      final adapter = _Adapter((options, _) {
        final q = options.uri.queryParameters;
        final tail = q['pg'] == '9';
        return ResponseBody.fromString(
          jsonEncode({
            'page': tail ? 9 : 1,
            'pagecount': 9,
            if (q['ac'] == 'list') 'class': [],
            'list': q['ac'] == 'list'
                ? []
                : [
                    {
                      'vod_id': tail ? '1992' : '2025',
                      'vod_name': tail ? '离婚' : '离婚喜剧',
                      'vod_year': tail ? '1992' : '2025',
                      'type_name': '剧情片',
                    },
                  ],
          }),
          200,
        );
      });
      final repo = CinemaRepository(
        dio: Dio()..httpClientAdapter = adapter,
        hideShortDramas: true,
      );
      final page = await repo.search(_source, '离婚');
      expect(page.items.map((t) => t.id), contains('1992'));
      expect(
        adapter.requests.where((r) => r.uri.queryParameters['pg'] == '9'),
        hasLength(1),
      );
    },
  );
  test(
    'a film crowded out by shorts and a namesake series is recovered by category',
    () async {
      final adapter = _Adapter((options, _) {
        final q = options.uri.queryParameters;
        Map<String, dynamic> item(
          int id,
          String name,
          String cat,
          int type,
          String year,
        ) => {
          'vod_id': id,
          'vod_name': name,
          'type_name': cat,
          'type_id': type,
          'vod_year': year,
        };
        final classes = [
          {'type_id': 1, 'type_name': '电影'},
          {'type_id': 11, 'type_pid': 1, 'type_name': '剧情片'},
          {'type_id': 2, 'type_name': '连续剧'},
          {'type_id': 15, 'type_pid': 2, 'type_name': '国产剧'},
          {'type_id': 8, 'type_name': '短剧'},
          {'type_id': 81, 'type_pid': 8, 'type_name': '现代都市'},
          {'type_id': 812, 'type_pid': 81, 'type_name': '专题'},
          {'type_id': 7, 'type_pid': 0, 'type_name': 'AI制作'},
          {'type_id': 98, 'type_pid': 7, 'type_name': 'AI动画短剧'},
          {'type_id': 981, 'type_pid': 98, 'type_name': '都市'},
        ];
        return ResponseBody.fromString(
          jsonEncode({
            'code': 1,
            'page': 1,
            'pagecount': 9,
            if (q['ac'] == 'list') 'class': classes,
            'list': [
              if (q['ac'] == 'detail' && q['t'] == null) ...[
                item(1, '离婚那一天', '专题', 812, '2026'),
                item(2, '离婚', 'AI漫剧', 999, '2025'),
                item(3, '离婚', '国产剧', 15, '1999'),
                item(4, 'AI短剧制作手记', '纪录片', 18, '2020'),
                item(5, '离婚之前', '短片', 10, '1993'),
                item(7, '离婚', '都市', 981, '2025'),
                item(8, '离婚', '短剧', 8, '2024'),
              ],
              if (q['t'] == '11') item(6, '离婚', '剧情片', 11, '1992'),
              if (q['t'] == '15') item(9, '另一个名字', '国产剧', 15, '1992'),
            ],
          }),
          200,
          headers: {
            'content-type': ['application/json'],
          },
        );
      });
      final repo = CinemaRepository(
        dio: Dio()..httpClientAdapter = adapter,
        hideShortDramas: true,
      );
      final page = await repo.search(_source, '离婚');
      expect(
        page.items.map((t) => t.id),
        unorderedEquals(['3', '4', '5', '6', '8']),
      );
      expect(page.categories.map((c) => c.id), contains('812'));
      expect(page.categories.map((c) => c.id), isNot(contains('981')));
      expect(page.categories.map((c) => c.id), isNot(contains('7')));
      expect(page.hasMore, isTrue);
      expect(
        adapter.requests
            .where((r) => r.uri.queryParameters.containsKey('t'))
            .length,
        lessThanOrEqualTo(4),
      );
    },
  );
  test('compact series fallback retains the requested season only', () async {
    final adapter = _Adapter(
      (o, _) => ResponseBody.fromString(
        jsonEncode({
          'code': 1,
          'list': [
            if (o.uri.queryParameters['wd'] == '重启吧')
              for (final season in [1, 2])
                {
                  'vod_id': season,
                  'vod_name': '重启吧！宇宙第$season季',
                  'type_name': '欧美剧',
                  'vod_year': '2025',
                },
          ],
        }),
        200,
      ),
    );
    final result = await _repository(adapter).search(_source, '重启吧宇宙第二季');
    expect(result.items.map((t) => t.id), ['2']);
  });

  test(
    'compact titles find punctuated films without admitting fragment-only hits',
    () async {
      for (final fixture in [
        ('摔跤吧爸爸', '摔跤吧', '摔跤吧！爸爸'),
        ('重启吧宇宙', '重启吧', '重启吧？宇宙'),
      ]) {
        final adapter = _Adapter((options, _) {
          final partial = options.uri.queryParameters['wd'] == fixture.$2;
          return ResponseBody.fromString(
            jsonEncode({
              'code': 1,
              'list': [
                if (partial) ...[
                  {
                    'vod_id': 1,
                    'vod_name': fixture.$3,
                    'type_name': '剧情片',
                    'vod_year': '2016',
                  },
                  {
                    'vod_id': 2,
                    'vod_name': '${fixture.$3}国语',
                    'type_name': '剧情片',
                    'vod_year': '2016',
                  },
                  {
                    'vod_id': 3,
                    'vod_name': '${fixture.$3}[电影解说]',
                    'vod_sub': fixture.$3,
                    'type_name': '电影解说',
                  },
                  {
                    'vod_id': 4,
                    'vod_name': '${fixture.$3}2',
                    'type_name': '剧情片',
                  },
                ],
              ],
            }),
            200,
          );
        });
        final result = await _repository(adapter).search(_source, fixture.$1);
        expect(result.items.map((t) => t.id), ['1', '2']);
        expect(adapter.requests.map((r) => r.uri.queryParameters['wd']), [
          fixture.$1,
          fixture.$2,
        ]);
      }
    },
  );

  test(
    'equivalent year searches retain exact work and both colon spellings',
    () async {
      final adapter = _Adapter((options, _) {
        final query = options.uri.queryParameters['wd'];
        return ResponseBody.fromString(
          jsonEncode({
            'page': 1,
            'pagecount': 1,
            'list': [
              if (query == '生化危机：爆发夜') ...[
                {
                  'vod_id': '633084638071357445',
                  'vod_name': '生化危机：爆发夜',
                  'type_name': '恐怖片',
                  'vod_year': '2026',
                },
                {
                  'vod_id': '2',
                  'vod_name': '生化危机：爆发夜',
                  'type_name': '恐怖片',
                  'vod_year': '2006',
                },
                {
                  'vod_id': '3',
                  'vod_name': '生化危机：其他续作',
                  'type_name': '恐怖片',
                  'vod_year': '2026',
                },
              ],
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      final repository = _repository(adapter);
      final result = await repository.search(_source, '生化危机：爆发夜2026');
      expect(result.items.map((x) => x.id), ['633084638071357445']);
      expect(adapter.requests, hasLength(3));
      expect(
        adapter.requests.map((x) => x.uri.queryParameters['wd']),
        containsAll(['生化危机：爆发夜', '生化危机:爆发夜']),
      );
      await repository.search(_source, '生化危机：爆发夜2026');
      expect(adapter.requests, hasLength(3));
    },
  );

  test(
    'season spellings share one search and retain only the requested season',
    () async {
      final adapter = _Adapter((options, _) {
        final query = options.uri.queryParameters['wd'];
        return ResponseBody.fromString(
          jsonEncode({
            'page': 1,
            'pagecount': 1,
            'list': [
              if (query == '美国恐怖故事第十二季')
                {
                  'vod_id': '43991',
                  'vod_name': '美国恐怖故事 第十二季',
                  'type_name': '欧美剧',
                  'vod_year': '2023',
                },
              if (query == '美国恐怖故事')
                {
                  'vod_id': '629627612989227013',
                  'vod_name': '美国恐怖故事',
                  'type_name': '欧美剧',
                  'vod_year': '2011',
                  'vod_play_from': 'hls',
                  'vod_play_url':
                      'S11E01\$https://media.example/11.m3u8'
                      '#第 12 季 第 1 集\$https://media.example/12.m3u8',
                },
            ],
          }),
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      });
      final repository = _repository(adapter);
      for (final name in [
        '美国恐怖故事第12季',
        '美国恐怖故事十二季',
        '美国恐怖故事 第１２季',
        '美国恐怖故事 S12',
      ]) {
        final result = await repository.search(_source, name);
        expect(result.items.map((title) => title.id), [
          '43991',
          '629627612989227013~s12',
        ]);
        expect(
          result.items.last.routes.single.episodes.single.url,
          endsWith('/12.m3u8'),
        );
      }
      expect(adapter.requests, hasLength(3));
    },
  );

  test(
    'same trimmed search coalesces and subsequent discovery reuses its response',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final adapter = _Adapter((options, _) async {
        if (!started.isCompleted) started.complete();
        await release.future;
        return _response(options);
      });
      final repository = _repository(adapter);
      final rawSearch = repository.search(_source, '  星际穿越  ');
      final expandedSearch = repository.search(_source, '星际穿越');
      await started.future;
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.uri.queryParameters['wd'], '星际穿越');
      release.complete();
      final results = await Future.wait([rawSearch, expandedSearch]);
      expect(identical(results[0], results[1]), isTrue);
      expect(
        identical(await repository.search(_source, '星际穿越'), results[0]),
        isTrue,
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'query case, internal whitespace and pagination retain remote semantics',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      await repository.search(_source, 'The Movie');
      await repository.search(_source, 'the movie');
      await repository.search(_source, 'The  Movie');
      await repository.search(_source, 'The Movie', page: 2);
      await repository.search(_source, ' The Movie ');
      expect(adapter.requests, hasLength(4));
      expect(adapter.requests.map((r) => r.uri.queryParameters['wd']), [
        'The Movie',
        'the movie',
        'The  Movie',
        'The Movie',
      ]);
      expect(adapter.requests.last.uri.queryParameters['pg'], '2');
      await repository.search(_source, '   ');
      expect(adapter.requests, hasLength(4));
    },
  );

  test(
    'full source configuration isolates searches while map order is canonical',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      final configured = _source.copyWith(
        requestHeaders: {'X-Mode': 'a', 'Referer': 'https://source.invalid/'},
        rule: {
          'nested': {'a': 1, 'b': 2},
        },
      );
      for (final current in [
        _source,
        _source.copyWith(id: 'other'),
        _source.copyWith(url: 'https://updated.invalid/api'),
        configured,
        configured.copyWith(requestHeaders: {'X-Mode': 'b'}),
        configured.copyWith(
          rule: {
            'nested': {'a': 1, 'b': 3},
          },
        ),
      ]) {
        await repository.search(current, '测试');
      }
      expect(adapter.requests, hasLength(6));
      await repository.search(
        configured.copyWith(
          requestHeaders: {'Referer': 'https://source.invalid/', 'X-Mode': 'a'},
          rule: {
            'nested': {'b': 2, 'a': 1},
          },
        ),
        '测试',
      );
      expect(adapter.requests, hasLength(6));
    },
  );

  test('successful empty results share a three minute expiry', () async {
    var now = DateTime.utc(2026);
    final adapter = _Adapter((r, _) => _response(r, empty: true));
    final repository = _repository(adapter, now: () => now);
    expect((await repository.search(_source, '暂未更新')).items, isEmpty);
    now = now.add(const Duration(minutes: 2, seconds: 59));
    await repository.search(_source, '暂未更新');
    expect(adapter.requests, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    await repository.search(_source, '暂未更新');
    expect(adapter.requests, hasLength(2));
  });

  test(
    'a failed search is immediately retryable and does not poison cache',
    () async {
      final adapter = _Adapter(
        (options, index) => index == 1
            ? ResponseBody.fromString('temporary failure', 503)
            : _response(options),
      );
      final repository = _repository(adapter);
      await expectLater(
        repository.search(_source, '测试'),
        throwsA(isA<CinemaSourceException>()),
      );
      expect((await repository.search(_source, '测试')).items.single.title, '测试');
      await repository.search(_source, '测试');
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'invalidating in-flight search prevents its old completion replacing fresh results',
    () async {
      final started = Completer<void>(), oldGate = Completer<void>();
      final adapter = _Adapter((options, index) async {
        if (index == 1) {
          started.complete();
          await oldGate.future;
        }
        return _response(options, label: index == 1 ? '旧搜索' : '新搜索');
      });
      final repository = _repository(adapter);
      final old = repository.search(_source, '测试');
      await started.future;
      repository.invalidateSearchCache(source: _source);
      expect(
        (await repository.search(_source, '测试')).items.single.title,
        '新搜索',
      );
      oldGate.complete();
      expect((await old).items.single.title, '旧搜索');
      expect(
        (await repository.search(_source, '测试')).items.single.title,
        '新搜索',
      );
      expect(adapter.requests, hasLength(2));
    },
  );

  test(
    'manual refresh clears matching searches but preserves other sources',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      final other = _source.copyWith(id: 'other');
      await repository.search(_source, '测试');
      await repository.search(other, '测试');
      repository.invalidateBrowseCache(source: _source);
      await repository.search(other, '测试');
      expect(adapter.requests, hasLength(2));
      await repository.search(_source, '测试');
      expect(adapter.requests, hasLength(3));
      repository.invalidateBrowseCache();
      await repository.search(_source, '测试');
      await repository.search(other, '测试');
      expect(adapter.requests, hasLength(5));
    },
  );

  test(
    'search cache holds 96 entries and retains recently revisited queries',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      for (var i = 0; i < 96; i++) {
        await repository.search(_source, '作品$i');
      }
      await repository.search(_source, '作品0');
      await repository.search(_source, '作品96');
      await repository.search(_source, '作品0');
      expect(adapter.requests, hasLength(97));
      await repository.search(_source, '作品1');
      expect(adapter.requests, hasLength(98));
    },
  );
}
