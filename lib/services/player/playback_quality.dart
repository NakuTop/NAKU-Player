import 'package:kazumi/services/storage/storage.dart';
import 'package:media_kit/media_kit.dart';

class PlaybackQualityPreferences {
  const PlaybackQualityPreferences({
    this.fineScaling = false,
    this.smoothMotion = false,
    this.highestBitrate = true,
    this.bufferMegabytes = 128,
  });
  factory PlaybackQualityPreferences.read({
    T Function<T>(SettingKey<T> key)? readSetting,
  }) {
    T read<T>(SettingKey<T> key) {
      try {
        return (readSetting ?? GStorage.getSetting)<T>(key);
      } catch (_) {
        return key.defaultValue;
      }
    }

    return PlaybackQualityPreferences(
      fineScaling: read(SettingsKeys.fineVideoScaling),
      smoothMotion: read(SettingsKeys.smoothVideoMotion),
      highestBitrate: read(SettingsKeys.highestVideoBitrate),
      bufferMegabytes: normalizeBuffer(read(SettingsKeys.videoBufferMegabytes)),
    );
  }
  final bool fineScaling, smoothMotion, highestBitrate;
  final int bufferMegabytes;
  static int normalizeBuffer(int value) =>
      const {32, 64, 128, 256}.contains(value) ? value : 128;
  Map<String, String> get properties => {
    'hls-bitrate': highestBitrate ? 'max' : '5000000',
    'scale': fineScaling ? 'ewa_lanczossharp' : 'bilinear',
    'cscale': fineScaling ? 'spline36' : 'bilinear',
    'dscale': fineScaling ? 'mitchell' : 'bilinear',
    'deband': fineScaling ? 'yes' : 'no',
    'video-sync': smoothMotion ? 'display-resample' : 'audio',
    'tscale': 'oversample',
    'interpolation': smoothMotion ? 'yes' : 'no',
  };
  Future<void> apply(NativePlayer player) async {
    for (final entry in properties.entries) {
      await player.setProperty(entry.key, entry.value);
    }
  }
}

/// Read decoder/renderer facts, never infer resolution from titles or shader size.
class PlaybackQualitySnapshot {
  const PlaybackQualitySnapshot(this.properties);
  final Map<String, String> properties;
  static Future<PlaybackQualitySnapshot> read(NativePlayer player) async {
    final data = <String, String>{};
    for (final key in const [
      'video-params/w',
      'video-params/h',
      'container-fps',
      'estimated-vf-fps',
      'video-codec',
      'video-params/gamma',
      'video-bitrate',
      'hwdec-current',
      'frame-drop-count',
      'decoder-frame-drop-count',
      'demuxer-cache-duration',
      'display-sync-active',
      'display-fps',
    ]) {
      try {
        data[key] = await player.getProperty(key);
      } catch (_) {
        /* Not available on every output. */
      }
    }
    return PlaybackQualitySnapshot(data);
  }

  String get resolution {
    final w = int.tryParse(properties['video-params/w'] ?? '') ?? 0;
    final h = int.tryParse(properties['video-params/h'] ?? '') ?? 0;
    if (w == 0 || h == 0) return '正在读取';
    final label = w >= 3840 || h >= 2160
        ? '4K'
        : h >= 1080
        ? '1080p'
        : h >= 720
        ? '720p'
        : '';
    return '$w × $h${label.isEmpty ? '' : ' · $label'}';
  }

  String number(String key, {String suffix = '', int digits = 1}) {
    final value = double.tryParse(properties[key] ?? '');
    return value == null || !value.isFinite || value < 0
        ? '暂无数据'
        : '${value.toStringAsFixed(digits)}$suffix';
  }
}
