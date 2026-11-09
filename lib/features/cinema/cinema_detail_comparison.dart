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
       _probe = probe ?? CinemaMediaProbe(),
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
      return;
    }
    running = true;
    final token = _token = CancelToken();
    bool current() => !_disposed && !_paused && !token.isCancelled;
    try {
      do {
        _again = false;
        final variants = catalogue.variants.toList();
        for (var i = 0; i < variants.length && current(); i += 3) {
          await Future.wait(
            variants.skip(i).take(3).map((title) async {
              try {
                await catalogue.load(title);
              } catch (_) {}
            }),
          );
          if (!current()) return;
          _anchor ??= _initialCandidate();
          notifyListeners();
        }
        if (!current()) return;
        final targets = CinemaRouteProbeBatch.plan(
          candidates.where((c) => !_checked.contains(c.key)),
          limit: 24,
        );
        for (final target in targets) {
          for (final c in target.candidates) {
            pending.add(c.key);
            _checked.add(c.key);
          }
        }
        notifyListeners();
        await CinemaRouteProbeBatch(_probe).run(
          targets,
          cancel: token,
          budget: const Duration(seconds: 45),
          onResult: (target, result) {
            if (!current()) return;
            for (final c in target.candidates) {
              results[c.key] = result;
              pending.remove(c.key);
            }
            notifyListeners();
          },
        );
        if (!current()) return;
        // A batch deadline is not evidence that an untested route is unusable.
        for (final key in pending) {
          _checked.remove(key);
        }
        pending.clear();
      } while (_again && current());
    } finally {
      running = false;
      if (identical(_token, token)) _token = null;
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
