import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_resource_availability.dart';
import 'package:kazumi/features/cinema/cinema_seasons.dart';
import 'package:kazumi/features/cinema/cinema_work_sources.dart';

const _source = CinemaSource(
  id: 'one',
  name: 'test',
  kind: CinemaSourceKind.maccms,
  url: 'https://source.example/api',
);
const _anchor = CinemaTitle(
  id: 'meta',
  sourceId: 'douban-discovery',
  title: '泰坦尼克号',
  year: '1997',
  category: '电影',
);
CinemaTitle _edition(
  String id,
  String name, {
  String year = '1997',
  bool routes = true,
  String source = 'one',
}) => CinemaTitle(
  id: id,
  sourceId: source,
  title: name,
  year: year,
  category: '电影',
  routes: routes
      ? const [
          CinemaRoute(
            name: 'test',
            episodes: [
              CinemaEpisode(
                name: '正片',
                url: 'https://media.example/video.m3u8',
              ),
            ],
          ),
        ]
      : const [],
);

class _Repository extends CinemaRepository {
  int calls = 0, active = 0, peak = 0, details = 0;
  bool fail = false, empty = false, noLines = false;
  Completer<void>? gate;
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    calls++;
    active++;
    if (active > peak) peak = active;
    try {
      if (gate != null) await gate!.future;
      if (fail) throw StateError('offline');
      return CinemaPage(
        page: page,
        pageCount: 2,
        items: empty
            ? []
            : [
                _edition(
                  '$page',
                  page == 1 ? '泰坦尼克号' : '泰坦尼克号国语4K',
                  routes: !noLines,
                ),
                _edition('remake', '泰坦尼克号', year: '2012'),
              ],
      );
    } finally {
      active--;
    }
  }

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    details++;
    return title;
  }
}

void main() {
  test(
    'lookup time limit reports an incomplete check, not a successful empty result',
    () async {
      final repo = _Repository();
      var failures = 0;
      final found = await discoverCinemaWorkSources(
        anchor: _anchor,
        known: [],
        sources: [_source],
        repository: repo,
        isCurrent: () => true,
        maxDuration: Duration.zero,
        onSourceError: (_, _) => failures++,
      ).toList();
      expect(found, isEmpty);
      expect(failures, 1);
      expect(repo.calls, 0);
    },
  );

  test(
    'quality wins source priority without merging remakes or sequel numbers',
    () {
      final ordinary = _edition('1', '泰坦尼克号');
      final uhd = _edition('2', '泰坦尼克号国语4K', source: 'two');
      final groups = groupCinemaTitles(
        [
          ordinary,
          uhd,
          _edition('3', '泰坦尼克号2'),
          _edition('4', '泰坦尼克号', year: '2012'),
        ],
        sourcePriority: ['one', 'two'],
      );
      expect(groups, hasLength(3));
      expect(groups.first.representative.key, uhd.key);
      expect(groups.first.variants, hasLength(2));
      expect(cinemaWorkQueries(uhd).first, '泰坦尼克号');
    },
  );
  test(
    'existing source is searched and a later page adds its 4K edition',
    () async {
      final repo = _Repository();
      final first = _edition('1', '泰坦尼克号');
      final results = await discoverCinemaWorkSources(
        anchor: first,
        known: [first],
        sources: [_source],
        repository: repo,
        isCurrent: () => true,
      ).toList();
      expect(repo.calls, 2);
      expect(results.last.map((t) => t.id), ['1', '2']);
      expect(orderCinemaVariants(results.last, ['one']).first.id, '2');
    },
  );
  test(
    'coalesced availability keeps actual lines and excludes wrong-year results',
    () async {
      final repo = _Repository()..gate = Completer<void>();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final first = service.check(_anchor, [_source]);
      final second = service.check(_anchor, [_source]);
      expect(identical(first, second), isTrue);
      repo.gate!.complete();
      final result = await first;
      expect(result.state, CinemaResourceState.found);
      expect(result.has4K, isTrue);
      expect(result.variants.map((t) => t.id), ['2', '1']);
      await service.check(_anchor, [_source]);
      expect(repo.calls, 2);
    },
  );
  test(
    'failed queries differ from a completed search with no matches and retry sooner',
    () async {
      var now = DateTime(2026);
      final repo = _Repository()..fail = true;
      final service = CinemaResourceAvailabilityService(repo, now: () => now);
      addTearDown(service.dispose);
      expect(
        (await service.check(_anchor, [_source])).state,
        CinemaResourceState.incomplete,
      );
      repo
        ..fail = false
        ..empty = true;
      now = now.add(const Duration(seconds: 31));
      expect(
        (await service.check(_anchor, [_source])).state,
        CinemaResourceState.missing,
      );
      expect(
        (await service.check(_anchor, [])).state,
        CinemaResourceState.noSources,
      );
    },
  );
  test(
    'source URL changes invalidate availability even when source ID stays the same',
    () async {
      final repo = _Repository();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      await service.check(_anchor, [_source]);
      final changed = CinemaSource.fromJson({
        ..._source.toJson(),
        'url': 'https://other.example/api',
      });
      repo.empty = true;
      expect(
        (await service.check(_anchor, [changed])).state,
        CinemaResourceState.missing,
      );
      expect(repo.calls, greaterThan(2));
    },
  );
  test(
    'catalogue entries without lines are hydrated and never advertised as resources',
    () async {
      final repo = _Repository()..noLines = true;
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      expect(
        (await service.check(_anchor, [_source])).state,
        CinemaResourceState.missing,
      );
      expect(repo.details, greaterThan(0));
    },
  );
  test(
    'background queue caps concurrent work and skips disposed cards',
    () async {
      final repo = _Repository()..gate = Completer<void>();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final jobs = [
        for (var i = 0; i < 8; i++)
          service.check(_anchor.copyWith(year: '${1997 + i}'), [
            _source,
          ], isCurrent: () => i < 2),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(repo.peak, 2);
      repo.gate!.complete();
      await Future.wait(jobs);
      expect(repo.peak, 2);
      expect(jobs, hasLength(8));
    },
  );
}
