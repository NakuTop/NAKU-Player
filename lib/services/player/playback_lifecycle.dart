import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';

/// AppKit can report a hidden Flutter view during a native fullscreen animation.
/// Minimizing follows background playback; hiding uses the separate opt-in
/// pause-on-hide policy. Merely losing focus never pauses desktop playback.
Future<bool> isPlaybackWindowBackgrounded({
  bool? isMacOS,
  Future<bool> Function()? isMinimized,
  Future<bool> Function()? isVisible,
  bool? appHidden,
  bool? pauseWhenHidden,
}) async {
  if (!(isMacOS ?? defaultTargetPlatform == TargetPlatform.macOS)) return true;
  try {
    if (await (isMinimized ?? windowManager.isMinimized)()) return true;
    final hidden =
        (appHidden ?? DesktopWindowControls.instance.hidden) ||
        !await (isVisible ?? windowManager.isVisible)();
    return hidden &&
        (pauseWhenHidden ??
            DesktopWindowControls.instance.preferences.pauseOnHide);
  } catch (_) {
    // An unavailable window bridge is not evidence that playback was hidden.
    return false;
  }
}
