import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/storage/storage.dart';

abstract final class DesktopWindowConfig {
  /// Captured during window setup; preference changes apply on the next launch.
  // Native Mac traffic lights and Windows caption controls remain available
  // even when an older installation saved the opt-in preference as false.
  static final bool showWindowButton = resolveWindowButtonVisibility(
    operatingSystem: Platform.operatingSystem,
    readPreference: () => GStorage.getSetting(SettingsKeys.showWindowButton),
  );

  @visibleForTesting
  static bool resolveWindowButtonVisibility({
    required String operatingSystem,
    required bool Function() readPreference,
  }) => switch (operatingSystem) {
    'macos' || 'windows' => true,
    _ => readPreference(),
  };
}
