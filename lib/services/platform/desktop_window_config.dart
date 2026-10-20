import 'dart:io';
import 'package:kazumi/services/storage/storage.dart';

abstract final class DesktopWindowConfig {
  /// Captured during window setup; preference changes apply on the next launch.
  // Windows always exposes its native caption controls. A preference imported
  // from macOS must not leave a desktop window with no usable caption buttons.
  static final bool showWindowButton =
      Platform.isWindows || GStorage.getSetting(SettingsKeys.showWindowButton);
}
