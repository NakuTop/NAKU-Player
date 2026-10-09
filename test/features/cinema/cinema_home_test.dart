import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

const _source = CinemaSource(
  id: 'fixture',
  name: '测试目录',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.com/api.php/provide/vod',
);

class _Repository extends CinemaRepository {
  Completer<CinemaPage>? pending;
  final browsed = <String?>[];
  bool useMetadata = false;
  bool manyItems = false;
  bool failBrowse = false;
  final searched = <String>[];
  final delayedBrowse = <String, Completer<CinemaPage>>{};

  List<CinemaTitle> _metadataItems(String? categoryId, int page) {
    final prefix = categoryId == '22' ? '剧集' : '电影';
    final category = categoryId == '22' ? '欧美剧' : '剧情片';
    final suffix = page == 1 ? '' : '第$page页';
    return [
      CinemaTitle(
        id: '$categoryId-$page-popular',
        sourceId: _source.id,
        title: '$prefix较早热门$suffix',
        category: category,
        sourceHits: 90,
        sourceUpdatedAt: DateTime.utc(2025),
      ),
      CinemaTitle(
        id: '$categoryId-$page-latest',
        sourceId: _source.id,
        title: '$prefix最近更新$suffix',
        category: category,
        sourceHits: 10,
        sourceUpdatedAt: DateTime.utc(2026),
      ),
      CinemaTitle(
        id: '$categoryId-$page-missing',
        sourceId: _source.id,
        title: '$prefix缺少数据$suffix',
        category: category,
      ),
    ];
  }

  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browsed.add(categoryId);
    if (failBrowse) throw const CinemaSourceException('fixture offline');
    if (delayedBrowse[categoryId] case final pending?) return pending.future;
    return CinemaPage(
      page: page,
      pageCount: useMetadata ? 2 : 1,
      items: manyItems
          ? List.generate(
              30,
              (index) => CinemaTitle(
                id: '$categoryId-$index',
                sourceId: source.id,
                title: '${categoryId == '22' ? '剧集' : '电影'}作品 $index',
                category: categoryId == '22' ? '欧美剧' : '剧情片',
              ),
            )
          : useMetadata
          ? _metadataItems(categoryId, page)
          : [
              CinemaTitle(
                id: 'title-$categoryId',
                sourceId: source.id,
                title: categoryId == '22' ? '剧集测试作品' : '电影测试作品',
                category: categoryId == '22' ? '欧美剧' : '剧情片',
              ),
            ],
      categories: const [
        CinemaCategory(id: '1', name: '电影'),
        CinemaCategory(id: '11', name: '剧情片', parentId: '1'),
        CinemaCategory(id: '12', name: '奇幻片'),
        CinemaCategory(id: '60', name: 'Netflix电影'),
        CinemaCategory(id: '2', name: '电视剧'),
        CinemaCategory(id: '22', name: '欧美剧', parentId: '2'),
        CinemaCategory(id: '23', name: '美国剧'),
        CinemaCategory(id: '61', name: 'Netflix自制剧'),
      ],
    );
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searched.add(keyword);
    if (keyword == '延迟') return (pending = Completer<CinemaPage>()).future;
    if (keyword == '排序搜索') {
      return const CinemaPage(
        items: [
          CinemaTitle(
            id: 'search-low',
            sourceId: 'fixture',
            title: '搜索低热结果',
            category: '剧情片',
            sourceHits: 1,
          ),
          CinemaTitle(
            id: 'search-high',
            sourceId: 'fixture',
            title: '搜索高热结果',
            category: '剧情片',
            sourceHits: 999,
          ),
        ],
      );
    }
    if (keyword == '多页') {
      return CinemaPage(
        page: page,
        pageCount: 2,
        items: [
          CinemaTitle(
            id: 'result-$page',
            sourceId: 'fixture',
            title: '第$page页作品',
            category: '剧情片',
          ),
        ],
      );
    }
    return const CinemaPage(
      items: [
        CinemaTitle(
          id: 'interstellar',
          sourceId: 'fixture',
          title: '星际穿越',
          category: '科幻片',
        ),
      ],
    );
  }
}

class _Discovery extends CinemaSearchDiscoveryRepository {
  bool paginated = false;
  Completer<CinemaSearchDiscovery>? worksPending;
  @override
  Future<CinemaSearchDiscovery> actorWorks(
    String id,
    String name, {
    int start = 0,
    CancelToken? cancelToken,
  }) => (worksPending = Completer<CinemaSearchDiscovery>()).future;
  final calls = <String>[];
  @override
  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async {
    calls.add(keyword);
    if (paginated) {
      return const CinemaSearchDiscovery(
        celebrityId: '1049484',
        celebrityName: '测试演员',
        hasMore: true,
        nextStart: 12,
        titles: [CinemaDiscoveryTitle(id: '36889088', title: '怒之杀')],
      );
    }
    return keyword == 'Jason Statham'
        ? const CinemaSearchDiscovery(
            celebrityName: '杰森·斯坦森',
            celebrityId: '1049484',
            titles: [
              CinemaDiscoveryTitle(id: '36889088', title: '怒之杀', year: '2026'),
            ],
          )
        : const CinemaSearchDiscovery(queries: ['星际穿越']);
  }
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yingchuan-ui-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    await store.load();
    repository = _Repository();
  });
  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    double width = 1280,
    CinemaSearchDiscoveryRepository? discovery,
  }) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: CinemaHomePage(
          enableSearchDiscovery: discovery != null,
          searchDiscovery: discovery,
          enableWatchTogether: false,
          store: store,
          repository: repository,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'original-name search resolves Chinese titles without losing raw source results',
    (tester) async {
      final discovery = _Discovery();
      await mount(tester, discovery: discovery);
      await tester.enterText(find.byType(TextField).first, 'Interstellar');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repository.searched, containsAll(['Interstellar', '星际穿越']));
      expect(find.text('星际穿越'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'actor metadata survives section return and opens source search',
    (tester) async {
      final discovery = _Discovery();
      await mount(tester, discovery: discovery);
      await tester.enterText(find.byType(TextField).first, 'Jason Statham');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('杰森·斯坦森参演作品 · 点击查找片源'), findsOneWidget);
      await tester.tap(find.text('剧集').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('电影').first);
      await tester.pumpAndSettle();
      expect(discovery.calls, ['Jason Statham']);
      await tester.ensureVisible(find.text('怒之杀').first);
      await tester.tap(find.text('怒之杀').first);
      await tester.pumpAndSettle();
      expect(repository.searched, contains('怒之杀'));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('source pagination does not strand concurrent actor pagination', (
    tester,
  ) async {
    final discovery = _Discovery()..paginated = true;
    await mount(tester, discovery: discovery);
    await tester.enterText(find.byType(TextField).first, '多页');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('更多参演作品'));
    await tester.tap(find.text('更多参演作品'));
    await tester.pump();
    await tester.ensureVisible(find.text('加载更多搜索结果'));
    await tester.tap(find.text('加载更多搜索结果'));
    await tester.pump();
    discovery.worksPending!.complete(
      const CinemaSearchDiscovery(
        celebrityId: '1049484',
        celebrityName: '测试演员',
        hasMore: true,
        nextStart: 24,
        titles: [CinemaDiscoveryTitle(id: '1889243', title: '星际穿越')],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '更多参演作品'))
          .onPressed,
      isNotNull,
    );
    expect(tester.takeException(), isNull);
  });

  Finder sortChip(CinemaCatalogSort sort) =>
      find.byKey(ValueKey('catalog-sort-${sort.name}'));

  void expectSelected(WidgetTester tester, CinemaCatalogSort sort) {
    expect(tester.widget<ChoiceChip>(sortChip(sort)).selected, isTrue);
  }

  void expectBefore(WidgetTester tester, String first, String second) {
    // Card title text is after its poster fallback text in the widget tree.
    expect(
      tester.getTopLeft(find.text(first).last).dx,
      lessThan(tester.getTopLeft(find.text(second).last).dx),
    );
  }

  testWidgets('catalogue chips sort actual metadata without re-fetching', (
    tester,
  ) async {
    repository.useMetadata = true;
    await mount(tester);
    expectSelected(tester, CinemaCatalogSort.latest);
    expect(find.text('当前页·片源更新时间'), findsOneWidget);
    expectBefore(tester, '电影最近更新', '电影较早热门');
    expect(find.textContaining('本页 2/3 项有更新时间'), findsOneWidget);
    final requests = repository.browsed.length;
    await tester.tap(sortChip(CinemaCatalogSort.popular));
    await tester.pumpAndSettle();
    expectSelected(tester, CinemaCatalogSort.popular);
    expect(find.text('当前页·片源热度'), findsOneWidget);
    expectBefore(tester, '电影较早热门', '电影最近更新');
    expectBefore(tester, '电影最近更新', '电影缺少数据');
    expect(repository.browsed, hasLength(requests));
    await tester.tap(sortChip(CinemaCatalogSort.latest));
    await tester.pumpAndSettle();
    expectBefore(tester, '电影最近更新', '电影较早热门');
  });

  testWidgets('movie and series sort selections remain independent', (
    tester,
  ) async {
    repository.useMetadata = true;
    await mount(tester);
    await tester.tap(sortChip(CinemaCatalogSort.popular));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expectSelected(tester, CinemaCatalogSort.latest);
    expectBefore(tester, '剧集最近更新', '剧集较早热门');
    await tester.tap(sortChip(CinemaCatalogSort.popular));
    await tester.pumpAndSettle();
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expectSelected(tester, CinemaCatalogSort.popular);
    expectBefore(tester, '电影较早热门', '电影最近更新');
    await tester.tap(sortChip(CinemaCatalogSort.latest));
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expectSelected(tester, CinemaCatalogSort.popular);
    expectBefore(tester, '剧集较早热门', '剧集最近更新');
  });

  testWidgets(
    'popular selection does not reorder searches or show search chips',
    (tester) async {
      repository.useMetadata = true;
      await mount(tester);
      await tester.tap(sortChip(CinemaCatalogSort.popular));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '排序搜索');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(sortChip(CinemaCatalogSort.popular), findsNothing);
      expect(sortChip(CinemaCatalogSort.latest), findsNothing);
      expectBefore(tester, '搜索低热结果', '搜索高热结果');
      await tester.enterText(find.byType(TextField), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expectSelected(tester, CinemaCatalogSort.popular);
      expectBefore(tester, '电影较早热门', '电影最近更新');
    },
  );

  testWidgets(
    'page changes retain sorting and replace the current-page items',
    (tester) async {
      repository.useMetadata = true;
      await mount(tester);
      await tester.tap(sortChip(CinemaCatalogSort.popular));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('下一页'));
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
      expect(find.text('2 / 2'), findsOneWidget);
      expect(find.text('电影较早热门'), findsNothing);
      expectBefore(tester, '电影较早热门第2页', '电影最近更新第2页');
    },
  );

  testWidgets(
    'missing source metrics are explained instead of implying a chart',
    (tester) async {
      await mount(tester);
      expect(find.text('片源未提供本页可用更新时间，保留片源顺序。'), findsOneWidget);
      await tester.tap(sortChip(CinemaCatalogSort.popular));
      await tester.pumpAndSettle();
      expect(find.text('片源未提供本页可用热度，保留片源顺序。'), findsOneWidget);
      expect(find.text('电影测试作品'), findsWidgets);
    },
  );

  testWidgets(
    'opens a real leaf category and switches movie / series catalogues',
    (tester) async {
      await mount(tester);
      expect(repository.browsed, [null, '11']);
      expect(find.text('电影测试作品'), findsWidgets);
      expect(find.text('奇幻片'), findsOneWidget);
      expect(find.text('Netflix电影'), findsOneWidget);
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(repository.browsed.last, '22');
      expect(find.text('剧集测试作品'), findsWidgets);
      expect(find.text('美国剧'), findsOneWidget);
      expect(find.text('Netflix自制剧'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'searches movie source directly and ignores stale search after a tab change',
    (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(TextField), '星际穿越');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('星际穿越'), findsWidgets);
      await tester.enterText(find.byType(TextField), '延迟');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      repository.pending!.complete(
        const CinemaPage(
          items: [
            CinemaTitle(
              id: 'old',
              sourceId: 'fixture',
              title: '过期搜索结果',
              category: '剧情片',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('过期搜索结果'), findsNothing);
      expect(find.text('剧集测试作品'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loads later search pages without discarding earlier results', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), '多页');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('加载更多搜索结果'));
    await tester.tap(find.text('加载更多搜索结果'));
    await tester.pumpAndSettle();
    expect(find.text('第1页作品'), findsWidgets);
    expect(find.text('第2页作品'), findsWidgets);
    expect(find.text('加载更多搜索结果'), findsNothing);
  });

  testWidgets('returning to a catalogue keeps its page and makes no requests', (
    tester,
  ) async {
    repository.useMetadata = true;
    await mount(tester);
    await tester.ensureVisible(find.byTooltip('下一页'));
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    final calls = repository.browsed.length;
    await tester.tap(find.text('电影'));
    await tester.pump();
    expect(find.text('2 / 2'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(repository.browsed, hasLength(calls));
    expect(find.text('电影最近更新第2页'), findsWidgets);
    // Series can reuse the categories already loaded by Movies.
    expect(repository.browsed.where((id) => id == null), hasLength(1));
  });

  testWidgets('an offscreen catalogue finishes once and is ready on return', (
    tester,
  ) async {
    await mount(tester);
    final pending = repository.delayedBrowse['22'] = Completer<CinemaPage>();
    await tester.tap(find.text('剧集'));
    await tester.pump();
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(find.text('电影测试作品'), findsWidgets);
    pending.complete(
      const CinemaPage(
        items: [
          CinemaTitle(
            id: 'ready-series',
            sourceId: 'fixture',
            title: '后台完成的剧集',
            category: '欧美剧',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    final calls = repository.browsed.length;
    expect(find.text('后台完成的剧集'), findsNothing);
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(find.text('后台完成的剧集'), findsWidgets);
    expect(repository.browsed, hasLength(calls));
    expect(tester.takeException(), isNull);
  });

  testWidgets('movie and series retain independent scroll offsets on return', (
    tester,
  ) async {
    repository.manyItems = true;
    await mount(tester);
    final catalogue = find.byType(CustomScrollView);
    final verticalScroll = find.descendant(
      of: catalogue,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    double offset() =>
        tester.state<ScrollableState>(verticalScroll).position.pixels;

    await tester.drag(catalogue, const Offset(0, -650));
    await tester.pumpAndSettle();
    final movieOffset = offset();
    expect(movieOffset, greaterThan(500));

    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(offset(), 0);
    await tester.drag(catalogue, const Offset(0, -280));
    await tester.pumpAndSettle();
    final seriesOffset = offset();
    expect(seriesOffset, greaterThan(150));
    final calls = repository.browsed.length;

    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(offset(), closeTo(movieOffset, 1));
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(offset(), closeTo(seriesOffset, 1));
    expect(repository.browsed, hasLength(calls));
    expect(tester.takeException(), isNull);
  });

  testWidgets('search results and input survive a sidebar round trip', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), '星际穿越');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '星际穿越',
    );
    expect(find.text('星际穿越'), findsWidgets);
    expect(repository.searched, ['星际穿越']);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('refresh failure leaves previously loaded cards usable', (
    tester,
  ) async {
    await mount(tester);
    repository.failBrowse = true;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('电影测试作品'), findsWidgets);
    expect(find.text('暂时无法刷新，保留上次加载的内容。'), findsOneWidget);
    expect(find.text('暂时未能连接'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library changes do not invalidate an already loaded catalogue', (
    tester,
  ) async {
    await mount(tester);
    final calls = repository.browsed.length;
    await tester.runAsync(
      () => store.toggleFavorite(
        const CinemaTitle(id: 'saved', sourceId: 'fixture', title: '收藏测试'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('电影测试作品'), findsWidgets);
    expect(repository.browsed, hasLength(calls));
  });

  testWidgets(
    'failed category switch cannot show cards from the previous category',
    (tester) async {
      await mount(tester);
      repository.failBrowse = true;
      await tester.tap(find.text('奇幻片'));
      await tester.pumpAndSettle();
      expect(find.text('电影测试作品'), findsNothing);
      expect(find.text('暂时未能连接'), findsOneWidget);
    },
  );

  testWidgets('compact window exposes navigation without layout overflow', (
    tester,
  ) async {
    await mount(tester, width: 700);
    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('我的收藏'));
    await tester.pumpAndSettle();
    expect(find.text('暂无收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
