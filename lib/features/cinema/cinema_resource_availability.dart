import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'cinema_grouping.dart';
import 'cinema_media_identity.dart';
import 'cinema_models.dart';
import 'cinema_repository.dart';
import 'cinema_work_sources.dart';

enum CinemaResourceState {
  waiting,
  checking,
  found,
  missing,
  incomplete,
  noSources,
}

class CinemaResourceAvailability {
  const CinemaResourceAvailability({
    this.state = CinemaResourceState.waiting,
    this.variants = const [],
    this.checked = 0,
    this.total = 0,
  });
  final CinemaResourceState state;
  final List<CinemaTitle> variants;
  final int checked, total;
  bool get has4K => variants.any((t) => cinemaVariantQuality(t) > 0);
  String get label => switch (state) {
    CinemaResourceState.waiting => '待查找资源',
    CinemaResourceState.checking => '正在查找资源',
    CinemaResourceState.found => has4K ? '有资源 · 4K' : '有资源',
    CinemaResourceState.missing => '暂未找到资源',
    CinemaResourceState.incomplete => '资源查询未完成',
    CinemaResourceState.noSources => '未启用片源',
  };
}

class CinemaResourceEntry extends ValueNotifier<CinemaResourceAvailability> {
  CinemaResourceEntry() : super(const CinemaResourceAvailability());
  DateTime? completedAt;
  Future<CinemaResourceAvailability>? pending;
  final consumers = <bool Function()>[];
  bool get observed => hasListeners;
}

/// Only mounted cards enqueue work. Two work lookups at once, with the shared
/// discovery routine limiting each to three providers. Cache keys include the
/// entire enabled-source configuration, so a new URL cannot reuse old results.
class CinemaResourceAvailabilityService {
  CinemaResourceAvailabilityService(this.repository, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final CinemaRepository repository;
  final DateTime Function() _now;
  final _entries = <String, CinemaResourceEntry>{};
  final _queue = <Future<void> Function()>[];
  int _active = 0;
  bool _disposed = false;

  List<CinemaSource> _sources(Iterable<CinemaSource> sources) => sources
      .where((s) => s.enabled && s.kind == CinemaSourceKind.maccms)
      .toList();

  String _key(CinemaTitle title, Iterable<CinemaSource> sources) => jsonEncode([
    cinemaMediaTitleKey(title.title),
    title.year,
    title.doubanId,
    title.category,
    _sources(sources).map((s) => s.toJson()).toList(),
  ]);

  CinemaResourceEntry entry(CinemaTitle title, Iterable<CinemaSource> sources) {
    final key = _key(title, sources);
    // Evict only unobserved completed entries. Active cards retain their state.
    if (_entries.length >= 160 && !_entries.containsKey(key)) {
      final stale = _entries.entries
          .where((e) => !e.value.observed && e.value.pending == null)
          .map((e) => e.key)
          .toList();
      for (final key in stale.take(40)) {
        _entries.remove(key)?.dispose();
      }
    }
    return _entries.putIfAbsent(key, CinemaResourceEntry.new);
  }

  CinemaResourceAvailability? peek(
    CinemaTitle title,
    Iterable<CinemaSource> sources,
  ) => _entries[_key(title, sources)]?.value;

  Future<CinemaResourceAvailability> check(
    CinemaTitle title,
    Iterable<CinemaSource> sources, {
    bool Function()? isCurrent,
    bool force = false,
  }) {
    if (_disposed) return Future.value(const CinemaResourceAvailability());
    final selected = _sources(sources);
    final target = entry(title, selected);
    final ttl = target.value.state == CinemaResourceState.incomplete
        ? const Duration(seconds: 30)
        : const Duration(minutes: 10);
    if (!force &&
        target.completedAt != null &&
        _now().difference(target.completedAt!) < ttl) {
      return Future.value(target.value);
    }
    target.consumers.add(isCurrent ?? () => true);
    if (target.pending != null) return target.pending!;
    final done = Completer<CinemaResourceAvailability>();
    target.pending = done.future;
    bool current() => !_disposed && target.consumers.any((f) => f());
    _queue.add(() async {
      var checked = 0;
      var failed = false;
      var variants = <CinemaTitle>[];
      void publish(CinemaResourceState state) {
        if (_disposed) return;
        target.value = CinemaResourceAvailability(
          state: state,
          variants: List.unmodifiable(variants),
          checked: checked,
          total: selected.length,
        );
      }

      try {
        if (!current()) return;
        if (selected.isEmpty) {
          publish(CinemaResourceState.noSources);
          target.completedAt = _now();
          return;
        }
        publish(CinemaResourceState.checking);
        await for (final found in discoverCinemaWorkSources(
          anchor: title,
          known: const [],
          sources: selected,
          repository: repository,
          isCurrent: current,
          maxDuration: const Duration(seconds: 25),
          onSourceChecked: (_) => checked++,
          onSourceError: (_, _) {
            failed = true;
          },
        )) {
          if (!current()) break;
          // Some list APIs omit playback lines: hydrate the exact source ID
          // before claiming that a resource exists. Never probe a video here.
          final playable = <CinemaTitle>[];
          for (var item in found.where(
            (t) => t.sourceId != 'douban-discovery',
          )) {
            if (item.routes.isEmpty) {
              final source = selected
                  .where((s) => s.id == item.sourceId)
                  .firstOrNull;
              if (source == null || !current()) continue;
              try {
                item = await repository
                    .detail(source, item)
                    .timeout(const Duration(seconds: 8));
              } catch (_) {
                failed = true;
                continue;
              }
            }
            if (item.routes.any(
              (r) => r.episodes.any((e) => e.url.isNotEmpty),
            )) {
              playable.add(item);
            }
          }
          variants = orderCinemaVariants(playable, selected.map((s) => s.id));
          publish(
            variants.isEmpty
                ? CinemaResourceState.checking
                : CinemaResourceState.found,
          );
          // A positive badge needs one confirmed catalogue resource. Other
          // providers and additional editions are discovered on the detail
          // page, keeping the next visible card out of a long source queue.
          if (variants.isNotEmpty) break;
        }
        if (!current()) {
          publish(
            variants.isEmpty
                ? CinemaResourceState.waiting
                : CinemaResourceState.found,
          );
          return;
        }
        publish(
          variants.isNotEmpty
              ? CinemaResourceState.found
              : failed
              ? CinemaResourceState.incomplete
              : CinemaResourceState.missing,
        );
        target.completedAt = _now();
      } catch (_) {
        publish(
          variants.isEmpty
              ? CinemaResourceState.incomplete
              : CinemaResourceState.found,
        );
        target.completedAt = _now();
      } finally {
        target.pending = null;
        target.consumers.clear();
        done.complete(target.value);
      }
    });
    _drain();
    return done.future;
  }

  void _drain() {
    while (_active < 2 && _queue.isNotEmpty) {
      final run = _queue.removeAt(0);
      _active++;
      unawaited(
        run().whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }

  void dispose() {
    _disposed = true;
    // Queued jobs still complete their futures; they observe disposed first.
    _drain();
    // ValueNotifiers may still have mounted listeners during parent disposal;
    // let those widgets detach naturally instead of notifying disposed state.
    _entries.clear();
  }
}
