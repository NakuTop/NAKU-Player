import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_route_probe.dart';

const source = CinemaSource(
  id: 'a',
  name: 'a',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.test/api',
);
const title = CinemaTitle(
  id: '1',
  sourceId: 'a',
  title: 'Movie',
  category: '电影',
  routes: [
    CinemaRoute(
      name: 'm3u8',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://example.test/video.m3u8'),
      ],
    ),
    CinemaRoute(
      name: 'alternate hls',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://example.test/video.m3u8'),
      ],
    ),
    CinemaRoute(
      name: 'mp4',
      episodes: [
        CinemaEpisode(name: '正片', url: 'https://example.test/video.mp4'),
      ],
    ),
    CinemaRoute(
      name: 'web',
      episodes: [CinemaEpisode(name: '正片', url: 'https://example.test/page')],
    ),
  ],
);
CinemaPlaybackCandidate candidate(int route) => CinemaPlaybackCandidate(
  title: title,
  source: source,
  routeIndex: route,
  episodeIndex: 0,
);
CinemaRouteMeasurement measurement(
  int route,
  double speed, {
  bool ok = true,
  int? bitrate,
  int delay = 50,
}) => CinemaRouteMeasurement(
  candidate(route),
  CinemaMediaProbeResult(
    ok: ok,
    elapsedMs: 100,
    mbps: speed,
    bitrate: bitrate,
    firstByteMs: delay,
  ),
);

class _Probe extends CinemaMediaProbe {
  _Probe({this.blocked = false})
    : super(transport: CinemaMediaTransport(dio: Dio()));
  final bool blocked;
  final calls = <String>[];
  int active = 0, maximum = 0;
  final pending = Completer<CinemaMediaProbeResult>();
  @override
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) async {
    calls.add(url);
    active++;
    if (active > maximum) maximum = active;
    try {
      if (blocked) return await pending.future;
      await Future<void>.delayed(
        Duration(milliseconds: url.endsWith('.mp4') ? 2 : 10),
      );
      return const CinemaMediaProbeResult(ok: true, elapsedMs: 10, mbps: 12);
    } finally {
      active--;
    }
  }
}

void main() {
  test(
    'recommendation rejects failed and invalid speeds, preserves sufficient bitrate and tie order',
    () {
      expect(
        cinemaBestMeasuredRoute([
          measurement(0, 100, ok: false),
          measurement(1, double.nan),
          measurement(2, 0),
        ]),
        isNull,
      );
      expect(
        cinemaBestMeasuredRoute([
          measurement(0, 80, bitrate: 100000000),
          measurement(2, 20, bitrate: 5000000),
        ])!.candidate.routeIndex,
        2,
      );
      expect(
        cinemaBestMeasuredRoute([
          measurement(0, 12, delay: 30),
          measurement(2, 12, delay: 50),
        ])!.candidate.routeIndex,
        0,
      );
      expect(
        cinemaBestMeasuredRoute([
          measurement(2, 12),
          measurement(0, 12),
        ])!.candidate.routeIndex,
        2,
      );
    },
  );
  test(
    'duplicate media uses one probe, unresolved web routes are excluded, resolved requests retain headers',
    () {
      final plan = CinemaRouteProbeBatch.plan([
        for (var i = 0; i < 4; i++) candidate(i),
      ]);
      expect(plan.length, 2);
      expect(plan.first.candidates.length, 2);
      final withResolved = CinemaRouteProbeBatch.plan(
        [candidate(3)],
        resolved: {
          candidate(3).key: (
            url: 'https://example.test/gateway',
            headers: {'Referer': 'https://example.test/page'},
            hls: true,
          ),
        },
      );
      expect(
        withResolved.single.headers['Referer'],
        'https://example.test/page',
      );
      expect(withResolved.single.hls, isTrue);
    },
  );
  test(
    'batch bounds concurrency and ranks ties by plan instead of completion time',
    () async {
      final probe = _Probe();
      addTearDown(() => probe.transport.dio.close(force: true));
      final plan = CinemaRouteProbeBatch.plan([candidate(0), candidate(2)]);
      final results = await CinemaRouteProbeBatch(probe).run(plan);
      expect(probe.maximum, 2);
      expect(probe.calls.length, 2);
      expect(cinemaBestMeasuredRoute(results)!.candidate.routeIndex, 0);
    },
  );
  test(
    'whole-batch deadline ends an uncooperative probe and discards its late results',
    () async {
      final probe = _Probe(blocked: true);
      addTearDown(() => probe.transport.dio.close(force: true));
      var observed = 0;
      final result = await CinemaRouteProbeBatch(probe).run(
        CinemaRouteProbeBatch.plan([candidate(0), candidate(2)]),
        budget: const Duration(milliseconds: 20),
        onResult: (_, _) => observed++,
      );
      expect(result, isEmpty);
      expect(observed, 0);
      probe.pending.complete(
        const CinemaMediaProbeResult(ok: true, elapsedMs: 1, mbps: 200),
      );
      await Future<void>.delayed(Duration.zero);
      expect(observed, 0);
    },
  );
  test('a cancelled batch never starts media requests', () async {
    final probe = _Probe();
    addTearDown(() => probe.transport.dio.close(force: true));
    final cancel = CancelToken()..cancel();
    expect(
      await CinemaRouteProbeBatch(
        probe,
      ).run(CinemaRouteProbeBatch.plan([candidate(0)]), cancel: cancel),
      isEmpty,
    );
    expect(probe.calls, isEmpty);
  });
}
