import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_hls_ads.dart';

const manifest = '''
#EXTM3U
#EXTINF:1144,
before.ts
#EXT-X-DISCONTINUITY
#EXT-X-CUE-OUT:DURATION=15
#EXTINF:15,
ad.ts
#EXT-X-CUE-IN
#EXT-X-DISCONTINUITY
#EXTINF:50,
after.ts
#EXT-X-ENDLIST
''';

void main() {
  test('only a closed, corroborated cue pair marks the original timeline', () {
    expect(cinemaHlsAdBreaks(manifest), [
      (
        start: const Duration(seconds: 1144),
        end: const Duration(seconds: 1159),
      ),
    ]);
    for (final unsafe in [
      manifest.replaceAll(RegExp(r'^#EXT-X-CUE.*\n', multiLine: true), ''),
      manifest.replaceFirst('#EXT-X-CUE-IN', ''),
      manifest.replaceFirst('DURATION=15', 'DURATION=4'),
      manifest.replaceFirst('#EXT-X-ENDLIST', ''),
      manifest.replaceFirst('#EXTINF:50,\nafter.ts', ''),
    ]) {
      expect(cinemaHlsAdBreaks(unsafe), isEmpty);
    }
  });
}
