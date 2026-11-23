import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

typedef CinemaCacheFile = ({File file, FileStat stat});

/// Only disposable, app-owned paths participate. Download directories and
/// saved subtitles, settings, accounts and library databases are never scanned.
class CinemaDiskCacheFiles {
  CinemaDiskCacheFiles({
    Directory? support,
    Directory? temporary,
    Directory? cache,
  }) : _support = support,
       _temporary = temporary,
       _cache = cache;
  static final instance = CinemaDiskCacheFiles();
  Directory? _support, _temporary, _cache;
  void Function()? onWrite;
  final _sessions = <String, RandomAccessFile>{};
  int originalBytes = 0;
  static final _image = RegExp(
    r'^(?:[a-f0-9]{32,64}|[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})\.(?:jpg|jpeg|png|gif|webp|avif|heic|img|file|bmp|ico|svg)$',
    caseSensitive: false,
  );
  static final _json = RegExp(r'^[a-f0-9]{64}\.json$');
  Future<List<CinemaCacheFile>> entries() async {
    _support ??= await getApplicationSupportDirectory();
    _temporary ??= await getTemporaryDirectory();
    _cache ??= await getApplicationCacheDirectory();
    final support = _support!.path,
        temporary = _temporary!.path,
        cache = _cache!.path;
    final roots = <(String, String, RegExp)>[
      (support, 'cinema/posters', _image),
      (temporary, 'libCachedImageData', _image),
      if (temporary != cache) (cache, 'libCachedImageData', _image),
      (
        support,
        'cinema/home-cache',
        RegExp(r'^(?:catalog|resource)-[a-f0-9]{64}\.json$'),
      ),
      (
        support,
        'cinema/ratings',
        RegExp(r'^(?:ratings-v1\.json|title\.ratings\.tsv\.gz)$'),
      ),
      (support, 'cinema/danmaku-v1', _json),
      (support, 'cinema/subtitles-v1/season-v1', _json),
      (support, 'cinema/subtitles-v1/season-sources-v1', _json),
    ];
    final entries = await Isolate.run(() => _scan(roots));
    try {
      originalBytes = await _originalUsage();
    } on FileSystemException {
      // A second player can close its session while the inventory is read.
    }
    return entries;
  }

  static Future<List<CinemaCacheFile>> _scan(
    List<(String, String, RegExp)> roots,
  ) async {
    final result = <CinemaCacheFile>[];
    for (final (base, relative, pattern) in roots) {
      try {
        var path = base;
        var valid = true;
        for (final part in p.split(relative)) {
          path = p.join(path, part);
          if (FileSystemEntity.typeSync(path, followLinks: false) !=
              FileSystemEntityType.directory) {
            valid = false;
            break;
          }
        }
        if (!valid) continue;
        for (final item in Directory(path).listSync(followLinks: false)) {
          if (item is! File || !pattern.hasMatch(p.basename(item.path))) {
            continue;
          }
          final stat = item.statSync();
          if (stat.type == FileSystemEntityType.file) {
            result.add((file: item, stat: stat));
          }
        }
      } on FileSystemException {
        // Another cache can expire entries while the inventory is being read.
      }
    }
    return result;
  }

  Future<Directory> get _originalRoot async => Directory(
    p.join(
      (_cache ??= await getApplicationCacheDirectory()).path,
      'naku-original-v1',
    ),
  );

  Future<Directory> openOriginal() async {
    final parent = await _originalRoot;
    await parent.create(recursive: true);
    final root = await parent.createTemp('session-');
    final pending = File(p.join(root.path, 'opening.lock'));
    final lock = await pending.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.exclusive);
      _sessions[root.path] = lock;
      // Publish the marker only after the cross-process lock is held.
      await pending.rename(p.join(root.path, 'active.lock'));
      onWrite?.call();
      return root;
    } catch (_) {
      _sessions.remove(root.path);
      await lock.close();
      if (await root.exists()) await root.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> closeOriginal(Directory dir) async {
    final lock = _sessions.remove(dir.path);
    try {
      await dir.delete(recursive: true);
    } on PathNotFoundException {
      // The helper and app can finish their exit at the same time.
    } finally {
      await lock?.close();
      onWrite?.call();
    }
  }

  Future<int> _originalUsage() async {
    final parent = await _originalRoot;
    if (await FileSystemEntity.type(parent.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return 0;
    }
    var used = 0;
    await for (final d in parent.list(followLinks: false)) {
      if (d is! Directory || !p.basename(d.path).startsWith('session-')) {
        continue;
      }
      final guard = File(p.join(d.path, 'active.lock'));
      if (await FileSystemEntity.type(guard.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      if (!_sessions.containsKey(d.path)) {
        RandomAccessFile? handle;
        try {
          handle = await guard.open(mode: FileMode.append);
          await handle.lock(FileLock.exclusive);
          // No process owns this ephemeral torrent cache after a crash.
          await d.delete(recursive: true);
          continue;
        } on FileSystemException {
          // A different running player owns the session.
        } finally {
          await handle?.close();
        }
      }
      final data = p.join(d.path, 'cache');
      if (await FileSystemEntity.type(data, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      // Torrent files may be sparse; count allocated blocks rather than the length of the film.
      final size = await Process.run('/usr/bin/du', ['-sk', data]);
      if (size.exitCode == 0) {
        used +=
            (int.tryParse(
                  '${size.stdout}'.trim().split(RegExp(r'\s+')).first,
                ) ??
                0) *
            1024;
      }
    }
    return used;
  }
}
