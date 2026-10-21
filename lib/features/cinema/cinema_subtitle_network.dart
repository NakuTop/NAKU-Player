import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// User-facing failure categories omit request URLs, headers and credentials.
String cinemaSubtitleFailureMessage(Object error) {
  if (error is FormatException) return error.message.toString();
  if (error is ProcessException) return 'Windows 字幕解压组件启动失败';
  if (error is DioException) {
    final code = error.response?.statusCode;
    if (code != null) return '资源服务暂不可用（HTTP $code）';
    if (error.error is HandshakeException) return '字幕源 HTTPS 握手失败';
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout) {
      return '字幕源连接超时';
    }
    if (error.type == DioExceptionType.cancel) return '字幕请求已取消';
    return '字幕源网络连接失败';
  }
  if (error is HandshakeException) return '字幕源 HTTPS 握手失败';
  return '资源无法读取或不是有效字幕';
}

/// Fail over only anonymous public subtitle reads whose automatic Windows
/// system-proxy connection fails. Explicit in-app proxy settings are handled
/// outside this adapter and must never be bypassed.
class CinemaSubtitleNetworkAdapter implements HttpClientAdapter {
  CinemaSubtitleNetworkAdapter({
    required this.primary,
    required this.systemProxy,
    HttpClientAdapter? direct,
  }) : direct =
           direct ??
           IOHttpClientAdapter(
             createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
           );

  final HttpClientAdapter primary, direct;
  final String Function(Uri) systemProxy;
  final _directRoutes = <String, String>{};
  final recoveredHosts = <String>{};
  static const _gatewayErrors = {502, 503, 504};

  static bool publicRead(RequestOptions request) =>
      request.method.toUpperCase() == 'GET' &&
      request.data == null &&
      request.uri.scheme == 'https' &&
      request.uri.userInfo.isEmpty &&
      const {
        'assrt.net',
        'www.subhd.tv',
        'v3-cinemeta.strem.io',
        'opensubtitles-v3.strem.io',
        'subs5.strem.io',
        'dl.opensubtitles.org',
      }.contains(request.uri.host) &&
      !request.headers.keys.any(
        (key) => RegExp(
          r'authorization|cookie|token|api.key|signature',
          caseSensitive: false,
        ).hasMatch(key),
      ) &&
      !request.uri.queryParameters.keys.any(
        (key) => RegExp(
          r'token|password|secret|signature|api.key',
          caseSensitive: false,
        ).hasMatch(key),
      );

  static bool _connectionFailure(Object error) =>
      error is HandshakeException ||
      error is SocketException ||
      error is DioException &&
          (const {
                DioExceptionType.connectionError,
                DioExceptionType.connectionTimeout,
                DioExceptionType.receiveTimeout,
              }.contains(error.type) ||
              error.error is HandshakeException ||
              error.error is SocketException);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final route = systemProxy(options.uri);
    final safe =
        requestStream == null &&
        publicRead(options) &&
        route.startsWith('PROXY ');
    if (safe && _directRoutes[options.uri.host] == route) {
      try {
        final response = await direct.fetch(options, null, cancelFuture);
        if (!_gatewayErrors.contains(response.statusCode)) return response;
        await response.stream.drain<void>();
      } catch (error) {
        if (!_connectionFailure(error)) rethrow;
      }
      _directRoutes.remove(options.uri.host);
    }
    try {
      final response = await primary.fetch(
        options,
        requestStream,
        cancelFuture,
      );
      if (!safe || !_gatewayErrors.contains(response.statusCode)) {
        return response;
      }
      await response.stream.drain<void>();
    } catch (error) {
      if (!safe ||
          !_connectionFailure(error) ||
          options.cancelToken?.isCancelled == true) {
        rethrow;
      }
    }
    if (options.cancelToken?.isCancelled == true) {
      throw DioException.requestCancelled(
        requestOptions: options,
        reason: '字幕请求已取消',
      );
    }
    final response = await direct.fetch(options, null, cancelFuture);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      _directRoutes[options.uri.host] = route;
      recoveredHosts.add(options.uri.host);
    }
    return response;
  }

  @override
  void close({bool force = false}) {
    primary.close(force: force);
    direct.close(force: force);
  }
}
