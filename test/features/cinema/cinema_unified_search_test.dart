import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_ratings_panel.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_startup_preferences.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';

const _sources = [
  CinemaSource(
    id: 'unified-a',
    name: '统一搜索源甲',
    kind: CinemaSourceKind.maccms,
    url: 'https://unified-a.invalid/api',
  ),
  CinemaSource(
    id: 'unified-b',
    name: '统一搜索源乙',
    kind: CinemaSourceKind.maccms,
    url: 'https://unified-b.invalid/api',
  ),
];

// Deliberately identical names and years: film and television must remain
// separate works while copies of the same type from two providers may merge.
CinemaTitle _title(CinemaSource source, {required bool series}) => CinemaTitle(
  id: series ? 'tv' : 'movie',
  sourceId: source.id,
  title: '同名作品',
  year: '2026',
  category: series ? '欧美剧' : '剧情片',
);

const _metadata = [
  CinemaDiscoveryTitle(
    id: '100001',
    title: '同名作品',
    year: '2026',
    kind: 'movie',
    identityVerified: true,
  ),
  CinemaDiscoveryTitle(
    id: '100002',
    title: '同名作品',
    year: '2026',
    kind: 'tv',
    identityVerified: true,
  ),
];

class _Repository extends CinemaRepository {
  final details = <({String source, String id, String category})>[];
  final searches = <String>[];

  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '1', name: '剧情片'),
    CinemaCategory(id: '2', name: '欧美剧'),
  ];

  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async => const CinemaPage(items: []);

  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) => browse(source, categoryId: categoryId, page: page);

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searches.add(keyword);
    return CinemaPage(
      items: switch (keyword) {
        '同名作品' => [_title(source, series: false), _title(source, series: true)],
        '部分片源' => [_title(source, series: false)],
        _ => const [],
      },
    );
  }

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    details.add((source: source.id, id: title.id, category: title.category));
    final series = title.category == '欧美剧';
    return title.copyWith(
      routes: [
        CinemaRoute(
          name: series ? '剧集专属线路' : '电影专属线路',
          episodes: [
            for (var index = 1; index <= (series ? 2 : 1); index++)
              CinemaEpisode(
                name: series ? '剧集第$index集' : '电影正片',
                url: 'https://${source.id}.invalid/${title.id}-$index.mp4',
              ),
          ],
        ),
      ],
    );
  }
}

class _Discovery extends CinemaSearchDiscoveryRepository {
  @override
  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async => switch (keyword) {
    '仅元数据' || '部分片源' => const CinemaSearchDiscovery(titles: _metadata),
    'Unified Story' => const CinemaSearchDiscovery(
      titles: _metadata,
      queries: ['同名作品'],
    ),
    _ => const CinemaSearchDiscovery(),
  };
}

class _Catalogue extends DoubanRepository {
  Completer<DoubanResultPage>? moviePending;
  final calls = <DoubanKind>[];

  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async {
    calls.add(kind);
    if (kind == DoubanKind.movie && moviePending != null) {
      return moviePending!.future;
    }
    return const DoubanResultPage(
      items: [],
      start: 0,
      nextStart: 0,
      hasMore: false,
    );
  }
}

class _Ratings extends CinemaRatingsRepository {
  CinemaRatings _result(CinemaTitle title) => CinemaRatings(
    identity: RatingIdentity(doubanId: title.doubanId),
    ratings: const [],
    message: '',
  );

  @override
  CinemaRatings peek(CinemaTitle title) => _result(title);

  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async =>
      _result(title);

  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async =>
      _result(title);

  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async => _result(title);

  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async => const DoubanSubjectDetails(doubanId: '');
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _Catalogue catalogue;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-unified-search-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: _sources,
    );
    await store.load();
    repository = _Repository();
    catalogue = _Catalogue();
  });

  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester,
    String section, {
    CinemaStartupTarget initialStartup = const CinemaStartupTarget(),
  }) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          repository: repository,
          ratingsRepository: _Ratings(),
          searchDiscovery: _Discovery(),
          catalogDiscovery: catalogue,
          initialStartup: initialStartup,
          enableWatchTogether: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('cinema-destination-$section')));
    await tester.pumpAndSettle();
  }

  Future<void> search(WidgetTester tester, String keyword) async {
    await tester.enterText(find.byType(TextField).first, keyword);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  Finder sourceCard(bool series) =>
      find.byKey(ValueKey('title-card:unified-a::${series ? 'tv' : 'movie'}'));

  Future<void> assertDetail(
    WidgetTester tester,
    Finder card, {
    required bool series,
  }) async {
    await tester.ensureVisible(card);
    await tester.tap(card);
    await tester.pumpAndSettle();
    final detail = tester.widget<CinemaRatingsPanel>(
      find.byType(CinemaRatingsPanel),
    );
    expect(detail.title.id, series ? 'tv' : 'movie');
    expect(detail.title.category, series ? '欧美剧' : '剧情片');
    expect(detail.title.sourceId, 'unified-a');
    expect(detail.title.routes.single.name, series ? '剧集专属线路' : '电影专属线路');
    expect(detail.title.routes.single.episodes, hasLength(series ? 2 : 1));
    expect(
      detail.title.routes.single.episodes.first.url,
      'https://unified-a.invalid/${series ? 'tv' : 'movie'}-1.mp4',
    );
    expect(repository.details.last, (
      source: 'unified-a',
      id: series ? 'tv' : 'movie',
      category: series ? '欧美剧' : '剧情片',
    ));
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'leaving a pending desktop search submission cannot overwrite another page query',
    (tester) async {
      await mount(
        tester,
        'settings',
        initialStartup: const CinemaStartupTarget(
          section: CinemaStartupSection.settings,
        ),
      );
      final pending = catalogue.moviePending = Completer<DoubanResultPage>();
      final field = find.byKey(const ValueKey('cinema-unified-search'));
      await tester.enterText(field, '过期的电影搜索');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(catalogue.calls, [DoubanKind.movie]);
      expect(repository.searches, isEmpty);

      await tester.tap(find.byKey(const ValueKey('cinema-destination-series')));
      await tester.pumpAndSettle();
      await tester.enterText(field, '当前剧集查询');
      pending.complete(
        const DoubanResultPage(
          items: [],
          start: 0,
          nextStart: 0,
          hasMore: false,
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.searches, isEmpty);
      expect(tester.widget<TextField>(field).controller!.text, '当前剧集查询');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
    skip: !Platform.isMacOS,
  );

  for (final section in ['movies', 'series']) {
    testWidgets(
      '$section search keeps same-name movies and TV as separate playable works',
      (tester) async {
        await mount(tester, section);
        await search(tester, '同名作品');
        expect(sourceCard(false), findsOneWidget);
        expect(sourceCard(true), findsOneWidget);
        // Two providers become one result per work, without merging film and TV.
        expect(
          find.byKey(const ValueKey('title-card:unified-b::movie')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('title-card:unified-b::tv')),
          findsNothing,
        );
        await assertDetail(tester, sourceCard(false), series: false);
        await assertDetail(tester, sourceCard(true), series: true);
      },
      skip: !Platform.isMacOS,
    );

    testWidgets(
      '$section translated discovery resolves both film and TV source results',
      (tester) async {
        await mount(tester, section);
        await search(tester, 'Unified Story');
        expect(repository.searches, containsAll(['Unified Story', '同名作品']));
        expect(sourceCard(false), findsOneWidget);
        expect(sourceCard(true), findsOneWidget);
        await assertDetail(tester, sourceCard(false), series: false);
        await assertDetail(tester, sourceCard(true), series: true);
      },
      skip: !Platform.isMacOS,
    );

    testWidgets(
      '$section metadata suggestions include film and TV and resolve typed routes',
      (tester) async {
        await mount(tester, section);
        await search(tester, '仅元数据');
        final film = find.byKey(const ValueKey('discovery-title:100001'));
        final television = find.byKey(const ValueKey('discovery-title:100002'));
        expect(film, findsOneWidget);
        expect(television, findsOneWidget);
        await assertDetail(tester, film, series: false);
        await assertDetail(tester, television, series: true);
      },
      skip: !Platform.isMacOS,
    );

    testWidgets(
      '$section movie source does not suppress same-name TV metadata suggestion',
      (tester) async {
        await mount(tester, section);
        await search(tester, '部分片源');
        expect(sourceCard(false), findsOneWidget);
        expect(
          find.byKey(const ValueKey('discovery-title:100001')),
          findsNothing,
        );
        final television = find.byKey(const ValueKey('discovery-title:100002'));
        expect(television, findsOneWidget);
        await assertDetail(tester, television, series: true);
      },
      skip: !Platform.isMacOS,
    );
  }
}
