import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'cinema_video_metadata_test.dart'
    show metadataBox, metadataMp4, metadataTs;

void main() {
  late HttpServer server;
  late Dio dio;
  final hits = <String, int>{};
  var sent = 0;
  late Uint8List tailMp4;
  String url(String path) => 'http://127.0.0.1:${server.port}$path';
  setUp(() async {
    sent = 0;
    hits.clear();
    tailMp4 = Uint8List.fromList([
      ...metadataBox('ftyp', [0, 0, 0, 0]),
      ...metadataBox('mdat', Uint8List(3 * 1024 * 1024)),
      ...metadataMp4(),
    ]);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      try {
        if (request.headers.value('X-Session') != 'local-fixture') {
          request.response.statusCode = 403;
          return;
        }
        if (path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n${path.contains('encrypted') ? '#EXT-X-KEY:METHOD=AES-128,URI="key"\n' : ''}#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
          return;
        }
        final bytes =
            path == '/native.mp4' &&
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
    'encrypted segments never gain a false video-header quality label',
    () async {
      final result = await CinemaMediaProbe(
        transport: CinemaMediaTransport(dio: dio),
      ).measure(url('/encrypted.m3u8'), headers);
      expect(result.ok, isTrue);
      expect(result.qualityEvidence, CinemaQualityEvidence.unknown);
      expect(result.qualityLabel, '画质未知');
      expect(hits['/key'], isNull);
    },
  );
}
