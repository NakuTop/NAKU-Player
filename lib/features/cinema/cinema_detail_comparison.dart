import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'cinema_models.dart';
import 'cinema_movie_versions.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_repository.dart';
import 'cinema_route_probe.dart';
import 'cinema_source_priority.dart';
import 'cinema_media_transport.dart';

/// A detail-screen session. Closing it cancels all media reads, and late
/// catalogue results cannot change a newer screen or a manual selection.
class CinemaDetailComparison extends ChangeNotifier {
  CinemaDetailComparison({
    required CinemaTitle title,
    required CinemaSource source,
    required Iterable<CinemaTitle> variants,
    required Iterable<CinemaSource> sources,
    required CinemaRepository repository,
    CinemaMediaProbe? probe,
    this.initialRoute = 0,
    this.initialEpisode = 0,
  }) : catalogue = CinemaPlaybackCatalogue(
         title: title,
         source: source,
         variants: variants,
         sources: sources,
         repository: repository,
       ),
       _probe = probe ?? CinemaMediaProbe.detail(),
       _ownsProbe = probe == null,
       _initialTitle = title;

  final CinemaPlaybackCatalogue catalogue;
  final CinemaMediaProbe _probe;
  final bool _ownsProbe;
  final CinemaTitle _initialTitle;
  final int initialRoute, initialEpisode;
  final results = <String, CinemaMediaProbeResult>{};
  final pending = <String>{};
  final _checked = <String>{};
  CinemaPlaybackCandidate? _anchor;
  CancelToken? _token;
  Completer<void>? _wake;
  bool _disposed = false, running = false, _again = false, _paused = false;
  List<CinemaPlaybackCandidate> get candidates =>
      _anchor == null ? const [] : catalogue.matching(_anchor!);
  CinemaPlaybackCandidate? get recommended => cinemaRecommendedCandidate(
    candidates,
    sourceOrder: catalogue.sourceOrder,
    results: results,
  );
  CinemaPlaybackCandidate? forVariant(CinemaTitle title) =>
      cinemaRecommendedCandidate(
        candidates.where((c) => c.title.key == title.key),
        sourceOrder: catalogue.sourceOrder,
        results: results,
      ) ??
      candidates.where((c) => c.title.key == title.key).firstOrNull;
  Future<CinemaTitle> load(CinemaTitle title, {bool retry = false}) =>
      catalogue.load(title, retry: retry);

  void addVariants(Iterable<CinemaTitle> values) {
    if (_disposed) return;
    catalogue.addVariants(values);
    unawaited(start());
  }

  Future<void> start({bool refresh = false}) async {
    if (_disposed) return;
    if (refresh) {
      _paused = false;
      _probe.invalidate();
      results.clear();
      _checked.clear();
    }
    if (_paused) return;
    if (running) {
      _again = true;
      if (_wake?.isCompleted == false) _wake!.complete();
      return;
    }
    running = true;
    final token = _token = CancelToken();
    bool current() => !_disposed && !_paused && !token.isCancelled;
    final deadline = Timer(
      const Duration(seconds: 12),
      () => token.cancel('详情检测时限已到'),
    );
    final tasks = <Future<void>>{};
    final requested = <String>{};
    final queued = <CinemaRouteProbeTarget>[];
    final targets = <String, CinemaRouteProbeTarget>{};
    final completed = <String, CinemaMediaProbeResult>{};
    var loading = 0, measuring = 0;
    void wake() {
      if (_wake?.isCompleted == false) _wake!.complete();
    }

    void launch(Future<void> Function() operation) {
      late Future<void> task;
      task = Future<void>.sync(operation).whenComplete(() {
        tasks.remove(task);
        wake();
      });
      tasks.add(task);
    }

    // One preferred edition from each source gets a turn before extra versions
    // of the same source. Recommendation still follows the user's source order.
    Iterable<CinemaPlaybackCandidate> fairCandidates() sync* {
      final groups = <String, List<CinemaPlaybackCandidate>>{};
      for (final candidate in candidates) {
        groups.putIfAbsent(candidate.title.key, () => []).add(candidate);
      }
      for (final group in groups.values) {
        group.sort(
          (a, b) =>
              cinemaCandidateQuality(b).compareTo(cinemaCandidateQuality(a)),
        );
      }
      for (var round = 0; groups.values.any((g) => g.length > round); round++) {
        for (final group in groups.values) {
          if (round < group.length) yield group[round];
        }
      }
    }

    try {
      while (current()) {
        _wake = Completer<void>();
        _again = false;
        for (final title in catalogue.variants) {
          if (requested.contains(title.key)) continue;
          if (catalogue.loaded(title) != null) {
            requested.add(title.key);
            continue;
          }
          if (loading >= 3) continue;
          requested.add(title.key);
          loading++;
          launch(() async {
            try {
              await catalogue.load(title);
            } catch (_) {
              // A slow or failed catalogue must not hold up the other sources.
            } finally {
              loading--;
            }
          });
        }
        _anchor ??= _initialCandidate();
        final additions = CinemaRouteProbeBatch.plan(
          fairCandidates().where((c) => !_checked.contains(c.key)),
          limit: 24,
        );
        for (final next in additions) {
          final existing = targets[next.identity];
          if (existing == null && targets.length >= 24) continue;
          final target = existing ?? next;
          if (existing == null) {
            targets[next.identity] = next;
            queued.add(next);
          } else {
            existing.candidates.addAll(next.candidates);
          }
          for (final c in next.candidates) {
            _checked.add(c.key);
            final result = completed[target.identity];
            if (result != null) {
              results[c.key] = result;
            } else {
              pending.add(c.key);
            }
          }
        }
        while (measuring < 3 && queued.isNotEmpty && current()) {
          final target = queued.removeAt(0);
          measuring++;
          launch(() async {
            try {
              await CinemaRouteProbeBatch(_probe).run(
                [target],
                cancel: token,
                budget: const Duration(seconds: 5),
                probeTimeout: const Duration(milliseconds: 4500),
                onResult: (_, result) {
                  if (!current()) return;
                  completed[target.identity] = result;
                  for (final c in target.candidates) {
                    results[c.key] = result;
                    pending.remove(c.key);
                  }
                  notifyListeners();
                },
              );
            } finally {
              measuring--;
            }
          });
        }
        notifyListeners();
        if (tasks.isEmpty && !_again) break;
        await Future.any([_wake!.future, token.whenCancel.then((_) {})]);
      }
    } finally {
      deadline.cancel();
      token.cancel();
      running = false;
      if (identical(_token, token)) _token = null;
      _wake = null;
      // A deadline is not evidence that an untested route is unusable.
      _checked.removeAll(pending);
      if (!_disposed) {
        pending.clear();
        notifyListeners();
      }
    }
  }

  CinemaPlaybackCandidate? _initialCandidate() {
    for (final variant in [
      _initialTitle,
      ...catalogue.variants.where((v) => v.key != _initialTitle.key),
    ]) {
      final title = catalogue.loaded(variant);
      if (title == null || title.routes.isEmpty) continue;
      final route =
          initialRoute < title.routes.length &&
              title.routes[initialRoute].episodes.isNotEmpty
          ? initialRoute
          : cinemaPreferredRoute(title);
      if (route < 0) continue;
      final episode = initialEpisode.clamp(
        0,
        title.routes[route].episodes.length - 1,
      );
      return CinemaPlaybackCandidate(
        title: title,
        source: catalogue.sourceFor(title),
        routeIndex: route,
        episodeIndex: episode,
      );
    }
    return null;
  }

  void pause() {
    _paused = true;
    _token?.cancel('离开详情对比');
  }

  @override
  void dispose() {
    _disposed = true;
    pause();
    if (_ownsProbe) _probe.transport.dio.close(force: true);
    super.dispose();
  }
}
