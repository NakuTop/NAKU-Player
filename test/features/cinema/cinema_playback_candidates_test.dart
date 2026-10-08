import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_playback_candidates.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';

const a = CinemaSource(
  id: 'a',
  name: 'A',
  kind: CinemaSourceKind.maccms,
  url: 'https://a.example',
);
const b = CinemaSource(
  id: 'b',
  name: 'B',
  kind: CinemaSourceKind.maccms,
  url: 'https://b.example',
);
CinemaTitle work(
  String source, {
  String year = '2022',
  String name = '流人第一季',
  List<String> episodes = const ['第01集', '第02集'],
}) => CinemaTitle(
  id: '1',
  sourceId: source,
  title: name,
  year: year,
  category: '欧美剧',
  routes: [
    CinemaRoute(
      name: 'HLS',
      episodes: [
        for (final e in episodes)
          CinemaEpisode(name: e, url: 'https://$source.example/$e.m3u8'),
      ],
    ),
  ],
);
CinemaPlaybackCandidate candidate(CinemaTitle t, {int episode = 0}) =>
    CinemaPlaybackCandidate(
      title: t,
      source: t.sourceId == 'a' ? a : b,
      routeIndex: 0,
      episodeIndex: episode,
    );

class Repo extends CinemaRepository {
  int calls = 0;
  @override
  Future<CinemaTitle> detail(CinemaSource s, CinemaTitle t) async {
    calls++;
    throw const CinemaSourceException('offline');
  }
}

void main() {
  test('same episode matches reordered provider numbers rather than index', () {
    expect(
      cinemaMatchPlaybackEpisode(
        current: candidate(work('a')),
        target: work('b', episodes: ['EP02', 'EP01']),
        routeIndex: 0,
      ),
      1,
    );
  });
  test('duplicate names, different year or season never auto-switch', () {
    for (final target in [
      work('b', episodes: ['EP01', '第1集']),
      work('b', year: '2023'),
      work('b', name: '流人第二季'),
    ]) {
      expect(
        cinemaMatchPlaybackEpisode(
          current: candidate(work('a')),
          target: target,
          routeIndex: 0,
        ),
        isNull,
      );
    }
  });
  test('attempt ledger cannot repeat routes or exceed budget', () {
    final attempts = CinemaFailoverAttempts(limit: 2);
    expect(attempts.claim(candidate(work('a'))), isTrue);
    expect(attempts.claim(candidate(work('a'))), isFalse);
    expect(attempts.claim(candidate(work('b'))), isTrue);
    expect(attempts.claim(candidate(work('b'), episode: 1)), isFalse);
    expect(attempts.exhausted, isTrue);
  });
  test(
    'catalogue excludes unrelated works and reuses available route data',
    () async {
      final repo = Repo();
      final catalogue = CinemaPlaybackCatalogue(
        title: work('a'),
        source: a,
        variants: [
          work('b'),
          work('b', name: '其他剧'),
        ],
        sources: [a, b],
        repository: repo,
      );
      expect(catalogue.variants.length, 2);
      expect((await catalogue.load(work('b'))).sourceId, 'b');
      expect(repo.calls, 0);
      expect(catalogue.matching(candidate(work('a'))).length, 2);
    },
  );
  test(
    'failed detail is cached and only explicit retry reissues request',
    () async {
      final repo = Repo();
      final other = work('b').copyWith(routes: []);
      final catalogue = CinemaPlaybackCatalogue(
        title: work('a'),
        source: a,
        variants: [other],
        sources: [a, b],
        repository: repo,
      );
      await expectLater(
        catalogue.load(other),
        throwsA(isA<CinemaSourceException>()),
      );
      await expectLater(
        catalogue.load(other),
        throwsA(isA<CinemaSourceException>()),
      );
      expect(repo.calls, 1);
      await expectLater(
        catalogue.load(other, retry: true),
        throwsA(isA<CinemaSourceException>()),
      );
      expect(repo.calls, 2);
    },
  );
}
