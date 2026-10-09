import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/network/metered_network_service.dart';
import 'package:kazumi/services/player/low_memory_mode.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

typedef CinemaSettingReader = T Function<T>(SettingKey<T> key);
typedef CinemaSettingWriter =
    Future<void> Function<T>(SettingKey<T> key, T value);

/// A playback session reads the same preferences as the anime player. Changing
/// defaults never overwrites a user's temporary rate or an active follow session.
class CinemaPlayerPreferences {
  CinemaPlayerPreferences._({
    required this.rate,
    required this.volume,
    required this.muted,
    required this.hardwareAcceleration,
    required this.hardwareDecoder,
    required this.superResolution,
    required this.aspectRatio,
    required this.arrowSkipSeconds,
    required this.buttonSkipSeconds,
    required this.longPressRate,
    required this.controlsHoverDuration,
    required this.disableAnimations,
    required this.resume,
    required this.autoPlay,
    required this.autoPlayNext,
    required this.backgroundPlayback,
    required this.privateMode,
    required this.forceAdBlocker,
    required this.showPlayerError,
    required this.bufferSize,
    required this.shortcuts,
  });

  factory CinemaPlayerPreferences.read({
    CinemaSettingReader? readSetting,
    List<String> Function(String name, List<String> defaults)? readShortcut,
    bool? isMetered,
  }) {
    T read<T>(SettingKey<T> key) {
      try {
        return (readSetting ?? GStorage.getSetting)<T>(key);
      } catch (_) {
        // Tests and early startup can precede Hive initialization. Read-only
        // fallback; opening a player must never replace stored preferences.
        return key.defaultValue;
      }
    }

    double rate(double value, double fallback) =>
        value.isFinite ? value.clamp(.25, 3).toDouble() : fallback;
    final rememberedVolume = read(SettingsKeys.defaultVolume);
    final decoder = read(SettingsKeys.hardwareDecoder).trim();
    final lowMemory = switch (read(SettingsKeys.lowMemoryPolicy)) {
      'always' => LowMemoryMode.always,
      'never' => LowMemoryMode.never,
      null when read(SettingsKeys.lowMemoryMode) => LowMemoryMode.always,
      _ => LowMemoryMode.auto,
    };
    final shortcuts = <String, List<String>>{};
    for (final action in supportedShortcuts) {
      final defaults = defaultShortcuts[action]!;
      try {
        shortcuts[action] = List.unmodifiable(
          readShortcut?.call('shortcut_$action', defaults) ??
              GStorage.getStringListSettingByName(
                'shortcut_$action',
                defaultValue: defaults,
              ),
        );
      } catch (_) {
        shortcuts[action] = defaults;
      }
    }
    // Keep cinema controls accessible, without stealing a customized binding.
    for (final extra in const {
      'episodes': 'E',
      'pip': 'I',
      'together': 'W',
      'favorite': 'B',
    }.entries) {
      if (!shortcuts.values.any((keys) => keys.contains(extra.value))) {
        shortcuts[extra.key] = [extra.value];
      }
    }
    return CinemaPlayerPreferences._(
      rate: rate(read(SettingsKeys.defaultPlaySpeed), 1),
      volume: rememberedVolume.isFinite
          ? rememberedVolume.clamp(0, 100).toDouble()
          : 100,
      muted: read(SettingsKeys.playerMuted),
      hardwareAcceleration: read(SettingsKeys.hAenable),
      hardwareDecoder: decoder.isEmpty ? 'auto-safe' : decoder,
      superResolution: SuperResolutionMode.fromStorageValue(
        read(SettingsKeys.defaultSuperResolutionMode),
      ),
      aspectRatio: PlayerAspectRatio.fromStorageValue(
        read(SettingsKeys.defaultAspectRatioType),
      ),
      arrowSkipSeconds: read(SettingsKeys.arrowKeySkipTime).clamp(0, 3600),
      buttonSkipSeconds: read(SettingsKeys.buttonSkipTime).clamp(0, 3600),
      longPressRate: rate(
        read(SettingsKeys.defaultShortcutForwardPlaySpeed),
        2,
      ),
      controlsHoverDuration: Duration(
        milliseconds: read(
          SettingsKeys.playerControllerLayerDisappearTime,
        ).clamp(1000, 10000),
      ),
      disableAnimations: read(SettingsKeys.playerDisableAnimations),
      resume: read(SettingsKeys.playResume),
      autoPlay: read(SettingsKeys.autoPlay),
      autoPlayNext: read(SettingsKeys.autoPlayNext),
      backgroundPlayback: read(SettingsKeys.backgroundPlayback),
      privateMode: read(SettingsKeys.privateMode),
      forceAdBlocker: read(SettingsKeys.forceAdBlocker),
      showPlayerError: read(SettingsKeys.showPlayerError),
      // Retain cinema's bounded default rather than adopting the anime cache's
      // 1.5 GiB budget. The shared low-memory policy reduces it to 2 MiB.
      bufferSize:
          lowMemory.isEnabled(
            isMetered: isMetered ?? MeteredNetworkService.isMetered,
          )
          ? 2 * 1024 * 1024
          : PlaybackQualityPreferences.normalizeBuffer(
                  read(SettingsKeys.videoBufferMegabytes),
                ) *
                1024 *
                1024,
      shortcuts: Map.unmodifiable(shortcuts),
    );
  }

  static const supportedShortcuts = {
    'playorpause',
    'forward',
    'rewind',
    'next',
    'prev',
    'volumeup',
    'volumedown',
    'togglemute',
    'fullscreen',
    'exitfullscreen',
    'skip',
    'speed1',
    'speed2',
    'speed3',
    'speedup',
    'speeddown',
  };

  final double rate, volume, longPressRate;
  final bool muted, hardwareAcceleration, disableAnimations;
  final bool resume, autoPlay, autoPlayNext, backgroundPlayback;
  final bool privateMode, forceAdBlocker, showPlayerError;
  final String hardwareDecoder;
  final SuperResolutionMode superResolution;
  final PlayerAspectRatio aspectRatio;
  final int arrowSkipSeconds, buttonSkipSeconds, bufferSize;
  final Duration controlsHoverDuration;
  final Map<String, List<String>> shortcuts;

  double get initialVolume => muted ? 0 : volume;

  PlayerConfiguration get playerConfiguration => PlayerConfiguration(
    title: 'NAKU播放器',
    osc: false,
    bufferSize: bufferSize,
    adBlocker: forceAdBlocker,
  );

  VideoControllerConfiguration get videoConfiguration =>
      VideoControllerConfiguration(
        enableHardwareAcceleration: hardwareAcceleration,
        hwdec: hardwareAcceleration ? hardwareDecoder : 'no',
      );

  int? nextEpisode({
    required int index,
    required int count,
    bool following = false,
  }) => autoPlayNext && !following && index >= 0 && index + 1 < count
      ? index + 1
      : null;

  /// Both players share the last audible volume; muting must not erase it.
  static Future<void> rememberVolume(
    double value, {
    CinemaSettingWriter? writeSetting,
  }) async {
    if (!value.isFinite) return;
    final write = writeSetting ?? GStorage.putSetting;
    final volume = value.clamp(0, 100).toDouble();
    if (volume > 0) await write<double>(SettingsKeys.defaultVolume, volume);
    await write<bool>(SettingsKeys.playerMuted, volume == 0);
  }
}

/// Coalesces slider events and serializes the two shared preference writes.
/// An exit flush also joins a timer-triggered write already in progress.
class CinemaVolumePersistence {
  CinemaVolumePersistence({Future<void> Function(double)? save})
    : _save = save ?? CinemaPlayerPreferences.rememberVolume;

  final Future<void> Function(double) _save;
  double? _pending;
  Future<void>? _tail;

  void update(double value) {
    if (value.isFinite) _pending = value.clamp(0, 100).toDouble();
  }

  Future<void> flush() {
    final value = _pending;
    if (value == null) return _tail ?? Future.value();
    _pending = null;
    final previous = _tail;
    return _tail = (() async {
      try {
        await previous;
      } catch (_) {
        // A later valid change may recover after an earlier storage failure.
      }
      await _save(value);
    })();
  }
}
