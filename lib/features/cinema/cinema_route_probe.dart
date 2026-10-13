import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'cinema_media_source.dart';
import 'cinema_media_transport.dart';
import 'cinema_playback_candidates.dart';

class CinemaRouteMeasurement {
  const CinemaRouteMeasurement(this.candidate, this.result);
  final CinemaPlaybackCandidate candidate;
  final CinemaMediaProbeResult result;
  bool get usable =>
      result.ok &&
      result.mbps != null &&
      result.mbps!.isFinite &&
      result.mbps! > 0;
  bool get sufficient =>
      result.bitrate == null ||
      result.bitrate! <= 0 ||
      result.mbps! * 1000000 >= result.bitrate! * 1.3;
}

/// Rank successful video reads by sustainable bandwidth, then actual speed and
/// response time. Exact ties retain catalogue/user order. Source labels never
/// supply a synthetic speed or quality score.
CinemaRouteMeasurement? cinemaBestMeasuredRoute(
  Iterable<CinemaRouteMeasurement> measurements,
) {
  CinemaRouteMeasurement? best;
  for (final value in measurements.where((m) => m.usable)) {
    if (best == null ||
        value.sufficient && !best.sufficient ||
        value.sufficient == best.sufficient &&
            (value.result.mbps! > best.result.mbps! ||
                value.result.mbps == best.result.mbps &&
                    (value.result.firstByteMs ?? value.result.elapsedMs) <
                        (best.result.firstByteMs ?? best.result.elapsedMs))) {
      best = value;
    }
  }
  return best;
}

class CinemaRouteProbeTarget {
  CinemaRouteProbeTarget(this.url, this.headers, this.hls);
  final String url;
  final Map<String, String> headers;
  final bool hls;
  final List<CinemaPlaybackCandidate> candidates = [];
}

class CinemaRouteProbeBatch {
  CinemaRouteProbeBatch(this.probe);
  final CinemaMediaProbe probe;

  static List<CinemaRouteProbeTarget> plan(
    Iterable<CinemaPlaybackCandidate> candidates, {
    Map<String, ({String url, Map<String, String> headers, bool hls})>
        resolved =
        const {},
    int limit = 12,
  }) {
    final grouped = <String, CinemaRouteProbeTarget>{};
    final seen = <String>{};
    for (final candidate in candidates) {
      if (!seen.add(candidate.key)) continue;
      final known = resolved[candidate.key];
      if (known == null &&
          !cinemaUsesDirectMedia(
            candidate.source,
            candidate.route,
            candidate.episode,
          )) {
        continue;
      }
      final url = known?.url ?? candidate.episode.url;
      final headers = known?.headers ?? candidate.source.headers;
      final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
      if (!{'http', 'https'}.contains(Uri.tryParse(url)?.scheme)) continue;
      final hls =
          known?.hls ??
          (path.endsWith('.m3u8') ||
              !path.endsWith('.mp4') &&
                  RegExp(
                    r'm3u8|\bhls\b',
                    caseSensitive: false,
                  ).hasMatch(candidate.route.name));
      final keys = headers.keys.toList()..sort();
      final identity = jsonEncode([
        url,
        {for (final key in keys) key: headers[key]},
        hls,
      ]);
      var target = grouped[identity];
      if (target == null) {
        if (grouped.length >= limit) continue;
        target = grouped[identity] = CinemaRouteProbeTarget(url, headers, hls);
      }
      target.candidates.add(candidate);
    }
    return grouped.values.toList();
  }

  Future<List<CinemaRouteMeasurement>> run(
    List<CinemaRouteProbeTarget> targets, {
    CancelToken? cancel,
    Duration budget = const Duration(seconds: 10),
    void Function(CinemaRouteProbeTarget target, CinemaMediaProbeResult result)?
    onResult,
  }) async {
    final owned = CancelToken();
    if (cancel?.isCancelled == true) owned.cancel();
    if (cancel != null) {
      unawaited(cancel.whenCancel.then((_) => owned.cancel()));
    }
    final deadline = Timer(budget, () => owned.cancel('本轮测速时限已到'));
    final results = <String, CinemaRouteMeasurement>{};
    var next = 0;
    Future<void> worker() async {
      while (!owned.isCancelled && next < targets.length) {
        final target = targets[next++];
        CinemaMediaProbeResult? result;
        try {
          result = await Future.any<CinemaMediaProbeResult?>([
            probe.measure(
              target.url,
              target.headers,
              hls: target.hls,
              cancel: owned,
              timeout: const Duration(seconds: 6),
            ),
            owned.whenCancel.then((_) => null),
          ]);
        } catch (_) {
          result = const CinemaMediaProbeResult(
            ok: false,
            elapsedMs: 0,
            reason: '视频连接失败',
          );
        }
        if (owned.isCancelled || result == null) return;
        for (final candidate in target.candidates) {
          results[candidate.key] = CinemaRouteMeasurement(candidate, result);
        }
        onResult?.call(target, result);
      }
    }

    try {
      await Future.wait([worker(), worker()]);
      // Completion order is affected by latency; ties use the original plan.
      return [
        for (final target in targets)
          for (final candidate in target.candidates) ?results[candidate.key],
      ];
    } finally {
      deadline.cancel();
      owned.cancel();
    }
  }
}
