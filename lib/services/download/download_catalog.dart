import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/utils/async_serial_queue.dart';

/// A second durable index independent of Hive. Media files also carry a
/// sidecar, so an empty index after an upgrade can be rebuilt without fetching
/// videos again. Deletions have tombstones and cannot resurrect old records.
class DownloadCatalog {
  DownloadCatalog(this.directory);
  final Directory directory;
  final _writes = AsyncSerialQueue();
  static Future<DownloadCatalog> application() async => DownloadCatalog(
    Directory(
      p.join(
        (await getApplicationSupportDirectory()).path,
        'download-catalog-v1',
      ),
    ),
  );
  File _file(String key) =>
      File(p.join(directory.path, '${sha256.convert(utf8.encode(key))}.json'));

  static Map<String, dynamic> encode(DownloadRecord record) => {
    'schema': 1,
    'key': record.key,
    'id': record.bangumiId,
    'name': record.bangumiName,
    'cover': record.bangumiCover,
    'plugin': record.pluginName,
    'created': record.createdAt.millisecondsSinceEpoch,
    'media': record.mediaMetadata,
    'source': record.sourceLabel,
    'episodes': [
      for (final e in record.episodes.values)
        {
          'number': e.episodeNumber,
          'name': e.episodeName,
          'road': e.road,
          'status': e.status,
          'progress': e.progressPercent,
          'segments': e.totalSegments,
          'downloaded': e.downloadedSegments,
          'file': e.localM3u8Path,
          'directory': e.downloadDirectory,
          'url': e.networkM3u8Url,
          'page': e.episodePageUrl,
          'completed': e.completedAt?.millisecondsSinceEpoch,
          'error': e.errorMessage,
          'bytes': e.totalBytes,
          'headers': e.requestHeadersJson,
        },
    ],
  };

  static DownloadRecord decode(Map<String, dynamic> data) {
    if (data['schema'] != 1 ||
        data['episodes'] is! List ||
        (data['episodes'] as List).length > 100000) {
      throw const FormatException('不支持的本地下载索引');
    }
    final record = DownloadRecord(
      data['id'] as int,
      data['name'] as String,
      data['cover'] as String,
      data['plugin'] as String,
      {},
      DateTime.fromMillisecondsSinceEpoch(data['created'] as int),
      mediaMetadata: data['media'] as String? ?? '',
      sourceLabel: data['source'] as String? ?? '',
    );
    if (record.key != data['key']) throw const FormatException('下载索引身份不符');
    for (final raw in data['episodes'] as List) {
      final e = Map<String, dynamic>.from(raw as Map);
      final episode = DownloadEpisode(
        e['number'] as int,
        e['name'] as String,
        e['road'] as int,
        e['status'] as int,
        (e['progress'] as num).toDouble(),
        e['segments'] as int,
        e['downloaded'] as int,
        e['file'] as String,
        e['directory'] as String,
        e['url'] as String,
        e['completed'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(e['completed'] as int),
        e['error'] as String? ?? '',
        e['bytes'] as int,
        e['page'] as String,
        requestHeadersJson: e['headers'] as String? ?? '',
      );
      record.episodes[episode.episodeNumber] = episode;
    }
    return record;
  }

  Future<void> _atomic(File file, Map<String, dynamic> value) async {
    await file.parent.create(recursive: true);
    // Previous successfully written metadata survives an interrupted write.
    if (await file.exists()) await file.copy('${file.path}.previous');
    final pending = File('${file.path}.pending');
    await pending.writeAsString(jsonEncode(value), flush: true);
    await pending.rename(file.path);
  }

  Future<void> save(DownloadRecord record) => _writes.run(() async {
    final data = encode(record);
    await _atomic(_file(record.key), data);
    final tombstone = File('${_file(record.key).path}.deleted');
    if (await tombstone.exists()) await tombstone.delete();
    final parents = record.episodes.values
        .where((e) => e.downloadDirectory.isNotEmpty)
        .map((e) => p.dirname(e.downloadDirectory))
        .toSet();
    for (final parent in parents) {
      if (await Directory(parent).exists() &&
          p.basename(parent) == '${record.bangumiId}_${record.pluginName}' &&
          !await FileSystemEntity.isLink(parent)) {
        await _atomic(File(p.join(parent, 'naku-download.json')), data);
      }
    }
  });

  Future<void> remove(String key) => _writes.run(() async {
    final deleted = {'schema': 1, 'key': key, 'deleted': true};
    // Keep the deletion separate from the recoverable previous metadata.
    await _atomic(File('${_file(key).path}.deleted'), deleted);
    await _atomic(_file(key), deleted);
  });

  Future<List<DownloadRecord>> recover(Iterable<String> roots) async {
    final found = <String, DownloadRecord>{};
    final deleted = <String>{};
    if (await directory.exists()) {
      await for (final f in directory.list(followLinks: false)) {
        if (f is File && f.path.endsWith('.deleted')) {
          try {
            final marker = jsonDecode(await f.readAsString()) as Map;
            deleted.add(marker['key'] as String);
          } catch (_) {
            /* Never interpret unreadable metadata as a deletion. */
          }
        }
        if (f is! File || !f.path.endsWith('.json')) continue;
        try {
          final data =
              jsonDecode(await f.readAsString()) as Map<String, dynamic>;
          if (data['deleted'] == true) {
            deleted.add(data['key'] as String);
          } else {
            final r = decode(data);
            found[r.key] = r;
          }
        } catch (_) {
          try {
            final r = decode(
              jsonDecode(await File('${f.path}.previous').readAsString())
                  as Map<String, dynamic>,
            );
            found[r.key] = r;
          } catch (_) {
            /* A damaged sidecar never removes the media. */
          }
        }
      }
    }
    for (final root in roots.toSet()) {
      final base = Directory(root);
      if (!await base.exists()) continue;
      await for (final folder in base.list(followLinks: false)) {
        if (folder is! Directory) continue;
        final match = RegExp(
          r'^(\d+)_(.+)$',
        ).firstMatch(p.basename(folder.path));
        if (match == null) continue;
        final id = int.parse(match[1]!);
        final plugin = match[2]!;
        final key = '${plugin}_$id';
        if (deleted.contains(key)) continue;
        DownloadRecord? record = found[key];
        if (record == null) {
          try {
            record = decode(
              jsonDecode(
                    await File(
                      p.join(folder.path, 'naku-download.json'),
                    ).readAsString(),
                  )
                  as Map<String, dynamic>,
            );
            if (record.key != key) record = null;
          } catch (_) {
            /* Legacy downloads have no sidecar. */
          }
        }
        record ??= DownloadRecord(
          id,
          '本地作品 $id',
          '',
          plugin,
          {},
          (await folder.stat()).modified,
          sourceLabel: '$plugin · 本地恢复',
        );
        await for (final episodeDir in folder.list(followLinks: false)) {
          if (episodeDir is! Directory) continue;
          final number = int.tryParse(p.basename(episodeDir.path));
          if (number == null || number < 1) continue;
          final existing = record.episodes[number];
          final local = await findVideo(episodeDir);
          if (local == null) continue;
          if (existing != null) {
            existing.downloadDirectory = episodeDir.path;
            existing.localM3u8Path = local.path;
            // A pending/failed task is not automatically declared complete.
            continue;
          }
          record.episodes[number] = DownloadEpisode(
            number,
            '第$number集（本地恢复，集号待核对）',
            0,
            DownloadStatus.completed,
            1,
            1,
            1,
            local.path,
            episodeDir.path,
            '',
            (await local.stat()).modified,
            '由现有文件恢复，原始集号尚未核对',
            await local.length(),
            '',
          );
        }
        if (record.episodes.isNotEmpty) found[key] = record;
      }
    }
    found.removeWhere((key, _) => deleted.contains(key));
    for (final record in found.values) {
      for (final episode in record.episodes.values) {
        if (episode.status == DownloadStatus.completed) {
          final local = episode.downloadDirectory.isEmpty
              ? null
              : await findVideo(Directory(episode.downloadDirectory));
          if (local == null) {
            episode.status = DownloadStatus.paused;
            episode.errorMessage = '下载记录已恢复，视频尚未找到；请重新连接原下载目录';
          } else {
            episode.localM3u8Path = local.path;
          }
        } else {
          episode.status = DownloadStatus.paused;
        }
      }
    }
    return found.values.toList();
  }

  static Future<File?> findVideo(
    Directory directory, {
    bool includeRejected = false,
  }) async {
    if (!includeRejected) {
      try {
        final marker =
            jsonDecode(
                  await File(
                    p.join(directory.path, '.naku-content.json'),
                  ).readAsString(),
                )
                as Map;
        if (marker['duplicateOf'] != null) return null;
      } catch (_) {
        /* Legacy downloads have no content marker. */
      }
    }
    for (final name in [
      'master.m3u8',
      'playlist.m3u8',
      'video.mp4',
      'video.mkv',
      'video.mov',
      'video.webm',
      'video.m4v',
      'video.ts',
    ]) {
      final f = File(p.join(directory.path, name));
      if (await FileSystemEntity.isLink(f.path) ||
          !await f.exists() ||
          await f.length() == 0) {
        continue;
      }
      if (name.endsWith('.m3u8')) {
        if (!await _completePlaylist(f, {})) continue;
      } else if (name.endsWith('.mp4') ||
          name.endsWith('.mov') ||
          name.endsWith('.m4v')) {
        if (!await _completeMp4(f)) continue;
      }
      return f;
    }
    return null;
  }

  static Future<bool> _completeMp4(File file) async {
    final input = await file.open();
    try {
      final length = await input.length();
      var offset = 0, count = 0;
      var movie = false, media = false;
      while (offset + 8 <= length && count++ < 1000) {
        await input.setPosition(offset);
        final header = await input.read(8);
        var size = ByteData.sublistView(header).getUint32(0);
        final type = ascii.decode(header.sublist(4), allowInvalid: true);
        var headerSize = 8;
        if (size == 1) {
          final extended = await input.read(8);
          if (extended.length != 8) return false;
          size = ByteData.sublistView(extended).getUint64(0);
          headerSize = 16;
        } else if (size == 0) {
          size = length - offset;
        }
        if (size < headerSize || offset + size > length) return false;
        movie |= type == 'moov';
        media |= type == 'mdat';
        offset += size;
      }
      return movie && media && offset == length;
    } finally {
      await input.close();
    }
  }

  static Future<bool> _completePlaylist(File f, Set<String> visited) async {
    if (!visited.add(f.path) ||
        visited.length > 10 ||
        !await f.exists() ||
        await FileSystemEntity.isLink(f.path)) {
      return false;
    }
    final text = await f.readAsString();
    if (!text.startsWith('#EXTM3U')) return false;
    final refs = <String>[];
    for (final line in const LineSplitter().convert(text)) {
      if (line.isEmpty) continue;
      if (!line.startsWith('#')) refs.add(line.trim());
      refs.addAll(RegExp(r'URI="([^"]+)"').allMatches(line).map((m) => m[1]!));
    }
    if (refs.isEmpty) return false;
    for (final ref in refs) {
      if (Uri.tryParse(ref)?.hasScheme != false || p.isAbsolute(ref)) {
        return false;
      }
      final path = p.normalize(p.join(f.parent.path, ref));
      if (!p.isWithin(f.parent.path, path) ||
          await FileSystemEntity.isLink(path)) {
        return false;
      }
      final part = File(path);
      if (!await part.exists() || await part.length() == 0) return false;
      if (ref.endsWith('.m3u8') && !await _completePlaylist(part, visited)) {
        return false;
      }
    }
    return text.contains('#EXT-X-STREAM-INF') ||
        text.contains('#EXT-X-ENDLIST');
  }
}

abstract interface class DownloadRecordRecovery {
  Future<int> recoverLocalRecords();
}
