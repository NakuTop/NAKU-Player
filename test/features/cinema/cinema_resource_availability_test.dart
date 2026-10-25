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

class _NativeRepository extends _Repository {
  CinemaTitle? hydrated;
  bool detailFails = false;
  Completer<CinemaTitle>? detailGate;
  final detailKeys = <String>[];

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    details++;
    detailKeys.add('${source.id}:${title.key}');
    active++;
    if (active > peak) peak = active;
    try {
      if (detailFails) throw StateError('detail offline');
      if (detailGate != null) return await detailGate!.future;
      return hydrated ?? title;
    } finally {
      active--;
    }
  }
}

void main() {
  test(
    'a playable native card confirms its actual quality without search',
    () async {
      final repo = _NativeRepository();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final native = _edition('native', '泰坦尼克号国语4K');
      final result = await service.check(native, [_source]);
      expect(result.state, CinemaResourceState.found);
      expect(result.variants, [native]);
      expect(result.has4K, isTrue);
      expect((result.checked, result.total), (1, 1));
      expect((repo.calls, repo.details), (0, 0));
    },
  );

  test(
    'native exact detail supplies playback lines before any name search',
    () async {
      final native = _edition('native', '泰坦尼克号', routes: false);
      final hydrated = _edition('native', '泰坦尼克号国语4K');
      final repo = _NativeRepository()..hydrated = hydrated;
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final result = await service.check(native, [_source]);
      expect(result.state, CinemaResourceState.found);
      expect(result.variants, [hydrated]);
      expect(result.has4K, isTrue);
      expect(repo.calls, 0);
      expect(repo.detailKeys, ['one:one::native']);
    },
  );

  for (final fails in [false, true]) {
    test(
      'an ${fails ? 'failed' : 'empty'} native detail falls back without a false positive',
      () async {
        final native = _edition('native', '泰坦尼克号', routes: false);
        final repo = _NativeRepository()
          ..empty = true
          ..detailFails = fails;
        final service = CinemaResourceAvailabilityService(repo);
        addTearDown(service.dispose);
        final result = await service.check(native, [_source]);
        expect(
          result.state,
          fails ? CinemaResourceState.incomplete : CinemaResourceState.missing,
        );
        expect(result.variants, isEmpty);
        expect(repo.calls, greaterThan(0));
        expect(repo.details, 1);
        expect((result.checked, result.total), (1, 1));
      },
    );
  }

  test('discovery can recover after a failed native detail', () async {
    final repo = _NativeRepository()..detailFails = true;
    final service = CinemaResourceAvailabilityService(repo);
    addTearDown(service.dispose);
    final result = await service.check(
      _edition('native', '泰坦尼克号', routes: false),
      [_source],
    );
    expect(result.state, CinemaResourceState.found);
    expect(result.variants.map((title) => title.id), ['2', '1']);
    expect(result.has4K, isTrue);
    expect(repo.calls, greaterThan(0));
    expect(repo.details, 1);
  });

  for (final sourceId in ['disabled', 'unrelated']) {
    test('a $sourceId native anchor cannot grant availability', () async {
      final repo = _NativeRepository()..empty = true;
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final result = await service
          .check(_edition('native', '泰坦尼克号4K', source: sourceId), [
            _source,
            if (sourceId == 'disabled')
              _source.copyWith(id: 'disabled', enabled: false),
          ]);
      expect(result.state, CinemaResourceState.missing);
      expect(result.variants, isEmpty);
      expect(repo.details, 0);
      expect(repo.calls, greaterThan(0));
    });
  }

  test(
    'a native detail response for another source cannot grant availability',
    () async {
      final repo = _NativeRepository()
        ..empty = true
        ..hydrated = _edition('native', '泰坦尼克号', source: 'unrelated');
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final result = await service.check(
        _edition('native', '泰坦尼克号', routes: false),
        [_source],
      );
      expect(result.state, CinemaResourceState.incomplete);
      expect(result.variants, isEmpty);
      expect(repo.calls, greaterThan(0));
    },
  );

  test(
    'a stale native-detail consumer cannot publish a positive badge',
    () async {
      final repo = _NativeRepository()..detailGate = Completer<CinemaTitle>();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final native = _edition('native', '泰坦尼克号', routes: false);
      var current = true;
      final states = <CinemaResourceState>[];
      final entry = service.entry(native, [_source]);
      entry.addListener(() => states.add(entry.value.state));
      final pending = service.check(native, [
        _source,
      ], isCurrent: () => current);
      expect(repo.details, 1);
      current = false;
      repo.detailGate!.complete(_edition('native', '泰坦尼克号4K'));
      final result = await pending;
      expect(states, isNot(contains(CinemaResourceState.found)));
      expect(result.state, CinemaResourceState.waiting);
      expect(entry.completedAt, isNull);
      expect(repo.calls, 0);
    },
  );

  test('native detail hydration shares the maximum-two lookup queue', () async {
    final gate = Completer<CinemaTitle>();
    final repo = _NativeRepository()..detailGate = gate;
    final service = CinemaResourceAvailabilityService(repo);
    addTearDown(service.dispose);
    var current = true;
    final pending = [
      for (var index = 0; index < 5; index++)
        service.check(_edition('native-$index', '影片$index', routes: false), [
          _source,
        ], isCurrent: () => current),
    ];
    expect(repo.peak, 2);
    expect(repo.details, 2);
    current = false;
    gate.complete(_edition('ignored', '影片'));
    await Future.wait(pending);
    expect(repo.peak, 2);
    expect(repo.details, 2);
    expect(repo.calls, 0);
  });

  test(
    'cancelled native revalidation preserves the saved positive badge',
    () async {
      final repo = _NativeRepository();
      final service = CinemaResourceAvailabilityService(repo);
      addTearDown(service.dispose);
      final native = _edition('native', '泰坦尼克号4K');
      final saved = await service.check(native, [_source]);
      repo.detailGate = Completer<CinemaTitle>();
      var current = true;
      final pending = service.check(
        native.copyWith(routes: const []),
        [_source],
        isCurrent: () => current,
        force: true,
      );
      expect(service.peek(native, [_source]), same(saved));
      current = false;
      repo.detailGate!.complete(native);
      expect(await pending, same(saved));
      expect(service.peek(native, [_source]), same(saved));
      expect(repo.calls, 0);
    },
  );

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
