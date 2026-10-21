import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/windows_playback_policy.dart';

void main() {
  test(
    'Windows prioritizes native D3D11 and replaces foreign platform decoders',
    () {
      for (final value in [
        '',
        'auto-safe',
        'videotoolbox',
        'vaapi',
        'mediacodec',
      ]) {
        expect(
          cinemaHardwareDecoder(value, platform: TargetPlatform.windows),
          'd3d11va,auto',
        );
      }
      expect(
        cinemaHardwareDecoder('no', platform: TargetPlatform.windows),
        'no',
      );
      expect(
        cinemaHardwareDecoder('nvdec-copy', platform: TargetPlatform.windows),
        'nvdec-copy',
      );
      expect(
        cinemaHardwareDecoder('videotoolbox', platform: TargetPlatform.macOS),
        'videotoolbox',
      );
    },
  );
  test(
    'forward and backward caches share the selected total budget including low-memory mode',
    () {
      for (final mb in [2, 32, 64, 128, 256]) {
        final total = mb * 1024 * 1024;
        final properties = windowsPlaybackProperties(total);
        final forward = int.parse(properties['demuxer-max-bytes']!);
        final backward = int.parse(properties['demuxer-max-back-bytes']!);
        expect(forward + backward, lessThanOrEqualTo(total));
        expect(properties['demuxer-readahead-secs'], '30');
        expect(int.parse(properties['vd-lavc-threads']!), lessThanOrEqualTo(8));
      }
    },
  );
}
