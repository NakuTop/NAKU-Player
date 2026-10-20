import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

/// Shared native state for cinema, anime and PiP. Win32 completes immediately;
/// only AppKit requires an animation acknowledgement.
abstract final class DesktopFullscreen {
  static const channel = MethodChannel('com.predidit.kazumi/intent');
  static bool get _windows => defaultTargetPlatform == TargetPlatform.windows;
  static Future<bool> isFullScreen() async => _windows
      ? await channel.invokeMethod<bool>('isFullscreen') ?? false
      : windowManager.isFullScreen();
  static Future<void> setFullScreen(bool value) async {
    if (_windows) {
      await channel.invokeMethod<void>('setFullscreen', {
        'isFullScreen': value,
      });
    } else {
      await windowManager.setFullScreen(value);
    }
  }
}
