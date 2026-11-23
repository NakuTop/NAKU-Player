import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/services/storage/cinema_disk_cache_files.dart';

void main() {
  late Directory root, support, temp, cacheDir, video;
  late CinemaDiskCacheFiles inventory;
  late CinemaMediaCache cache;
  const image = '12345678-abab-4aba-8def-0123456789ab.jpg';
  final hash = 'a' * 64;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('naku-total-quota-test-');
    support = Directory('${root.path}/support');
    temp = Directory('${root.path}/tmp');
    cacheDir = Directory('${root.path}/cache');
    video = Directory('${cacheDir.path}/naku-video-v2');
    inventory = CinemaDiskCacheFiles(
      support: support,
      temporary: temp,
      cache: cacheDir,
    );
    cache = CinemaMediaCache(
      directory: video,
      diskFiles: inventory,
      preferences: const CinemaCachePreferences(quotaMB: 1),
    );
  });
  tearDown(() async {
    await cache.shutdown();
    cache.dispose();
    await root.delete(recursive: true);
  });
  Future<File> write(String path, int kib, int day) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(Uint8List(kib * 1024));
    await file.setLastAccessed(DateTime.utc(2026, 1, day));
    await file.setLastModified(DateTime.utc(2026, 1, day));
    return file;
  }

  test(
    'lowering the saved quota evicts the least recently read cache and persists across launches',
    () async {
      final library = File('${root.path}/library/library.json');
      final store = CinemaStore(file: library, defaults: const []);
      await store.load();
      await cache.configure(const CinemaCachePreferences(quotaMB: 2048));
      await cache.bindHistory(store);
      final recent = await write('${support.path}/cinema/posters/$image', 1, 1);
      final stale = await write(
        '${support.path}/cinema/home-cache/catalog-$hash.json',
        1,
        2,
      );
      for (final file in [recent, stale]) {
        final handle = await file.open(mode: FileMode.append);
        await handle.truncate(70 * 1024 * 1024);
        await handle.close();
        await file.setLastModified(DateTime.utc(2026, 1, 1));
      }
      await recent.setLastAccessed(DateTime.utc(2026, 1, 6));
      await stale.setLastAccessed(DateTime.utc(2026, 1, 2));
      await cache.setTotalLimit(128);
      expect(await recent.exists(), isTrue);
      expect(await stale.exists(), isFalse);
      expect(cache.preferences.quotaMB, 128);
      await store.flush();
      final reopened = CinemaStore(file: library, defaults: const []);
      await reopened.load();
      expect(
        CinemaCachePreferences.parse(
          reopened.extras['mediaCache'] as Map,
        ).quotaMB,
        128,
      );
      reopened.dispose();
      store.dispose();
    },
  );
  test(
    'one total evicts globally oldest assets first; downloads, manual subtitles, profiles and links survive',
    () async {
      final poster = await write(
        '${support.path}/cinema/posters/$image',
        400,
        1,
      );
      final fragment = await write('${video.path}/$hash.bin', 400, 2);
      final home = await write(
        '${support.path}/cinema/home-cache/catalog-$hash.json',
        600,
        3,
      );
      final danmaku = await write(
        '${support.path}/cinema/danmaku-v1/$hash.json',
        300,
        4,
      );
      final protected = [
        for (final name in [
          'Downloads/video.mp4',
          'Downloads/.naku-danmaku/manifest.json',
          'cinema/library-v1.json',
          'cinema/subtitles-v1/$hash.json',
        ])
          await write('${support.path}/$name', 12, 1),
      ];
      await Link(
        '${support.path}/cinema/posters/${'f' * 64}.jpg',
      ).create(protected.first.path);
      await cache.initialize();
      expect(await poster.exists(), isFalse);
      expect(await fragment.exists(), isFalse);
      expect(await home.exists(), isTrue);
      expect(await danmaku.exists(), isTrue);
      for (final file in protected) {
        expect(await file.length(), 12 * 1024);
      }
      expect(cache.totalCacheBytes, 900 * 1024);
      final extra = await write(
        '${temp.path}/libCachedImageData/$image',
        300,
        5,
      );
      inventory.onWrite!();
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(await home.exists(), isFalse);
      expect(await extra.exists(), isTrue);
      expect(cache.totalCacheBytes, 600 * 1024);
    },
  );
  test(
    'an active original cache counts toward the limit and a dead session can be retired',
    () async {
      final session = await inventory.openOriginal();
      final active = await write('${session.path}/cache/chunks', 530, 1);
      final expired = await write(
        '${support.path}/cinema/posters/$image',
        600,
        2,
      );
      await cache.initialize();
      expect(await active.exists(), isTrue);
      expect(await expired.exists(), isFalse);
      expect(cache.totalCacheBytes, greaterThanOrEqualTo(530 * 1024));
      await inventory.closeOriginal(session);
      expect(await session.exists(), isFalse);
      final stale = Directory(
        '${cacheDir.path}/naku-original-v1/session-stale',
      );
      await stale.create(recursive: true);
      await File('${stale.path}/active.lock').create();
      await write('${stale.path}/cache/old', 70, 1);
      await cache.configure(const CinemaCachePreferences(quotaMB: 1));
      expect(await stale.exists(), isFalse);
      expect(cache.totalCacheBytes, 0);
    },
  );
}
