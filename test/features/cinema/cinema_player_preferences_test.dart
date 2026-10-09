import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_player_preferences.dart';
import 'package:kazumi/pages/player/controller/player_aspect_ratio.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/services/storage/storage.dart';

CinemaPlayerPreferences preferences(
  Map<String, Object?> values, {
  bool metered = false,
  List<String> Function(String, List<String>)? shortcuts,
}) => CinemaPlayerPreferences.read(
  readSetting: <T>(SettingKey<T> key) =>
      (values.containsKey(key.name) ? values[key.name] : key.defaultValue) as T,
  readShortcut: shortcuts ?? (_, defaults) => defaults,
  isMetered: metered,
);

void main() {
  test('unavailable settings use read-only defaults', () {
    final p = CinemaPlayerPreferences.read(
      readSetting: <T>(_) => throw StateError('unavailable'),
      readShortcut: (_, _) => throw StateError('unavailable'),
      isMetered: false,
    );
    expect(p.rate, 1);
    expect(p.initialVolume, 100);
    expect(p.playerConfiguration.bufferSize, 64 * 1024 * 1024);
    expect(p.videoConfiguration.enableHardwareAcceleration, isTrue);
    expect(p.superResolution, SuperResolutionMode.off);
    expect(p.shortcuts['forward'], ['Arrow Right']);
  });

  test(
    'shared keys configure the real media-kit player and video controller',
    () {
      final p = preferences({
        'defaultPlaySpeed': 1.75,
        'defaultVolume': 37.0,
        'playerMuted': true,
        'hAenable': false,
        'hardwareDecoder': 'videotoolbox',
        SettingsKeys.defaultSuperResolutionMode.name: 3,
        'defaultAspectRatioType': 4,
        'arrowKeySkipTime': 7,
        'buttonSkipTime': 45,
        'defaultShortcutForwardPlaySpeed': 2.5,
        'playerControllerLayerDisappearTime': 5500,
        'playerDisableAnimations': true,
        'playResume': false,
        'autoPlay': false,
        'autoPlayNext': false,
        'backgroundPlayback': true,
        'privateMode': true,
        'forceAdBlocker': true,
        'showPlayerError': true,
      });
      expect(p.rate, 1.75);
      expect(p.volume, 37);
      expect(p.initialVolume, 0);
      expect(p.videoConfiguration.enableHardwareAcceleration, isFalse);
      expect(p.videoConfiguration.hwdec, 'no');
      expect(
        preferences({
          'hardwareDecoder': 'videotoolbox',
        }).videoConfiguration.hwdec,
        'videotoolbox',
      );
      expect(p.playerConfiguration.adBlocker, isTrue);
      expect(p.superResolution, SuperResolutionMode.quality);
      expect(p.aspectRatio, PlayerAspectRatio.ratio4x3);
      expect(p.arrowSkipSeconds, 7);
      expect(p.buttonSkipSeconds, 45);
      expect(p.longPressRate, 2.5);
      expect(p.controlsHoverDuration, const Duration(milliseconds: 5500));
      expect(p.disableAnimations, isTrue);
      expect(p.resume, isFalse);
      expect(p.autoPlay, isFalse);
      expect(p.autoPlayNext, isFalse);
      expect(p.backgroundPlayback, isTrue);
      expect(p.privateMode, isTrue);
      expect(p.showPlayerError, isTrue);
    },
  );

  test(
    'legacy and network-aware low-memory choices retain a bounded cinema cache',
    () {
      expect(preferences({'lowMemoryMode': true}).bufferSize, 2 * 1024 * 1024);
      expect(preferences({}, metered: true).bufferSize, 2 * 1024 * 1024);
      expect(
        preferences({'lowMemoryPolicy': 'never'}, metered: true).bufferSize,
        64 * 1024 * 1024,
      );
      expect(
        preferences({'lowMemoryPolicy': 'always'}).bufferSize,
        2 * 1024 * 1024,
      );
    },
  );

  test('invalid persisted ranges are bounded without writing them back', () {
    final p = preferences({
      'defaultPlaySpeed': double.nan,
      'defaultVolume': double.infinity,
      'defaultShortcutForwardPlaySpeed': 90.0,
      'hardwareDecoder': ' ',
      SettingsKeys.defaultSuperResolutionMode.name: -1,
      'defaultAspectRatioType': 99,
      'arrowKeySkipTime': -10,
      'buttonSkipTime': 999999,
      'playerControllerLayerDisappearTime': -1,
    });
    expect(p.rate, 1);
    expect(p.volume, 100);
    expect(p.longPressRate, 3);
    expect(p.hardwareDecoder, 'auto-safe');
    expect(p.superResolution, SuperResolutionMode.off);
    expect(p.aspectRatio, PlayerAspectRatio.automatic);
    expect(p.arrowSkipSeconds, 0);
    expect(p.buttonSkipSeconds, 3600);
    expect(p.controlsHoverDuration, const Duration(seconds: 1));
  });

  test('cinema extra keys never steal a customized common shortcut', () {
    final p = preferences(
      {},
      shortcuts: (name, defaults) =>
          name == 'shortcut_fullscreen' ? ['E'] : defaults,
    );
    expect(p.shortcuts['fullscreen'], ['E']);
    expect(p.shortcuts.containsKey('episodes'), isFalse);
    expect(p.shortcuts['prev'], ['P']);
    expect(p.shortcuts['pip'], ['I']);
    expect(p.shortcuts.containsKey('toggledanmaku'), isFalse);
  });

  test(
    'mute preserves last audible volume shared with the anime player',
    () async {
      final values = <String, Object?>{};
      Future<void> write<T>(SettingKey<T> key, T value) async {
        values[key.name] = value;
      }

      await CinemaPlayerPreferences.rememberVolume(38, writeSetting: write);
      await CinemaPlayerPreferences.rememberVolume(0, writeSetting: write);
      expect(values, {'defaultVolume': 38.0, 'playerMuted': true});
      await CinemaPlayerPreferences.rememberVolume(140, writeSetting: write);
      expect(values, {'defaultVolume': 100.0, 'playerMuted': false});
    },
  );

  test(
    'automatic advance respects boundaries and never overrides active follow',
    () {
      final p = preferences({});
      expect(p.nextEpisode(index: 0, count: 2), 1);
      expect(p.nextEpisode(index: 1, count: 2), isNull);
      expect(p.nextEpisode(index: 0, count: 2, following: true), isNull);
      expect(
        preferences({'autoPlayNext': false}).nextEpisode(index: 0, count: 2),
        isNull,
      );
    },
  );

  test(
    'exit joins a timer save and a later mute cannot be overwritten by it',
    () async {
      final writingVolume = Completer<void>();
      final releaseVolume = Completer<void>();
      final values = <String, Object?>{};
      final writes = <String>[];
      Future<void> write<T>(SettingKey<T> key, T value) async {
        if (key == SettingsKeys.defaultVolume) {
          writingVolume.complete();
          await releaseVolume.future;
        }
        writes.add('${key.name}:$value');
        values[key.name] = value;
      }

      final queue = CinemaVolumePersistence(
        save: (value) =>
            CinemaPlayerPreferences.rememberVolume(value, writeSetting: write),
      );
      queue.update(20);
      queue.update(38);
      final timerSave = queue.flush();
      await writingVolume.future;
      var joined = false;
      final exitJoin = queue.flush().then((_) => joined = true);
      await Future<void>.delayed(Duration.zero);
      expect(joined, isFalse);
      queue.update(0);
      final muteSave = queue.flush();
      expect(writes, isEmpty);
      releaseVolume.complete();
      await Future.wait([timerSave, exitJoin, muteSave]);
      expect(writes, [
        'defaultVolume:38.0',
        'playerMuted:false',
        'playerMuted:true',
      ]);
      expect(values, {'defaultVolume': 38.0, 'playerMuted': true});
    },
  );

  test('a later volume change can recover after a failed write', () async {
    var attempts = 0;
    final queue = CinemaVolumePersistence(
      save: (_) async {
        if (attempts++ == 0) throw StateError('fixture storage error');
      },
    );
    queue.update(20);
    await expectLater(queue.flush(), throwsStateError);
    queue.update(30);
    await queue.flush();
    expect(attempts, 2);
  });
}
