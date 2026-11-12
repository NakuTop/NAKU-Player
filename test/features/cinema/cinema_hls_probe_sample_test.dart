import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_hls_probe_sample.dart';

void main() {
  final base = Uri.parse('https://video.example/folder/list.m3u8');
  test(
    'init and first segment retain their own range, key and explicit IV',
    () {
      final sample = cinemaHlsProbeSample('''#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="init.key",IV=0x12
#EXT-X-MAP:URI="init.mp4",BYTERANGE="256@512"
#EXT-X-KEY:METHOD=AES-128,URI="media.key"
#EXT-X-MEDIA-SEQUENCE:257
#EXT-X-BYTERANGE:1024@8192
segment.mp4
#EXT-X-KEY:METHOD=NONE
later.mp4
''', base);
      expect(
        sample.initialization!.uri.toString(),
        'https://video.example/folder/init.mp4',
      );
      expect(sample.initialization!.range(65536), 'bytes=512-767');
      expect(sample.initialization!.encryption!.iv!.last, 0x12);
      expect(sample.media.range(256), 'bytes=8192-8447');
      expect(sample.media.encryption!.key!.path, '/folder/media.key');
      expect(sample.media.encryption!.iv!.skip(14), [1, 1]);
    },
  );
  test(
    'missing init IV, unsupported key formats and invalid IV remain unsupported',
    () {
      final missing = cinemaHlsProbeSample(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXT-X-MAP:URI="init"\nseg\n',
        base,
      );
      expect(missing.initialization!.encryption!.key, isNull);
      expect(missing.media.encryption!.key, isNotNull);
      for (final options in [',IV=0xinvalid', ',KEYFORMAT="com.example.drm"']) {
        final value = cinemaHlsProbeSample(
          '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"$options\nseg\n',
          base,
        );
        expect(value.media.encryption!.key, isNull);
      }
    },
  );
  test(
    'METHOD NONE clears encryption; an implicit first byte range is rejected',
    () {
      final value = cinemaHlsProbeSample(
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="k"\n#EXT-X-KEY:METHOD=NONE\nseg\n',
        base,
      );
      expect(value.media.encryption, isNull);
      expect(
        () => cinemaHlsProbeSample('#EXTM3U\n#EXT-X-BYTERANGE:16\nseg\n', base),
        throwsFormatException,
      );
    },
  );
}
