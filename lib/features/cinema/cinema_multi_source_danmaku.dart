import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'cinema_direct_danmaku.dart';
import 'cinema_logvar_client.dart';
import 'cinema_overseas_danmaku.dart';

// Overseas sources go first in the bounded queue. They need not wait for a
// slower domestic catalogue, and neither winner cancels the other selection.
const cinemaSelectableDanmakuSources = {
  'renren': '人人视频',
  'aiyifan': '爱一帆',
  ...cinemaDirectDanmakuProviders,
};
const cinemaDanmakuSourcesPreference = 'cinemaDanmakuSourcesV1';
Set<String> cinemaDanmakuSourcesFrom(Object? value) => value is List
    ? value
          .whereType<String>()
          .where(cinemaSelectableDanmakuSources.containsKey)
          .toSet()
    : cinemaSelectableDanmakuSources.keys.toSet();

enum CinemaDanmakuSourceStatus { loading, loaded, empty, unavailable }

class CinemaDanmakuSourceResult {
  const CinemaDanmakuSourceResult(this.id, this.status, [this.selection]);
  final String id;
  final CinemaDanmakuSourceStatus status;
  final CinemaLogvarSelection? selection;
}

abstract interface class CinemaMultiSourceDanmakuMatcher
    implements CinemaDanmakuMatcher {
  Future<void> matchSources(
    CinemaLogvarQuery query, {
    required Set<String> sources,
    required void Function(CinemaDanmakuSourceResult) onSource,
    CancelToken? cancelToken,
  });
}

class _OverseasSource implements CinemaDanmakuMatcher {
  _OverseasSource(this.id) : client = CinemaOverseasDanmakuClient();
  final String id;
  final CinemaOverseasDanmakuClient client;
  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) => id == 'renren'
      ? client.matchRenren(
          query,
          cancelToken: cancelToken,
          onProgress: onProgress,
        )
      : client.matchAiyifan(
          query,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
  @override
  void close() => client.close();
}

/// One cancellable batch, at most three platform lookups at a time. Only the
/// user's selected sources are contacted. Each result can be shown immediately.
class CinemaMultiSourceDanmakuClient
    implements CinemaMultiSourceDanmakuMatcher {
  CinemaMultiSourceDanmakuClient({
    this.initialPosition = 0,
    CinemaDanmakuMatcher Function(String id)? sourceFactory,
    this.sourceTimeout = const Duration(seconds: 25),
  }) : _sourceFactory = sourceFactory;
  final double initialPosition;
  final Duration sourceTimeout;
  final CinemaDanmakuMatcher Function(String id)? _sourceFactory;
  final _clients = <CinemaDanmakuMatcher>{};
  final _batches = <CancelToken>{};
  bool _closed = false;

  CinemaDanmakuMatcher _client(String id) =>
      _sourceFactory?.call(id) ??
      (id == 'renren' || id == 'aiyifan'
          ? _OverseasSource(id)
          : CinemaDirectDanmakuClient(
              initialPosition: initialPosition,
              providers: {id},
            ));

  @override
  Future<void> matchSources(
    CinemaLogvarQuery query, {
    required Set<String> sources,
    required void Function(CinemaDanmakuSourceResult) onSource,
    CancelToken? cancelToken,
  }) async {
    if (query.title.trim().length < 2 ||
        query.title.length > 160 ||
        query.title.contains('://') ||
        RegExp(r'[/\\\r\n]').hasMatch(query.title) ||
        query.season < 1 ||
        query.episode < 1 ||
        query.episode > 5000) {
      throw const FormatException('公开片名或集数无效');
    }
    final batch = CancelToken();
    _batches.add(batch);
    CancelToken? linked = batch;
    unawaited(cancelToken?.whenCancel.then((error) => linked?.cancel(error)));
    if (cancelToken?.isCancelled == true) {
      batch.cancel(cancelToken!.cancelError);
    }
    void check() {
      if (batch.isCancelled) throw batch.cancelError!;
      if (_closed) throw StateError('弹幕请求已关闭');
    }

    var cursor = 0;
    final ids = cinemaSelectableDanmakuSources.keys
        .where(sources.contains)
        .toList();
    Future<void> worker() async {
      while (cursor < ids.length) {
        check();
        final id = ids[cursor++];
        onSource(
          CinemaDanmakuSourceResult(id, CinemaDanmakuSourceStatus.loading),
        );
        late final CinemaDanmakuMatcher client;
        try {
          client = _client(id);
        } catch (_) {
          check();
          onSource(
            CinemaDanmakuSourceResult(
              id,
              CinemaDanmakuSourceStatus.unavailable,
            ),
          );
          continue;
        }
        _clients.add(client);
        final child = CancelToken();
        CancelToken? childLink = child;
        unawaited(batch.whenCancel.then((error) => childLink?.cancel(error)));
        try {
          final result = await client
              .match(query, cancelToken: child)
              .timeout(
                sourceTimeout,
                onTimeout: () {
                  child.cancel('平台弹幕查询超时');
                  throw TimeoutException('source timeout');
                },
              );
          check();
          onSource(
            CinemaDanmakuSourceResult(
              id,
              result == null
                  ? CinemaDanmakuSourceStatus.empty
                  : CinemaDanmakuSourceStatus.loaded,
              result,
            ),
          );
          if (result?.timeline == null) {
            client.close();
            _clients.remove(client);
          }
        } catch (_) {
          child.cancel('平台弹幕查询结束');
          client.close();
          _clients.remove(client);
          check();
          onSource(
            CinemaDanmakuSourceResult(
              id,
              CinemaDanmakuSourceStatus.unavailable,
            ),
          );
        } finally {
          childLink = null;
        }
      }
    }

    try {
      check();
      await Future.any<void>([
        Future.wait(
          List.generate(math.min(3, ids.length), (_) => worker()),
        ).then<void>((_) {}),
        batch.whenCancel.then<void>((error) => throw error),
      ]);
      check();
    } finally {
      linked = null;
      _batches.remove(batch);
      batch.cancel('弹幕批次结束');
    }
  }

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    final combined = CinemaCombinedDanmakuTimeline();
    CinemaLogvarSelection? first;
    await matchSources(
      query,
      sources: cinemaSelectableDanmakuSources.keys.toSet(),
      cancelToken: cancelToken,
      onSource: (result) {
        onProgress?.call('正在获取${cinemaSelectableDanmakuSources[result.id]}弹幕');
        if (result.selection case final selection?) {
          first ??= selection;
          combined.add(result.id, selection);
        }
      },
    );
    if (first == null) return null;
    combined.select(cinemaSelectableDanmakuSources.keys.toSet());
    final window = await combined.window(
      initialPosition,
      cancelToken: cancelToken,
    );
    return CinemaLogvarSelection(
      first!.work,
      first!.episode,
      window.entries,
      combined.endSeconds,
      provider: '多源弹幕',
      timeline: combined,
      windowStart: window.start,
      windowEnd: window.end,
      partial: window.partial,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final batch in _batches) {
      batch.cancel('弹幕已关闭');
    }
    for (final client in _clients) {
      client.close();
    }
    _clients.clear();
  }
}

/// Private cache keeps provenance; the generic import parser intentionally
/// labels every imported row Local and must remain unchanged.
List<DanmakuEntry> parseCinemaMultiSourceCache(String text) {
  final data = jsonDecode(text);
  if (data is! Map || data['comments'] is! List) return [];
  final result = <DanmakuEntry>[];
  for (final row in (data['comments'] as List).take(6000)) {
    if (row is! Map || row['m'] is! String || row['p'] is! String) continue;
    final message = row['m'] as String, parts = (row['p'] as String).split(',');
    if (parts.length != 4 || message.isEmpty || message.length > 120) continue;
    final time = double.tryParse(parts[0]),
        type = int.tryParse(parts[1]),
        color = int.tryParse(parts[2]);
    if (time == null ||
        !time.isFinite ||
        time < 0 ||
        time > 604800 ||
        ![1, 4, 5].contains(type) ||
        color == null ||
        color < 0 ||
        color > 0xffffff ||
        !cinemaSelectableDanmakuSources.keys.any((id) => parts[3] == '[$id]')) {
      continue;
    }
    result.add(
      DanmakuEntry(
        time: time,
        message: message,
        type: type!,
        color: Color(0xff000000 | color),
        source: parts[3],
      ),
    );
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  return result;
}

typedef _Comment = ({
  double time,
  String message,
  int color,
  int type,
  String source,
});

// Run dense-window ordering/deduplication off the UI isolate. Fair per-source
// sampling prevents a very dense source from consuming the complete budget.
List<_Comment> _merge(List<_Comment> rows) {
  final groups = <String, List<_Comment>>{};
  for (final row in rows) {
    (groups[row.source] ??= []).add(row);
  }
  final budget = (6000 ~/ math.max(1, groups.length)).clamp(1, 6000);
  final selected = <_Comment>[];
  for (final group in groups.values) {
    group.sort((a, b) => a.time.compareTo(b.time));
    if (group.length <= budget) {
      selected.addAll(group);
    } else {
      for (var i = 0; i < budget; i++) {
        selected.add(group[i * group.length ~/ budget]);
      }
    }
  }
  selected.sort((a, b) {
    final byTime = a.time.compareTo(b.time);
    return byTime != 0 ? byTime : a.source.compareTo(b.source);
  });
  final seen = <String>{};
  return selected
      .where(
        (row) => seen.add(
          '${(row.time * 10).round()}|${row.type}|${row.message.trim()}',
        ),
      )
      .toList();
}

/// Combines bounded native windows with full-episode overseas data. Full lists
/// stay in their source; the clock and the disk cache hold only one merged window.
class CinemaCombinedDanmakuTimeline implements CinemaDanmakuTimeline {
  final _sources = <String, CinemaLogvarSelection>{};
  final _windows = <String, CinemaDanmakuWindow>{};
  Set<String> _selected = {};
  final counts = <String, int>{};
  bool _closed = false;
  bool contains(String id) => _sources.containsKey(id);
  void select(Set<String> ids) => _selected = Set.of(ids);
  void add(String id, CinemaLogvarSelection selection) {
    _sources[id] = selection;
    if (selection.timeline != null) {
      _windows[id] = CinemaDanmakuWindow(
        selection.entries,
        selection.windowStart,
        selection.windowEnd,
        partial: selection.partial,
      );
    }
  }

  @override
  double get endSeconds => _sources.values.fold(
    1.0,
    (end, s) => math.max(
      end,
      math.max(
        s.duration,
        s.timeline?.endSeconds ??
            (s.entries.isEmpty ? 0 : s.entries.last.time + 1),
      ),
    ),
  );
  @override
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  }) async {
    void check() {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (_closed) throw StateError('多源弹幕已关闭');
    }

    check();
    final start = math.max(0.0, position - 30),
        end = math.max(0.0, position) + 150;
    final ids = _sources.keys.where(_selected.contains).toList();
    final rows = <_Comment>[];
    var cursor = 0, failed = 0;
    Future<void> worker() async {
      while (cursor < ids.length) {
        check();
        final id = ids[cursor++], selection = _sources[id]!;
        List<DanmakuEntry> entries;
        if (selection.timeline case final timeline?) {
          var cached = _windows[id];
          if (cached == null ||
              position < cached.start ||
              (position >= cached.end - 30 &&
                  cached.end < timeline.endSeconds)) {
            try {
              cached = await timeline
                  .window(position, cancelToken: cancelToken)
                  .timeout(const Duration(seconds: 20));
              check();
              _windows[id] = cached;
            } catch (_) {
              check();
              failed++;
            }
          }
          entries = cached?.entries ?? const [];
          if (cached?.partial == true) failed++;
        } else {
          entries = selection.entries;
        }
        check();
        var count = 0;
        for (final entry in entries) {
          if (entry.time < start || entry.time > end) continue;
          count++;
          rows.add((
            time: entry.time,
            message: entry.message,
            color: entry.color.toARGB32(),
            type: entry.type,
            source: '[$id]',
          ));
        }
        counts[id] = count;
      }
    }

    await Future.wait(List.generate(math.min(2, ids.length), (_) => worker()));
    check();
    final merged = rows.length >= 512
        ? await compute(_merge, rows)
        : _merge(rows);
    check();
    return CinemaDanmakuWindow(
      [
        for (final row in merged)
          DanmakuEntry(
            time: row.time,
            message: row.message,
            color: Color(row.color),
            type: row.type,
            source: row.source,
          ),
      ],
      start,
      end,
      partial: failed > 0,
    );
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final source in _sources.values) {
      source.timeline?.close();
    }
    _sources.clear();
    _windows.clear();
    counts.clear();
  }
}
