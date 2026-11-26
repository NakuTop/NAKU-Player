import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'cinema_catalog_categories.dart';
import 'cinema_models.dart';
import 'cinema_media_identity.dart';
import 'cinema_original_match.dart' show originalEpisode;
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
    this.preferFullHD = false,
    this.initialRoute = 0,
    this.initialEpisode = 0,
  }) : catalogue = CinemaPlaybackCatalogue(
         title: title,
         source: source,
         variants: variants,
         sources: sources,
         repository: repository,
       ),
       _probe = probe ?? CinemaMediaProbe.detail(preferFullHD: preferFullHD),
       _ownsProbe = probe == null,
       _initialTitle = title;

  final CinemaPlaybackCatalogue catalogue;
  final CinemaMediaProbe _probe;
  final bool _ownsProbe, preferFullHD;
  static const _quickParallelism = 2;
  static const _quickTimeout = Duration(milliseconds: 2400);
  final _quickResults = <String, CinemaMediaProbeResult>{};
  final CinemaTitle _initialTitle;
  final int initialRoute, initialEpisode;
  final results = <String, CinemaMediaProbeResult>{};
  final pending = <String>{};
  final _checked = <String>{};
  CinemaPlaybackCandidate? _anchor;
  CancelToken? _token;
  Completer<void>? _wake;
  bool _disposed = false, running = false, _again = false, _paused = false;
  List<CinemaPlaybackCandidate> get candidates => _anchor == null
      ? const []
      : catalogue
            .matching(_anchor!)
            .where((c) => c.source.id != 'douban-discovery')
            .toList();
  bool isUltraHD(CinemaPlaybackCandidate route) {
    final result = results[route.key];
    final tier = result?.confirmedQualityTier ?? 0;
    if (tier > 0) return tier >= 2160;
    if (result?.qualityEvidence == CinemaQualityEvidence.manifest &&
        ((result?.width ?? 0) >= 3840 || (result?.height ?? 0) >= 2160)) {
      return true;
    }
    return cinemaCandidateQuality(route) >= 4;
  }

  bool get fullHDProbeComplete =>
      preferFullHD && !running && _quickResults.isNotEmpty;

  CinemaPlaybackCandidate? get streaming4K => candidates
      .where((c) => isUltraHD(c) || results[c.key]?.hasUhdVariant == true)
      .firstOrNull;

  int _hdPriority(CinemaPlaybackCandidate c) =>
      switch (cinemaCandidateQuality(c)) {
        3 => 0,
        2 || 0 => 1,
        1 => 2,
        _ => 3,
      };

  CinemaPlaybackCandidate? get recommended {
    if (!preferFullHD) {
      return cinemaRecommendedCandidate(
        candidates,
        sourceOrder: catalogue.sourceOrder,
        results: results,
      );
    }
    final options = candidates.where(
      (c) => !isUltraHD(c) && results[c.key]?.ok != false,
    );
    CinemaPlaybackCandidate? best;
    for (final c in options) {
      if (best == null || _hdPriority(c) < _hdPriority(best)) best = c;
    }
    return best;
  }

  CinemaPlaybackCandidate? get measuredRecommendation {
    final options = preferFullHD
        ? candidates.where((c) => !isUltraHD(c)).toList()
        : candidates;
    if (preferFullHD || Platform.isWindows) {
      final regular = cinemaBestRegularCandidate(options, results: results);
      if (regular != null || preferFullHD) return regular;
    }
    return cinemaBestConfirmedCandidate(
      options,
      results: results,
      preferSpeed: Platform.isMacOS || Platform.isAndroid,
    );
  }

  CinemaPlaybackCandidate? measuredForSource(String id) =>
      cinemaBestConfirmedCandidate(
        candidates.where((candidate) => candidate.source.id == id),
        results: results,
        preferSpeed: Platform.isMacOS || Platform.isAndroid,
      );

  CinemaPlaybackCandidate? forVariant(CinemaTitle title) {
    final options = candidates.where((c) => c.title.key == title.key);
    return cinemaBestConfirmedCandidate(
          options,
          results: results,
          preferSpeed: Platform.isMacOS || Platform.isAndroid,
        ) ??
        options.where((c) => results.containsKey(c.key)).firstOrNull ??
        cinemaRecommendedCandidate(options, sourceOrder: catalogue.sourceOrder);
  }

  List<CinemaTitle> _episodeTitles = const [];
  List<CinemaPlaybackCandidate> _episodes = const [];
  static final _series = RegExp(r'剧|劇|动漫|動畫|动画|番剧|综艺|綜藝');
  static final _film = RegExp(r'电影|電影|片$');

  /// The visible episode list belongs to the work, even if its fastest source
  /// only carries a few episodes. Picking an episode never pins its provider.
  List<CinemaPlaybackCandidate> episodeChoices({
    CinemaPlaybackCandidate? original,
  }) {
    final titles = [
      for (final v in catalogue.variants)
        if (v.sourceId != 'douban-discovery') ?catalogue.loaded(v),
      if (original != null && original.source.id == 'douban-discovery')
        original.title,
    ];
    if (listEquals(titles, _episodeTitles)) return _episodes;
    _episodeTitles = titles;
    final expectedSeason =
        cinemaSeasonName(_initialTitle.title)?.number ??
        _initialTitle.originalReference?.season;
    final numbered = <(int, int, String), CinemaPlaybackCandidate>{};
    final named = <String, CinemaPlaybackCandidate>{};
    for (final title in titles) {
      final season =
          cinemaSeasonName(title.title)?.number ??
          title.originalReference?.season ??
          expectedSeason;
      final film = _film.hasMatch(title.category);
      final series =
          season != null ||
          cinemaVarietyCategory(title.category) ||
          !film && _series.hasMatch(title.category);
      final source = title.sourceId == 'douban-discovery'
          ? original!.source
          : catalogue.sourceFor(title);
      for (var r = 0; r < title.routes.length; r++) {
        if (cinemaHasMovieVersions(title, r)) continue;
        final items = title.routes[r].episodes;
        for (var e = 0; e < items.length; e++) {
          final label = items[e].name.trim();
          final coordinate = originalEpisode(label);
          final s = coordinate.season ?? season ?? 1;
          if (label.isEmpty || expectedSeason != null && s != expectedSeason) {
            continue;
          }
          final part = cinemaPlaybackEpisodePart(label);
          final number = coordinate.episode;
          CinemaPlaybackCandidate candidate() => CinemaPlaybackCandidate(
            title: title,
            source: source,
            routeIndex: r,
            episodeIndex: e,
          );
          if (number != null &&
              number > 0 &&
              (!film || series || int.tryParse(label) == null)) {
            numbered.putIfAbsent((s, number, part), candidate);
          } else if (part.isNotEmpty ||
              series &&
                  items.length > 1 &&
                  cinemaVersionQuality(label) == 0 &&
                  !const {'正片', '播放'}.contains(label)) {
            named.putIfAbsent(
              '$s/${cinemaIdentityTypography(label).toLowerCase()}',
              candidate,
            );
          }
        }
      }
    }
    final order = numbered.keys.toList()
      ..sort((a, b) {
        final seasons = a.$1.compareTo(b.$1);
        if (seasons != 0) return seasons;
        final episodes = a.$2.compareTo(b.$2);
        return episodes == 0 ? a.$3.compareTo(b.$3) : episodes;
      });
    _episodes = [for (final key in order) numbered[key]!, ...named.values];
    return _episodes;
  }

  bool _hasPlayableRoute(CinemaTitle title) =>
      title.routes.any((route) => route.episodes.isNotEmpty);

  Future<CinemaTitle> load(CinemaTitle title, {bool retry = false}) {
    final cached = catalogue.loaded(title);
    if (retry && cached != null && !_hasPlayableRoute(cached)) {
      return catalogue.refresh(title);
    }
    return catalogue.load(title, retry: retry);
  }

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
      _quickResults.clear();
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
    final tasks = <Future<void>>{};
    final requested = <String>{};
    final queued = <CinemaRouteProbeTarget>[];
    final targets = <String, CinemaRouteProbeTarget>{};
    final completed = preferFullHD
        ? _quickResults
        : <String, CinemaMediaProbeResult>{};
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
    // of the same source.
    Iterable<CinemaPlaybackCandidate> fairCandidates() sync* {
      final groups = <String, List<CinemaPlaybackCandidate>>{};
      for (final candidate in candidates) {
        if (preferFullHD &&
            (isUltraHD(candidate) || cinemaCandidateQuality(candidate) < 0)) {
          continue;
        }
        groups.putIfAbsent(candidate.title.key, () => []).add(candidate);
      }
      for (final group in groups.values) {
        group.sort(
          (a, b) => preferFullHD
              ? _hdPriority(a).compareTo(_hdPriority(b))
              : cinemaCandidateQuality(b).compareTo(cinemaCandidateQuality(a)),
        );
      }
      for (var round = 0; groups.values.any((g) => g.length > round); round++) {
        if (preferFullHD && round > 0 && catalogue.unread.isNotEmpty) break;
        final row = groups.values
            .where((g) => round < g.length)
            .map((g) => g[round]);
        if (preferFullHD) {
          final roundCandidates = row.indexed.toList()
            ..sort((a, b) {
              final order = _hdPriority(a.$2).compareTo(_hdPriority(b.$2));
              return order == 0 ? a.$1.compareTo(b.$1) : order;
            });
          yield* roundCandidates.map((entry) => entry.$2);
        } else {
          yield* row;
        }
      }
    }

    try {
      while (current()) {
        _wake = Completer<void>();
        _again = false;
        for (final title in catalogue.variants) {
          if (requested.contains(title.key)) continue;
          final cached = catalogue.loaded(title);
          if (cached != null && (!refresh || _hasPlayableRoute(cached))) {
            requested.add(title.key);
            continue;
          }
          if (loading >= 3) continue;
          requested.add(title.key);
          loading++;
          launch(() async {
            try {
              await load(title, retry: refresh);
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
          limit: candidates.length,
        );
        for (final next in additions) {
          final existing = targets[next.identity];
          final target = existing ?? next;
          if (existing == null && !completed.containsKey(next.identity)) {
            if (preferFullHD &&
                measuring + queued.length >= _quickParallelism) {
              continue;
            }
            targets[next.identity] = next;
            queued.add(next);
          } else if (existing != null) {
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
                budget: preferFullHD
                    ? _quickTimeout
                    : const Duration(seconds: 10),
                probeTimeout: preferFullHD
                    ? _quickTimeout
                    : const Duration(seconds: 9),
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
              if (current() && !completed.containsKey(target.identity)) {
                final result = CinemaMediaProbeResult(
                  ok: false,
                  elapsedMs: preferFullHD
                      ? _quickTimeout.inMilliseconds
                      : 10000,
                  reason: '连接超时',
                );
                completed[target.identity] = result;
                for (final c in target.candidates) {
                  results[c.key] = result;
                  pending.remove(c.key);
                }
              }
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
      token.cancel();
      running = false;
      if (identical(_token, token)) _token = null;
      _wake = null;
      // Only navigation cancellation leaves routes unchecked.
      _checked.removeAll(pending);
      if (!_disposed) {
        pending.clear();
        notifyListeners();
        if (_resumeAfterCancellation && !_paused) {
          _resumeAfterCancellation = false;
          unawaited(start());
        }
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

  bool _resumeAfterCancellation = false;

  void resume() {
    _paused = false;
    if (running && _token?.isCancelled == true) {
      _resumeAfterCancellation = true;
    } else {
      unawaited(start());
    }
  }

  void pause() {
    _resumeAfterCancellation = false;
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
