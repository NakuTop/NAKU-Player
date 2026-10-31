import 'dart:async';
import 'package:dio/dio.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'cinema_grouping.dart';
import 'cinema_models.dart';
import 'cinema_media_transport.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_route_probe.dart';

bool cinemaPrefersSource(CinemaSource source) =>
    source.kind == CinemaSourceKind.maccms &&
    (source.id == 'maccms-juliang' ||
        Uri.tryParse(source.url)?.host.toLowerCase() == 'api.juliang.live');

/// These are the provider's two real playback endpoints, not two API hosts.
bool cinemaPreferredEndpoint(CinemaPlaybackCandidate candidate) =>
    cinemaPrefersSource(candidate.source) &&
    const {
      'jlm3u8',
      'jlplayer',
    }.contains(candidate.route.name.trim().toLowerCase());

List<CinemaPlaybackCandidate> cinemaPreferredEndpoints(
  Iterable<CinemaPlaybackCandidate> candidates,
) {
  final choices = candidates.where(cinemaPreferredEndpoint).toList();
  if (choices.isEmpty) return const [];
  // Ordinary/4K variants stay separate source records. Choose the strongest
  // catalogue variant before comparing its two endpoints, not another source.
  var title = choices.first.title;
  for (final candidate in choices.skip(1)) {
    if (cinemaVariantQuality(candidate.title) > cinemaVariantQuality(title)) {
      title = candidate.title;
    }
  }
  final seen = <String>{};
  return choices
      .where(
        (c) => c.title.key == title.key && seen.add(c.route.name.toLowerCase()),
      )
      .take(2)
      .toList();
}

CinemaRouteMeasurement? cinemaBestSourcePriorityRoute(
  Iterable<CinemaRouteMeasurement> measurements, {
  bool Function(CinemaMediaProbeResult)? supported,
  CinemaRouteMeasurement? Function(Iterable<CinemaRouteMeasurement>)? fallback,
}) {
  final usable = measurements
      .where((m) => m.usable && (supported?.call(m.result) ?? true))
      .toList();
  final preferred = usable.where((m) => cinemaPreferredEndpoint(m.candidate));
  if (preferred.isNotEmpty) return cinemaBestMeasuredRoute(preferred);
  return (fallback ?? cinemaBestMeasuredRoute)(usable);
}

typedef CinemaPreferredMedia = ({
  String url,
  VideoSourceFormat format,
  Map<String, String> headers,
});

class CinemaPreferredProbeResult {
  const CinemaPreferredProbeResult(this.measurements, this.resolved);
  final List<CinemaRouteMeasurement> measurements;
  final Map<String, CinemaPreferredMedia> resolved;
}

/// Foreground startup check. Only the two confirmed preferred endpoints may
/// navigate a resolver here; ordinary background probes remain direct-only.
class CinemaPreferredRouteProbe {
  const CinemaPreferredRouteProbe(this.probe);
  final CinemaMediaProbe probe;

  Future<CinemaPreferredProbeResult> run(
    Iterable<CinemaPlaybackCandidate> candidates, {
    required Future<CinemaPreferredMedia> Function(CinemaPlaybackCandidate)
    resolve,
    CancelToken? cancel,
    Duration budget = const Duration(seconds: 10),
  }) async {
    final choices = cinemaPreferredEndpoints(candidates);
    final owned = CancelToken();
    if (cancel?.isCancelled == true) owned.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => owned.cancel()));
    }
    final deadline = Timer(budget, () => owned.cancel('首选端检查超时'));
    final resolved = <String, CinemaPreferredMedia>{};
    final results = <String, CinemaRouteMeasurement>{};
    Future<void> check(CinemaPlaybackCandidate candidate) async {
      if (owned.isCancelled) return;
      CinemaMediaProbeResult result;
      try {
        final media = await Future.any<CinemaPreferredMedia?>([
          resolve(candidate).timeout(const Duration(seconds: 6)),
          owned.whenCancel.then((_) => null),
        ]);
        if (media == null || owned.isCancelled) return;
        resolved[candidate.key] = media;
        final measured = await Future.any<CinemaMediaProbeResult?>([
          probe.measure(
            media.url,
            media.headers,
            hls:
                media.format == VideoSourceFormat.hls ||
                Uri.tryParse(media.url)?.path.toLowerCase().endsWith('.m3u8') ==
                    true,
            cancel: owned,
            timeout: const Duration(seconds: 6),
          ),
          owned.whenCancel.then((_) => null),
        ]);
        if (measured == null || owned.isCancelled) return;
        result = measured;
      } catch (_) {
        if (owned.isCancelled) return;
        result = const CinemaMediaProbeResult(
          ok: false,
          elapsedMs: 0,
          reason: '首选端未能加载',
        );
      }
      results[candidate.key] = CinemaRouteMeasurement(candidate, result);
    }

    try {
      await Future.wait(choices.map(check));
      return CinemaPreferredProbeResult([
        for (final candidate in choices)
          results[candidate.key] ??
              CinemaRouteMeasurement(
                candidate,
                const CinemaMediaProbeResult(
                  ok: false,
                  elapsedMs: 0,
                  reason: '首选端检查超时',
                ),
              ),
      ], resolved);
    } finally {
      deadline.cancel();
      owned.cancel();
    }
  }
}
