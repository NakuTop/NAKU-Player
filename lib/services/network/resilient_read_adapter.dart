import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:ech_http/ech_http.dart';
import 'package:http/http.dart' as http;
import 'macos_system_proxy.dart';

/// Bounded failover for public reads; no replay of writes, credentials or streams.
class ResilientReadAdapter implements HttpClientAdapter {
  ResilientReadAdapter({
    required this.primaryFactory,
    HttpClientAdapter Function()? directFactory,
    Future<ResponseBody> Function(RequestOptions, Future<void>?)? encryptedRead,
    int Function()? revision,
    Uri? Function(Uri)? proxy,
    Future<void> Function()? refresh,
  }) : directFactory =
           directFactory ??
           (() => IOHttpClientAdapter(
             createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
           )),
       _encryptedRead = encryptedRead ?? _echRead,
       _revision = revision ?? (() => MacOSSystemProxy.revision),
       _proxy = proxy ?? MacOSSystemProxy.proxyFor,
       _refresh = refresh ?? MacOSSystemProxy.initialize;
  final HttpClientAdapter Function() primaryFactory, directFactory;
  final Future<ResponseBody> Function(RequestOptions, Future<void>?)
  _encryptedRead;
  final int Function() _revision;
  final Uri? Function(Uri) _proxy;
  final Future<void> Function() _refresh;
  HttpClientAdapter? _primary, _direct;
  int _seenRevision = -1;
  bool _closed = false;
  final _preferred = <String, (String, DateTime)>{};
  static bool eligible(RequestOptions options) {
    final host = options.uri.host.toLowerCase();
    final ip = InternetAddress.tryParse(host);
    if (!['GET', 'HEAD'].contains(options.method.toUpperCase()) ||
        options.data != null ||
        options.responseType == ResponseType.stream ||
        options.uri.userInfo.isNotEmpty ||
        !['https', 'http'].contains(options.uri.scheme) ||
        !host.contains('.') ||
        host.endsWith('.local')) {
      return false;
    }
    if (options.uri.queryParameters.keys.any(
      (key) => RegExp(
        'token|password|secret|signature|api.key',
        caseSensitive: false,
      ).hasMatch(key),
    ))
      return false;
    if (options.headers.keys.any(
      (k) => RegExp(
        'authorization|cookie|token|api.key|signature|x-appid',
        caseSensitive: false,
      ).hasMatch(k),
    )) {
      return false;
    }
    if (ip != null) {
      if (ip.isLoopback ||
          ip.isLinkLocal ||
          ip.type == InternetAddressType.IPv6) {
        return false;
      }
      final b = ip.rawAddress;
      if (b[0] == 10 ||
          b[0] == 127 ||
          b[0] == 192 && b[1] == 168 ||
          b[0] == 172 && b[1] >= 16 && b[1] <= 31) {
        return false;
      }
    }
    return true;
  }

  static bool networkFailure(Object error) =>
      error is DioException &&
      const {
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
      }.contains(error.type);
  void _sync() {
    if (_seenRevision == _revision()) return;
    _primary?.close();
    _direct?.close();
    _primary = null;
    _direct = null;
    _preferred.clear();
    _seenRevision = _revision();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_closed) throw StateError('Network adapter closed');
    _sync();
    var cancelled = options.cancelToken?.isCancelled ?? false;
    cancelFuture?.then((_) => cancelled = true);
    final safe = requestStream == null && eligible(options);
    final uri = options.uri;
    final preferred = _preferred[uri.host];
    final route =
        safe && preferred != null && preferred.$2.isAfter(DateTime.now())
        ? preferred.$1
        : 'system';
    final hasProxy = _proxy(uri) != null;
    final routes = <String>{
      route,
      'system',
      if (safe && hasProxy) 'direct',
      if (safe && uri.scheme == 'https' && uri.port == 443) 'ech',
    };
    Object? lastError;
    StackTrace? lastStack;
    for (final next in routes) {
      if (cancelled || options.cancelToken?.isCancelled == true) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: '请求已取消',
        );
      }
      try {
        final attempt = safe
            ? options.copyWith(
                connectTimeout: const Duration(seconds: 4),
                receiveTimeout: options.receiveTimeout,
              )
            : options;
        final response = next == 'ech'
            ? await _encryptedRead(attempt, cancelFuture)
            : await (next == 'direct'
                      ? _direct ??= directFactory()
                      : _primary ??= primaryFactory())
                  .fetch(attempt, requestStream, cancelFuture);
        if (safe && response.statusCode >= 200 && response.statusCode < 300) {
          if (_preferred.length >= 64) _preferred.remove(_preferred.keys.first);
          _preferred[uri.host] = (
            next,
            DateTime.now().add(const Duration(minutes: 1)),
          );
        }
        return response;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        if (!safe || cancelled || !networkFailure(error)) rethrow;
        if (next == 'system') {
          await _refresh();
          _sync();
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStack!);
  }

  static Future<ResponseBody> _echRead(
    RequestOptions options,
    Future<void>? cancelFuture,
  ) async {
    final bootstrap = EchClient(
      connectTimeout: const Duration(seconds: 3),
      timeout: const Duration(seconds: 4),
    );
    final client = EchClient(
      connectTimeout: const Duration(seconds: 4),
      timeout: const Duration(seconds: 8),
      resolver: DohEchResolver(
        client: bootstrap,
        endpoint: Uri.https('dns.alidns.com', '/resolve'),
        hosts: {options.uri.host},
        // Domestic resolvers can also synthesize blocked A records. Known
        // Cloudflare edges are scoped to Bangumi; TLS still verifies its host.
        addressOverrides: const {
          'api.bgm.tv': ['104.26.9.23', '104.26.8.23', '172.67.73.67'],
          'next.bgm.tv': ['104.26.9.23', '104.26.8.23', '172.67.73.67'],
          'lain.bgm.tv': ['104.26.9.23', '104.26.8.23', '172.67.73.67'],
        },
        configDomains: const {
          'api.bgm.tv': 'crypto.cloudflare.com',
          'next.bgm.tv': 'crypto.cloudflare.com',
          'lain.bgm.tv': 'crypto.cloudflare.com',
        },
      ),
    );
    final abort = Completer<void>();
    cancelFuture?.then((_) {
      if (!abort.isCompleted) abort.complete();
    });
    var released = false;
    void close() {
      if (released) return;
      released = true;
      client.close();
      bootstrap.close();
    }

    try {
      final request =
          http.AbortableRequest(
              options.method,
              options.uri,
              abortTrigger: abort.future,
            )
            ..followRedirects = options.followRedirects
            ..maxRedirects = options.maxRedirects;
      options.headers.forEach((key, value) {
        if (value != null) request.headers[key] = '$value';
      });
      final response = await client.send(request);
      Stream<Uint8List> body() async* {
        try {
          await for (final bytes in response.stream) {
            yield Uint8List.fromList(bytes);
          }
        } finally {
          close();
        }
      }

      return ResponseBody(
        body(),
        response.statusCode,
        headers: {
          for (final e in response.headers.entries)
            if (![
              'content-length',
              'content-encoding',
            ].contains(e.key.toLowerCase()))
              e.key: [e.value],
        },
        onClose: close,
      );
    } catch (error, stack) {
      close();
      if (options.cancelToken?.isCancelled == true || abort.isCompleted) {
        throw DioException.requestCancelled(
          requestOptions: options,
          reason: error,
        );
      }
      throw DioException.connectionError(
        requestOptions: options,
        reason: '直连及加密 DNS 连接均未成功',
        error: error,
        stackTrace: stack,
      );
    }
  }

  @override
  void close({bool force = false}) {
    _closed = true;
    _primary?.close(force: force);
    _direct?.close(force: force);
  }
}
