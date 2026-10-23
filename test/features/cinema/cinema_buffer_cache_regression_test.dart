import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/request/core/network_config.dart';

void main() {
  late HttpServer origin;
  late Directory directory;
  late CinemaMediaCache cache;
  final data = Uint8List.fromList(List.generate(65536, (i) => i % 256));
  final hits = <String, int>{};
  bool online = true;
  Completer<void>? gate;
  Completer<void>? started;
  setUp(() async {
    online = true;
    gate = null;
    started = null;
    hits.clear();
    directory = await Directory.systemTemp.createTemp('naku-buffer-cache-');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      try {
        hits.update(request.uri.path, (n) => n + 1, ifAbsent: () => 1);
        if (!online) {
          request.response.statusCode = 503;
          return;
        }
        if (request.uri.path.endsWith('.m3u8')) {
          request.response.write(
            '#EXTM3U\n#EXTINF:10,\nseg.ts\n${request.uri.path.contains('live') ? '' : '#EXT-X-ENDLIST\n'}',
          );
          return;
        }
        if (started != null && !started!.isCompleted) started!.complete();
        await gate?.future;
        final range = RegExp(
          r'^bytes=(\d+)-(\d*)$',
        ).firstMatch(request.headers.value('range') ?? '');
        final start = range == null ? 0 : int.parse(range[1]!);
        final end = range == null || range[2]!.isEmpty
            ? data.length - 1
            : int.parse(range[2]!);
        if (range != null) {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes $start-$end/${data.length}',
          );
        }
        request.response.contentLength = end - start + 1;
        request.response.add(data.sublist(start, end + 1));
      } catch (_) {
        /* Cancelled warmup may close its HTTP request. */
      } finally {
        try {
          await request.response.close();
        } catch (_) {}
      }
    });
    cache = CinemaMediaCache(
      directory: directory,
      transport: CinemaMediaTransport(dio: Dio()),
    );
  });
  tearDown(() async {
    await cache.shutdown();
    cache.dispose();
    cache.transport.dio.close(force: true);
    await origin.close(force: true);
    await directory.delete(recursive: true);
  });
  String url(String p) => 'http://127.0.0.1:${origin.port}/$p';
  Future<Uint8List> read(String url, {String? range}) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (range != null) req.headers.set('Range', range);
      final response = await req.close();
      expect(response.statusCode, inInclusiveRange(200, 206));
      final out = BytesBuilder();
      await for (final part in response) {
        out.add(part);
      }
      return out.takeBytes();
    } finally {
      client.close(force: true);
    }
  }

  test(
    'foreground adopts an already downloading exact segment instead of cancelling and restarting it',
    () async {
      final opened = (await cache.open(url('vod.m3u8'), {}))!;
      final playlist = String.fromCharCodes(await read(opened.url));
      final media = playlist
          .split('\n')
          .firstWhere((l) => l.startsWith('http'));
      gate = Completer<void>();
      started = Completer<void>();
      final warming = cache.warmNext(url('vod.m3u8'), {});
      await started!.future.timeout(const Duration(seconds: 2));
      final foreground = read(media);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      gate!.complete();
      expect(await foreground, data);
      await warming;
      expect(hits['/seg.ts'], 1);
      await opened.session.close();
    },
  );
  test(
    'first open-ended full response is cached and later closed ranges need no network',
    () async {
      final opened = (await cache.open(url('live.m3u8'), {}))!;
      final playlist = String.fromCharCodes(await read(opened.url));
      final media = playlist
          .split('\n')
          .firstWhere((l) => l.startsWith('http'));
      expect(await read(media, range: 'bytes=0-'), data);
      online = false;
      expect(await read(media, range: 'bytes=128-255'), data.sublist(128, 256));
      expect(hits['/seg.ts'], 1);
      await opened.session.close();
    },
  );

  test(
    'automatic HLS routing stays active when disk caching is disabled',
    () async {
      await cache.shutdown();
      cache.dispose();
      cache.transport.dio.close(force: true);
      final router = CinemaMediaRouter(
        enabled: () => true,
        configuration: () => const NetworkConfig(followSystemProxy: false),
      );
      addTearDown(router.close);
      cache = CinemaMediaCache(
        directory: directory,
        preferences: const CinemaCachePreferences(enabled: false),
        transport: CinemaMediaTransport(router: router),
      );
      final opened = (await cache.open(url('live.m3u8'), {}))!;
      final manifest = String.fromCharCodes(await read(opened.url));
      final media = manifest
          .split('\n')
          .firstWhere((line) => line.startsWith('http'));
      expect(await read(media), data);
      expect(await read(media), data);
      expect(
        hits['/seg.ts'],
        2,
        reason: 'disabled disk cache must not silently persist video',
      );
      expect(cache.bytesUsed, 0);
      expect(opened.session.networkRoute, '直连');
      expect(
        await directory
            .list()
            .where((entry) => entry.path.endsWith('.bin'))
            .isEmpty,
        true,
      );
      await opened.session.close();
    },
  );
}
