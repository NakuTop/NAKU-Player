import 'package:flutter/foundation.dart';

/// Keep foreign platform preferences from disabling Windows' native decoder.
String cinemaHardwareDecoder(String saved, {TargetPlatform? platform}) {
  final value = saved.trim();
  final target = platform ?? defaultTargetPlatform;
  if (target == TargetPlatform.macOS) {
    if (value.isEmpty ||
        [
          'auto',
          'auto-safe',
          'd3d11va',
          'd3d11va,auto',
          'd3d11va-copy',
          'dxva2',
          'dxva2-copy',
          'mediacodec',
          'mediacodec-copy',
          'vaapi',
          'vdpau',
          'cuda',
          'nvdec',
        ].contains(value)) {
      return 'videotoolbox,auto';
    }
    return value;
  }
  if (target != TargetPlatform.windows) {
    return value.isEmpty ? 'auto-safe' : value;
  }
  if (value.isEmpty ||
      [
        'auto',
        'auto-safe',
        'videotoolbox',
        'mediacodec',
        'mediacodec-copy',
        'vaapi',
        'vdpau',
      ].contains(value)) {
    return 'd3d11va,auto';
  }
  return value;
}

Map<String, String> windowsPlaybackProperties(int bufferBytes) => {
  // One bounded cache, 30 seconds of forward read, modest backward seek cache.
  'cache': 'yes',
  'cache-secs': '30',
  'demuxer-readahead-secs': '30',
  'demuxer-max-bytes': '${bufferBytes * 3 ~/ 4}',
  'demuxer-max-back-bytes':
      '${(bufferBytes ~/ 4).clamp(512 * 1024, 32 * 1024 * 1024)}',
  'vd-lavc-threads': '4',
};
