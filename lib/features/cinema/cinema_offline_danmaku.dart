import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'cinema_logvar_client.dart';
import 'cinema_multi_source_danmaku.dart';

const _folder = 'cinema-danmaku-v1';
String _identity(String value) => sha256.convert(utf8.encode(value)).toString();
String _encode(List<Map<String, dynamic>> rows) =>
    jsonEncode({'comments': rows});

/// A download owns an immutable snapshot. Only a small time window is decoded
/// for playback; the snapshot never competes with the evictable online cache.
class CinemaOfflineDanmaku {
  CinemaOfflineDanmaku._(this.directory, this.manifest);
  final Directory directory;
  final Map<String, dynamic> manifest;
  DateTime? get capturedAt => DateTime.tryParse('${manifest['capturedAt']}');
  Map<String, dynamic> get sources =>
      Map<String, dynamic>.from(manifest['sources'] as Map);

  static Future<CinemaOfflineDanmaku?> open(
    String episodeDirectory,
    String identity,
  ) async {
    try {
      final directory = Directory('$episodeDirectory/$_folder');
      final file = File('${directory.path}/manifest.json');
      if (!await file.exists() || await file.length() > 1024 * 1024) {
        return null;
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! Map ||
          data['version'] != 1 ||
          data['identity'] != _identity(identity) ||
          data['sources'] is! Map) {
        return null;
      }
      return CinemaOfflineDanmaku._(directory, Map<String, dynamic>.from(data));
    } catch (_) {
      return null;
    }
  }

  CinemaCombinedDanmakuTimeline timeline(Set<String> selected) {
    final combined = CinemaCombinedDanmakuTimeline()..select(selected);
    for (final id in cinemaSelectableDanmakuSources.keys) {
      final metadata = sources[id];
      if (metadata is! Map || metadata['chunks'] is! List) continue;
      final end = metadata['duration'];
      if (end is! num || !end.isFinite || end < 0 || end > 604800) continue;
      combined.add(
        id,
        CinemaLogvarSelection(
          const CinemaLogvarWork(id: 0, title: '离线弹幕'),
          const CinemaLogvarEpisode(0, '下载时快照', null),
          const [],
          end.toDouble(),
          provider: cinemaSelectableDanmakuSources[id]!,
          timeline: _DiskTimeline(
            directory,
            id,
            List.of(metadata['chunks'] as List),
            end.toDouble(),
            metadata['complete'] != true,
          ),
        ),
      );
    }
    return combined;
  }

  static Future<void> capture({
    required String episodeDirectory,
    required String identity,
    required CinemaLogvarQuery query,
    required CinemaMultiSourceDanmakuMatcher client,
    required CancelToken cancelToken,
    bool Function()? isCurrent,
  }) async {
    final capturedAt = DateTime.now().toUtc().toIso8601String();
    Directory? staging;
    void check() {
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      if (isCurrent?.call() == false) throw StateError('下载已移除');
    }

    try {
      check();
      if (await open(episodeDirectory, identity) != null) return;
      if (!await Directory(episodeDirectory).exists()) return;
      check();
      await for (final entity in Directory(
        episodeDirectory,
      ).list(followLinks: false)) {
        check();
        if (entity is Directory &&
            RegExp(
              r'^\.danmaku-[A-Za-z0-9]+$',
            ).hasMatch(entity.path.split(Platform.pathSeparator).last)) {
          await entity.delete(recursive: true);
        }
      }
      check();
      staging = await Directory(episodeDirectory).createTemp('.danmaku-');
      final selections = <String, CinemaLogvarSelection>{};
      final sources = <String, dynamic>{};
      await client.matchSources(
        query,
        sources: cinemaSelectableDanmakuSources.keys.toSet(),
        cancelToken: cancelToken,
        onSource: (result) {
          if (cancelToken.isCancelled) return;
          sources[result.id] = {'status': result.status.name};
          if (result.selection case final selection?) {
            selections[result.id] = selection;
          }
        },
      );
      check();
      for (final item in selections.entries) {
        check();
        final id = item.key, selection = item.value;
        final chunks = <Map<String, dynamic>>[];
        var complete = !selection.partial;
        final duration = math.max(
          selection.duration,
          selection.timeline?.endSeconds ??
              (selection.entries.isEmpty
                  ? 0.0
                  : selection.entries.map((e) => e.time).reduce(math.max) + 1),
        );
        if (!duration.isFinite || duration < 0 || duration > 604800) continue;
        Future<void> write(List<DanmakuEntry> entries) async {
          final valid =
              entries
                  .where(
                    (e) =>
                        e.time.isFinite &&
                        e.time >= 0 &&
                        e.time <= 604800 &&
                        e.message.isNotEmpty &&
                        e.message.length <= 120 &&
                        [1, 4, 5].contains(e.type),
                  )
                  .toList()
                ..sort((a, b) => a.time.compareTo(b.time));
          for (var offset = 0; offset < valid.length; offset += 6000) {
            check();
            final part = valid.sublist(
              offset,
              math.min(offset + 6000, valid.length),
            );
            final rows = part
                .map(
                  (e) => DanmakuEntry(
                    time: e.time,
                    message: e.message,
                    type: e.type,
                    color: e.color,
                    source: '[$id]',
                  ).toJson(),
                )
                .toList();
            final name = '$id-${chunks.length}.json';
            final text = rows.length >= 512
                ? await compute(_encode, rows)
                : _encode(rows);
            check();
            await File('${staging!.path}/$name').writeAsString(text);
            chunks.add({
              'file': name,
              'start': part.first.time,
              'end': part.last.time,
              'count': part.length,
            });
          }
        }

        try {
          if (selection.timeline case final timeline?) {
            var cursor = 0.0;
            while (cursor < duration) {
              check();
              final window = await timeline
                  .window(cursor, cancelToken: cancelToken)
                  .timeout(const Duration(seconds: 25));
              check();
              if (!window.end.isFinite ||
                  window.end <= cursor ||
                  window.start > cursor) {
                complete = false;
                break;
              }
              complete = complete && !window.partial;
              final next = math.min(duration, window.end);
              await write(
                window.entries
                    .where(
                      (e) =>
                          e.time >= cursor &&
                          (e.time < next || next == duration),
                    )
                    .toList(),
              );
              cursor = next;
            }
          } else {
            await write(selection.entries);
          }
        } catch (_) {
          check();
          complete = false;
        }
        sources[id] = {
          'status': 'loaded',
          'duration': duration,
          'complete': complete,
          'chunks': chunks,
        };
      }
      check();
      await File('${staging.path}/manifest.json').writeAsString(
        jsonEncode({
          'version': 1,
          'identity': _identity(identity),
          'capturedAt': capturedAt,
          'title': query.label,
          'sources': sources,
        }),
      );
      check();
      // Deletion waits for this job before removing the episode directory.
      await staging.rename('$episodeDirectory/$_folder');
      staging = null;
    } finally {
      client.close();
      if (staging != null && await staging.exists()) {
        await staging.delete(recursive: true);
      }
    }
  }
}

class _DiskTimeline implements CinemaDanmakuTimeline {
  _DiskTimeline(
    this.directory,
    this.id,
    this.chunks,
    this.endSeconds,
    this.partial,
  );
  final Directory directory;
  final String id;
  final List<dynamic> chunks;
  final bool partial;
  @override
  final double endSeconds;
  bool _closed = false;
  @override
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  }) async {
    final start = math.max(0.0, position - 30), end = position + 150;
    final entries = <DanmakuEntry>[];
    var missing = partial;
    for (final chunk in chunks) {
      if (_closed || cancelToken?.isCancelled == true) {
        throw StateError('离线弹幕已关闭');
      }
      if (chunk is! Map ||
          chunk['start'] is! num ||
          chunk['end'] is! num ||
          chunk['end'] < start ||
          chunk['start'] > end) {
        continue;
      }
      final name = chunk['file'];
      if (name is! String || !RegExp('^$id-[0-9]+\\.json\$').hasMatch(name)) {
        continue;
      }
      try {
        final file = File('${directory.path}/$name');
        if (await file.length() > 8 * 1024 * 1024) {
          missing = true;
          continue;
        }
        final rows = await compute(
          parseCinemaMultiSourceCache,
          await file.readAsString(),
        );
        entries.addAll(rows.where((e) => e.time >= start && e.time <= end));
      } catch (_) {
        missing = true;
      }
    }
    entries.sort((a, b) => a.time.compareTo(b.time));
    return CinemaDanmakuWindow(entries, start, end, partial: missing);
  }

  @override
  void close() => _closed = true;
}

/// One background snapshot at a time, independent of the video download queue.
/// Completed jobs remain marked for this controller's lifetime to avoid retrying
/// on every progress event. A resumed download can retry after an app restart.
class CinemaOfflineDanmakuQueue {
  final _jobs = <String, _SnapshotJob>{};
  Future<void> _tail = Future.value();
  void schedule(String key, Future<void> Function(CancelToken) capture) {
    if (_jobs.containsKey(key)) return;
    final job = _SnapshotJob();
    _jobs[key] = job;
    job.done = _tail.then((_) async {
      if (job.cancel.isCancelled) return;
      job.running = true;
      try {
        await capture(job.cancel);
      } catch (_) {
      } finally {
        job.running = false;
      }
    });
    _tail = job.done;
  }

  Future<void> cancel(String key) async {
    final job = _jobs.remove(key);
    if (job == null) return;
    job.cancel.cancel('下载已移除');
    if (job.running) await job.done;
  }
}

class _SnapshotJob {
  final cancel = CancelToken();
  bool running = false;
  Future<void> done = Future.value();
}
