import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_tv_media_policy.dart';

class _ManifestOrigin implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    requests.add(options);
    final master =
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="中文",URI="audio/index.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160,AUDIO="audio"\n4k/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,AUDIO="audio"\n1080/index.m3u8\n';
    return ResponseBody.fromString(
      options.uri.path.endsWith('master.m3u8')
          ? master
          : '#EXTM3U\n#EXTINF:5,\naudio.ts\n#EXT-X-ENDLIST\n',
      200,
      headers: {
        'content-type': ['application/vnd.apple.mpegurl'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'optional TV manifest policy keeps external audio and upstream headers through loopback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'tv-master-policy-',
      );
      final origin = _ManifestOrigin();
      final transport = CinemaMediaTransport(
        dio: Dio()..httpClientAdapter = origin,
      );
      final cache = CinemaMediaCache(
        directory: directory,
        transport: transport,
      );
      final client = HttpClient();
      Future<String> read(String url) async {
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close();
        expect(response.statusCode, 200);
        return response.transform(utf8.decoder).join();
      }

      try {
        final opened = (await cache.open(
          'https://media.example/title/master.m3u8',
          {'X-Fixture': 'fixture-session'},
          manifestPolicy: (text, base) async => cinemaTVSelectHlsVariant(
            text,
            base,
            base.resolve('1080/index.m3u8'),
          ),
        ))!;
        final master = await read(opened.url);
        expect(master, contains('BANDWIDTH=4000000'));
        expect(master, isNot(contains('BANDWIDTH=20000000')));
        expect(master, contains('AUDIO="audio"'));
        final audio = RegExp(
          r'#EXT-X-MEDIA:[^\n]*URI="([^"]+)"',
        ).firstMatch(master)![1]!;
        expect(audio, startsWith('http://127.0.0.1:'));
        await read(audio);
        expect(
          origin.requests.map((r) => r.uri.path),
          contains('/title/audio/index.m3u8'),
        );
        expect(
          origin.requests.every(
            (r) => r.headers['X-Fixture'] == 'fixture-session',
          ),
          true,
        );
        await opened.session.close();
      } finally {
        client.close(force: true);
        await cache.shutdown();
        cache.dispose();
        transport.dio.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
