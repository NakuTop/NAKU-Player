import 'package:flutter/services.dart';

/// Sparkle owns update preferences and only accepts our signed release feed.
abstract final class NakuUpdateService {
  static const repositoryUrl = 'https://github.com/NakuTop/NAKU-Player';
  static const _channel = MethodChannel('naku/updater');

  static Future<Map<String, dynamic>> state() async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('state') ?? {},
      );
  static Future<void> check() => _channel.invokeMethod<void>('check');
  static Future<void> configure({
    bool? automaticChecks,
    bool? automaticDownloads,
  }) => _channel.invokeMethod<void>('configure', {
    'automaticChecks': ?automaticChecks,
    'automaticDownloads': ?automaticDownloads,
  });
}

/// A route-scoped lease protects paused, buffering and picture-in-picture video
/// as well as actively playing video. Multiple open players cannot clear each
/// other's protection. Unsupported platforms/older bridges remain usable.
final class NakuPlaybackUpdateLease {
  NakuPlaybackUpdateLease() : _id = 'playback-${_nextId++}';
  static int _nextId = 0;
  final String _id;
  bool _closed = false;
  Future<void>? _started;

  Future<void> start() => _started ??= _send(true);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Preserve ordering even if a route is disposed before channel setup ends.
    await start();
    await _send(false);
  }

  Future<void> _send(bool active) async {
    try {
      await NakuUpdateService._channel.invokeMethod<void>('playbackSession', {
        'id': _id,
        'active': active,
      });
    } on MissingPluginException {
      // No Sparkle on non-macOS builds.
    } on PlatformException {
      // Updating protection must never prevent the media route from opening.
    }
  }
}
