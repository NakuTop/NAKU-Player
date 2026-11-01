import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The system's explicit Low Power Mode, not an inferred battery percentage.
/// Losing focus is not a reason to interrupt video or reduce its byte budget.
class MacOSPlaybackPower extends ChangeNotifier {
  MacOSPlaybackPower({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel('naku/playback-power'),
      supported = supported ?? Platform.isMacOS;
  static final instance = MacOSPlaybackPower();
  final MethodChannel _channel;
  final bool supported;
  bool lowPowerMode = false, _disposed = false;
  int _revision = 0;
  Future<void>? _initializing;

  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    if (!supported || _disposed) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') {
        _revision++;
        _apply(call.arguments);
      }
    });
    final revision = _revision;
    try {
      final state = await _channel.invokeMethod<Object?>('state');
      if (revision == _revision) _apply(state);
    } on MissingPluginException {
      // Older hosts retain the ordinary 30-second pause grace.
    } on PlatformException {
      // Optional power information must never block playback.
    }
  }

  void _apply(Object? value) {
    if (_disposed || value is! Map || value['lowPowerMode'] is! bool) return;
    final next = value['lowPowerMode'] as bool;
    if (next == lowPowerMode) return;
    lowPowerMode = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    if (supported) _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
