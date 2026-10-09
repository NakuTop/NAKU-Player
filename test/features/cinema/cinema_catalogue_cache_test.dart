import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

const _source = CinemaSource(
  id: 'fixture',
  name: '目录缓存测试',
  kind: CinemaSourceKind.maccms,
  url: 'https://catalogue.example/api.php/provide/vod',
);

class _Adapter implements HttpClientAdapter {
  _Adapter([this.respond]);

  final FutureOr<ResponseBody> Function(RequestOptions, int)? respond;
  final requests = <RequestOptions>[];

  int get categoryRequests => requests
      .where((request) => request.uri.queryParameters['ac'] == 'list')
      .length;
  int get pageRequests => requests.length - categoryRequests;

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

ResponseBody _response(RequestOptions request, {String label = '电影'}) =>
    ResponseBody.fromString(
      jsonEncode({
        'code': 1,
        'page': request.uri.queryParameters['pg'],
        'pagecount': 100,
        'list': request.uri.queryParameters['ac'] == 'list'
            ? []
            : [
                {'vod_id': 1, 'vod_name': label},
              ],
        'class': [
          {'type_id': 1, 'type_name': label},
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

  test('concurrent identical pages share both catalogue requests', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final adapter = _Adapter((request, index) async {
      if (index == 2) started.complete();
      await gate.future;
      return _response(request);
    });
    final repository = _repository(adapter);
    final first = repository.browse(_source, categoryId: '1');
    final second = repository.browse(_source, categoryId: '1');
    final categories = repository.categories(_source);
    await started.future;
    expect(adapter.requests, hasLength(2));
    gate.complete();
    final results = await Future.wait([first, second]);
    expect(identical(results.first, results.last), isTrue);
    expect(await categories, hasLength(1));
    await repository.browse(_source, categoryId: '1');
    expect(adapter.categoryRequests, 1);
    expect(adapter.pageRequests, 1);
  });

  test('pages and categories are separate keys and can be revisited', () async {
    final adapter = _Adapter();
    final repository = _repository(adapter);
    await repository.browse(_source, categoryId: '1');
    await repository.browse(_source, categoryId: '2');
    await repository.browse(_source, categoryId: '1', page: 2);
    await repository.browse(_source, categoryId: '1');
    await repository.browse(_source, categoryId: '2');
    expect(adapter.categoryRequests, 1);
    expect(adapter.pageRequests, 3);
  });

  test(
    'source URL, headers and nested rules all isolate cached data',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      final headers = _source.copyWith(
        requestHeaders: {'Referer': 'https://site.example', 'X-Mode': 'a'},
      );
      final rule = headers.copyWith(
        rule: {
          'nested': {'a': 1, 'b': 2},
        },
      );
      for (final source in [
        _source,
        _source.copyWith(url: '${_source.url}?v=2'),
        headers,
        headers.copyWith(requestHeaders: {'X-Mode': 'b'}),
        rule,
        rule.copyWith(
          rule: {
            'nested': {'a': 1, 'b': 3},
          },
        ),
      ]) {
        await repository.browse(source);
      }
      expect(adapter.categoryRequests, 6);
      expect(adapter.pageRequests, 6);
      await repository.browse(
        rule.copyWith(
          requestHeaders: {'X-Mode': 'a', 'Referer': 'https://site.example'},
          rule: {
            'nested': {'b': 2, 'a': 1},
          },
        ),
      );
      expect(adapter.requests, hasLength(12));
    },
  );

  test('page TTL expires independently of the longer category TTL', () async {
    var now = DateTime.utc(2026);
    final adapter = _Adapter();
    final repository = _repository(adapter, now: () => now);
    await repository.browse(_source);
    now = now.add(const Duration(minutes: 4));
    await repository.browse(_source);
    expect(adapter.pageRequests, 1);
    now = now.add(const Duration(minutes: 1));
    await repository.browse(_source);
    expect(adapter.pageRequests, 2);
    expect(adapter.categoryRequests, 1);
    now = now.add(const Duration(minutes: 25));
    await repository.browse(_source);
    expect(adapter.pageRequests, 3);
    expect(adapter.categoryRequests, 2);
  });

  for (final failingAction in ['list', 'detail']) {
    test(
      '$failingAction failures are retried without caching an error',
      () async {
        var shouldFail = true;
        final adapter = _Adapter((request, _) {
          if (request.uri.queryParameters['ac'] == failingAction &&
              shouldFail) {
            shouldFail = false;
            return ResponseBody.fromString('temporary failure', 503);
          }
          return _response(request);
        });
        final repository = _repository(adapter);
        await expectLater(
          repository.browse(_source),
          throwsA(isA<CinemaSourceException>()),
        );
        final result = await repository.browse(_source);
        expect(result.items.single.title, '电影');
        expect(adapter.pageRequests, 2);
        expect(adapter.categoryRequests, failingAction == 'list' ? 2 : 1);
      },
    );
  }

  test(
    'manual refresh cannot be replaced by an older in-flight result',
    () async {
      final started = Completer<void>();
      final oldGate = Completer<void>();
      final adapter = _Adapter((request, index) async {
        final old = index <= 2;
        if (index == 2) started.complete();
        if (old) await oldGate.future;
        return _response(request, label: old ? '旧目录' : '新目录');
      });
      final repository = _repository(adapter);
      final old = repository.browse(_source);
      await started.future;
      repository.invalidateBrowseCache(source: _source);
      final refreshed = await repository.browse(_source);
      expect(refreshed.items.single.title, '新目录');
      oldGate.complete();
      expect((await old).items.single.title, '旧目录');
      final cached = await repository.browse(_source);
      expect(cached.items.single.title, '新目录');
      expect((await repository.categories(_source)).single.name, '新目录');
      expect(adapter.requests, hasLength(4));
    },
  );

  test(
    'source-scoped refresh preserves other sources and global refresh clears all',
    () async {
      final adapter = _Adapter();
      final repository = _repository(adapter);
      final other = _source.copyWith(id: 'other');
      await repository.browse(_source);
      await repository.browse(other);
      repository.invalidateBrowseCache(source: _source);
      await repository.browse(other);
      expect(adapter.requests, hasLength(4));
      await repository.browse(_source);
      expect(adapter.requests, hasLength(6));
      repository.invalidateBrowseCache();
      await repository.browse(other);
      await repository.browse(_source);
      expect(adapter.requests, hasLength(10));
    },
  );

  test('page cache is bounded and keeps recently revisited pages', () async {
    final adapter = _Adapter();
    final repository = _repository(adapter);
    for (var page = 1; page <= 48; page++) {
      await repository.browse(_source, page: page);
    }
    await repository.browse(_source, page: 1);
    await repository.browse(_source, page: 49);
    await repository.browse(_source, page: 1);
    expect(adapter.pageRequests, 49);
    await repository.browse(_source, page: 2);
    expect(adapter.pageRequests, 50);
    expect(adapter.categoryRequests, 1);
  });

  test('category cache retains at most 24 source configurations', () async {
    final adapter = _Adapter();
    final repository = _repository(adapter);
    for (var i = 0; i < 25; i++) {
      await repository.categories(_source.copyWith(id: 'source-$i'));
    }
    await repository.categories(_source.copyWith(id: 'source-24'));
    expect(adapter.categoryRequests, 25);
    await repository.categories(_source.copyWith(id: 'source-0'));
    expect(adapter.categoryRequests, 26);
  });
}
