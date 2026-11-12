import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/api.dart';
import 'cinema_video_metadata_test.dart'
    show metadataBox, metadataMp4, metadataTs;

void main() {
  late HttpServer server;
  late Dio dio;
  final hits = <String, int>{};
  final ranges = <String, String?>{};
  var sent = 0;
  late Uint8List tailMp4;
  final aesKey = Uint8List.fromList(List.generate(16, (i) => i + 1));
  Uint8List encrypted(int sequence) {
    final raw = [...metadataTs(), ...Uint8List(2048)];
    final padding = 16 - raw.length % 16;
    final plain = Uint8List.fromList([
      ...raw,
      ...List.filled(padding, padding),
    ]);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(
        true,
        ParametersWithIV(KeyParameter(aesKey), Uint8List(16)..last = sequence),
      );
    final result = Uint8List(plain.length);
    for (var i = 0; i < plain.length; i += 16) {
      cipher.processBlock(plain, i, result, i);
    }
    return result;
  }

  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  setUp(() async {
    sent = 0;
    hits.clear();
    ranges.clear();
    tailMp4 = Uint8List.fromList([
      ...metadataBox('ftyp', [0, 0, 0, 0]),
      ...metadataBox('mdat', Uint8List(3 * 1024 * 1024)),
      ...metadataMp4(),
    ]);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      ranges[path] = request.headers.value('range');
      try {
        if (request.headers.value('X-Session') != 'local-fixture') {
          request.response.statusCode = 403;
          return;
        }
        if (path == '/aes.key') {
          request.response.add(aesKey);
          return;
        }
        if (path == '/failed.ts') {
          request.response.statusCode = 503;
          return;
        }
        if (path == '/init-failure.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10,\nfailed.ts\n',
          );
          return;
        }
        if (path == '/init.mp4') {
          request.response.add(metadataMp4());
          return;
        }
        if (path == '/master-failure.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=1920x1080\nlower.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=3840x2160\nfailed.m3u8\n',
          );
          return;
        }
        if (path == '/failed.m3u8') {
          request.response.write('#EXTM3U\n#EXTINF:10,\nfailed.ts\n');
          return;
        }
        if (path == '/implicit.m3u8' || path == '/explicit.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:9\n#EXT-X-KEY:METHOD=AES-128,URI="aes.key"${path.startsWith('/explicit') ? ',IV=0x05' : ''}\n#EXTINF:10,\n${path.startsWith('/explicit') ? 'explicit' : 'implicit'}.ts\n#EXT-X-KEY:METHOD=AES-128,URI="later.key"\n#EXTINF:10,\nlater.ts\n',
          );
          return;
        }
        if (path == '/sample-aes.m3u8') {
          request.response.write(
            '#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI="drm.key"\n#EXTINF:10,\nsegment.ts\n',
          );
          return;
        }
        if (path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n${path.contains('encrypted') ? '#EXT-X-KEY:METHOD=AES-128,URI="key"\n' : ''}#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
          return;
        }
        final bytes = path == '/implicit.ts' || path == '/explicit.ts'
            ? encrypted(path == '/implicit.ts' ? 9 : 5)
            : path == '/bulk.ts'
            ? Uint8List.fromList([...metadataTs(), ...Uint8List(1024 * 1024)])
            : path == '/native.mp4' &&
                  const String.fromEnvironment('NAKU_QUALITY_FIXTURE') != ''
            ? await File(
                const String.fromEnvironment('NAKU_QUALITY_FIXTURE'),
              ).readAsBytes()
            : path.endsWith('.mp4')
            ? tailMp4
            : Uint8List.fromList([...metadataTs(), ...Uint8List(2048)]);
        var start = 0, end = bytes.length - 1;
        final range = RegExp(
          r'^bytes=(\d+)-(\d+)$',
        ).firstMatch(request.headers.value('range') ?? '');
        if (range != null) {
          start = int.parse(range[1]!);
          end = int.parse(range[2]!).clamp(start, bytes.length - 1);
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/${bytes.length}',
          );
        }
        request.response.headers.contentType = ContentType.binary;
        sent += end - start + 1;
        request.response.add(Uint8List.sublistView(bytes, start, end + 1));
      } finally {
        await request.response.close();
      }
    });
    dio = Dio();
  });
  tearDown(() async {
    dio.close(force: true);
    await server.close(force: true);
  });
  const headers = {'X-Session': 'local-fixture'};
  test(
    'an initialization video header remains visible if the media segment fails',
    () async {
      final result = await CinemaMediaProbe.detail(
        transport: CinemaMediaTransport(dio: dio),
      ).measure(url('/init-failure.m3u8'), headers);
      expect(result.ok, isFalse);
      expect(result.width, 1920);
      expect(result.height, 1080);
      expect(result.qualityEvidence, CinemaQualityEvidence.videoHeader);
    },
  );
  test(
    'single-variant HLS reads actual TS dimensions instead of naming it 4K',
    () async {
      final result = await CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
      ).measure(url('/plain.m3u8'), headers);
      expect(result.ok, isTrue);
      expect(result.width, 1280);
      expect(result.height, 720);
      expect(result.qualityEvidence, CinemaQualityEvidence.videoHeader);
      expect(result.label, contains('视频头确认'));
    },
  );
  test(
    'MP4 moov-at-end uses a bounded suffix range rather than downloading the film',
    () async {
      final probe = CinemaMediaProbe(transport: CinemaMediaTransport(dio: dio));
      final result = await probe.measure(url('/film.mp4'), headers);
      expect(result.ok, isTrue);
      expect(result.width, 1920);
      expect(result.height, 1080);
      expect(sent, lessThanOrEqualTo(2 * 1024 * 1024));
      expect(hits['/film.mp4'], 2);
    },
  );
  test(
    'probe cache is bounded to the same URL and request headers and manual refresh invalidates it',
    () async {
      final probe = CinemaMediaProbe(transport: CinemaMediaTransport(dio: dio));
      final first = await probe.measure(url('/plain.m3u8'), headers);
      await probe.measure(url('/plain.m3u8'), headers);
      expect(hits['/segment.ts'], 1);
      final denied = await probe.measure(url('/plain.m3u8'), const {});
      expect(denied.ok, isFalse);
      expect(denied.reason, contains('鉴权'));
      expect(first.ok, isTrue);
      probe.invalidate();
      await probe.measure(url('/plain.m3u8'), headers);
      expect(hits['/segment.ts'], 2);
    },
  );
  test(
    'real local MP4 fixture reports the packaged MPV known dimensions with bounded reads',
    () async {
      final result = await CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
      ).measure(url('/native.mp4'), headers);
      expect(result.ok, isTrue);
      expect(result.width, 1280);
      expect(result.height, 720);
      expect(result.codec, 'H.264');
      expect(result.qualityEvidence, CinemaQualityEvidence.videoHeader);
      expect(sent, lessThanOrEqualTo(2 * 1024 * 1024));
    },
    skip: const String.fromEnvironment('NAKU_QUALITY_FIXTURE') == '',
  );
  test(
    'invalid keys never give encrypted bytes a false video-header quality label',
    () async {
      final result = await CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
      ).measure(url('/encrypted.m3u8'), headers);
      expect(result.ok, isTrue);
      expect(result.qualityEvidence, CinemaQualityEvidence.unknown);
      expect(result.qualityLabel, '画质未知');
      expect(hits['/key'], 1);
    },
  );
  for (final mode in ['implicit', 'explicit']) {
    test(
      'detail reads AES-128 video dimensions using $mode IV before playback',
      () async {
        final result = await CinemaMediaProbe(
          transport: CinemaMediaTransport(dio: dio),
          quick: true,
        ).measure(url('/$mode.m3u8'), headers);
        expect(result.ok, isTrue);
        expect((result.width, result.height), (1280, 720));
        expect(result.qualityEvidence, CinemaQualityEvidence.videoHeader);
        expect(hits['/aes.key'], 1);
        expect(hits['/later.key'], isNull);
        expect(hits['/later.ts'], isNull);
      },
    );
  }
  test('sample encryption stays unknown without trying a DRM key', () async {
    final result = await CinemaMediaProbe(
      transport: CinemaMediaTransport(dio: dio),
    ).measure(url('/sample-aes.m3u8'), headers);
    expect(result.ok, isTrue);
    expect(result.height, isNull);
    expect(hits['/drm.key'], isNull);
  });
  test(
    'detail sampling is capped at 256 KiB and reopens reuse bounded results',
    () async {
      final cache = CinemaMediaProbeCache();
      final one = CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
        quick: true,
        cache: cache,
      );
      final result = await one.measure(url('/bulk.ts'), headers);
      expect(result.height, 720);
      expect(ranges['/bulk.ts'], 'bytes=0-262143');
      expect(sent, 262144);
      final two = CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
        quick: true,
        cache: cache,
      );
      expect((await two.measure(url('/bulk.ts'), headers)).height, 720);
      expect(hits['/bulk.ts'], 1);
    },
  );
  test(
    'the highest resolution wins over bitrate and survives a failed segment',
    () async {
      final result = await CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
        quick: true,
      ).measure(url('/master-failure.m3u8'), headers);
      expect(result.ok, isFalse);
      expect((result.width, result.height), (3840, 2160));
      expect(result.qualityEvidence, CinemaQualityEvidence.manifest);
      expect(hits['/lower.m3u8'], isNull);
    },
  );
}
