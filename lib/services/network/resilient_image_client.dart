import 'dart:async';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'resilient_read_adapter.dart';
import 'macos_system_proxy.dart';

class ResilientImageClient extends http.BaseClient {
  ResilientImageClient()
    : _adapter = ResilientReadAdapter(
        primaryFactory: () => IOHttpClientAdapter(
          createHttpClient: () =>
              HttpClient()..findProxy = MacOSSystemProxy.findProxy,
        ),
      );
  final ResilientReadAdapter _adapter;
  final _requests = <CancelToken>{};
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final cancel = CancelToken();
    _requests.add(cancel);
    final done = Completer<void>();
    cancel.whenCancel.then((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      final response = await _adapter.fetch(
        RequestOptions(
          path: request.url.toString(),
          method: request.method,
          headers: request.headers,
          responseType: ResponseType.bytes,
          connectTimeout: const Duration(seconds: 4),
          receiveTimeout: const Duration(seconds: 12),
          followRedirects: request.followRedirects,
          maxRedirects: request.maxRedirects,
          cancelToken: cancel,
        ),
        null,
        done.future,
      );
      Stream<List<int>> body() async* {
        try {
          yield* response.stream;
        } finally {
          _requests.remove(cancel);
        }
      }

      final headers = {
        for (final e in response.headers.entries) e.key: e.value.join(', '),
      };
      return http.StreamedResponse(
        body(),
        response.statusCode,
        headers: headers,
        request: request,
        contentLength: headers.containsKey('content-encoding')
            ? null
            : int.tryParse(headers['content-length'] ?? ''),
      );
    } catch (_) {
      _requests.remove(cancel);
      rethrow;
    }
  }

  @override
  void close() {
    for (final cancel in _requests) {
      cancel.cancel('图片请求已关闭');
    }
    _requests.clear();
    _adapter.close(force: true);
  }
}
