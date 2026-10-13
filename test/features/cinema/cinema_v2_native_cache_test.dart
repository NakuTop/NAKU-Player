import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';

void main() {
  test(
    'native libmpv decodes warmed synthetic 4K HLS through the persistent cache',
    () async {
      final root = Directory(
        Platform.environment['NAKU_CACHE_NATIVE_FIXTURE']!,
      );
      final library = Platform.environment['NAKU_CACHE_MPV_LIBRARY']!;
      final cacheDir = await Directory.systemTemp.createTemp(
        'naku-native-cache-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final hits = <String, int>{};
      final ranges = <String>[];
      var allowVideo = true;
      origin.listen((request) async {
        try {
          final name = request.uri.pathSegments.single;
          if (!RegExp(r'^4k(?:-\d{3}\.ts|\.m3u8)$').hasMatch(name)) {
            request.response.statusCode = 404;
            return;
          }
          hits[name] = (hits[name] ?? 0) + 1;
          ranges.add('$name ${request.headers.value('range')}');
          if (!allowVideo && name.endsWith('.ts')) {
            request.response.statusCode = 503;
            return;
          }
          final file = File('${root.path}/$name');
          request.response.contentLength = await file.length();
          await request.response.addStream(file.openRead());
        } catch (_) {
          /* The bounded probe can close an outstanding request. */
        } finally {
          try {
            await request.response.close();
          } catch (_) {}
        }
      });
      final transport = CinemaMediaTransport(dio: Dio());
      final cache = CinemaMediaCache(directory: cacheDir, transport: transport);
      try {
        final url = 'http://127.0.0.1:${origin.port}/4k.m3u8';
        await cache.warmNext(url, const {});
        expect(hits['4k-000.ts'], 1);
        expect(cache.bytesUsed, greaterThan(1024 * 1024));
        allowVideo = false;
        final opened = (await cache.open(url, const {}))!;
        final process = await Process.start(
          'python3',
          ['test/support/native_cache_probe.py'],
          environment: {
            'DYLD_FRAMEWORK_PATH': File(
              library,
            ).parent.path.replaceFirst(RegExp(r'/Mpv\.framework(?:/.*)?$'), ''),
          },
        );
        process.stdin.write(
          jsonEncode({'library': library, 'url': opened.url}),
        );
        await process.stdin.close();
        final stdout = process.stdout.transform(utf8.decoder).join();
        final stderr = process.stderr.transform(utf8.decoder).join();
        final timer = Timer(const Duration(seconds: 22), () => process.kill());
        final result = await process.exitCode;
        timer.cancel();
        final output = await stdout;
        expect(result, 0, reason: '${await stderr}\n$output\nrequests:$ranges');
        final facts = jsonDecode(output) as Map;
        expect(facts['width'], '3840');
        expect(facts['height'], '2160');
        expect(double.parse(facts['time-pos']), greaterThan(1));
        expect(facts['audio-codec'], isNotNull);
        expect(facts['subtitleDelayReturnCode'], 0);
        expect(cache.hits, greaterThan(0));
        expect(
          hits['4k-000.ts'],
          1,
          reason:
              'The origin refuses video after warmup; decode must use cached bytes.',
        );
        final evidence = File('${root.path}/native-cache-evidence.json');
        await evidence.writeAsString(
          jsonEncode({
            'facts': facts,
            'cacheHits': cache.hits,
            'upstreamHits': hits,
            'scope':
                'Synthetic 4K HLS, headless software decode on this Mac; not installed UI or public-source acceptance.',
          }),
        );
        await opened.session.close();
      } finally {
        await cache.shutdown();
        cache.dispose();
        transport.dio.close(force: true);
        await origin.close(force: true);
        await cacheDir.delete(recursive: true);
      }
    },
    skip:
        Platform.environment['NAKU_CACHE_NATIVE_FIXTURE'] == null ||
        Platform.environment['NAKU_CACHE_MPV_LIBRARY'] == null,
    timeout: const Timeout(Duration(seconds: 40)),
  );
}
