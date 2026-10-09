import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// AppKit can report a hidden Flutter view during a native fullscreen animation.
/// Only an actually hidden/minimized window should stop desktop playback.
Future<bool> isPlaybackWindowBackgrounded({
  bool? isMacOS,
  Future<bool> Function()? isMinimized,
  Future<bool> Function()? isVisible,
}) async {
  if (!(isMacOS ?? defaultTargetPlatform == TargetPlatform.macOS)) return true;
  try {
    return await (isMinimized ?? windowManager.isMinimized)() ||
        !await (isVisible ?? windowManager.isVisible)();
  } catch (_) {
    // An unavailable window bridge is not evidence that playback was hidden.
    return false;
  }
}
