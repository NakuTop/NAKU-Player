import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart' show KeyParameter, ParametersWithIV;
import 'cinema_hls_probe_sample.dart';
import 'cinema_video_metadata.dart';
import 'cinema_playback_buffer.dart';
import 'cinema_media_routing.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/network_config.dart';

/// Bounded, proxy-aware requests shared by probes and the persistent HLS cache.
class CinemaMediaTransport {
  factory CinemaMediaTransport.direct() {
    const config = NetworkConfig(followSystemProxy: false, enableLog: false);
    return CinemaMediaTransport(
      dio: Dio(
        BaseOptions(
          connectTimeout: config.connectTimeout,
          receiveTimeout: config.receiveTimeout,
        ),
      )..httpClientAdapter = config.createAdapter(),
    );
  }
  CinemaMediaTransport({Dio? dio, CinemaMediaRouter? router})
    : dio = dio ?? _create(),
      router = router ?? (dio == null ? CinemaMediaRouter.instance : null);
  final CinemaMediaRouter? router;
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
    bool metadata = false,
  }) => router?.active == true
      ? router!.open(
          uri,
          headers,
          cancel: cancel,
          range: range,
          metadata: metadata,
        )
      : dio.get<ResponseBody>(
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
    bool metadata = false,
    Duration timeout = const Duration(seconds: 20),
  }) async => (await read(
    uri,
    headers,
    cancel: cancel,
    limit: limit,
    partial: partial,
    range: range,
    metadata: metadata,
    timeout: timeout,
  )).bytes;

  Future<({Uint8List bytes, Uri uri})> read(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
    int limit = 2 * 1024 * 1024,
    bool partial = false,
    String? range,
    bool metadata = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final owned = CancelToken();
    if (cancel?.isCancelled == true) owned.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => owned.cancel()));
    }
    final deadline = Timer(timeout, () => owned.cancel('请求超时'));
    try {
      final response = await stream(
        uri,
        headers,
        cancel: owned,
        range: range,
        metadata: metadata,
      );
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
      .decode(await bytes(uri, headers, cancel: cancel, metadata: true))
      .replaceFirst('\uFEFF', '');

  Future<({String text, Uri uri})> document(
    Uri uri,
    Map<String, String> headers, {
    CancelToken? cancel,
  }) async {
    final result = await read(uri, headers, cancel: cancel, metadata: true);
    return (
      text: utf8.decode(result.bytes).replaceFirst('\uFEFF', ''),
      uri: result.uri,
    );
  }
}

enum CinemaQualityEvidence { unknown, manifest, videoHeader }

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
    this.codec = '',
    this.hlsVariants = const [],
    this.qualityEvidence = CinemaQualityEvidence.unknown,
  });
  final String codec;
  final List<Uri> hlsVariants;
  final CinemaQualityEvidence qualityEvidence;
  final bool ok;
  final int elapsedMs;
  final int? firstByteMs, width, height, bitrate;
  final double? mbps;
  final String reason;
  int get confirmedQualityTier {
    final w = width ?? 0, h = height ?? 0;
    if (!ok ||
        qualityEvidence != CinemaQualityEvidence.videoHeader ||
        w <= 0 ||
        h <= 0)
      return 0;
    if (w >= 7680 || h >= 4320) return 4320;
    if (w >= 3840 || h >= 2160) return 2160;
    if (w >= 1800 || h >= 1000) return 1080;
    if (w >= 1200 || h >= 700) return 720;
    return h;
  }

  String get qualityLabel => confirmedQualityTier == 0
      ? '待检测'
      : '$width×$height${codec.isEmpty ? '' : ' · $codec'} · 视频头确认';
  String get label => labelForRate(1);
  String labelForRate(double rate) => ok
      ? '${mbps?.toStringAsFixed(1) ?? '?'}Mbps · 响应 ${firstByteMs ?? elapsedMs}ms'
            ' · $qualityLabel'
            '${bitrate == null || mbps == null
                ? ''
                : mbps! * 1000000 > bitrate! * 1.3 * CinemaPlaybackBufferPolicy(rate).rate
                ? ' · 码率余量充足'
                : ' · 码率余量偏低'}'
      : reason;
}

/// Reads actual media bytes, not the catalogue API. Samples are capped at 2 MiB
/// and a wall-clock deadline. Throughput includes time to first byte.
class CinemaMediaProbeCache {
  final entries = <String, ({DateTime at, CinemaMediaProbeResult result})>{};
  void clear() => entries.clear();
}

class CinemaMediaProbe {
  CinemaMediaProbe({
    CinemaMediaTransport? transport,
    this.quick = false,
    CinemaMediaProbeCache? cache,
  }) : transport = transport ?? CinemaMediaTransport(),
       _results = cache ?? CinemaMediaProbeCache();
  factory CinemaMediaProbe.detail({CinemaMediaTransport? transport}) =>
      CinemaMediaProbe(
        transport: transport,
        quick: true,
        cache: _detailResults,
      );
  static final _detailResults = CinemaMediaProbeCache();
  final CinemaMediaTransport transport;
  final bool quick;
  final CinemaMediaProbeCache _results;
  Map<String, ({DateTime at, CinemaMediaProbeResult result})> get _cache =>
      _results.entries;
  String _key(String url, Map<String, String> headers, bool hls) {
    final names = headers.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode([
              url,
              transport.router?.networkRevision.toString(),
              hls,
              quick,
              {for (final name in names) name: headers[name]},
            ]),
          ),
        )
        .toString();
  }

  void invalidate() => _cache.clear();
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) async {
    final key = _key(url, headers, hls);
    final cached = _cache.remove(key);
    if (cached != null &&
        cancel?.isCancelled != true &&
        DateTime.now().difference(cached.at) <
            (cached.result.ok
                ? const Duration(minutes: 1)
                : const Duration(seconds: 30))) {
      _cache[key] = cached;
      return cached.result;
    }
    final result = await _measure(
      url,
      headers,
      cancel: cancel,
      timeout: timeout,
      hls: hls,
    );
    if (cancel?.isCancelled != true) {
      _cache[key] = (at: DateTime.now(), result: result);
      while (_cache.length > 128) {
        _cache.remove(_cache.keys.first);
      }
    }
    return result;
  }

  Future<CinemaMediaProbeResult> _measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    required Duration timeout,
    required bool hls,
  }) async {
    final token = CancelToken(), timer = Stopwatch()..start();
    if (cancel?.isCancelled == true) token.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => token.cancel()));
    }
    final deadline = Timer(timeout, () => token.cancel('测速超时'));
    int? width, height, bitrate;
    var evidence = CinemaQualityEvidence.unknown;
    CinemaHlsProbeResource? sampleResource, initialization;
    var codec = '';
    final selectedVariants = <Uri>[];
    try {
      var target = Uri.parse(url);
      if (!['http', 'https'].contains(target.scheme)) {
        throw const FormatException('仅支持网络视频');
      }
      if (hls || target.path.toLowerCase().endsWith('.m3u8')) {
        for (var depth = 0; depth < 4; depth++) {
          final document = await transport.read(
            target,
            headers,
            cancel: token,
            limit: 65536,
            partial: true,
            metadata: true,
          );
          target = document.uri;
          final manifest = utf8
              .decode(document.bytes)
              .replaceFirst('\uFEFF', '');
          if (!manifest.trimLeft().startsWith('#EXTM3U')) {
            throw const FormatException('媒体清单无效');
          }
          final variants = cinemaHlsVariants(manifest, target);
          if (variants.isNotEmpty) {
            final variant = variants.reduce((a, b) {
              final pixelsA = (a.width ?? 0) * (a.height ?? 0);
              final pixelsB = (b.width ?? 0) * (b.height ?? 0);
              return pixelsA != pixelsB
                  ? (pixelsA > pixelsB ? a : b)
                  : a.bitrate >= b.bitrate
                  ? a
                  : b;
            });
            target = variant.uri;
            selectedVariants.add(target);
            width = variant.width;
            height = variant.height;
            bitrate = variant.bitrate;
            codec = variant.codec;
            if (width != null && height != null) {
              evidence = CinemaQualityEvidence.manifest;
            }
          } else {
            final sample = cinemaHlsProbeSample(manifest, target);
            sampleResource = sample.media;
            initialization = sample.initialization;
            target = sample.media.uri;
            break;
          }
        }
      }
      CinemaVideoMetadata? metadata;
      final keys = <Uri, Uint8List?>{};
      Future<CinemaVideoMetadata?> inspect(
        Uint8List bytes,
        CinemaHlsProbeEncryption? encryption,
      ) async {
        Uint8List? key;
        if (encryption != null) {
          if (encryption.key == null || encryption.iv == null) return null;
          if (!keys.containsKey(encryption.key)) {
            try {
              final value = await transport.bytes(
                encryption.key!,
                headers,
                cancel: token,
                limit: 16,
                metadata: true,
              );
              keys[encryption.key!] = value.length == 16 ? value : null;
            } catch (_) {
              if (token.isCancelled) rethrow;
              keys[encryption.key!] = null;
            }
          }
          key = keys[encryption.key];
          if (key == null) return null;
        }
        // Parse/decrypt only the bounded sample, off the UI isolate. No player,
        // audio decoder or persistent copy of the key is created.
        final iv = encryption?.iv;
        return _inspectVideoHeader(bytes, key: key, iv: iv);
      }

      var initializationBytes = 0;
      if (initialization != null) {
        final bytes = await transport.bytes(
          initialization.uri,
          headers,
          cancel: token,
          range: initialization.range(65536),
          limit: initialization.sampleLength(65536),
          partial: initialization.start == 0,
        );
        initializationBytes = bytes.length;
        metadata = await inspect(bytes, initialization.encryption);
        if (metadata != null) {
          width = metadata.width;
          height = metadata.height;
          codec = metadata.codec;
          evidence = CinemaQualityEvidence.videoHeader;
        }
      }
      final sampleLimit =
          sampleResource?.sampleLength(
            quick ? 262144 : 1572864 - initializationBytes,
          ) ??
          (quick ? 262144 : 1572864 - initializationBytes);
      final sampleWatch = Stopwatch()..start();
      final response = await transport.stream(
        target,
        headers,
        cancel: token,
        range:
            sampleResource?.range(sampleLimit) ?? 'bytes=0-${sampleLimit - 1}',
      );
      if (sampleResource != null &&
          sampleResource.start > 0 &&
          (response.statusCode != 206 ||
              response.headers
                      .value('content-range')
                      ?.startsWith('bytes ${sampleResource.start}-') !=
                  true)) {
        await response.data!.stream.listen((_) {}).cancel();
        throw const FormatException('片源不支持分段范围请求');
      }
      final type = response.headers.value('content-type')?.toLowerCase() ?? '';
      if (type.contains('text/html') || type.contains('application/json')) {
        await response.data!.stream.listen((_) {}).cancel();
        throw const FormatException('片源返回网页而非视频');
      }
      int count = 0;
      final sample = BytesBuilder(copy: false);
      int? firstByte;
      await for (final chunk in response.data!.stream) {
        firstByte ??= sampleWatch.elapsedMilliseconds;
        final length = chunk.length.clamp(0, sampleLimit - count);
        sample.add(Uint8List.sublistView(chunk, 0, length));
        count += length;
        if (count >= sampleLimit) break;
      }
      sampleWatch.stop();
      if (count < 1024) throw const FormatException('视频数据不足');
      metadata ??= await inspect(
        sample.takeBytes(),
        sampleResource?.encryption,
      );
      // A fast-start MP4 needs no extra request. A moov-at-end MP4 may use
      // one bounded suffix range; never download the full film to inspect it.
      final contentRange = response.headers.value('content-range') ?? '';
      final total = int.tryParse(contentRange.split('/').last) ?? 0;
      if (sampleResource == null &&
          metadata == null &&
          total > sampleLimit &&
          response.statusCode == 206) {
        try {
          final remaining =
              (quick ? 524288 : 2097152) - initializationBytes - count;
          final start = (total - remaining).clamp(sampleLimit, total - 1);
          final tail = await transport.stream(
            target,
            headers,
            cancel: token,
            range: 'bytes=$start-${total - 1}',
          );
          if (tail.statusCode == 206 &&
              tail.headers
                      .value('content-range')
                      ?.startsWith('bytes $start-') ==
                  true) {
            final suffix = BytesBuilder(copy: false);
            await for (final chunk in tail.data!.stream) {
              final allowed = chunk.length.clamp(0, remaining - suffix.length);
              suffix.add(Uint8List.sublistView(chunk, 0, allowed));
              if (suffix.length >= remaining) break;
            }
            final tailBytes = suffix.takeBytes();
            metadata = await _inspectVideoHeader(tailBytes, mp4Tail: true);
          } else {
            await tail.data!.stream.listen((_) {}).cancel();
          }
        } catch (_) {
          if (token.isCancelled) rethrow;
        }
      }
      if (metadata != null) {
        width = metadata.width;
        height = metadata.height;
        codec = metadata.codec;
        evidence = CinemaQualityEvidence.videoHeader;
      }
      if (token.isCancelled) throw const FormatException('检测已取消');
      return CinemaMediaProbeResult(
        ok: true,
        elapsedMs: timer.elapsedMilliseconds,
        firstByteMs: firstByte,
        mbps: count * 8 / sampleWatch.elapsedMicroseconds.clamp(1, 100000000),
        width: width,
        height: height,
        bitrate: bitrate,
        codec: codec,
        qualityEvidence: evidence,
        hlsVariants: List.unmodifiable(selectedVariants),
      );
    } catch (error) {
      return CinemaMediaProbeResult(
        ok: false,
        elapsedMs: timer.elapsedMilliseconds,
        reason: token.isCancelled
            ? '测速超时或已取消'
            : error is FormatException
            ? error.message
            : error is DioException &&
                  [401, 403].contains(error.response?.statusCode)
            ? '片源拒绝访问，请检查鉴权或请求头'
            : '视频连接失败',
        width: width,
        height: height,
        bitrate: bitrate,
        codec: codec,
        qualityEvidence: evidence,
      );
    } finally {
      deadline.cancel();
      token.cancel();
    }
  }
}

Future<CinemaVideoMetadata?> _inspectVideoHeader(
  Uint8List bytes, {
  Uint8List? key,
  Uint8List? iv,
  bool mp4Tail = false,
}) => Isolate.run(() {
  var plain = bytes;
  if (key != null) {
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv!));
    plain = Uint8List(bytes.length - bytes.length % 16);
    for (var at = 0; at < plain.length; at += 16) {
      cipher.processBlock(bytes, at, plain, at);
    }
  }
  return cinemaVideoMetadata(plain, mp4Tail: mp4Tail);
});

class CinemaHlsVariant {
  const CinemaHlsVariant(
    this.uri,
    this.bitrate,
    this.width,
    this.height, [
    this.codec = '',
    this.codecs = '',
    this.videoRange = '',
  ]);
  final Uri uri;
  final int bitrate;
  final int? width, height;
  final String codec, codecs, videoRange;
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
        _cinemaHlsVideoCodec(lines[i]),
        RegExp(r'CODECS="([^"]+)"').firstMatch(lines[i])?[1] ?? '',
        RegExp(r'VIDEO-RANGE=([^,]+)').firstMatch(lines[i])?[1] ?? '',
      ),
    );
  }
  return result;
}

String _cinemaHlsVideoCodec(String line) {
  final value =
      RegExp(r'CODECS="([^"]+)"').firstMatch(line)?[1]?.toLowerCase() ?? '';
  if (value.contains('avc1') ||
      value.contains('avc3') ||
      value.contains('dvav') ||
      value.contains('dva1')) {
    return 'AVC';
  }
  if (value.contains('hvc1') ||
      value.contains('hev1') ||
      value.contains('dvhe') ||
      value.contains('dvh1')) {
    return 'HEVC';
  }
  if (value.contains('av01') || value.contains('dav1')) return 'AV1';
  if (value.contains('vp09')) return 'VP9';
  return '';
}
