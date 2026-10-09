import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_filters.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';

final _sources = [
  for (var i = 0; i < 5; i++)
    CinemaSource(
      id: 'pipeline-$i',
      name: '测试源$i',
      kind: CinemaSourceKind.maccms,
      url: 'https://pipeline$i.invalid/api',
    ),
];
typedef _Request = ({String source, String keyword, int page});

class _Repository extends CinemaRepository {
  final searches = <_Request>[];
  final browses = <({String source, String year})>[];
  final delayedKeywords = <String>{};
  final pending = <_Request, Completer<CinemaPage>>{};
  int active = 0, peakActive = 0;
  bool moreSearchPages = false;

  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '11', name: '剧情片'),
  ];
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) => browseFiltered(source, categoryId: categoryId, page: page);
  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) async {
    browses.add((source: source.id, year: year));
    return CinemaPage(
      items: [
        CinemaTitle(
          id: 'catalogue',
          sourceId: source.id,
          title: '年度目录${source.id}',
          year: year.isEmpty ? '2026' : year,
          category: '剧情片',
          categoryId: '11',
        ),
      ],
    );
  }

  CinemaPage result(_Request request) {
    final index = int.parse(request.source.split('-').last);
    final name = switch (request.keyword) {
      'Interstellar' => '星际穿越$index',
      '旧查询' => '旧结果$index',
      '新查询' => '当前结果$index',
      '评分查询' => '评分作品$index',
      _ => '异步作品$index',
    };
    return CinemaPage(
      page: request.page,
      pageCount: moreSearchPages ? 2 : 1,
      items: [
        CinemaTitle(
          id: '${request.keyword}-${request.page}',
          sourceId: request.source,
          title: request.page == 1 ? name : '$name第二页',
          aliases: request.keyword,
          year: request.keyword == 'Interstellar' ? '2014' : '2019',
          category: '剧情片',
          categoryId: '11',
        ),
      ],
    );
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    final request = (source: source.id, keyword: keyword, page: page);
    searches.add(request);
    active++;
    if (active > peakActive) peakActive = active;
    try {
      if (delayedKeywords.contains(keyword)) {
        return await (pending[request] = Completer<CinemaPage>()).future;
      }
      return result(request);
    } finally {
      active--;
    }
  }

  void complete(int source, String keyword, {bool fail = false}) {
    final request = (source: 'pipeline-$source', keyword: keyword, page: 1);
    final completion = pending[request]!;
    if (fail) {
      completion.completeError(const CinemaSourceException('late old failure'));
    } else {
      completion.complete(result(request));
    }
  }
}

class _Discovery extends DoubanRepository {
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

class _Ratings extends CinemaRatingsRepository {
  final notifier = ChangeNotifier();
  final providerLoads = <(String, String)>[];
  @override
  Listenable get changes => notifier;
  @override
  double? scoreFor(CinemaTitle title, String provider) {
    final index = int.parse(title.sourceId.split('-').last);
    return (provider == 'IMDb'
        ? <double?>[9, 8, 7, null, 6]
        : <double?>[6, 9, 8, null, 7])[index];
  }

  @override
  CinemaRatings peek(CinemaTitle title) => CinemaRatings(
    identity: const RatingIdentity(),
    message: 'isolated pipeline fixture',
    ratings: [
      for (final provider in ['豆瓣', 'IMDb'])
        CinemaRating(
          provider: provider,
          value: scoreFor(title, provider),
          note: 'fixture',
          verified: true,
        ),
    ],
  );
  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async => peek(title);
  @override
  Future<CinemaRatings> loadForProvider(
    CinemaTitle title,
    String provider, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    providerLoads.add((title.key, provider));
    return peek(title);
  }
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _Ratings ratings;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('home-search-pipeline-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: _sources,
    );
    await store.load();
    repository = _Repository();
    ratings = _Ratings();
  });
  tearDown(() async {
    store.dispose();
    ratings.notifier.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester) async {
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
          catalogDiscovery: _Discovery(),
          enableWatchTogether: false,
          enableSearchDiscovery: false,
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

  Future<void> year(WidgetTester tester, String current, String next) async {
    await tester.tap(find.byKey(ValueKey('cinema-filter-年份-$current')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(next).last);
    await tester.tap(find.text(next).last);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CinemaFilterBar>(find.byType(CinemaFilterBar)).value.year,
      next,
    );
  }

  Finder card(String source, String keyword, {int page = 1}) =>
      find.byKey(ValueKey('title-card:$source::$keyword-$page'));
  List<int> visualOrder(WidgetTester tester, String keyword) {
    final positions = [
      for (var i = 0; i < 5; i++)
        (index: i, position: tester.getTopLeft(card('pipeline-$i', keyword))),
    ];
    positions.sort((a, b) {
      final row = a.position.dy.compareTo(b.position.dy);
      return row == 0 ? a.position.dx.compareTo(b.position.dx) : row;
    });
    return positions.map((p) => p.index).toList();
  }

  testWidgets(
    'new searches clear the previous catalogue or search year filter',
    (tester) async {
      await mount(tester);
      await year(tester, '', '2026');
      expect(repository.browses.any((r) => r.year == '2026'), isTrue);
      await search(tester, 'Interstellar');
      final firstFilters = tester.widget<CinemaFilterBar>(
        find.byType(CinemaFilterBar),
      );
      expect(firstFilters.value.isEmpty, isTrue);
      expect(firstFilters.scope, '当前搜索结果');
      expect(card('pipeline-0', 'Interstellar'), findsOneWidget);
      expect(find.text('星际穿越0'), findsWidgets);
      expect(find.textContaining('2014'), findsWidgets);

      await year(tester, '', '2014');
      await search(tester, '新查询');
      expect(
        tester
            .widget<CinemaFilterBar>(find.byType(CinemaFilterBar))
            .value
            .isEmpty,
        isTrue,
      );
      expect(card('pipeline-0', '新查询'), findsOneWidget);
      expect(find.text('当前结果0'), findsWidgets);
      expect(card('pipeline-0', 'Interstellar'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three rolling workers start the next source while the first is still pending',
    (tester) async {
      repository.delayedKeywords.add('异步查询');
      await mount(tester);
      await search(tester, '异步查询', settle: false);
      expect(repository.searches.map((r) => r.source), [
        'pipeline-0',
        'pipeline-1',
        'pipeline-2',
      ]);
      expect(repository.active, 3);
      repository.complete(1, '异步查询');
      await tester.pump();
      expect(repository.searches.map((r) => r.source), [
        'pipeline-0',
        'pipeline-1',
        'pipeline-2',
        'pipeline-3',
      ]);
      expect(
        repository
            .pending[(source: 'pipeline-0', keyword: '异步查询', page: 1)]!
            .isCompleted,
        isFalse,
      );
      expect(repository.peakActive, 3);
      expect(card('pipeline-1', '异步查询'), findsOneWidget);
      repository.complete(2, '异步查询');
      await tester.pump();
      expect(repository.searches.last.source, 'pipeline-4');
      expect(repository.peakActive, 3);
      for (final i in [0, 3, 4]) {
        repository.complete(i, '异步查询');
      }
      await tester.pumpAndSettle();
      expect(repository.active, 0);
      expect(repository.searches, hasLength(5));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late results and failures from a previous generation cannot alter the new search',
    (tester) async {
      repository.delayedKeywords.add('旧查询');
      await mount(tester);
      await search(tester, '旧查询', settle: false);
      expect(
        repository.searches.where((r) => r.keyword == '旧查询'),
        hasLength(3),
      );
      await search(tester, '新查询');
      expect(find.text('当前结果0'), findsWidgets);
      repository.complete(0, '旧查询');
      repository.complete(1, '旧查询', fail: true);
      repository.complete(2, '旧查询');
      await tester.pumpAndSettle();
      expect(
        repository.searches.where((r) => r.keyword == '旧查询'),
        hasLength(3),
        reason: 'Stale generation must not start its fourth/fifth source.',
      );
      expect(
        repository.searches.where((r) => r.keyword == '新查询'),
        hasLength(5),
      );
      expect(find.text('旧结果0'), findsNothing);
      expect(find.textContaining('连接失败'), findsNothing);
      for (var i = 0; i < 5; i++) {
        expect(card('pipeline-$i', '新查询'), findsOneWidget);
      }
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '新查询',
      );
      expect(repository.active, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'search score sorting keeps the query and loaded results without browsing again',
    (tester) async {
      repository.moreSearchPages = true;
      await mount(tester);
      await search(tester, '评分查询');
      final browses = repository.browses.length;
      final searches = repository.searches.length;
      await tester.tap(find.byKey(const ValueKey('catalog-sort-rating')));
      await tester.pumpAndSettle();
      expect(visualOrder(tester, '评分查询'), [1, 2, 4, 0, 3]);
      await tester.tap(find.byKey(const ValueKey('catalog-rating-provider')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('IMDb').last);
      await tester.pumpAndSettle();
      expect(visualOrder(tester, '评分查询'), [0, 1, 2, 4, 3]);
      expect(repository.browses.length, browses);
      expect(repository.searches.length, searches);
      expect(
        tester.widget<CinemaFilterBar>(find.byType(CinemaFilterBar)).scope,
        '当前搜索结果',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '评分查询',
      );
      expect(ratings.providerLoads.any((call) => call.$2 == 'IMDb'), isTrue);

      final more = find.text('加载更多搜索结果');
      await tester.ensureVisible(more);
      await tester.tap(more);
      await tester.pumpAndSettle();
      final nextPages = repository.searches.where((r) => r.page == 2).toList();
      expect(nextPages, hasLength(5));
      expect(
        nextPages.every((r) => r.keyword == '评分查询'),
        isTrue,
        reason: 'Pagination must retain activeKeyword after score sorting.',
      );
      expect(repository.browses.length, browses);
      expect(tester.takeException(), isNull);
    },
  );
}
