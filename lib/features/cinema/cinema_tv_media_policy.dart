import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_media_transport.dart';
import 'cinema_original_match.dart';
import 'cinema_route_probe.dart';
import 'cinema_video_metadata.dart';

/// TV reads the network's existing proxy; it never creates a proxy service.
class CinemaTVMediaEnvironment {
  CinemaTVMediaEnvironment({this.reader, this.supported, this.now});
  static final instance = CinemaTVMediaEnvironment();
  final Future<Map<String, dynamic>> Function()? reader;
  final bool Function()? supported;
  final DateTime Function()? now;
  Map<String, dynamic> _snapshot = const {};
  DateTime? _readAt;
  Future<void>? _reading;
  bool get available =>
      supported?.call() ?? (Platform.isAndroid && NakuDevice.isTV);
  Object get revision =>
      _snapshot['key']?.toString() ?? 'android-network-unknown';
  Future<void> refresh() async {
    if (!available) return;
    final at = now?.call() ?? DateTime.now();
    if (_readAt != null &&
        at.difference(_readAt!) < const Duration(seconds: 3)) {
      return;
    }
    if (_reading != null) return _reading;
    final task = () async {
      try {
        final result = reader != null
            ? await reader!()
            : await const MethodChannel(
                    'naku/device',
                  ).invokeMapMethod<String, dynamic>('mediaNetwork') ??
                  {};
        _snapshot = Map.of(result);
        _readAt = at;
      } on MissingPluginException {
        _readAt = at;
      } on PlatformException {
        // A transient read failure retains the last verified network snapshot.
      }
    }();
    _reading = task;
    try {
      await task;
    } finally {
      if (identical(_reading, task)) _reading = null;
    }
  }

  Uri? proxyFor(Uri uri, NetworkConfig configuration) {
    if (configuration.hasProxy) return configuration.proxyForUri(uri);
    if (!available || !configuration.followSystemProxy) {
      return configuration.proxyForUri(uri);
    }
    if (LogvarConfiguration.isPrivateHost(uri.host) || _excluded(uri.host)) {
      return null;
    }
    final host = '${_snapshot['proxyHost'] ?? ''}'.trim();
    final port = int.tryParse('${_snapshot['proxyPort']}');
    if (host.isNotEmpty &&
        !RegExp(r'[\s/@]').hasMatch(host) &&
        port != null &&
        port > 0 &&
        port <= 65535) {
      return Uri(scheme: 'http', host: host, port: port);
    }
    if (_snapshot['hasPac'] == true) {
      throw const FormatException('当前网络的 PAC 代理尚未提供可用连接，无法自动选择视频路径。');
    }
    return null;
  }

  bool _excluded(String host) {
    final rules = _snapshot['proxyExclusionList'];
    if (rules is! List) return false;
    return rules.any((rule) {
      final pattern = '$rule'.trim().toLowerCase();
      if (pattern.isEmpty) return false;
      if (pattern == '<local>') return !host.contains('.');
      return RegExp(
        '^${RegExp.escape(pattern).replaceAll(r'\*', '.*')}\$',
      ).hasMatch(host.toLowerCase());
    });
  }

  ({int width, int height})? sizeFor(String codec) {
    final normalized = codec
        .toUpperCase()
        .replaceAll('H.264', 'AVC')
        .replaceAll('H.265', 'HEVC');
    final rows = _snapshot['decoderCapabilities'];
    if (rows is! List) return null;
    for (final row in rows.whereType<Map>()) {
      if ('${row['codec']}'.toUpperCase() != normalized) continue;
      final w = int.tryParse('${row['maxWidth']}'),
          h = int.tryParse('${row['maxHeight']}');
      if (w != null && h != null && w > 0 && h > 0) {
        return (width: w, height: h);
      }
    }
    return null;
  }

  bool supports(CinemaMediaProbeResult result) {
    if (!available ||
        result.codec.isEmpty ||
        result.width == null ||
        result.height == null) {
      return true;
    }
    final size = sizeFor(result.codec);
    // An old bridge has no capability snapshot; do not invent codec support.
    if (_snapshot['decoderCapabilities'] is! List) return true;
    return size != null &&
        result.width! <= size.width &&
        result.height! <= size.height;
  }

  bool supportsOriginalVideo(CinemaVideoMetadata video) {
    final codecs = _snapshot['decoderCapabilities'];
    if (!available ||
        codecs is! List ||
        codecs.isEmpty ||
        !const {
          'AVC',
          'H.264',
          'HEVC',
          'H.265',
          'AV1',
          'VP9',
        }.contains(video.codec.toUpperCase())) {
      return true;
    }
    return supports(
      CinemaMediaProbeResult(
        ok: true,
        elapsedMs: 0,
        width: video.width,
        height: video.height,
        codec: video.codec,
      ),
    );
  }

  /// Release names describe the encode only provisionally. A missing hardware
  /// snapshot cannot rule out a release, and hybrid DV/HDR10 remains playable.
  int originalCompatibility(OriginalEdition edition) {
    if (!available) return 0;
    final name = edition.name.toLowerCase();
    final codecs = _snapshot['decoderCapabilities'];
    final codec = RegExp(r'\b(?:av1|av01)\b').hasMatch(name)
        ? 'AV1'
        : RegExp(r'(?:x265|h[ .]?265|hevc)').hasMatch(name)
        ? 'HEVC'
        : RegExp(r'(?:x264|h[ .]?264|avc)').hasMatch(name)
        ? 'AVC'
        : '';
    if (codecs is List && codecs.isNotEmpty && codec.isNotEmpty) {
      final size = sizeFor(codec);
      if (size == null || (size.width < 3840 && size.height < 2160)) return -1;
    }
    final display = _snapshot['displayCapabilities'];
    final dv = RegExp(r'(?:\bdv\b|dovi|dolby[ ._-]*vision)').hasMatch(name);
    if (dv &&
        display is Map &&
        display['known'] == true &&
        display['dolbyVision'] != true) {
      if (RegExp(
        r'(?:profile|prof|p)[ ._-]*0?5\b|dv[ ._-]*only|dvhe\.05',
      ).hasMatch(name)) {
        return -1;
      }
      // Unknown DV profile ranks after an explicitly compatible encode.
      if (!RegExp(
        r'hdr10|hdr[ ._-]*10|hybrid|hdr[ ._-]+dv|dv[ ._-]+hdr',
      ).hasMatch(name)) {
        return 1;
      }
    }
    return 0;
  }

  /// Manifest hints eliminate unsupported DV-only variants before a speed
  /// measurement can prefer them. The native renderer validates actual tracks.
  bool supportsVariant(CinemaHlsVariant variant) {
    if (!supports(
      CinemaMediaProbeResult(
        ok: true,
        elapsedMs: 0,
        codec: variant.codec,
        width: variant.width,
        height: variant.height,
      ),
    )) {
      return false;
    }
    final display = _snapshot['displayCapabilities'];
    if (display is! Map || display['known'] != true) return true;
    final profile = int.tryParse(
      RegExp(
            r'(?:dvhe|dvh1|dvav|dva1|dav1)\.(\d{2})\.',
            caseSensitive: false,
          ).firstMatch(variant.codecs)?[1] ??
          '',
    );
    if (profile != null &&
        display['dolbyVision'] != true &&
        !{7, 8, 9, 10}.contains(profile)) {
      return false;
    }
    if (variant.videoRange == 'PQ' &&
        display['hdr10'] != true &&
        display['dolbyVision'] != true) {
      return false;
    }
    if (variant.videoRange == 'HLG' &&
        display['hlg'] != true &&
        display['dolbyVision'] != true) {
      return false;
    }
    return true;
  }

  ({int width, int height}) get maximumSize {
    final sizes = [
      'AVC',
      'HEVC',
      'AV1',
      'VP9',
    ].map(sizeFor).whereType<({int width, int height})>().toList();
    sizes.sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));
    return sizes.firstOrNull ?? (width: 1920, height: 1080);
  }
}

/// Prefer confirmed higher resolution only after meeting real bitrate headroom.
CinemaRouteMeasurement? cinemaBestMeasuredTVRoute(
  Iterable<CinemaRouteMeasurement> measurements, {
  bool Function(CinemaMediaProbeResult)? supported,
}) {
  final usable = measurements
      .where((m) => m.usable && (supported?.call(m.result) ?? true))
      .toList();
  if (usable.isEmpty) return null;
  final sufficient = usable.where((m) => m.sufficient).toList();
  if (sufficient.isEmpty) return cinemaBestMeasuredRoute(usable);
  sufficient.sort((a, b) {
    final pixelsA = (a.result.width ?? 0) * (a.result.height ?? 0);
    final pixelsB = (b.result.width ?? 0) * (b.result.height ?? 0);
    if (pixelsA != pixelsB) return pixelsB.compareTo(pixelsA);
    return b.result.mbps!.compareTo(a.result.mbps!);
  });
  return sufficient.first;
}

/// Keep HLS rendition groups and headers while choosing only a video variant.
/// Opening the variant URL itself would silently lose external audio/subtitles.
String cinemaTVSelectHlsVariant(String manifest, Uri base, Uri selected) {
  final lines = manifest.split('\n');
  final remove = <int>{};
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].trim().startsWith('#EXT-X-STREAM-INF:')) continue;
    var next = i + 1;
    while (next < lines.length && lines[next].trim().isEmpty) {
      next++;
    }
    if (next >= lines.length || lines[next].trim().startsWith('#')) continue;
    if (base.resolve(lines[next].trim()) != selected) {
      remove.add(i);
      remove.add(next);
    }
  }
  return [
    for (var i = 0; i < lines.length; i++)
      if (!remove.contains(i)) lines[i],
  ].join('\n');
}
