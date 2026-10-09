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
