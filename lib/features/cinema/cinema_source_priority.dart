import 'cinema_media_transport.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_route_probe.dart';

int _quality(
  CinemaPlaybackCandidate candidate,
  CinemaMediaProbeResult? result,
) {
  if (cinemaCandidateQuality(candidate) < 0)
    return cinemaCandidateQuality(candidate);
  if ((result?.height ?? 0) > 0) return result!.height!;
  return switch (cinemaCandidateQuality(candidate)) {
    5 => 4320,
    4 => 2160,
    3 => 1080,
    2 => 720,
    1 => 480,
    final value => value,
  };
}

/// Source order, then resolution, then speed. Labels are only a fallback when
/// the actual video dimensions are not yet available.
CinemaPlaybackCandidate? cinemaRecommendedCandidate(
  Iterable<CinemaPlaybackCandidate> candidates, {
  required Iterable<String> sourceOrder,
  Map<String, CinemaMediaProbeResult> results = const {},
  bool Function(CinemaMediaProbeResult)? supported,
}) {
  final priority = {
    for (final entry in sourceOrder.toList().indexed) entry.$2: entry.$1,
  };
  final available =
      candidates
          .where((c) {
            final result = results[c.key];
            return result == null ||
                result.ok && (supported?.call(result) ?? true);
          })
          .toList()
          .indexed
          .toList()
        ..sort((a, b) {
          final source = (priority[a.$2.source.id] ?? priority.length)
              .compareTo(priority[b.$2.source.id] ?? priority.length);
          if (source != 0) return source;
          final ar = results[a.$2.key], br = results[b.$2.key];
          final quality = _quality(b.$2, br).compareTo(_quality(a.$2, ar));
          if (quality != 0) return quality;
          final speed = (br?.mbps ?? 0).compareTo(ar?.mbps ?? 0);
          if (speed != 0) return speed;
          final latency = (ar?.firstByteMs ?? 1000000).compareTo(
            br?.firstByteMs ?? 1000000,
          );
          return latency != 0 ? latency : a.$1.compareTo(b.$1);
        });
  return available.firstOrNull?.$2;
}

CinemaRouteMeasurement? cinemaBestSourcePriorityRoute(
  Iterable<CinemaRouteMeasurement> measurements, {
  required Iterable<String> sourceOrder,
  bool Function(CinemaMediaProbeResult)? supported,
}) {
  final usable = measurements.where((m) => m.usable).toList();
  final best = cinemaRecommendedCandidate(
    usable.map((m) => m.candidate),
    sourceOrder: sourceOrder,
    results: {for (final m in usable) m.candidate.key: m.result},
    supported: supported,
  );
  return usable.where((m) => m.candidate.key == best?.key).firstOrNull;
}
