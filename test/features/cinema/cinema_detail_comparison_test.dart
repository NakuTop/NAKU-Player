import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_detail_comparison.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_media_transport.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';

const first = CinemaSource(
  id: 'maccms-zuid',
  name: '最大',
  kind: CinemaSourceKind.maccms,
  url: 'https://first.example',
);
const second = CinemaSource(
  id: 'maccms-juliang',
  name: '巨量',
  kind: CinemaSourceKind.maccms,
  url: 'https://second.example',
);
CinemaTitle movie(CinemaSource source, {bool card = false}) => CinemaTitle(
  id: 'movie',
  sourceId: source.id,
  title: '同一电影',
  category: '恐怖片',
  year: '2026',
  routes: card
      ? []
      : [
          CinemaRoute(
            name: 'm3u8',
            episodes: [
              for (final version in ['TD', 'HD', '4K'])
                CinemaEpisode(
                  name: version,
                  url: 'https://${source.id}.example/$version.m3u8',
                ),
            ],
          ),
        ],
);

class Repository extends CinemaRepository {
  final calls = <String>[];
  Completer<CinemaTitle>? firstPending;
  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    calls.add(source.id);
    if (source.id == first.id && firstPending != null) {
      return firstPending!.future;
    }
    return movie(source);
  }
}

class Probe extends CinemaMediaProbe {
  Probe() : super(transport: CinemaMediaTransport(dio: Dio()));
  final calls = <String>[];
  Completer<CinemaMediaProbeResult>? blocker;
  @override
  Future<CinemaMediaProbeResult> measure(
    String url,
    Map<String, String> headers, {
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 8),
    bool hls = false,
  }) async {
    calls.add(url);
    if (blocker != null) return blocker!.future;
    return CinemaMediaProbeResult(
      ok: true,
      elapsedMs: 30,
      firstByteMs: 20,
      mbps: url.contains('juliang') ? 999 : 12,
      width: url.contains('TD')
          ? 7680
          : url.contains('4K')
          ? 3840
          : 1920,
      height: url.contains('TD')
          ? 4320
          : url.contains('4K')
          ? 2160
          : 1080,
    );
  }
}

void main() {
  test(
    'lazy higher-priority source and its full-film versions precede loaded later source',
    () async {
      final repo = Repository(), anchor = movie(second);
      final catalogue = CinemaPlaybackCatalogue(
        title: anchor,
        source: second,
        variants: [movie(first, card: true)],
        sources: [first, second],
        repository: repo,
      );
      final choice = await catalogue.firstMatching(
        CinemaPlaybackCandidate(
          title: anchor,
          source: second,
          routeIndex: 0,
          episodeIndex: 0,
        ),
      );
      expect(repo.calls, [first.id]);
      expect(choice!.source.id, first.id);
      expect(choice.episode.name, '4K');
      final next = await catalogue.firstMatching(
        choice,
        accept: (c) => c.key != choice.key,
      );
      expect(next!.episode.name, 'HD');
      expect(next.source.id, first.id);
    },
  );
  test(
    'ready sources publish dimensions before a slow catalogue returns',
    () async {
      final probe = Probe(),
          repo = Repository()..firstPending = Completer<CinemaTitle>();
      final comparison = CinemaDetailComparison(
        title: movie(second),
        source: second,
        variants: [movie(first, card: true)],
        sources: [first, second],
        repository: repo,
        probe: probe,
      );
      addTearDown(comparison.dispose);
      addTearDown(() => probe.transport.dio.close(force: true));
      final ready = Completer<void>();
      comparison.addListener(() {
        if (comparison.results.isNotEmpty && !ready.isCompleted) {
          ready.complete();
        }
      });
      final task = comparison.start();
      await ready.future.timeout(const Duration(seconds: 1));
      expect(repo.firstPending!.isCompleted, isFalse);
      expect(comparison.results.values.first.height, 2160);
      expect(comparison.recommended!.source.id, second.id);
      repo.firstPending!.complete(movie(first));
      await task;
      expect(comparison.recommended!.source.id, first.id);
      expect(comparison.results, hasLength(6));
    },
  );
  test(
    'three bounded probes give both sources a turn before extra editions',
    () async {
      final probe = Probe()..blocker = Completer<CinemaMediaProbeResult>();
      final comparison = CinemaDetailComparison(
        title: movie(first),
        source: first,
        variants: [movie(second)],
        sources: [first, second],
        repository: Repository(),
        probe: probe,
      );
      final task = comparison.start();
      await Future<void>.delayed(Duration.zero);
      expect(probe.calls, hasLength(3));
      expect(probe.calls.take(2), [
        'https://${first.id}.example/4K.m3u8',
        'https://${second.id}.example/4K.m3u8',
      ]);
      comparison.dispose();
      await task.timeout(const Duration(seconds: 1));
      probe.blocker!.complete(
        const CinemaMediaProbeResult(ok: true, elapsedMs: 1),
      );
      probe.transport.dio.close(force: true);
    },
  );
  test(
    'detail compares all sources and every movie edition then recommends user-first 4K',
    () async {
      final probe = Probe(), repo = Repository();
      final comparison = CinemaDetailComparison(
        title: movie(second, card: true),
        source: second,
        variants: [movie(first, card: true)],
        sources: [first, second],
        repository: repo,
        probe: probe,
      );
      addTearDown(comparison.dispose);
      addTearDown(() => probe.transport.dio.close(force: true));
      await comparison.start();
      expect(probe.calls, hasLength(6));
      expect(comparison.results, hasLength(6));
      expect(comparison.recommended!.source.id, first.id);
      expect(comparison.recommended!.episode.name, '4K');
      expect(comparison.running, false);
    },
  );
  test(
    'closing detail cancels an uncooperative media read and ignores late completion',
    () async {
      final probe = Probe()..blocker = Completer<CinemaMediaProbeResult>();
      final comparison = CinemaDetailComparison(
        title: movie(first),
        source: first,
        variants: [],
        sources: [first],
        repository: Repository(),
        probe: probe,
      );
      var changes = 0;
      comparison.addListener(() => changes++);
      final task = comparison.start();
      await Future<void>.delayed(Duration.zero);
      expect(probe.calls, isNotEmpty);
      comparison.dispose();
      final stopped = changes;
      await task.timeout(const Duration(seconds: 1));
      probe.blocker!.complete(
        const CinemaMediaProbeResult(ok: true, elapsedMs: 1, mbps: 999),
      );
      await Future<void>.delayed(Duration.zero);
      expect(changes, stopped);
      expect(comparison.results, isEmpty);
      probe.transport.dio.close(force: true);
    },
  );
  test(
    'late discovered source uses saved order and no duplicate media reads',
    () async {
      final probe = Probe();
      final comparison = CinemaDetailComparison(
        title: movie(second),
        source: second,
        variants: [],
        sources: [first, second],
        repository: Repository(),
        probe: probe,
      );
      addTearDown(comparison.dispose);
      addTearDown(() => probe.transport.dio.close(force: true));
      await comparison.start();
      expect(comparison.recommended!.source.id, second.id);
      comparison.addVariants([movie(first)]);
      while (comparison.running) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(comparison.recommended!.source.id, first.id);
      expect(probe.calls.toSet(), hasLength(6));
      expect(probe.calls, hasLength(6));
    },
  );
}
