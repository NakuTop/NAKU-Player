import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_route_probe.dart';
import 'package:kazumi/features/cinema/cinema_source_priority.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

const preferred = CinemaSource(
  id: 'maccms-juliang',
  name: '巨量资源',
  kind: CinemaSourceKind.maccms,
  url: 'https://api.juliang.live/api/provide/vod/',
);
const other = CinemaSource(
  id: 'other',
  name: 'Other',
  kind: CinemaSourceKind.maccms,
  url: 'https://other.invalid/api',
);
CinemaPlaybackCandidate candidate(int route, {bool juliang = true}) {
  final source = juliang ? preferred : other;
  return CinemaPlaybackCandidate(
    source: source,
    title: CinemaTitle(
      id: '1',
      sourceId: source.id,
      title: '同片',
      year: '2025',
      category: '电影',
      routes: const [
        CinemaRoute(
          name: 'jlm3u8',
          episodes: [
            CinemaEpisode(name: '正片', url: 'https://media.invalid/a.m3u8'),
          ],
        ),
        CinemaRoute(
          name: 'jlplayer',
          episodes: [
            CinemaEpisode(name: '正片', url: 'https://media.invalid/page'),
          ],
        ),
        CinemaRoute(
          name: 'other',
          episodes: [
            CinemaEpisode(name: '正片', url: 'https://media.invalid/other.mp4'),
          ],
        ),
      ],
    ),
    routeIndex: route,
    episodeIndex: 0,
  );
}

CinemaMediaProbeResult result(double speed, {bool ok = true}) =>
    CinemaMediaProbeResult(ok: ok, elapsedMs: 20, firstByteMs: 10, mbps: speed);

class Probe extends CinemaMediaProbe {
  Probe(this.results) : super(transport: CinemaMediaTransport(dio: Dio()));
  final Map<String, CinemaMediaProbeResult> results;
  final calls = <String>[];
  Completer<CinemaMediaProbeResult>? blocked;
  @override
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) {
    calls.add(url);
    return blocked?.future ?? Future.value(results[url]!);
  }
}

Future<CinemaPreferredMedia> resolve(CinemaPlaybackCandidate c) async => (
  url: c.routeIndex == 1 ? 'https://media.invalid/b.m3u8' : c.episode.url,
  format: VideoSourceFormat.hls,
  headers: const <String, String>{},
);
void main() {
  test(
    'preferred source outranks a faster cached low quality source while its faster endpoint wins',
    () {
      final measurements = [
        CinemaRouteMeasurement(candidate(2, juliang: false), result(900)),
        CinemaRouteMeasurement(candidate(0), result(8)),
        CinemaRouteMeasurement(candidate(1), result(30)),
      ];
      expect(
        cinemaBestSourcePriorityRoute(measurements)!.candidate.routeIndex,
        1,
      );
      expect(
        cinemaBestSourcePriorityRoute(measurements)!.candidate.source.id,
        preferred.id,
      );
    },
  );
  test(
    'one preferred failure retains the surviving endpoint; only two failures allow fallback',
    () {
      final measurements = [
        CinemaRouteMeasurement(candidate(0), result(0, ok: false)),
        CinemaRouteMeasurement(candidate(1), result(8)),
        CinemaRouteMeasurement(candidate(2, juliang: false), result(900)),
      ];
      expect(
        cinemaBestSourcePriorityRoute(measurements)!.candidate.source.id,
        preferred.id,
      );
      measurements[1] = CinemaRouteMeasurement(
        candidate(1),
        result(0, ok: false),
      );
      expect(
        cinemaBestSourcePriorityRoute(measurements)!.candidate.source.id,
        other.id,
      );
    },
  );
  test(
    'TV excludes decoder-incompatible preferred media before allowing fallback',
    () {
      final preferredResult = CinemaRouteMeasurement(candidate(0), result(5));
      final fallback = CinemaRouteMeasurement(
        candidate(2, juliang: false),
        result(20),
      );
      expect(
        cinemaBestSourcePriorityRoute([
          preferredResult,
          fallback,
        ], supported: (r) => r.mbps != 5)!.candidate.source.id,
        other.id,
      );
    },
  );
  test(
    'foreground check resolves both named endpoints and never probes a fallback source',
    () async {
      final probe = Probe({
        'https://media.invalid/a.m3u8': result(8),
        'https://media.invalid/b.m3u8': result(30),
      });
      addTearDown(() => probe.transport.dio.close(force: true));
      final checked = await CinemaPreferredRouteProbe(probe).run([
        candidate(2, juliang: false),
        candidate(0),
        candidate(1),
      ], resolve: resolve);
      expect(probe.calls.toSet(), {
        'https://media.invalid/a.m3u8',
        'https://media.invalid/b.m3u8',
      });
      expect(
        checked.resolved[candidate(1).key]!.url,
        'https://media.invalid/b.m3u8',
      );
      expect(
        cinemaBestSourcePriorityRoute(
          checked.measurements,
        )!.candidate.routeIndex,
        1,
      );
    },
  );
  test(
    'a parser failure counts as an unavailable endpoint, not an empty playable success',
    () async {
      final probe = Probe({'https://media.invalid/a.m3u8': result(8)});
      addTearDown(() => probe.transport.dio.close(force: true));
      final checked = await CinemaPreferredRouteProbe(probe).run(
        [candidate(0), candidate(1)],
        resolve: (c) => c.routeIndex == 1
            ? Future.error(StateError('page failed'))
            : resolve(c),
      );
      expect(checked.measurements.length, 2);
      expect(checked.measurements.last.usable, false);
      expect(
        cinemaBestSourcePriorityRoute(
          checked.measurements,
        )!.candidate.routeIndex,
        0,
      );
    },
  );
  test(
    'cancelled startup never starts requests and late results cannot become a selection',
    () async {
      final probe = Probe({})..blocked = Completer<CinemaMediaProbeResult>();
      addTearDown(() => probe.transport.dio.close(force: true));
      final canceled = CancelToken()..cancel();
      expect(
        (await CinemaPreferredRouteProbe(probe).run(
          [candidate(0)],
          resolve: resolve,
          cancel: canceled,
        )).measurements.every((m) => !m.usable),
        true,
      );
      expect(probe.calls, isEmpty);
      final token = CancelToken();
      final waiting = CinemaPreferredRouteProbe(
        probe,
      ).run([candidate(0), candidate(1)], resolve: resolve, cancel: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel('manual selection');
      final checked = await waiting;
      probe.blocked!.complete(result(999));
      await Future<void>.delayed(Duration.zero);
      expect(checked.measurements.every((m) => !m.usable), true);
    },
  );
  test(
    'whole preferred deadline bounds uncooperative parser without using a fallback before it ends',
    () async {
      final probe = Probe({});
      addTearDown(() => probe.transport.dio.close(force: true));
      final parser = Completer<CinemaPreferredMedia>();
      final checked = await CinemaPreferredRouteProbe(probe).run(
        [candidate(0), candidate(1)],
        resolve: (_) => parser.future,
        budget: const Duration(milliseconds: 20),
      );
      expect(checked.measurements.length, 2);
      expect(checked.measurements.every((m) => !m.usable), true);
      expect(probe.calls, isEmpty);
      parser.complete(await resolve(candidate(0)));
    },
  );
}
