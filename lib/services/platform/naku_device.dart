import 'dart:io';
import 'package:flutter/services.dart';

/// Hardware classification, never inferred from the screen width.
class NakuDevice {
  static bool isTV = false;
  static bool get canDownload => !isTV;
  static bool get hasNAS => Platform.isMacOS || Platform.isAndroid;
  static Future<void> initialize() async {
    if (!Platform.isAndroid) return;
    final info = await const MethodChannel(
      'naku/device',
    ).invokeMapMethod<String, dynamic>('info');
    isTV = const bool.fromEnvironment('NAKU_TV') || info?['television'] == true;
    if (isTV) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }
}
