import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';

// Hold real enumeration while another player registers its segment.
class _PausedDirectory implements Directory {
  _PausedDirectory(this.inner);
  final Directory inner;
  bool pause = false;
  final scanning = Completer<void>();
  final release = Completer<void>();
  @override
  String get path => inner.path;
  @override
  Future<Directory> create({bool recursive = false}) =>
      inner.create(recursive: recursive);
  @override
  Future<bool> exists() => inner.exists();
  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) async* {
    if (pause) {
      pause = false;
      scanning.complete();
      await release.future;
    }
    yield* inner.list(recursive: recursive, followLinks: followLinks);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'clear rechecks playback registered during directory enumeration',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'naku-clear-new-player-',
      );
      final directory = _PausedDirectory(dir);
      final cache = CinemaMediaCache(
        directory: directory,
        preferences: const CinemaCachePreferences(quotaMB: 1),
      );
      try {
        await cache.initialize();
        final uri = Uri.parse('https://example.invalid/new.ts');
        final key = sha256
            .convert(
              utf8.encode(
                jsonEncode([uri.toString(), <String, String>{}, null]),
              ),
            )
            .toString();
        final file = File('${dir.path}/$key.bin');
        await file.writeAsBytes(List.filled(2 * 1024 * 1024, 5));
        directory.pause = true;
        final clearing = cache.clear();
        await directory.scanning.future;
        final opened = await cache.open(
          'https://example.invalid/new.m3u8',
          {},
          backgroundPrefetchAllowed: false,
        );
        opened!.session.register(uri);
        directory.release.complete();
        await clearing;
        expect(
          await file.exists(),
          true,
          reason: 'Deletion and trailing quota pruning protect the new player',
        );
        expect((await cache.usage()).protectedBytes, 2 * 1024 * 1024);
        await opened.session.close();
        expect(await file.exists(), false);
      } finally {
        if (!directory.release.isCompleted) directory.release.complete();
        await cache.shutdown();
        cache.dispose();
        await Future<void>.delayed(Duration.zero);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'clear preserves active fragments even when they exceed quota',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'naku-storage-protection-',
      );
      final cache = CinemaMediaCache(
        directory: dir,
        preferences: const CinemaCachePreferences(quotaMB: 1),
      );
      try {
        await cache.initialize();
        final playback = await cache.open(
          'https://example.invalid/movie.m3u8',
          {},
          backgroundPrefetchAllowed: false,
        );
        final segment = Uri.parse('https://example.invalid/part.ts');
        playback!.session.register(segment);
        final key = sha256
            .convert(
              utf8.encode(
                jsonEncode([segment.toString(), <String, String>{}, null]),
              ),
            )
            .toString();
        final active = File('${dir.path}/$key.bin');
        await active.writeAsBytes(List.filled(2 * 1024 * 1024, 7));
        final unused = File('${dir.path}/unused.bin');
        await unused.writeAsBytes(List.filled(128, 1));
        final download = File('${dir.path}/user-download.mp4');
        await download.writeAsBytes([9, 8, 7]);
        expect(await cache.usage(), (
          totalBytes: 2 * 1024 * 1024 + 128,
          protectedBytes: 2 * 1024 * 1024,
          clearableBytes: 128,
        ));
        await cache.clear();
        expect(await active.exists(), isTrue);
        expect(await unused.exists(), isFalse);
        expect(await download.readAsBytes(), [9, 8, 7]);
        expect((await cache.usage()).protectedBytes, 2 * 1024 * 1024);
        await playback.session.close();
        expect(
          await active.exists(),
          isFalse,
          reason: 'Quota may reclaim the fragment once playback releases it',
        );
      } finally {
        await cache.shutdown();
        cache.dispose();
        await Future<void>.delayed(Duration.zero);
        await dir.delete(recursive: true);
      }
    },
  );
}
