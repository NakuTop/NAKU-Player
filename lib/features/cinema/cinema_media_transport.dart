import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/network_config.dart';

/// Bounded, proxy-aware requests shared by probes and the persistent HLS cache.
class CinemaMediaTransport {
  CinemaMediaTransport({Dio? dio}) : dio = dio ?? _create();
  final Dio dio;
  static Dio _create() {
    final config = NetworkConfig.forMedia();
    return Dio(
      BaseOptions(
        connectTimeout: config.connectTimeout,
        receiveTimeout: const Duration(seconds: 12),
        sendTimeout: config.sendTimeout,
      ),
    )..httpClientAdapter = config.createAdapter();
  }

  Future<Response<ResponseBody>> stream(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    String? range,
  }) => dio.get<ResponseBody>(
    uri.toString(),
    cancelToken: cancel,
    options: Options(
      responseType: ResponseType.stream,
      headers: {...headers, 'Range': ?range},
      validateStatus: (code) => code != null && code >= 200 && code < 300,
    ),
  );
  Future<Uint8List> bytes(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    int limit = 2 * 1024 * 1024,
    bool partial = false,
    String? range,
    Duration timeout = const Duration(seconds: 20),
  }) async => (await read(
    uri,
    headers,
    cancel: cancel,
    limit: limit,
    partial: partial,
    range: range,
    timeout: timeout,
  )).bytes;

  Future<({Uint8List bytes, Uri uri})> read(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    int limit = 2 * 1024 * 1024,
    bool partial = false,
    String? range,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final owned = CancelToken();
    if (cancel?.isCancelled == true) owned.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => owned.cancel()));
    }
    final deadline = Timer(timeout, () => owned.cancel('请求超时'));
    try {
      final response = await stream(uri, headers, cancel: owned, range: range);
      if (range == null && !partial && response.statusCode == 206) {
        throw const FormatException('片源返回不完整的媒体片段');
      }
      if (range != null && !partial && response.statusCode != 206) {
        await response.data!.stream.listen((_) {}).cancel();
        throw const FormatException('片源不支持分段范围请求');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.data!.stream) {
        if (builder.length + chunk.length > limit) {
          if (!partial) throw const FormatException('媒体片段超过缓存限制');
          builder.add(chunk.sublist(0, limit - builder.length));
          break;
        }
        builder.add(chunk);
        if (partial && builder.length >= limit) break;
      }
      var resolved = response.requestOptions.uri;
      for (final redirect in response.redirects) {
        resolved = resolved.resolveUri(redirect.location);
      }
      return (bytes: builder.takeBytes(), uri: resolved);
    } finally {
      deadline.cancel();
      owned.cancel();
    }
  }

  Future<String> text(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) async => utf8
      .decode(await bytes(uri, headers, cancel: cancel))
      .replaceFirst('\uFEFF', '');

  Future<({String text, Uri uri})> document(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) async {
    final result = await read(uri, headers, cancel: cancel);
    return (
      text: utf8.decode(result.bytes).replaceFirst('\uFEFF', ''),
      uri: result.uri,
    );
  }
}

class CinemaMediaProbeResult {
  const CinemaMediaProbeResult({
    required this.ok,
    required this.elapsedMs,
    this.firstByteMs,
    this.mbps,
    this.width,
    this.height,
    this.bitrate,
    this.reason = '',
  });
  final bool ok;
  final int elapsedMs;
  final int? firstByteMs, width, height, bitrate;
  final double? mbps;
  final String reason;
  String get label => ok
      ? '${mbps?.toStringAsFixed(1) ?? '?'}Mbps · 响应 ${firstByteMs ?? elapsedMs}ms'
            '${width == null ? '' : ' · $width×$height'}'
            '${bitrate == null || mbps == null
                ? ''
                : mbps! * 1000000 > bitrate! * 1.3
                ? ' · 码率余量充足'
                : ' · 码率余量偏低'}'
      : reason;
}

/// Reads actual media bytes, not the catalogue API. Samples are capped at 2 MiB
/// and a wall-clock deadline. Throughput includes time to first byte.
class CinemaMediaProbe {
  CinemaMediaProbe({CinemaMediaTransport? transport})
    : transport = transport ?? CinemaMediaTransport();
  final CinemaMediaTransport transport;
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) async {
    final token = CancelToken(), timer = Stopwatch()..start();
    if (cancel?.isCancelled == true) token.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => token.cancel()));
    }
    final deadline = Timer(timeout, () => token.cancel('测速超时'));
    int? width, height, bitrate;
    try {
      var target = Uri.parse(url);
      if (!['http', 'https'].contains(target.scheme)) {
        throw const FormatException('仅支持网络视频');
      }
      if (hls || target.path.toLowerCase().endsWith('.m3u8')) {
        for (var depth = 0; depth < 4; depth++) {
          final document = await transport.document(
            target,
            headers,
            cancel: token,
          );
          target = document.uri;
          final manifest = document.text;
          if (!manifest.trimLeft().startsWith('#EXTM3U')) {
            throw const FormatException('媒体清单无效');
          }
          final variants = cinemaHlsVariants(manifest, target);
          if (variants.isNotEmpty) {
            final variant = variants.reduce(
              (a, b) => a.bitrate > b.bitrate ? a : b,
            );
            target = variant.uri;
            width = variant.width;
            height = variant.height;
            bitrate = variant.bitrate;
          } else {
            final segment = manifest
                .split('\n')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty && !s.startsWith('#'))
                .firstOrNull;
            if (segment == null) throw const FormatException('媒体清单没有片段');
            target = target.resolve(segment);
            break;
          }
        }
      }
      final sampleWatch = Stopwatch()..start();
      final response = await transport.stream(
        target,
        headers,
        cancel: token,
        range: 'bytes=0-2097151',
      );
      final type = response.headers.value('content-type')?.toLowerCase() ?? '';
      if (type.contains('text/html') || type.contains('application/json')) {
        await response.data!.stream.listen((_) {}).cancel();
        throw const FormatException('片源返回网页而非视频');
      }
      int count = 0;
      int? firstByte;
      await for (final chunk in response.data!.stream) {
        firstByte ??= sampleWatch.elapsedMilliseconds;
        count += chunk.length.clamp(0, 2097152 - count);
        if (count >= 2097152) break;
      }
      if (count < 1024) throw const FormatException('视频数据不足');
      return CinemaMediaProbeResult(
        ok: true,
        elapsedMs: timer.elapsedMilliseconds,
        firstByteMs: firstByte,
        mbps: count * 8 / sampleWatch.elapsedMicroseconds.clamp(1, 100000000),
        width: width,
        height: height,
        bitrate: bitrate,
      );
    } catch (error) {
      return CinemaMediaProbeResult(
        ok: false,
        elapsedMs: timer.elapsedMilliseconds,
        reason: token.isCancelled ? '测速超时或已取消' : '视频连接失败',
      );
    } finally {
      deadline.cancel();
      token.cancel();
    }
  }
}

class CinemaHlsVariant {
  const CinemaHlsVariant(this.uri, this.bitrate, this.width, this.height);
  final Uri uri;
  final int bitrate;
  final int? width, height;
}

List<CinemaHlsVariant> cinemaHlsVariants(String text, Uri base) {
  final lines = text.split('\n').map((s) => s.trim()).toList();
  final result = <CinemaHlsVariant>[];
  for (var i = 0; i + 1 < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
    final resolution = RegExp(r'RESOLUTION=(\d+)x(\d+)').firstMatch(lines[i]);
    final rate = RegExp(
      r'(?:^|,)BANDWIDTH=(\d+)',
    ).firstMatch(lines[i].split(':').skip(1).join(':'));
    final next = lines.skip(i + 1).where((s) => s.isNotEmpty).firstOrNull;
    if (next == null || next.startsWith('#')) continue;
    final uri = base.resolve(next);
    if (!['http', 'https'].contains(uri.scheme)) continue;
    result.add(
      CinemaHlsVariant(
        uri,
        int.tryParse(rate?[1] ?? '') ?? 0,
        int.tryParse(resolution?[1] ?? ''),
        int.tryParse(resolution?[2] ?? ''),
      ),
    );
  }
  return result;
}
