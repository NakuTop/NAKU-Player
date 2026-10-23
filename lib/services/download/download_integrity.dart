import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:kazumi/utils/async_serial_queue.dart';
import 'package:kazumi/services/download/download_catalog.dart';

class DuplicateDownloadException implements Exception {
  const DuplicateDownloadException(this.episode);
  final String episode;
  @override
  String toString() => '视频内容与第$episode集相同，已阻止重复完成。重试将重新解析；也可更换线路。现有视频已保留。';
}

class DownloadIntegrity {
  static final _commits = AsyncSerialQueue();
  static Future<String> _hash(String path) => Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString(),
  );

  /// Serialize verification and commit so two simultaneous identical downloads
  /// cannot both pass before the other has appeared on disk.
  static Future<void> commitFile(File staged, File destination) =>
      _commits.run(() async {
        final length = await staged.length();
        final digest = await _hash(staged.path);
        final root = destination.parent.parent;
        await for (final folder in root.list(followLinks: false)) {
          if (folder is! Directory ||
              folder.path == destination.parent.path ||
              int.tryParse(p.basename(folder.path)) == null) {
            continue;
          }
          await for (final other in folder.list(followLinks: false)) {
            if (other is! File ||
                !p.basename(other.path).startsWith('video.') ||
                other.path.endsWith('.tmp') ||
                await other.length() != length) {
              continue;
            }
            if (await _hash(other.path) == digest) {
              throw DuplicateDownloadException(p.basename(folder.path));
            }
          }
        }
        if (await FileSystemEntity.isLink(destination.path)) {
          throw const FileSystemException('视频目标是符号链接，已保留原文件');
        }
        if (await destination.exists()) {
          if (await destination.length() != length ||
              await _hash(destination.path) != digest) {
            throw const FileSystemException('此集已有不同的视频，已保留原文件，请先核对');
          }
          await staged
              .delete(); // Only the redundant staging file from this task.
          return;
        }
        await staged.rename(destination.path);
      });

  static Future<void> verifyHls(Directory directory) => _commits.run(() async {
    final current = await _hlsFingerprint(directory, refresh: true);
    if (current == null) throw const FormatException('本地视频分片尚未完整');
    await for (final sibling in directory.parent.list(followLinks: false)) {
      if (sibling is! Directory ||
          sibling.path == directory.path ||
          int.tryParse(p.basename(sibling.path)) == null) {
        continue;
      }
      try {
        // Validate the actual files before trusting a marker. This also covers
        // downloads made by older versions, which have no marker at all.
        final other = await _hlsFingerprint(sibling);
        if (other != null && other['sha256'] == current['sha256']) {
          await _writeHlsMarker(directory, {
            ...current,
            'duplicateOf': p.basename(sibling.path),
          });
          throw DuplicateDownloadException(p.basename(sibling.path));
        }
      } on DuplicateDownloadException {
        rethrow;
      } catch (_) {
        /* Unreadable or incomplete sibling media remains untouched. */
      }
    }
  });

  static Future<Map<String, dynamic>?> _hlsFingerprint(
    Directory directory, {
    bool refresh = false,
  }) async {
    final video = await DownloadCatalog.findVideo(
      directory,
      includeRejected: refresh,
    );
    if (video == null || !video.path.endsWith('.m3u8')) return null;
    final files = <File>[];
    for (final dir in [directory, Directory(p.join(directory.path, 'audio'))]) {
      if (!await dir.exists() || await FileSystemEntity.isLink(dir.path)) {
        continue;
      }
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File &&
            RegExp(
              r'^(seg_\d+\.ts|init_\d+\.mp4|key_\d+\.key)$',
            ).hasMatch(p.basename(entry.path))) {
          files.add(entry);
        }
      }
    }
    if (files.isEmpty) return null;
    files.sort((a, b) => a.path.compareTo(b.path));
    final stats = <List<Object>>[];
    for (final file in files) {
      final stat = await file.stat();
      stats.add([
        p.relative(file.path, from: directory.path),
        stat.size,
        stat.modified.microsecondsSinceEpoch,
      ]);
    }
    final manifest = jsonEncode(stats);
    if (!refresh) {
      final marker = File(p.join(directory.path, '.naku-content.json'));
      try {
        if (!await FileSystemEntity.isLink(marker.path)) {
          final cached = jsonDecode(await marker.readAsString()) as Map;
          if (cached['schema'] == 2 &&
              cached['manifest'] == manifest &&
              cached['sha256'] is String) {
            return Map<String, dynamic>.from(cached);
          }
        }
      } catch (_) {
        /* Rebuild the cache from media, never infer media from the cache. */
      }
    }
    final paths = files.map((f) => f.path).toList();
    // Stream on a worker isolate: a full season never becomes an in-memory
    // byte array. Include initialization, encryption keys and external audio.
    final digest = await Isolate.run(() async {
      final parts = <String>[];
      for (var i = 0; i < paths.length; i++) {
        final hash = (await sha256.bind(File(paths[i]).openRead()).first)
            .toString();
        parts.add('${stats[i][0]}:${stats[i][1]}:$hash');
      }
      return sha256.convert(utf8.encode(jsonEncode(parts))).toString();
    });
    final result = <String, dynamic>{
      'schema': 2,
      'manifest': manifest,
      'sha256': digest,
    };
    await _writeHlsMarker(directory, result);
    return result;
  }

  static Future<void> _writeHlsMarker(
    Directory directory,
    Map<String, dynamic> marker,
  ) async {
    final file = File(p.join(directory.path, '.naku-content.json'));
    final pending = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.pending',
    );
    await pending.writeAsString(jsonEncode(marker), flush: true);
    await pending.rename(file.path);
  }
}
