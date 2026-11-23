import 'package:dio/dio.dart';
import 'cinema_models.dart';
import 'cinema_media_transport.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_repository.dart';
import 'cinema_route_probe.dart';
import 'cinema_source_health.dart';

Future<void> checkCinemaSourceConnections(
  CinemaSourceHealth health,
  CinemaRepository repository,
  List<CinemaSource> sources, {
  CinemaMediaProbe? mediaProbe,
}) async {
  final targets = <String, CinemaRouteProbeTarget>{};
  final cancel = CancelToken(),
      probe = mediaProbe ?? CinemaMediaProbe(quick: true, preferFullHD: true);
  try {
    await health.probeAll(
      sources,
      (source) async {
        final page = await repository.probeCatalogue(source, cancel);
        final candidates = [
          for (final title in page.items.take(10))
            for (final (i, route) in title.routes.indexed)
              if (route.episodes.isNotEmpty)
                CinemaPlaybackCandidate(
                  title: title,
                  source: source,
                  routeIndex: i,
                  episodeIndex: 0,
                ),
        ];
        final target = CinemaRouteProbeBatch.plan(
          candidates,
          limit: 1,
        ).firstOrNull;
        if (target != null) targets[source.id] = target;
      },
      sample: (source) async {
        final t = targets[source.id];
        return t == null
            ? null
            : await probe.measure(
                t.url,
                t.headers,
                hls: t.hls,
                cancel: cancel,
                timeout: const Duration(seconds: 5),
              );
      },
      onCancel: () => cancel.cancel('已停止检测'),
    );
  } finally {
    if (mediaProbe == null) probe.transport.dio.close(force: true);
  }
}
