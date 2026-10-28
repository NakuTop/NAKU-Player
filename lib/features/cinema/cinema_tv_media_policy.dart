import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_media_transport.dart';
import 'cinema_route_probe.dart';

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
    if (_readAt != null && at.difference(_readAt!) < const Duration(seconds: 3)) {
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
