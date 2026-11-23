import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_source_connections.dart';
import 'package:kazumi/features/cinema/cinema_source_health.dart';
import 'cinema_video_metadata_test.dart' show metadataTs;

void main() {
  test(
    'a fresh check distinguishes catalogue, verified video, an HTTP denial and a sign-in page',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final root = await Directory.systemTemp.createTemp('naku-source-check-');
      final client = Dio();
      final health = CinemaSourceHealth(file: File('${root.path}/health.json'));
      addTearDown(() async {
        health.dispose();
        client.close(force: true);
        await server.close(force: true);
        await root.delete(recursive: true);
      });
      final base = 'http://127.0.0.1:${server.port}';
      final source = CinemaSource(
        id: 'check',
        name: '测试片源',
        kind: CinemaSourceKind.maccms,
        url: '$base/api',
        requestHeaders: const {'X-View': 'source'},
      );
      var apiStatus = 200, sampleStatus = 200, apiReads = 0, mediaReads = 0;
      var hasSample = true, html = false;
      server.listen((r) async {
        final out = r.response;
        if (r.headers.value('X-View') != 'source') {
          out.statusCode = 401;
        } else if (r.uri.path == '/api') {
          apiReads++;
          out.statusCode = apiStatus;
          out.write(
            jsonEncode({
              'code': 1,
              'list': [
                {
                  'vod_id': '1',
                  'vod_name': '影片',
                  'type_name': '电影',
                  'vod_play_from': hasSample ? 'hls' : '',
                  'vod_play_url': hasSample ? '正片\$$base/clip.m3u8' : '',
                },
              ],
            }),
          );
        } else if (r.uri.path == '/clip.m3u8') {
          out.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:5\n#EXTINF:5,\nsegment.ts\n#EXT-X-ENDLIST\n',
          );
        } else {
          mediaReads++;
          out.statusCode = sampleStatus;
          if (html) {
            out.write('<!DOCTYPE html><html>${'x' * 2048}</html>');
          } else {
            out.add([...metadataTs(), ...List<int>.filled(2048, 0)]);
          }
        }
        await out.close();
      });
      await health.load();
      final repo = CinemaRepository(dio: client);
      Future<void> check() => checkCinemaSourceConnections(
        health,
        repo,
        [source],
        mediaProbe: CinemaMediaProbe(
          transport: CinemaMediaTransport(dio: client),
          quick: true,
          preferFullHD: true,
        ),
      );
      await check();
      expect(health.connectionLabel(source), contains('已连接'));
      expect(health.connectionLabel(source, media: true), contains('样片可读'));
      expect(health.record(source, media: true)!.firstFrameMs, isNull);
      sampleStatus = 403;
      await check();
      expect(health.record(source)!.ok, isTrue);
      expect(health.connectionLabel(source, media: true), contains('403'));
      expect(health.record(source, media: true)!.mbps, isNull);
      final previous = mediaReads;
      apiStatus = 403;
      await check();
      expect(apiReads, 3);
      expect(health.connectionLabel(source), contains('HTTP 403'));
      expect(health.connectionLabel(source, media: true), contains('本次未检测'));
      expect(mediaReads, previous);
      apiStatus = 200;
      hasSample = false;
      await check();
      expect(health.connectionLabel(source, media: true), contains('未提供可测样片'));
      expect(mediaReads, previous);
      hasSample = true;
      html = true;
      sampleStatus = 200;
      await check();
      expect(health.record(source, media: true)!.ok, isFalse);
      expect(health.connectionLabel(source, media: true), contains('网页'));
    },
  );
}
