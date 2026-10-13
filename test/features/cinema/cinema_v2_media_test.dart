import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';

void main() {
  late Directory temp;
  late HttpServer origin;
  late CinemaMediaTransport transport;
  final hits = <String, int>{};
  final segment = Uint8List.fromList(List.generate(65536, (i) => i % 256));
  bool online = true;
  final manifests = <String, String>{
    '/master.m3u8':
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=1920x1080,AUDIO="a"\nvod.m3u8\n',
    '/vod.m3u8':
        '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXT-X-KEY:METHOD=AES-128,URI="secret.key"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:10,\nseg.ts\n#EXTINF:10,\nseg2.ts\n#EXT-X-ENDLIST\n',
    '/audio.m3u8': '#EXTM3U\n#EXTINF:10,\naudio.aac\n#EXT-X-ENDLIST\n',
    '/live.m3u8': '#EXTM3U\n#EXTINF:10,\nseg.ts\n',
    '/cdn/vod.m3u8': '#EXTM3U\n#EXTINF:10,\nseg.ts\n#EXT-X-ENDLIST\n',
    '/key-url.m3u8':
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="license"\n#EXTINF:10,\nseg.ts\n#EXT-X-ENDLIST\n',
    '/range.m3u8':
        '#EXTM3U\n#EXTINF:10,\n#EXT-X-BYTERANGE:32@16\nseg.ts\n#EXT-X-ENDLIST\n',
  };
  setUp(() async {
    online = true;
    hits.clear();
    temp = await Directory.systemTemp.createTemp('naku-cache-test-');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      try {
        if (!online || request.headers.value('X-Test') != 'required') {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        if (path == '/redirect.m3u8') {
          await request.response.redirect(Uri.parse('/cdn/vod.m3u8'));
          return;
        }
        if (path == '/error.mp4') {
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode({'error': 'x' * 2048}));
          return;
        }
        if (path == '/trickle.mp4') {
          for (var i = 0; i < 20; i++) {
            request.response.add(segment.sublist(0, 512));
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return;
        }
        if (path == '/slow.mp4') {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        final manifest = manifests[path];
        if (manifest != null) {
          request.response.write(manifest);
        } else {
          final range = request.headers.value('range'),
              match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
          if (match != null) {
            final start = int.parse(match[1]!),
                end = int.parse(match[2]!).clamp(0, segment.length - 1);
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/${segment.length}',
            );
            request.response.add(segment.sublist(start, end + 1));
          } else {
            request.response.add(segment);
          }
        }
      } catch (_) {
        /* Client cancellation is expected. */
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    transport = CinemaMediaTransport(
      dio: Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 1),
          receiveTimeout: const Duration(seconds: 2),
        ),
      ),
    );
  });
  tearDown(() async {
    transport.dio.close(force: true);
    await origin.close(force: true);
    await temp.delete(recursive: true);
  });
  String url(String path) => 'http://127.0.0.1:${origin.port}$path';
  const headers = {'X-Test': 'required'};
  Future<String> readText(String target) async {
    final client = HttpClient();
    try {
      final response = await (await client.getUrl(Uri.parse(target))).close();
      return await utf8.decoder.bind(response).join();
    } finally {
      client.close(force: true);
    }
  }

  Future<Uint8List> readBytes(String target, {String? range}) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse(target));
      if (range != null) request.headers.set('Range', range);
      final response = await request.close(), bytes = BytesBuilder();
      await for (final chunk in response) {
        bytes.add(chunk);
      }
      return bytes.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  test(
    'real media probe follows best variant and measures actual bytes',
    () async {
      final result = await CinemaMediaProbe(
        transport: transport,
      ).measure(url('/master.m3u8'), headers);
      expect(result.ok, true);
      expect(result.mbps, greaterThan(0));
      expect(result.width, 1920);
      expect(result.height, 1080);
      expect(result.bitrate, 500000);
      expect(hits['/seg.ts'], 1);
      expect(hits['/vod.m3u8'], 1);
    },
  );
  test(
    'probes report request failure and are cancellable on a wall-clock deadline',
    () async {
      final probe = CinemaMediaProbe(transport: transport);
      expect((await probe.measure(url('/master.m3u8'), const {})).ok, false);
      expect(
        (await probe.measure(
          url('/slow.mp4'),
          headers,
          timeout: const Duration(milliseconds: 20),
        )).ok,
        false,
      );
    },
  );
  test(
    'HLS proxy retains keys, init map and alternate audio, and reuses cached video',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      final opened = (await cache.open(url('/master.m3u8'), headers))!;
      final master = await readText(opened.url);
      expect(master, isNot(contains(origin.port.toString())));
      final audio = RegExp(r'URI="([^"]+)"').firstMatch(master)![1]!;
      expect(await readText(audio), contains('127.0.0.1'));
      final playlist = master
          .split('\n')
          .firstWhere((s) => s.startsWith('http'));
      final vod = await readText(playlist);
      final keys = RegExp(
        r'URI="([^"]+)"',
      ).allMatches(vod).map((m) => m[1]!).toList();
      expect(keys.length, 2);
      expect(await readBytes(keys.first), segment);
      final media = vod.split('\n').firstWhere((s) => s.startsWith('http'));
      expect(await readBytes(media), segment);
      final initialHits = hits['/seg.ts'];
      online = false;
      expect(await readBytes(media), segment);
      expect(hits['/seg.ts'], initialHits);
      expect(cache.hits, greaterThanOrEqualTo(1));
      expect(
        await temp.list().where((e) => e.path.endsWith('.bin')).length,
        greaterThan(0),
      );
      await opened.session.close();
      await cache.shutdown();
      cache.dispose();
    },
  );
  test(
    'persistent cache works across sessions and respects distinct headers',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      final one = (await cache.open(url('/live.m3u8'), headers))!;
      final playlist = await readText(one.url),
          media = playlist.split('\n').firstWhere((s) => s.startsWith('http'));
      expect(await readBytes(media), segment);
      await one.session.close();
      final two = (await cache.open(url('/live.m3u8'), headers))!;
      final newMedia = (await readText(
        two.url,
      )).split('\n').firstWhere((s) => s.startsWith('http'));
      final before = hits['/seg.ts'];
      online = false;
      expect(await readBytes(newMedia), segment);
      expect(hits['/seg.ts'], before);
      await two.session.close();
      await cache.shutdown();
      cache.dispose();
    },
  );
  test('byte-range segments are not confused with complete files', () async {
    final cache = CinemaMediaCache(directory: temp, transport: transport);
    final opened = (await cache.open(url('/range.m3u8'), headers))!;
    final vod = await readText(opened.url),
        media = vod.split('\n').firstWhere((s) => s.startsWith('http'));
    expect(
      await readBytes(media, range: 'bytes=16-47'),
      segment.sublist(16, 48),
    );
    online = false;
    expect(
      await readBytes(media, range: 'bytes=16-47'),
      segment.sublist(16, 48),
    );
    await opened.session.close();
    await cache.shutdown();
    cache.dispose();
  });
  test(
    'warmed complete segments serve native open ranges, suffixes and unsatisfiable ranges without upstream access',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      final opened = (await cache.open(url('/vod.m3u8'), headers))!;
      final vod = await readText(opened.url);
      final media = vod.split('\n').firstWhere((s) => s.startsWith('http'));
      expect(await readBytes(media), segment);
      final initial = hits['/seg.ts'];
      online = false;
      expect(await readBytes(media, range: 'bytes=0-'), segment);
      expect(await readBytes(media, range: 'bytes=16-'), segment.sublist(16));
      expect(
        await readBytes(media, range: 'bytes=16-47'),
        segment.sublist(16, 48),
      );
      expect(
        await readBytes(media, range: 'bytes=-32'),
        segment.sublist(segment.length - 32),
      );
      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(media));
        request.headers.set('Range', 'bytes=999999-');
        final response = await request.close();
        expect(response.statusCode, 416);
        expect(
          response.headers.value('content-range'),
          'bytes */${segment.length}',
        );
        await response.drain();
      } finally {
        client.close(force: true);
      }
      expect(hits['/seg.ts'], initial);
      await opened.session.close();
      await cache.shutdown();
      cache.dispose();
    },
  );
  test(
    'cache proxy rejects guessed endpoints and clearing does not delete media downloads',
    () async {
      final cache = CinemaMediaCache(
        directory: Directory('${temp.path}/cache'),
        transport: transport,
      );
      final opened = (await cache.open(url('/vod.m3u8'), headers))!;
      final client = HttpClient();
      final request = await client.getUrl(
        Uri.parse(opened.url).replace(path: '/not-authorized/0/0/segment'),
      );
      final response = await request.close();
      expect(response.statusCode, 404);
      await response.drain<void>();
      client.close();
      final download = File('${temp.path}/keep.mp4');
      await download.writeAsBytes(segment);
      await cache.clear();
      expect(await download.exists(), true);
      await opened.session.close();
      await cache.shutdown();
      cache.dispose();
    },
  );
  test(
    'redirected playlists resolve relative media against the final URL',
    () async {
      final probe = await CinemaMediaProbe(
        transport: transport,
      ).measure(url('/redirect.m3u8'), headers);
      expect(probe.ok, true);
      expect(hits['/cdn/seg.ts'], 1);
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      addTearDown(() async {
        await cache.shutdown();
        cache.dispose();
      });
      final opened = (await cache.open(url('/redirect.m3u8'), headers))!;
      final playlist = await readText(opened.url);
      final media = playlist
          .split('\n')
          .firstWhere((s) => s.startsWith('http'));
      expect(await readBytes(media), segment);
      expect(hits['/seg.ts'], isNull);
    },
  );
  test(
    'key URLs without a file extension are forwarded on every request',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      addTearDown(() async {
        await cache.shutdown();
        cache.dispose();
      });
      final opened = (await cache.open(url('/key-url.m3u8'), headers))!;
      final playlist = await readText(opened.url);
      final key = RegExp(r'URI="([^"]+)"').firstMatch(playlist)![1]!;
      expect(await readBytes(key), segment);
      expect(await readBytes(key), segment);
      expect(hits['/license'], 2);
    },
  );
  test(
    'byte reads have a total deadline even while small chunks keep arriving',
    () async {
      final clock = Stopwatch()..start();
      await expectLater(
        transport.bytes(
          Uri.parse(url('/trickle.mp4')),
          headers,
          timeout: const Duration(milliseconds: 70),
        ),
        throwsA(isA<DioException>()),
      );
      expect(clock.elapsedMilliseconds, lessThan(500));
    },
  );
  test('an HTTP 200 error document does not pass a video speed test', () async {
    final token = CancelToken();
    final result = await CinemaMediaProbe(
      transport: transport,
    ).measure(url('/error.mp4'), headers, cancel: token);
    expect(result.ok, false);
    expect(token.isCancelled, false);
  });
  test(
    'paused VOD prefetches ahead and the next episode can reuse a warm segment',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      addTearDown(() async {
        await cache.shutdown();
        cache.dispose();
      });
      await cache.warmNext(url('/vod.m3u8'), headers);
      expect(hits['/seg2.ts'], 1);
      final opened = (await cache.open(url('/vod.m3u8'), headers))!;
      final playlist = await readText(opened.url);
      opened.session.update(Duration.zero, buffering: false);
      final media = playlist
          .split('\n')
          .where((s) => s.startsWith('http'))
          .last;
      final before = hits['/seg2.ts'];
      online = false;
      expect(await readBytes(media), segment);
      expect(hits['/seg2.ts'], before);
    },
  );
  test(
    'cache enforces disk quota by evicting the least recently used data',
    () async {
      for (var i = 0; i < 3; i++) {
        final file = File('${temp.path}/$i.bin');
        await file.writeAsBytes(Uint8List(700000));
        await file.setLastModified(
          DateTime.now().subtract(Duration(minutes: 3 - i)),
        );
      }
      final cache = CinemaMediaCache(
        directory: temp,
        transport: transport,
        preferences: const CinemaCachePreferences(quotaMB: 1),
      );
      addTearDown(() async {
        await cache.shutdown();
        cache.dispose();
      });
      await cache.initialize();
      expect(cache.bytesUsed, lessThanOrEqualTo(1024 * 1024));
      expect(await File('${temp.path}/2.bin').exists(), true);
      expect(await File('${temp.path}/0.bin').exists(), false);
    },
  );
  test(
    'cancelled next-episode warmup cannot start a network request',
    () async {
      final cache = CinemaMediaCache(directory: temp, transport: transport);
      addTearDown(() async {
        await cache.shutdown();
        cache.dispose();
      });
      final token = CancelToken()..cancel();
      await cache.warmNext(url('/vod.m3u8'), headers, cancel: token);
      expect(hits['/vod.m3u8'], isNull);
    },
  );
}
