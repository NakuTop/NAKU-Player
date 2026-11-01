import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';

void main() {
  test(
    'usage and clear protect active title fragments, preserve other files',
    () async {
      final dir = await Directory.systemTemp.createTemp('naku-usage-');
      final cache = CinemaMediaCache(directory: dir);
      final active = File('${dir.path}/active.bin');
      final other = File('${dir.path}/other.bin');
      final download = File('${dir.path}/movie.mp4');
      await active.writeAsBytes(List.filled(100, 1));
      await other.writeAsBytes(List.filled(200, 2));
      await download.writeAsBytes([1]);
      await File('${dir.path}/owners-v1.json').writeAsString(
        jsonEncode({
          'active': ['playing'],
        }),
      );
      final opened = (await cache.open(
        'https://example.invalid/test.m3u8',
        {},
        titleKey: 'playing',
        backgroundPrefetchAllowed: false,
      ))!;
      try {
        expect(await cache.usage(), (
          totalBytes: 300,
          protectedBytes: 100,
          clearableBytes: 200,
        ));
        await cache.clear();
        expect(await active.exists(), true);
        expect(await other.exists(), false);
        expect(await download.exists(), true);
        expect(await cache.usage(), (
          totalBytes: 100,
          protectedBytes: 100,
          clearableBytes: 0,
        ));
        await opened.session.close();
        expect(await cache.usage(), (
          totalBytes: 100,
          protectedBytes: 0,
          clearableBytes: 100,
        ));
        await cache.clear();
        expect(await active.exists(), false);
        expect(await download.exists(), true);
      } finally {
        await cache.shutdown();
        cache.dispose();
        await Future<void>.delayed(Duration.zero);
        await dir.delete(recursive: true);
      }
    },
  );
}
