import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/utils/m3u8_parser.dart';

void main() {
  const base = 'https://fixture.invalid/video/list.m3u8?token=x';
  test('highest variant retains its independent default audio group', () {
    final master = M3u8Parser.parseMasterPlaylist('''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",DEFAULT=YES,URI="../audio/list.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=100,RESOLUTION=1920x1080
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1000,RESOLUTION=3840x2160,AUDIO="audio"
high.m3u8
''', base);
    expect(master.bestVariant.resolution, '3840x2160');
    expect(master.bestVariant.audioGroup, master.audio.single.group);
    expect(master.audio.single.uri, 'https://fixture.invalid/audio/list.m3u8');
    expect(master.audio.single.isDefault, isTrue);
  });
  test(
    'fMP4 initialization and byte ranges are retained for download, localized for playback',
    () {
      final list = M3u8Parser.parseMediaPlaylist('''#EXTM3U
#EXT-X-TARGETDURATION:4
#EXT-X-MAP:URI="data.mp4",BYTERANGE="16@0"
#EXTINF:4,
#EXT-X-BYTERANGE:24@16
data.mp4
#EXTINF:4,
#EXT-X-BYTERANGE:24
data.mp4
#EXT-X-ENDLIST
''', base);
      expect(list.segments.first.byteRange!.header, 'bytes=16-39');
      expect(list.segments.last.byteRange!.header, 'bytes=40-63');
      expect(list.segments.first.initializationRange!.header, 'bytes=0-15');
      final local = M3u8Parser.buildLocalM3u8(
        list.segments,
        targetDuration: 4,
        initializationToLocal: {
          list.segments.first.initializationIdentity!: 'init_0.mp4',
        },
      );
      expect(local, contains('#EXT-X-MAP:URI="init_0.mp4"'));
      expect(local, isNot(contains('http')));
      expect(local, isNot(contains('BYTERANGE')));
      expect(local, contains('seg_00001.ts'));
    },
  );
  test(
    'AES IVs retain source sequence after ad filtering and local sequence reset',
    () {
      final list = M3u8Parser.parseMediaPlaylist('''#EXTM3U
#EXT-X-MEDIA-SEQUENCE:42
#EXT-X-KEY:METHOD=AES-128,URI="key"
#EXTINF:3,
a.ts
#EXTINF:3,
b.ts
#EXT-X-ENDLIST
''', base);
      final local = M3u8Parser.buildLocalM3u8(
        [list.segments.last],
        targetDuration: 3,
        keyUriToLocal: {'https://fixture.invalid/video/key': 'key_0.key'},
      );
      expect(local, contains('IV=0x0000000000000000000000000000002b'));
      expect(local, isNot(contains('https:')));
    },
  );
  test(
    'unsupported encryption and invalid range fail instead of corrupt completion',
    () {
      for (final line in [
        '#EXT-X-KEY:METHOD=SAMPLE-AES,URI="key"',
        '#EXT-X-BYTERANGE:10',
      ]) {
        expect(
          () => M3u8Parser.parseMediaPlaylist(
            '#EXTM3U\n$line\n#EXTINF:2,\na.ts',
            base,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => M3u8Parser.resolveUrl(base, 'file:///etc/passwd'),
        throwsFormatException,
      );
    },
  );
  test(
    'nested fetch failure never becomes a TS file or partial success',
    () async {
      final segment = M3u8Segment(
        duration: 2,
        uri: 'https://fixture.invalid/nested.m3u8',
        discontinuityGroup: 0,
      );
      await expectLater(
        M3u8Parser.resolveNestedSegments([
          segment,
        ], (_) async => throw StateError('offline')),
        throwsStateError,
      );
      await expectLater(
        M3u8Parser.resolveNestedSegments([
          segment,
        ], (_) async => '#EXTM3U\n#EXTINF:2,\nnested.m3u8'),
        throwsFormatException,
      );
    },
  );
}
