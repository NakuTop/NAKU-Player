import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_player_preferences.dart';
import 'package:kazumi/services/player/playback_lifecycle.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/services/storage/storage.dart';

void main() {
  test('decode facts distinguish real 4K from an enlarged 1080p picture', () {
    const source = PlaybackQualitySnapshot({
      'video-params/w': '1920',
      'video-params/h': '1080',
      'container-fps': '23.976',
      'estimated-vf-fps': '59.94',
    });
    expect(source.resolution, '1920 × 1080 · 1080p');
    expect(source.number('container-fps', digits: 3), '23.976');
    expect(
      const PlaybackQualitySnapshot({
        'video-params/w': '3840',
        'video-params/h': '2160',
      }).resolution,
      '3840 × 2160 · 4K',
    );
    expect(
      const PlaybackQualitySnapshot({
        'container-fps': 'nan',
      }).number('container-fps'),
      '暂无数据',
    );
    expect(const PlaybackQualitySnapshot({}).resolution, '正在读取');
  });

  test('buffer budget honors persisted choices and low-memory priority', () {
    for (final megabytes in [32, 64, 128, 256, -1, 4096]) {
      T read<T>(SettingKey<T> key) =>
          (key.name == SettingsKeys.videoBufferMegabytes.name
                  ? megabytes
                  : key.defaultValue)
              as T;
      final quality = PlaybackQualityPreferences.read(readSetting: read);
      final expected = megabytes < 32 || megabytes > 256 ? 128 : megabytes;
      expect(quality.bufferMegabytes, expected);
      expect(
        CinemaPlayerPreferences.read(
          readSetting: read,
          isMetered: false,
        ).bufferSize,
        expected * 1024 * 1024,
      );
      expect(
        CinemaPlayerPreferences.read(
          readSetting: read,
          isMetered: true,
        ).bufferSize,
        2 * 1024 * 1024,
      );
    }
  });

  test(
    'optional local processing does not request unavailable FFmpeg filters',
    () {
      const quality = PlaybackQualityPreferences(
        fineScaling: true,
        smoothMotion: true,
      );
      expect(quality.properties['hls-bitrate'], 'max');
      expect(quality.properties['scale'], 'ewa_lanczossharp');
      expect(quality.properties['video-sync'], 'display-resample');
      expect(quality.properties.containsKey('vf'), isFalse);
      expect(
        const PlaybackQualityPreferences().properties['interpolation'],
        'no',
      );
    },
  );

  test(
    'macOS fullscreen lifecycle events do not imply a hidden window',
    () async {
      expect(
        await isPlaybackWindowBackgrounded(
          isMacOS: true,
          isMinimized: () async => false,
          isVisible: () async => true,
        ),
        isFalse,
      );
      expect(
        await isPlaybackWindowBackgrounded(
          isMacOS: true,
          isMinimized: () async => true,
          isVisible: () async => true,
        ),
        isTrue,
      );
      expect(
        await isPlaybackWindowBackgrounded(
          isMacOS: true,
          isMinimized: () async => false,
          isVisible: () async => false,
        ),
        isTrue,
      );
      expect(
        await isPlaybackWindowBackgrounded(
          isMacOS: true,
          isMinimized: () async => throw StateError('bridge unavailable'),
        ),
        isFalse,
      );
      expect(await isPlaybackWindowBackgrounded(isMacOS: false), isTrue);
    },
  );
}
