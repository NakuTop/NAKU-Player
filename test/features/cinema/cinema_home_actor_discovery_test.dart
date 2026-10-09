import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_card_ratings.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_ratings_panel.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_page.dart';
import 'package:kazumi/features/cinema/douban/douban_themes.dart';

const _source = CinemaSource(
  id: 'actor-source',
  name: '演员测试源',
  kind: CinemaSourceKind.maccms,
  url: 'https://actor-source.invalid/api',
);
const _firstActor = CinemaDiscoveryPerson(
  id: '1049484',
  name: '演员甲',
  originalName: 'Actor A',
);
const _secondActor = CinemaDiscoveryPerson(
  id: '1054404',
  name: '演员乙',
  originalName: 'Actor B',
);
const _people = [_firstActor, _secondActor];
const _metadata = CinemaDiscoveryTitle(
  id: '36889088',
  title: '怒之杀',
  originalTitle: 'Mutiny',
  year: '2026',
  score: 5.6,
  identityVerified: true,
);
const _nextMetadata = CinemaDiscoveryTitle(
  id: '1292052',
  title: '下一部作品',
  year: '2025',
  identityVerified: true,
);
const _otherMetadata = CinemaDiscoveryTitle(
  id: '1291546',
  title: '乙的作品',
  year: '2024',
  identityVerified: true,
);
const _rawTitle = CinemaTitle(
  id: 'raw-film',
  sourceId: 'actor-source',
  title: '怒之杀',
  aliases: 'Mutiny',
  year: '2026',
  category: '剧情片',
);
const _route = CinemaRoute(
  name: '测试线路',
  episodes: [
    CinemaEpisode(name: '正片', url: 'https://media.invalid/fixture.m3u8'),
  ],
);

class _Repository extends CinemaRepository {
  final searches = <String>[];
  final details = <CinemaTitle>[];
  final pending = <String, Completer<CinemaPage>>{};
  final results = <String, List<CinemaTitle>>{};
  CinemaTitle detailResult = const CinemaTitle(
    id: 'raw-film',
    sourceId: 'actor-source',
    title: '怒之杀',
    aliases: 'Mutiny',
    year: '2026',
    category: '剧情片',
    routes: [_route],
    description: '来源接口最新简介',
  );
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '11', name: '剧情片'),
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
  }) async => const CinemaPage(items: []);
  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    expect(source.id, _source.id);
    searches.add(keyword);
    final gate = pending[keyword];
    if (gate != null) return gate.future;
    return CinemaPage(items: results[keyword] ?? const []);
  }

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    expect(source.id, _source.id);
    details.add(title);
    // The real source omits external IDs even though its search card has just
    // received verified discovery metadata. Do not echo the enriched input.
    return detailResult;
  }
}

typedef _ActorRequest = ({String id, int start});

class _SearchDiscovery extends CinemaSearchDiscoveryRepository {
  final searches = <String>[];
  final pendingSearch = <String, Completer<CinemaSearchDiscovery>>{};
  final searchResults = <String, CinemaSearchDiscovery>{};
  final requests = <_ActorRequest>[];
  final workResults = <_ActorRequest, CinemaSearchDiscovery>{};
  final pendingWorks = <_ActorRequest, Completer<CinemaSearchDiscovery>>{};
  final tokens = <_ActorRequest, CancelToken?>{};
  @override
  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    searches.add(keyword);
    final gate = pendingSearch[keyword];
    if (gate != null) return gate.future;
    return searchResults[keyword] ??
        const CinemaSearchDiscovery(people: _people);
  }

  CinemaSearchDiscovery works(_ActorRequest request) => CinemaSearchDiscovery(
    people: const [], // Home must retain the explicitly offered candidates.
    titles: request.id == _secondActor.id
        ? [_otherMetadata]
        : request.start == 0
        ? [_metadata]
        : [_metadata, _nextMetadata],
    celebrityId: request.id,
    celebrityName: request.id == _firstActor.id
        ? _firstActor.name
        : _secondActor.name,
    nextStart: request.start + 1,
    hasMore: request.id == _firstActor.id && request.start == 0,
  );
  @override
  Future<CinemaSearchDiscovery> actorWorks(
    String id,
    String name, {
    int start = 0,
    CancelToken? cancelToken,
  }) async {
    final request = (id: id, start: start);
    requests.add(request);
    tokens[request] = cancelToken;
    final gate = pendingWorks[request];
    // Deliberately ignore cancellation in this fake, so late replies exercise
    // the widget's own generation and cancellation guards.
    return gate == null
        ? (workResults[request] ?? works(request))
        : gate.future;
  }
}

class _Catalogue extends DoubanRepository {
  @override
  Future<DoubanResultPage> browse({
    required DoubanKind kind,
    String? sort,
    List<String> tags = const [],
    DoubanFilters filters = const DoubanFilters(),
    int start = 0,
    int count = 20,
    CancelToken? cancelToken,
  }) async =>
      const DoubanResultPage(items: [], start: 0, nextStart: 0, hasMore: false);
}

class _BoardCatalogue extends _Catalogue {
  final requests = <DoubanKind>[];
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
    requests.add(kind);
    return DoubanResultPage(
      items: [
        const DoubanTitle(
          id: '36889088',
          title: '怒之杀',
          originalTitle: 'Mutiny',
          kind: DoubanKind.movie,
          year: '2026',
          score: 5.6,
        ),
        for (var i = 1; i < 60; i++)
          DoubanTitle(
            id: '${70000000 + i}',
            title: '榜单作品$i',
            kind: kind,
            year: '2026',
          ),
      ],
      start: 0,
      nextStart: 60,
      hasMore: false,
      tags: const ['旅行'],
    );
  }

  @override
  Future<List<DoubanTagGroup>> tagGroups({
    required DoubanKind kind,
    DoubanFilters filters = const DoubanFilters(),
    CancelToken? cancelToken,
  }) async => [];
  @override
  Future<List<String>> discoverThemes({
    required DoubanKind kind,
    String? seed,
    CancelToken? cancelToken,
  }) async => [];
}

const _ratingResult = CinemaRatings(
  // Keep the review section inactive: this test checks identity plumbing via
  // its input title and never makes a real ratings/reviews/network request.
  identity: RatingIdentity(),
  message: 'isolated actor discovery fixture',
  ratings: [
    CinemaRating(provider: '豆瓣', value: 5.6, verified: true, note: 'fixture'),
    CinemaRating(provider: 'IMDb', value: 8.2, verified: true, note: 'fixture'),
    CinemaRating(
      provider: '烂番茄',
      value: 91,
      scale: 100,
      verified: true,
      note: 'fixture',
    ),
  ],
);

class _Ratings extends CinemaRatingsRepository {
  DoubanSubjectDetails detailsResult = const DoubanSubjectDetails(
    doubanId: '',
    note: 'fixture',
  );
  final notifier = ChangeNotifier();
  final loaded = <CinemaTitle>[];
  final providerLoads = <(String, String)>[];
  final cardLoads = <String>[];
  final scores = <(String, String), double?>{};
  @override
  Listenable get changes => notifier;
  @override
  CinemaRatings peek(CinemaTitle title) => _ratingResult;
  @override
  double? scoreFor(CinemaTitle title, String provider) {
    final key = (title.key, provider);
    return scores.containsKey(key)
        ? scores[key]
        : super.scoreFor(title, provider);
  }

  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async {
    loaded.add(title);
    return _ratingResult;
  }

  @override
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async =>
      _ratingResult;
  @override
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async => detailsResult;
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    cardLoads.add(title.key);
    return _ratingResult;
  }

  @override
  Future<CinemaRatings> loadForProvider(
    CinemaTitle title,
    String provider, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    providerLoads.add((title.key, provider));
    return _ratingResult;
  }
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _SearchDiscovery discovery;
  late _Ratings ratings;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('home-actor-discovery-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    await store.load();
    repository = _Repository();
    discovery = _SearchDiscovery();
    ratings = _Ratings();
  });
  tearDown(() async {
    store.dispose();
    ratings.notifier.dispose();
    await directory.delete(recursive: true);
  });

  Finder person(CinemaDiscoveryPerson value) =>
      find.byKey(ValueKey('discovery-person:${value.id}'));
  Finder metadataCard(CinemaDiscoveryTitle value) =>
      find.byKey(ValueKey('discovery-title:${value.id}'));
  Finder sourceCard() =>
      find.byKey(const ValueKey('title-card:actor-source::raw-film'));
  CinemaTitle cardTitle(WidgetTester tester) => tester
      .widget<CinemaCardRatings>(
        find.descendant(
          of: sourceCard(),
          matching: find.byType(CinemaCardRatings),
        ),
      )
      .title;

  Future<void> mount(WidgetTester tester, {DoubanRepository? catalogue}) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          repository: repository,
          ratingsRepository: ratings,
          catalogDiscovery: catalogue ?? _Catalogue(),
          doubanThemeCatalog: DoubanThemeCatalog(),
          searchDiscovery: discovery,
          enableWatchTogether: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> search(
    WidgetTester tester,
    String keyword, {
    bool settle = true,
  }) async {
    await tester.enterText(find.byType(TextField).first, keyword);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    if (settle) await tester.pumpAndSettle();
  }

  Future<void> select(
    WidgetTester tester,
    CinemaDiscoveryPerson value, {
    bool settle = true,
  }) async {
    await tester.ensureVisible(person(value));
    await tester.tap(person(value));
    await tester.pump();
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets(
    'actor selection is explicit and pagination retains candidates and unique works',
    (tester) async {
      await mount(tester);
      await search(tester, '演员');
      expect(discovery.requests, isEmpty);
      expect(person(_firstActor), findsOneWidget);
      expect(person(_secondActor), findsOneWidget);
      expect(metadataCard(_metadata), findsNothing);
      await select(tester, _firstActor);
      expect(discovery.requests, [(id: _firstActor.id, start: 0)]);
      expect(tester.widget<ChoiceChip>(person(_firstActor)).selected, isTrue);
      expect(tester.widget<ChoiceChip>(person(_secondActor)).selected, isFalse);
      expect(metadataCard(_metadata), findsOneWidget);
      await tester.tap(find.text('更多参演作品'));
      await tester.pumpAndSettle();
      expect(discovery.requests, [
        (id: _firstActor.id, start: 0),
        (id: _firstActor.id, start: 1),
      ]);
      expect(person(_firstActor), findsOneWidget);
      expect(person(_secondActor), findsOneWidget);
      expect(metadataCard(_metadata), findsOneWidget);
      expect(metadataCard(_nextMetadata), findsOneWidget);
      expect(find.text('更多参演作品'), findsNothing);
      expect(repository.details, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actor metadata sorts by provider, counts all works and preloads offscreen next-page cards',
    (tester) async {
      final nextPage = [
        for (var i = 0; i < 20; i++)
          CinemaDiscoveryTitle(
            id: '${40000000 + i}',
            title: '续页作品$i',
            year: '2023',
            identityVerified: true,
          ),
      ];
      discovery.workResults[(
        id: _firstActor.id,
        start: 0,
      )] = const CinemaSearchDiscovery(
        titles: [_metadata, _nextMetadata],
        celebrityId: '1049484',
        celebrityName: '演员甲',
        nextStart: 2,
        hasMore: true,
      );
      discovery.workResults[(
        id: _firstActor.id,
        start: 2,
      )] = CinemaSearchDiscovery(
        titles: nextPage,
        celebrityId: _firstActor.id,
        celebrityName: _firstActor.name,
        nextStart: 22,
      );
      ratings.scores.addAll({
        (_metadata.metadata.key, '豆瓣'): 5.6,
        (_nextMetadata.metadata.key, '豆瓣'): 8.6,
        (_metadata.metadata.key, 'IMDb'): 9.2,
        (_nextMetadata.metadata.key, 'IMDb'): 6.1,
        for (final title in nextPage) (title.metadata.key, 'IMDb'): 5.0,
        (nextPage.last.metadata.key, 'IMDb'): null,
      });
      await mount(tester);
      await search(tester, '演员');
      await select(tester, _firstActor);
      final initialSourceSearches = repository.searches.toList();
      await tester.tap(find.byKey(const ValueKey('catalog-sort-rating')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(metadataCard(_nextMetadata)).dx,
        lessThan(tester.getTopLeft(metadataCard(_metadata)).dx),
      );
      expect(find.textContaining('已加载 2/2 部有豆瓣评分'), findsOneWidget);
      expect(find.textContaining('片源结果与相关作品分别排序'), findsOneWidget);
      expect(
        ratings.providerLoads,
        containsAll([
          (_metadata.metadata.key, '豆瓣'),
          (_nextMetadata.metadata.key, '豆瓣'),
        ]),
      );

      await tester.tap(find.byKey(const ValueKey('catalog-rating-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('IMDb').last);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(metadataCard(_metadata)).dx,
        lessThan(tester.getTopLeft(metadataCard(_nextMetadata)).dx),
      );
      expect(find.textContaining('已加载 2/2 部有IMDb评分'), findsOneWidget);
      expect(repository.searches, initialSourceSearches);
      expect(repository.details, isEmpty);

      await tester.tap(find.text('更多参演作品'));
      await tester.pumpAndSettle();
      expect(discovery.requests.last, (id: _firstActor.id, start: 2));
      expect(find.textContaining('已加载 21/22 部有IMDb评分'), findsOneWidget);
      expect(
        metadataCard(nextPage.last),
        findsNothing,
        reason: 'The last card has not been built in the horizontal viewport.',
      );
      expect(ratings.cardLoads, isNot(contains(nextPage.last.metadata.key)));
      expect(
        ratings.providerLoads,
        containsAll([
          for (final title in nextPage) (title.metadata.key, 'IMDb'),
        ]),
        reason: 'Preloading must not depend on visible-card construction.',
      );
      expect(
        repository.searches,
        initialSourceSearches,
        reason:
            'Actor pagination and score controls must not rerun source search.',
      );
      expect(repository.details, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pendingPage in [0, 1]) {
    testWidgets(
      'switching actor cancels late page $pendingPage without replacing the new actor',
      (tester) async {
        final request = (id: _firstActor.id, start: pendingPage);
        final gate = discovery.pendingWorks[request] =
            Completer<CinemaSearchDiscovery>();
        await mount(tester);
        await search(tester, '演员');
        await select(tester, _firstActor, settle: pendingPage != 0);
        if (pendingPage == 1) {
          await tester.tap(find.text('更多参演作品'));
          await tester.pump();
        }
        final oldToken = discovery.tokens[request]!;
        expect(
          tester.widget<ChoiceChip>(person(_firstActor)).onSelected,
          isNull,
        );
        expect(
          tester.widget<ChoiceChip>(person(_secondActor)).onSelected,
          isNotNull,
        );
        await select(tester, _secondActor);
        expect(oldToken.isCancelled, isTrue);
        expect(metadataCard(_otherMetadata), findsOneWidget);
        gate.complete(discovery.works(request));
        await tester.pumpAndSettle();
        expect(
          tester.widget<ChoiceChip>(person(_secondActor)).selected,
          isTrue,
        );
        expect(
          tester.widget<ChoiceChip>(person(_firstActor)).selected,
          isFalse,
        );
        expect(metadataCard(_otherMetadata), findsOneWidget);
        expect(metadataCard(_metadata), findsNothing);
        expect(metadataCard(_nextMetadata), findsNothing);
        expect(find.text('更多参演作品'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final action in [
    'detail close',
    'canceled resolution',
    'recommended work',
  ]) {
    testWidgets(
      'Douban card $action returns to the same board and reopening restores it',
      (tester) async {
        final cancel = action == 'canceled resolution';
        final recommend = action == 'recommended work';
        if (recommend) {
          ratings.detailsResult = const DoubanSubjectDetails(
            doubanId: '36889088',
            title: '怒之杀',
            recommendations: [
              DoubanRecommendation(
                doubanId: '1292052',
                title: '推荐作品',
                year: '1994',
              ),
            ],
          );
        }
        final catalogue = _BoardCatalogue();
        final pending = Completer<CinemaPage>();
        if (cancel) {
          repository.pending['怒之杀'] = pending;
        } else {
          repository.results['怒之杀'] = [_rawTitle];
        }
        await mount(tester, catalogue: catalogue);
        await tester.tap(find.text('豆瓣榜单'));
        await tester.pumpAndSettle();
        final board = find.byType(DoubanPage);
        final view = find.descendant(
          of: board,
          matching: find.byType(CustomScrollView),
        );
        final scroll = tester.widget<CustomScrollView>(view).controller!;
        scroll.jumpTo(260);
        await tester.pumpAndSettle();
        final before = scroll.offset;
        final calls = catalogue.requests.length;
        final card = find.byKey(const ValueKey('douban-36889088'));
        expect(card.hitTestable(), findsOneWidget);
        await tester.tap(card);
        if (cancel) {
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.text('正在查找播放线路'), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          pending.complete(const CinemaPage(items: [_rawTitle]));
          await tester.pumpAndSettle();
          expect(find.byType(CinemaRatingsPanel), findsNothing);
        } else {
          await tester.pumpAndSettle();
          final panel = tester.widget<CinemaRatingsPanel>(
            find.byType(CinemaRatingsPanel),
          );
          expect(panel.title.doubanId, '36889088');
          expect(panel.title.aliases, 'Mutiny');
          expect(panel.title.sourceDoubanScore, 5.6);
          if (recommend) {
            final recommendedCard = find.byKey(
              const ValueKey('douban-rec-1292052'),
            );
            await tester.ensureVisible(recommendedCard);
            await tester.pumpAndSettle();
            await tester.tap(recommendedCard);
            await tester.pumpAndSettle();
            expect(find.text('暂未找到匹配的片源'), findsOneWidget);
            expect(repository.searches, contains('推荐作品'));
            expect(discovery.searches, isEmpty);
            await tester.tap(find.widgetWithText(TextButton, '关闭'));
            await tester.pumpAndSettle();
          } else {
            await tester.tap(find.byTooltip('关闭'));
            await tester.pumpAndSettle();
          }
        }
        expect(board, findsOneWidget);
        expect(tester.widget<CustomScrollView>(view).controller, same(scroll));
        expect(scroll.offset, closeTo(before, 1));
        expect(catalogue.requests, hasLength(calls));
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(board, findsNothing);
        await tester.tap(find.text('豆瓣榜单'));
        await tester.pumpAndSettle();
        expect(board, findsOneWidget);
        final restored = tester.widget<CustomScrollView>(view).controller!;
        expect(restored, isNot(same(scroll)));
        expect(restored.offset, closeTo(before, 1));
        expect(catalogue.requests, hasLength(calls));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'metadata card resolves a real source and keeps rating identity through ID-less detail',
    (tester) async {
      repository.results['怒之杀'] = [_rawTitle];
      await mount(tester);
      await search(tester, '演员');
      await select(tester, _firstActor);
      for (final provider in ['豆瓣', 'IMDb', '烂番茄']) {
        expect(
          find.descendant(
            of: metadataCard(_metadata),
            matching: find.byKey(ValueKey('card-rating-$provider')),
          ),
          findsOneWidget,
        );
      }
      await tester.tap(metadataCard(_metadata));
      await tester.pumpAndSettle();
      expect(repository.searches, contains('怒之杀'));
      expect(repository.details, hasLength(1));
      expect(repository.details.single.sourceId, _source.id);
      expect(repository.details.single.id, _rawTitle.id);
      expect(repository.details.single.doubanId, _metadata.id);
      final panel = tester.widget<CinemaRatingsPanel>(
        find.byType(CinemaRatingsPanel),
      );
      expect(panel.sourceName, _source.name);
      expect(panel.title.sourceId, _source.id);
      expect(panel.title.id, _rawTitle.id);
      expect(panel.title.doubanId, _metadata.id);
      expect(panel.title.sourceDoubanScore, _metadata.score);
      expect(panel.title.description, '来源接口最新简介');
      expect(panel.title.routes.single, _route);
      expect(ratings.loaded.last.doubanId, _metadata.id);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '开始观看'))
            .onPressed,
        isNotNull,
      );
      expect(find.byType(CinemaPlayerPage), findsNothing);
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final metadataFirst in [true, false]) {
    testWidgets(
      'verified discovery identity reaches source card with metadataFirst=$metadataFirst',
      (tester) async {
        final sourceGate = repository.pending['Mutiny'] =
            Completer<CinemaPage>();
        final metadataGate = discovery.pendingSearch['Mutiny'] =
            Completer<CinemaSearchDiscovery>();
        await mount(tester);
        await search(tester, 'Mutiny', settle: false);
        void finishSource() =>
            sourceGate.complete(const CinemaPage(items: [_rawTitle]));
        void finishMetadata() => metadataGate.complete(
          const CinemaSearchDiscovery(titles: [_metadata]),
        );
        if (metadataFirst) {
          finishMetadata();
          await tester.pump();
          expect(metadataCard(_metadata), findsOneWidget);
          expect(sourceCard(), findsNothing);
          finishSource();
        } else {
          finishSource();
          await tester.pump();
          expect(sourceCard(), findsOneWidget);
          expect(cardTitle(tester).doubanId, isEmpty);
          finishMetadata();
        }
        await tester.pumpAndSettle();
        expect(cardTitle(tester).doubanId, _metadata.id);
        expect(
          cardTitle(tester).sourceDoubanScore,
          isNull,
          reason:
              'Identity binding does not relabel public metadata as a source score.',
        );
        expect(cardTitle(tester).sourceId, _source.id);
        expect(
          metadataCard(_metadata),
          findsNothing,
          reason: 'One discovered work should not duplicate its source card.',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final candidates in [
    const [CinemaDiscoveryTitle(id: '36889088', title: '怒之杀', year: '2026')],
    const [
      _metadata,
      CinemaDiscoveryTitle(
        id: '12345678',
        title: '怒之杀',
        year: '2026',
        identityVerified: true,
      ),
    ],
  ]) {
    testWidgets(
      'source card rejects ${candidates.length == 1 ? 'unverified' : 'ambiguous'} metadata identity',
      (tester) async {
        repository.results['Mutiny'] = [_rawTitle];
        discovery.searchResults['Mutiny'] = CinemaSearchDiscovery(
          titles: candidates,
        );
        await mount(tester);
        await search(tester, 'Mutiny');
        expect(cardTitle(tester).doubanId, isEmpty);
        expect(cardTitle(tester).sourceDoubanScore, isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
