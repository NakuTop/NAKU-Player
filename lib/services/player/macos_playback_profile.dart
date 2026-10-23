import 'dart:io';
import 'package:kazumi/services/storage/storage.dart';

/// Opt-in for this personal installer. Applied once after opening the settings
/// store; later manual changes stay authoritative. Other releases opt out.
class MacOSPlaybackProfile {
  static const marker = SettingKey<bool>(
    'nakuMacPlaybackProfile2110Applied',
    false,
    group: SettingGroup.player,
  );
  static Future<void> apply({
    bool enabled = const bool.fromEnvironment('NAKU_OPTIMIZE_PLAYBACK_ONCE'),
    bool? isMacOS,
    T Function<T>(SettingKey<T>)? readSetting,
    Future<void> Function<T>(SettingKey<T>, T)? writeSetting,
  }) async {
    if (!enabled || !(isMacOS ?? Platform.isMacOS)) return;
    final read = readSetting ?? GStorage.getSetting;
    final write = writeSetting ?? GStorage.putSetting;
    if (read(marker)) return;
    await write(SettingsKeys.videoBufferMegabytes, 256);
    await write(SettingsKeys.mediaDirectConnection, false);
    await write(SettingsKeys.mediaAutoRouting, true);
    await write(SettingsKeys.lowMemoryPolicy, 'never');
    await write(marker, true);
  }
}
