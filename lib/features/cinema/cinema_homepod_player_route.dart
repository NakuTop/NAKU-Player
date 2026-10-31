import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';
import 'package:media_kit/media_kit.dart';

/// Keeps one movie player on the confirmed HomePod output route. Creating a
/// binding while the feature is off never changes the player's audio device.
class CinemaHomePodPlayerRoute {
  CinemaHomePodPlayerRoute(
    this.player, {
    HomePodAudioControls? controls,
    TargetPlatform? platform,
    void Function(String message)? onDiagnostic,
  }) : _controls = controls ?? HomePodAudioControls.instance,
       _supported = (platform ?? defaultTargetPlatform) == TargetPlatform.macOS,
       _diagnostic = onDiagnostic ?? _writeDiagnostic {
    if (_supported) {
      _controls.addListener(_observeRoute);
      _observeRoute();
    }
  }

  static const device = AudioDevice(
    'coreaudio/com.shenminghao.naku.virtualaudio.v1',
    'NAKU Audio',
  );

  final Player player;
  final HomePodAudioControls _controls;
  final bool _supported;
  final void Function(String message) _diagnostic;
  Future<void> _pending = Future<void>.value();
  AudioDevice? _previous;
  bool _desiredActive = false, _disposed = false;
  int _generation = 0;

  static void _writeDiagnostic(String message) {
    KazumiLogger().i('Cinema HomePod audio: $message', forceLog: true);
  }

  void _observeRoute() {
    if (_disposed || !_supported) return;
    final active = _controls.audioRouteActive;
    if (active == _desiredActive) return;
    _desiredActive = active;
    final generation = ++_generation;
    final previous = _pending;
    _pending = () async {
      await previous;
      if (!_current(generation)) return;
      await _apply(active, generation);
    }();
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _apply(bool active, int generation) async {
    if (!active && _previous == null) return;
    // Capture before the first setter: a later OFF must restore even if ON
    // completed after its request became stale, or reported a partial failure.
    if (active) _previous ??= player.state.audioDevice;
    final target = active ? device : _previous!;
    try {
      await player.setAudioDevice(target);
    } catch (error) {
      if (_current(generation)) {
        _diagnostic('route-error(active=$active,type=${error.runtimeType})');
      }
      return;
    }
    if (!_current(generation)) return;
    if (!active) _previous = null;
    _diagnostic('route-applied(active=$active,device=${_safe(target.name)})');
    unawaited(_snapshot('route-applied', generation));
  }

  /// Join the latest confirmed route before opening a new media item. A toggle
  /// arriving during an in-flight setter is included before this completes.
  Future<void> prepareForOpen() async {
    _observeRoute();
    while (!_disposed) {
      final pending = _pending;
      await pending;
      if (identical(pending, _pending)) return;
    }
  }

  /// Read only allowlisted audio facts; media URLs and headers are never read.
  void logPlaybackState() {
    if (_supported && !_disposed && _desiredActive) {
      unawaited(_snapshot('opened', _generation));
    }
  }

  Future<void> _snapshot(String stage, int generation) async {
    final native = player.platform;
    if (native is! NativePlayer || !_current(generation)) return;
    final facts = <String, String>{};
    for (final key in const [
      'current-ao',
      'audio-device',
      'aid',
      'mute',
      'volume',
      'audio-params/samplerate',
      'audio-params/channels',
      'audio-out-params/samplerate',
      'audio-out-params/channels',
    ]) {
      if (!_current(generation)) return;
      try {
        facts[key] = _safe(
          await native.getProperty(key, waitForInitialization: false),
        );
      } catch (_) {
        facts[key] = 'unavailable';
      }
    }
    if (_current(generation)) {
      _diagnostic('snapshot(stage=$stage,facts=$facts)');
    }
  }

  static String _safe(String value) {
    if (value.contains('://')) return 'redacted';
    final singleLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return singleLine.length > 160 ? singleLine.substring(0, 160) : singleLine;
  }

  /// Detach synchronously, then join any setter already underway before the
  /// owner disposes the underlying player. No restoration is needed on a player
  /// whose audio output is being destroyed.
  Future<void> dispose() {
    if (!_disposed) {
      _disposed = true;
      _generation++;
      if (_supported) _controls.removeListener(_observeRoute);
    }
    return _pending;
  }
}
