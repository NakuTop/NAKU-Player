import 'dart:io';
import 'package:kazumi/request/core/network_config.dart';
import 'package:media_kit/media_kit.dart';

/// Native and Dart downloads must use the same explicit connection choice.
/// Never disable certificate checks or silently bypass a configured proxy.
Future<void> configureNativePlayback(
  NativePlayer player,
  Uri media, {
  required bool Function() isCurrent,
  bool diskCache = true,
}) async {
  final config = NetworkConfig.forMedia();
  final properties = <String, String>{
    'http-proxy': const ['localhost', '127.0.0.1', '::1'].contains(media.host)
        ? ''
        : config.proxyForUri(media)?.toString() ?? '',
    'network-timeout': '10',
    'tls-verify': 'yes',
    if (Platform.isMacOS) 'tls-ca-file': '/etc/ssl/cert.pem',
    // The movie player has no disk-cache directory. RAM cache remains bounded
    // by PlayerConfiguration.bufferSize; don't repeatedly try an invalid file.
    if (!diskCache) 'cache-on-disk': 'no',
    'vd-lavc-software-fallback': '3',
  };
  for (final entry in properties.entries) {
    if (!isCurrent()) return;
    await player.setProperty(entry.key, entry.value);
  }
}

enum PlaybackFailureKind { network, format }

PlaybackFailureKind? playbackFailureKind(String message) {
  if (RegExp(
    r'handshake|connection (?:reset|refused|timed out)|'
    r'failed to open (?:segment|key)|unable to open resource|'
    r'HTTP error (?:4\d\d|5\d\d)|server returned (?:4\d\d|5\d\d)',
    caseSensitive: false,
  ).hasMatch(message)) {
    return PlaybackFailureKind.network;
  }
  if (RegExp(
    r'Failed to recognize file format|Failed to open|Nothing to play|'
    r'No video or audio streams selected',
    caseSensitive: false,
  ).hasMatch(message)) {
    return PlaybackFailureKind.format;
  }
  // A hardware decoder's fallback warning is not a terminal media failure.
  return null;
}
