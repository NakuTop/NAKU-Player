import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_route_probe.dart';
import 'package:kazumi/features/cinema/cinema_source_priority.dart';

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

void main() {
  test('user order beats provider names and later-source speed', () {
    final a = CinemaRouteMeasurement(candidate(0), result(900));
    final b = CinemaRouteMeasurement(candidate(2, juliang: false), result(2));
    expect(
      cinemaBestSourcePriorityRoute(
        [a, b],
        sourceOrder: [other.id, preferred.id],
      )!.candidate,
      b.candidate,
    );
    expect(
      cinemaBestSourcePriorityRoute(
        [b, a],
        sourceOrder: [preferred.id, other.id],
      )!.candidate,
      a.candidate,
    );
  });
  test('actual resolution wins over speed within one source', () {
    final hd = CinemaRouteMeasurement(
      candidate(0),
      const CinemaMediaProbeResult(
        ok: true,
        elapsedMs: 10,
        mbps: 900,
        width: 1920,
        height: 1080,
      ),
    );
    final uhd = CinemaRouteMeasurement(
      candidate(1),
      const CinemaMediaProbeResult(
        ok: true,
        elapsedMs: 50,
        mbps: 15,
        width: 3840,
        height: 2160,
      ),
    );
    expect(
      cinemaBestSourcePriorityRoute(
        [hd, uhd],
        sourceOrder: [preferred.id],
      )!.candidate.routeIndex,
      1,
    );
  });
  test('equal quality uses speed without changing source priority', () {
    final a = CinemaRouteMeasurement(candidate(0), result(8));
    final b = CinemaRouteMeasurement(candidate(1), result(30));
    expect(
      cinemaBestSourcePriorityRoute(
        [a, b],
        sourceOrder: [preferred.id],
      )!.candidate.routeIndex,
      1,
    );
  });
  test(
    'unavailable or decoder-incompatible source permits ordered fallback',
    () {
      final a = CinemaRouteMeasurement(candidate(0), result(0, ok: false));
      final b = CinemaRouteMeasurement(candidate(2, juliang: false), result(2));
      expect(
        cinemaBestSourcePriorityRoute(
          [a, b],
          sourceOrder: [preferred.id, other.id],
        )!.candidate.source.id,
        other.id,
      );
      expect(
        cinemaBestSourcePriorityRoute(
          [CinemaRouteMeasurement(candidate(0), result(5)), b],
          sourceOrder: [preferred.id, other.id],
          supported: (r) => r.mbps != 5,
        )!.candidate.source.id,
        other.id,
      );
    },
  );
  test(
    'unmeasured earlier source keeps its placement while comparison is pending',
    () {
      final a = candidate(0), b = candidate(2, juliang: false);
      expect(
        cinemaRecommendedCandidate(
          [b, a],
          sourceOrder: [preferred.id, other.id],
          results: {b.key: result(999)},
        ),
        a,
      );
    },
  );
}
