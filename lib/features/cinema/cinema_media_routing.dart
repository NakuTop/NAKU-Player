import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

class CinemaMediaRoute {
  const CinemaMediaRoute(this.proxy);
  final Uri? proxy;
  String get label => proxy == null ? '直连' : '代理';
}

class _Choice {
  _Choice(this.route, this.at, this.bytesPerSecond);
  final CinemaMediaRoute route;
  final DateTime at;
  final double bytesPerSecond;
  int slow = 0;
}

/// Race bounded, real media reads on the current direct/proxy paths. Decisions
/// are per CDN origin and proxy configuration, with a finite lifetime. Never
/// probes private NAS addresses or forwards their playback credentials.
class CinemaMediaRouter {
  CinemaMediaRouter({
    this.configuration,
    this.enabled,
    this.clientFactory,
    this.networkIdentity,
    this.probeTimeout = const Duration(seconds: 6),
  });
  static final instance = CinemaMediaRouter();
  final NetworkConfig Function()? configuration;
  final bool Function()? enabled;
  final Dio Function(CinemaMediaRoute)? clientFactory;
  final Duration probeTimeout;
  final Object Function()? networkIdentity;
  Object? _observedNetwork;
  Object get networkRevision =>
      networkIdentity?.call() ?? MacOSSystemProxy.revision;

  void _refreshNetwork() {
    final current = networkRevision;
    if (_observedNetwork == current) return;
    _observedNetwork = current;
    _choices.clear();
    _pending.clear();
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
  }

  final _clients = <String, Dio>{};
  final _choices = <String, _Choice>{};
  final _pending = <String, Future<CinemaMediaRoute>>{};

  bool get active {
    if (enabled != null) return enabled!();
    if (!Platform.isMacOS) return false;
    try {
      return GStorage.getSetting(SettingsKeys.mediaAutoRouting);
    } catch (_) {
      return true;
    }
  }

  NetworkConfig get _config {
    if (configuration != null) return configuration!();
    try {
      return NetworkConfig.fromSettings();
    } catch (_) {
      return const NetworkConfig();
    }
  }

  String _key(Uri uri, Uri? proxy, {bool metadata = false}) =>
      '${uri.origin}|${proxy ?? 'direct'}|${metadata ? 'metadata' : 'media'}|$networkRevision';
  Dio _client(CinemaMediaRoute route) =>
      _clients.putIfAbsent('${route.proxy ?? 'direct'}', () {
        if (_clients.length >= 4) {
          final first = _clients.keys.first;
          _clients.remove(first)?.close();
        }
        if (clientFactory != null) return clientFactory!(route);
        final proxy = route.proxy;
        final config = NetworkConfig(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 15),
          proxyHost: proxy?.host,
          proxyPort: proxy?.port,
          followSystemProxy: false,
          allowBadCertificates: false,
          enableLog: false,
        );
        return Dio(
          BaseOptions(
            connectTimeout: config.connectTimeout,
            receiveTimeout: config.receiveTimeout,
          ),
        )..httpClientAdapter = config.createAdapter();
      });

  Future<CinemaMediaRoute> select(
    Uri uri,
    Map<String, String> headers, {
    bool metadata = false,
  }) async {
    _refreshNetwork();
    final network = networkRevision;
    final proxy = _config.proxyForUri(uri);
    if (!active ||
        proxy == null ||
        LogvarConfiguration.isPrivateHost(uri.host)) {
      return CinemaMediaRoute(
        LogvarConfiguration.isPrivateHost(uri.host) ? null : proxy,
      );
    }
    final key = _key(uri, proxy, metadata: metadata);
    final cached = _choices[key];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(minutes: 10)) {
      return cached.route;
    }
    final result = await _pending.putIfAbsent(key, () async {
      try {
        return await _race(uri, headers, proxy, key, metadata: metadata);
      } finally {
        _pending.remove(key);
      }
    });
    if (network != networkRevision) {
      return select(uri, headers, metadata: metadata);
    }
    return result;
  }

  Future<CinemaMediaRoute> _race(
    Uri uri,
    Map<String, String> headers,
    Uri proxy,
    String key, {
    required bool metadata,
  }) async {
    final done = Completer<CinemaMediaRoute>();
    final tokens = [CancelToken(), CancelToken()];
    var remaining = 2;
    final timeout = Timer(probeTimeout, () {
      if (!done.isCompleted) done.complete(CinemaMediaRoute(proxy));
    });
    Future<void> probe(CinemaMediaRoute route, CancelToken token) async {
      final watch = Stopwatch()..start();
      var bytes = 0;
      try {
        final response = await _client(route).get<ResponseBody>(
          uri.toString(),
          options: Options(
            responseType: ResponseType.stream,
            headers: {...headers, 'Range': 'bytes=0-262143'},
            followRedirects: true,
            maxRedirects: 5,
          ),
          cancelToken: token,
        );
        await for (final part in response.data!.stream) {
          if (bytes == 0) {
            final prefix = String.fromCharCodes(
              part.take(80),
            ).trimLeft().toLowerCase();
            if (prefix.startsWith('<!doctype html') ||
                prefix.startsWith('<html') ||
                prefix.startsWith('{"error')) {
              throw const FormatException('not media');
            }
          }
          bytes += part.length;
          if (bytes >= 262144) break;
        }
        if (bytes == 0 || token.isCancelled) return;
        if (!done.isCompleted) {
          while (_choices.length >= 128) {
            _choices.remove(_choices.keys.first);
          }
          // A tiny HLS initialization/ad segment measures latency only. Let
          // the first full media segment establish the shared CDN decision.
          if ((metadata || bytes >= 32768) &&
              key == _key(uri, proxy, metadata: metadata)) {
            _choices[key] = _Choice(
              route,
              DateTime.now(),
              bytes /
                  (watch.elapsedMicroseconds / 1000000).clamp(
                    .001,
                    double.infinity,
                  ),
            );
          }
          done.complete(route);
        }
      } catch (_) {
        /* A losing path is expected, including a cancelled probe. */
      } finally {
        remaining--;
        if (remaining == 0 && !done.isCompleted) {
          done.complete(CinemaMediaRoute(proxy));
        }
      }
    }

    unawaited(probe(const CinemaMediaRoute(null), tokens[0]));
    unawaited(probe(CinemaMediaRoute(proxy), tokens[1]));
    try {
      return await done.future;
    } finally {
      timeout.cancel();
      for (final token in tokens) {
        token.cancel('route comparison complete');
      }
    }
  }

  String labelFor(Uri uri, {bool metadata = false}) {
    _refreshNetwork();
    final proxy = _config.proxyForUri(uri);
    return _choices[_key(uri, proxy, metadata: metadata)]?.route.label ??
        (proxy == null ? '直连' : '');
  }

  void reconsiderAfterStall(Uri uri) {
    final proxy = _config.proxyForUri(uri);
    final choice = _choices[_key(uri, proxy)];
    if (choice != null &&
        DateTime.now().difference(choice.at).inSeconds >= 30) {
      invalidate(uri);
    }
  }

  void invalidate(Uri uri) {
    _choices.removeWhere((key, _) => key.startsWith('${uri.origin}|'));
  }

  Future<Response<ResponseBody>> open(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    String? range,
    bool metadata = false,
  }) async {
    final selected = select(uri, headers, metadata: metadata);
    final route = cancel == null
        ? await selected
        : await Future.any<CinemaMediaRoute>([
            selected,
            cancel.whenCancel.then<CinemaMediaRoute>((e) => throw e),
          ]);
    final proxy = _config.proxyForUri(uri);
    var chosen = route;
    final requestWatch = Stopwatch()..start();
    Response<ResponseBody> response;
    Future<Response<ResponseBody>> get(CinemaMediaRoute r) =>
        _client(r).get<ResponseBody>(
          uri.toString(),
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            headers: {...headers, 'Range': ?range},
          ),
        );
    try {
      response = await get(route);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e) ||
          proxy == null ||
          LogvarConfiguration.isPrivateHost(uri.host)) {
        rethrow;
      }
      invalidate(uri);
      chosen = CinemaMediaRoute(route.proxy == null ? proxy : null);
      requestWatch.reset();
      response = await get(chosen);
      _choices[_key(uri, proxy, metadata: metadata)] = _Choice(
        chosen,
        DateTime.now(),
        0,
      );
    }
    response.extra['cinemaRoute'] = chosen.label;
    final original = response.data!;
    final source = original.stream;
    Stream<Uint8List> observe() async* {
      final watch = requestWatch;
      var bytes = 0;
      try {
        await for (final part in source) {
          bytes += part.length;
          yield part;
        }
        final choice = _choices[_key(uri, proxy, metadata: metadata)];
        if (choice != null &&
            watch.elapsed.inSeconds >= 2 &&
            bytes > 32768 &&
            DateTime.now().difference(choice.at).inSeconds >= 30) {
          final speed = bytes / (watch.elapsedMicroseconds / 1000000);
          if (choice.bytesPerSecond > 0 && speed < choice.bytesPerSecond * .6) {
            choice.slow++;
          } else {
            choice.slow = 0;
          }
          if (choice.slow >= 2) invalidate(uri);
        }
      } catch (_) {
        invalidate(uri);
        rethrow;
      }
    }

    original.stream = observe();
    return response;
  }

  void close() {
    for (final c in _clients.values) {
      c.close(force: true);
    }
    _clients.clear();
    _choices.clear();
  }
}
