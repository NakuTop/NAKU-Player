import 'package:kazumi/services/platform/naku_device.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_featured_wall.dart';
import 'package:kazumi/features/cinema/cinema_resource_badge.dart';
import 'package:kazumi/features/cinema/cinema_card_ratings.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';

const _source = CinemaSource(
  id: 'fixture',
  name: '测试目录',
  kind: CinemaSourceKind.maccms,
  url: 'https://example.com/api.php/provide/vod',
);

const _categories = [
  CinemaCategory(id: '1', name: '电影'),
  CinemaCategory(id: '11', name: '剧情片', parentId: '1'),
  CinemaCategory(id: '2', name: '电视剧'),
  CinemaCategory(id: '22', name: '欧美剧', parentId: '2'),
  CinemaCategory(id: '90', name: '擦边短剧', parentId: '2'),
];

class _CatalogDiscovery extends DoubanRepository {
  bool fail = false;
  List<DoubanTitle>? featuredFixtures;
  final calls = <DoubanFilters>[];
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
    calls.add(filters);
    if (fail) throw const DoubanException('fixture unavailable');
    if (sort == 'U') {
      final prefix = kind == DoubanKind.movie ? '电影' : '剧集';
      final suffix = start == 0 ? '' : '第2页';
      return DoubanResultPage(
        items:
            featuredFixtures ??
            [
              for (final (i, name) in ['较早热门', '最近更新', '缺少数据'].indexed)
                DoubanTitle(
                  id: '${kind == DoubanKind.movie ? 10000 : 20000}${start + i}',
                  title: '$prefix$name$suffix',
                  kind: kind,
                  year: '${DateTime.now().year}',
                  score: i == 0 ? 6 : 9,
                ),
            ],
        start: start,
        nextStart: start + 3,
        hasMore: start == 0,
      );
    }

    return const DoubanResultPage(
      items: [],
      start: 0,
      nextStart: 0,
      hasMore: false,
    );
  }
}

class _Repository extends CinemaRepository {
  bool hasHotResource = false;
  Completer<CinemaPage>? pending;
  final browsed = <String?>[];
  bool useMetadata = false;
  bool manyItems = false;
  bool failBrowse = false;
  final searched = <String>[];
  final delayedBrowse = <String, Completer<CinemaPage>>{};
  final delayedYears = <String, Completer<CinemaPage>>{};
  final filteredRequests =
      <({String source, String? category, String year, int page})>[];
  final failedSources = <String>{};
  bool blockedEntry = false;

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async =>
      title;

  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async =>
      _categories;

  @override
  Future<CinemaPage> browseFiltered(
    CinemaSource source, {
    String? categoryId,
    String year = '',
    int page = 1,
  }) async {
    filteredRequests.add((
      source: source.id,
      category: categoryId,
      year: year,
      page: page,
    ));
    if (failedSources.contains(source.id)) {
      throw const CinemaSourceException('fixture offline');
    }
    if (year.isEmpty || year == '${DateTime.now().year}') {
      return browse(source, categoryId: categoryId, page: page);
    }
    if (failBrowse) throw const CinemaSourceException('fixture offline');
    if (categoryId == '1' || categoryId == '2') {
      return const CinemaPage(items: []);
    }
    if (delayedYears[year] case final pending?) return pending.future;
    return CinemaPage(
      items: [
        CinemaTitle(
          id: '$categoryId-$year',
          sourceId: source.id,
          title: '$year年作品',
          year: year,
          category: categoryId == '22' ? '欧美剧' : '剧情片',
        ),
      ],
    );
  }

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
        year: '${DateTime.now().year}',
        sourceHits: 90,
        sourceUpdatedAt: DateTime.utc(2025),
      ),
      CinemaTitle(
        id: '$categoryId-$page-latest',
        sourceId: _source.id,
        title: '$prefix最近更新$suffix',
        category: category,
        year: '${DateTime.now().year}',
        sourceHits: 10,
        sourceUpdatedAt: DateTime.utc(2026),
      ),
      CinemaTitle(
        id: '$categoryId-$page-missing',
        sourceId: _source.id,
        title: '$prefix缺少数据$suffix',
        category: category,
        year: '${DateTime.now().year}',
      ),
      for (var index = 3; index < 20; index++)
        CinemaTitle(
          id: '$categoryId-$page-$index',
          sourceId: _source.id,
          title: '$prefix目录作品$page-$index',
          category: category,
          year: '${DateTime.now().year}',
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
    // MacCMS parent categories do not recurse into their children.
    if (categoryId == '1' || categoryId == '2') {
      return const CinemaPage(items: []);
    }
    if (delayedBrowse[categoryId] case final pending?) return pending.future;
    return CinemaPage(
      page: page,
      pageCount: useMetadata ? 3 : 1,
      items: blockedEntry && categoryId == '22'
          ? [
              const CinemaTitle(
                id: 'blocked',
                sourceId: 'fixture',
                title: '应被屏蔽的作品',
                categoryId: '90',
                category: '短剧',
                genres: '擦边',
              ),
            ]
          : manyItems
          ? List.generate(
              30,
              (index) => CinemaTitle(
                id: '$categoryId-$index',
                sourceId: source.id,
                title: '${categoryId == '22' ? '剧集' : '电影'}作品 $index',
                year: '${DateTime.now().year}',
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
                year: '2026',
                category: categoryId == '22' ? '欧美剧' : '剧情片',
              ),
            ],
      categories: _categories,
    );
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searched.add(keyword);
    if (hasHotResource && keyword.contains('较早热门')) {
      return CinemaPage(
        items: [
          CinemaTitle(
            id: 'hot4k',
            sourceId: source.id,
            title: '${keyword}4K',
            year: '${DateTime.now().year}',
            category: '电影',
            routes: const [
              CinemaRoute(
                name: 'test',
                episodes: [
                  CinemaEpisode(
                    name: '正片',
                    url: 'https://media.example/test.m3u8',
                  ),
                ],
              ),
            ],
          ),
        ],
      );
    }

    if (keyword == 'Interstellar') return const CinemaPage(items: []);
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
  setUpAll(() async {
    if (const String.fromEnvironment('NAKU_HOME_UI_OUTPUT').isEmpty) return;
    final bytes = await File(
      '/System/Library/Fonts/STHeiti Light.ttc',
    ).readAsBytes();
    for (final name in [
      '.AppleSystemUIFont',
      'Roboto',
      'MI_Sans_Regular',
      'Ahem',
    ]) {
      await (FontLoader(
        name,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          File(
            '../toolchains/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
          ).readAsBytes().then(ByteData.sublistView),
        ))
        .load();
  });

  late Directory directory;
  late CinemaStore store;
  late _Repository repository;
  late _CatalogDiscovery catalogDiscovery;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yingchuan-ui-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    await store.load();
    repository = _Repository();
    catalogDiscovery = _CatalogDiscovery();
  });
  tearDown(() async {
    store.dispose();
    await directory.delete(recursive: true);
  });

  Finder sortChip(CinemaCatalogSort sort) =>
      find.byKey(ValueKey('catalog-sort-${sort.name}'));

  Future<void> revealCatalogueFinder(WidgetTester tester, Finder target) async {
    final verticalScroll = find
        .descendant(
          of: find.byType(CustomScrollView).first,
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          ),
        )
        .first;
    if (target.evaluate().isEmpty) {
      // The full-width hero can put the controls beyond the lazy sliver's
      // cache. Scroll the catalogue until they exist before asking for an
      // element; ensureVisible cannot build an absent sliver child.
      await tester.scrollUntilVisible(target, 240, scrollable: verticalScroll);
    }
    await Scrollable.ensureVisible(tester.element(target), alignment: .35);
    // Actor pagination can intentionally remain pending while this control is
    // reached. The zero-duration scroll only needs a layout frame.
    await tester.pump();
    expect(target.hitTestable(), findsOneWidget);
  }

  Future<void> tapSort(WidgetTester tester, CinemaCatalogSort sort) async {
    final target = sortChip(sort);
    await revealCatalogueFinder(tester, target);
    await tester.tap(target);
  }

  Future<void> mount(
    WidgetTester tester, {
    double width = 1280,
    bool recentHot = false,
    bool prepareSeries = true,
    CinemaSearchDiscoveryRepository? discovery,
  }) async {
    tester.view.physicalSize = Size(width, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark().copyWith(platform: TargetPlatform.macOS),
        home: RepaintBoundary(
          key: const ValueKey('home-capture'),
          child: CinemaHomePage(
            enableSearchDiscovery: discovery != null,
            searchDiscovery: discovery,
            catalogDiscovery: catalogDiscovery,
            enableWatchTogether: false,
            store: store,
            repository: repository,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> section(String name) async {
      if (find.text(name).evaluate().isEmpty) {
        await tester.tap(find.byIcon(Icons.menu_rounded));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(name).first);
      await tester.pumpAndSettle();
    }

    if (!recentHot) {
      await tapSort(tester, CinemaCatalogSort.latest);
      await tester.pumpAndSettle();
      if (prepareSeries && width >= 1000) {
        await section('剧集');
        await tapSort(tester, CinemaCatalogSort.latest);
        await tester.pumpAndSettle();
        await section('电影');
      }
      repository.searched.clear();
      await revealCatalogueFinder(tester, sortChip(CinemaCatalogSort.latest));
      await tester.pumpAndSettle();
    }
  }

  Future<void> captureHome(WidgetTester tester, String name) async {
    const path = String.fromEnvironment('NAKU_HOME_UI_OUTPUT');
    if (path.isEmpty) return;
    await tester.runAsync(() async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('home-capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('$path/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  }

  Future<void> revealCatalogueControl(WidgetTester tester, String label) async {
    await revealCatalogueFinder(tester, find.text(label));
  }

  testWidgets('compact recent-hot cards keep readable resource states', (
    tester,
  ) async {
    repository.hasHotResource = true;
    await mount(tester, width: 700, recentHot: true);
    expect(find.byKey(const ValueKey('resource-found')), findsOneWidget);
    await captureHome(tester, 'home-compact.png');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'home defaults to recent hot and all years with resource badges, without 4K navigation',
    (tester) async {
      repository.hasHotResource = true;
      await mount(tester, recentHot: true);
      expect(find.text('4K'), findsNothing);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('catalog-sort-popular')),
            )
            .selected,
        isTrue,
      );
      expect(find.text('电影较早热门'), findsWidgets);
      expect(find.byKey(const ValueKey('resource-found')), findsOneWidget);
      expect(find.byKey(const ValueKey('resource-missing')), findsNWidgets(2));
      await captureHome(tester, 'home-wide.png');
      expect(catalogDiscovery.calls.first.year, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop featured selection is excluded from the real movie wall',
    (tester) async {
      catalogDiscovery.featuredFixtures = List.generate(
        12,
        (index) => DoubanTitle(
          id: '${30000000 + index}',
          title: '电影精选$index',
          kind: DoubanKind.movie,
          year: '2026',
        ),
      );
      await mount(tester, recentHot: true);
      final hero = tester.widget<CinemaFeaturedWall>(
        find.byType(CinemaFeaturedWall),
      );
      expect(hero.titles, hasLength(4));
      expect(hero.titles.map((title) => title.title), [
        '电影精选0',
        '电影精选1',
        '电影精选2',
        '电影精选3',
      ]);
      for (final title in hero.titles) {
        expect(find.byKey(ValueKey('title-card:${title.key}')), findsNothing);
      }
      await tester.tap(find.byTooltip('查看电影精选2'));
      await tester.pumpAndSettle();
      expect(find.text('电影精选2'), findsOneWidget);
      await captureHome(tester, 'home-featured-wide.png');
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -600),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('title-card:douban-discovery::30000004')),
        findsOneWidget,
      );
      await revealCatalogueControl(tester, '最新');
      await tapSort(tester, CinemaCatalogSort.latest);
      await tester.pumpAndSettle();
      expect(find.byType(CinemaFeaturedWall), findsNothing);
      expect(find.text('电影测试作品'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'movie and series latest and rating keep the shared cinematic hero and resource badges',
    (tester) async {
      repository.manyItems = true;
      List<DoubanTitle> selected(DoubanKind kind) => List.generate(
        12,
        (i) => DoubanTitle(
          id: '${30000000 + i}',
          title: '${kind.name}精选$i',
          kind: kind,
          year: '2026',
        ),
      );
      catalogDiscovery.featuredFixtures = selected(DoubanKind.movie);
      await mount(tester, recentHot: true, prepareSeries: false);
      for (final section in ['电影', '剧集']) {
        if (section == '剧集') {
          catalogDiscovery.featuredFixtures = selected(DoubanKind.tv);
          await tester.tap(find.text('剧集').first);
          await tester.pumpAndSettle();
        }
        for (final sort in CinemaCatalogSort.values) {
          final control = find.byKey(ValueKey('catalog-sort-${sort.name}'));
          await tapSort(tester, sort);
          await tester.pumpAndSettle();
          final heroFinder = find.byType(
            CinemaFeaturedWall,
            skipOffstage: false,
          );
          expect(
            heroFinder,
            findsOneWidget,
            reason:
                '$section/${sort.name}; selected=${tester.widget<ChoiceChip>(control).selected}; '
                'catalogue=${find.byWidgetPredicate((w) => w is Text && (w.data?.contains("部作品") ?? false)).evaluate().map((e) => (e.widget as Text).data).join("|")}; '
                'requests=${repository.filteredRequests}',
          );
          final hero = tester.widget<CinemaFeaturedWall>(heroFinder);
          expect(hero.titles, hasLength(4), reason: '$section/$sort');
          expect(tester.getSize(heroFinder).height, closeTo(860 - 96, .01));
          final status = hero.statusBuilder!(hero.titles.first) as Align;
          expect(status.child, isA<CinemaResourceBadge>());
          for (final title in hero.titles) {
            expect(
              find.byKey(ValueKey('title-card:${title.key}')),
              findsNothing,
            );
          }
          final cards = find.byWidgetPredicate(
            (widget) =>
                widget is InkWell &&
                widget.key is ValueKey<String> &&
                (widget.key as ValueKey<String>).value.startsWith(
                  'title-card:',
                ),
          );
          expect(cards, findsWidgets);
          expect(
            find.descendant(
              of: cards.first,
              matching: find.byType(CinemaResourceBadge),
            ),
            findsOneWidget,
          );
        }
      }
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'TV has a remote navigation rail and no downloads; phone keeps downloads',
    (tester) async {
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = false);
      await mount(tester, width: 800);
      expect(find.text('NAS 影视'), findsOneWidget);
      expect(find.text('下载管理'), findsNothing);
      expect(find.text('NAKU · TV'), findsOneWidget);
      expect(find.text('动漫'), findsNothing);
      expect(find.text('网页影院'), findsNothing);
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox());
      NakuDevice.isTV = false;
      await mount(tester);
      expect(find.byTooltip('下载管理'), findsOneWidget);
    },
  );

  testWidgets(
    'original-name search resolves Chinese titles without losing raw source results',
    (tester) async {
      final discovery = _Discovery();
      await mount(tester, discovery: discovery);
      await tester.enterText(find.byType(TextField).first, 'Interstellar');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repository.searched, containsAll(['Interstellar', '星际穿越']));
      expect(find.text('测试目录 · 1 个结果'), findsOneWidget);
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
    await revealCatalogueControl(tester, '加载更多搜索结果');
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

  Future<void> selectYear(WidgetTester tester, String year) async {
    final selector = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          (widget.key as ValueKey<String>).value.startsWith(
            'cinema-filter-年份-',
          ),
    );
    await tester.ensureVisible(selector);
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text(year).last);
    await tester.tap(find.text(year).last);
    await tester.pump();
  }

  Future<void> expectSelected(
    WidgetTester tester,
    CinemaCatalogSort sort,
  ) async {
    await revealCatalogueFinder(tester, sortChip(sort));
    expect(tester.widget<ChoiceChip>(sortChip(sort)).selected, isTrue);
  }

  void expectBefore(WidgetTester tester, String first, String second) {
    final hero = find.byType(CinemaFeaturedWall, skipOffstage: false);
    if (hero.evaluate().isNotEmpty) {
      final titles = tester.widget<CinemaFeaturedWall>(hero).titles;
      final firstHero = titles.indexWhere((title) => title.title == first);
      final secondHero = titles.indexWhere((title) => title.title == second);
      if (firstHero >= 0 || secondHero >= 0) {
        expect(
          firstHero >= 0,
          isTrue,
          reason: 'Hero works precede all works in the wall.',
        );
        if (secondHero >= 0) expect(firstHero, lessThan(secondHero));
        return;
      }
    }
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
    await expectSelected(tester, CinemaCatalogSort.latest);
    expect(
      find.byTooltip('已加载 4/40 项有更新时间，缺失项排后。按片源更新时间排序，不是影片上映时间。'),
      findsOneWidget,
    );
    expectBefore(tester, '电影最近更新', '电影较早热门');
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.contains('已加载 4/40 项有更新时间') ?? false),
      ),
      findsOneWidget,
    );
    final requests = repository.browsed.length;
    await tapSort(tester, CinemaCatalogSort.popular);
    await tester.pumpAndSettle();
    await expectSelected(tester, CinemaCatalogSort.popular);
    expect(
      find.byTooltip('按豆瓣近期热门顺序展示，卡片会自动检查片源；同片优先选择标记为 4K 的版本。'),
      findsOneWidget,
    );
    expectBefore(tester, '电影较早热门', '电影最近更新');
    expectBefore(tester, '电影最近更新', '电影缺少数据');
    expect(repository.browsed, hasLength(requests));
    await tapSort(tester, CinemaCatalogSort.latest);
    await tester.pumpAndSettle();
    expectBefore(tester, '电影最近更新', '电影较早热门');
  });

  testWidgets('movie and series sort selections remain independent', (
    tester,
  ) async {
    repository.useMetadata = true;
    await mount(tester);
    await tapSort(tester, CinemaCatalogSort.popular);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await expectSelected(tester, CinemaCatalogSort.latest);
    await tapSort(tester, CinemaCatalogSort.latest);
    await tester.pumpAndSettle();
    expectBefore(tester, '剧集最近更新', '剧集较早热门');
    await tapSort(tester, CinemaCatalogSort.popular);
    await tester.pumpAndSettle();
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    await expectSelected(tester, CinemaCatalogSort.popular);
    expectBefore(tester, '电影较早热门', '电影最近更新');
    await tapSort(tester, CinemaCatalogSort.latest);
    await tester.pumpAndSettle();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await expectSelected(tester, CinemaCatalogSort.popular);
    expectBefore(tester, '剧集较早热门', '剧集最近更新');
  });

  testWidgets(
    'searches retain selected sorting and catalogue order survives return',
    (tester) async {
      repository.useMetadata = true;
      await mount(tester);
      await tapSort(tester, CinemaCatalogSort.popular);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '排序搜索');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await expectSelected(tester, CinemaCatalogSort.popular);
      expect(sortChip(CinemaCatalogSort.latest), findsOneWidget);
      expect(sortChip(CinemaCatalogSort.rating), findsOneWidget);
      expectBefore(tester, '搜索高热结果', '搜索低热结果');
      await tester.enterText(find.byType(TextField), '');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      await expectSelected(tester, CinemaCatalogSort.popular);
      expectBefore(tester, '电影较早热门', '电影最近更新');
    },
  );

  testWidgets('loading more retains sorting and earlier source results', (
    tester,
  ) async {
    repository.useMetadata = true;
    await mount(tester);
    await tapSort(tester, CinemaCatalogSort.popular);
    await tester.pumpAndSettle();
    await revealCatalogueControl(tester, '加载更多作品');
    await tester.tap(find.text('加载更多作品'));
    await tester.pumpAndSettle();
    expect(find.text('6 部作品'), findsOneWidget);
    expect(find.text('电影较早热门'), findsWidgets);
    expectBefore(tester, '电影较早热门第2页', '电影最近更新第2页');
  });

  testWidgets(
    'missing source metrics are explained instead of implying a chart',
    (tester) async {
      await mount(tester);
      expect(find.byTooltip('片源未提供可用更新时间，保留目录顺序。'), findsOneWidget);
      await tapSort(tester, CinemaCatalogSort.popular);
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('按豆瓣近期热门顺序展示，卡片会自动检查片源；同片优先选择标记为 4K 的版本。'),
        findsOneWidget,
      );
      expect(find.text('电影较早热门'), findsWidgets);
    },
  );

  testWidgets(
    'unified catalogues load real movie and series leaves without provider tabs',
    (tester) async {
      await mount(tester);
      expect(repository.browsed, contains('11'));
      expect(find.text('电影测试作品'), findsWidgets);
      expect(find.text('奇幻片'), findsNothing);
      expect(find.text('Netflix电影'), findsNothing);
      expect(find.byTooltip('片源状态'), findsOneWidget);
      await tester.tap(find.byTooltip('片源状态'));
      await tester.pumpAndSettle();
      expect(find.text('测试目录 · 1'), findsOneWidget);
      await tester.tapAt(const Offset(12, 12));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButton<String> &&
              widget.items!.any((item) => item.value == _source.id),
        ),
        findsNothing,
      );
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(repository.browsed, contains('22'));
      expect(find.text('剧集测试作品'), findsWidgets);
      expect(find.text('美国剧'), findsNothing);
      expect(find.text('Netflix自制剧'), findsNothing);
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
    await revealCatalogueControl(tester, '加载更多搜索结果');
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
    expect(find.text('40 部作品'), findsOneWidget);
    await revealCatalogueControl(tester, '加载更多作品');
    await tester.tap(find.text('加载更多作品'));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView).first,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      ),
    );
    scroll.position.jumpTo(0);
    await tester.pump();
    await revealCatalogueControl(tester, '60 部作品');
    expect(find.text('60 部作品'), findsOneWidget);
    expect(
      repository.filteredRequests
          .where((request) => request.category == '11')
          .map((request) => request.page),
      [1, 2, 3],
    );
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    final calls = repository.browsed.length;
    await tester.tap(find.text('电影'));
    await tester.pump();
    await revealCatalogueControl(tester, '60 部作品');
    expect(find.text('60 部作品'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(repository.browsed, hasLength(calls));
    expect(
      find.text('电影最近更新第3页').evaluate().isNotEmpty ||
          tester
              .widget<CinemaFeaturedWall>(
                find.byType(CinemaFeaturedWall, skipOffstage: false),
              )
              .titles
              .any((title) => title.title == '电影最近更新第3页'),
      isTrue,
    );
    // Returning uses the exact loaded aggregate, verified by the request delta above.
  });

  testWidgets('sidebar switching removes the outgoing pane immediately', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('剧集'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('电影测试作品'), findsNothing);
    expect(find.text('剧集测试作品'), findsWidgets);
    // A second selection during the transition must keep only the latest pane.
    await tester.tap(find.text('电影').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('剧集测试作品'), findsNothing);
    expect(find.text('电影测试作品'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('settings groups source management appearance and updates', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('片源管理'), findsNothing);
    expect(find.text('外观与透明度'), findsNothing);
    expect(find.text('软件更新'), findsNothing);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('片源管理'), findsOneWidget);
    expect(find.text('外观与透明度'), findsOneWidget);
    expect(find.text('软件更新'), findsOneWidget);
    expect(find.text('已启用 1 / 1 个片源'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('settings-sources')));
    await tester.pumpAndSettle();
    expect(find.text('测试目录'), findsOneWidget);
    expect(find.byTooltip('返回设置'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-updates')), findsNothing);
    await tester.tap(find.byTooltip('返回设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-updates')));
    await tester.pumpAndSettle();
    expect(find.text('自动检查更新'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-sources')), findsOneWidget);
    final calls = repository.browsed.length;
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(repository.browsed, hasLength(calls));
    expect(find.text('电影测试作品'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an offscreen catalogue finishes once and is ready on return', (
    tester,
  ) async {
    await mount(tester, prepareSeries: false);
    final pending = repository.delayedBrowse['22'] = Completer<CinemaPage>();
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await tapSort(tester, CinemaCatalogSort.latest);
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
            year: '2026',
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

  testWidgets('scroll frames retain mounted poster cards and resource badges', (
    tester,
  ) async {
    repository.manyItems = true;
    await mount(tester);
    final verticalScroll = find.descendant(
      of: find.byType(CustomScrollView).first,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Scrollable && widget.axisDirection == AxisDirection.down,
      ),
    );
    final position = tester.state<ScrollableState>(verticalScroll).position;
    position.jumpTo(1000);
    await tester.pumpAndSettle();
    final mountedCards = find.byType(CinemaCardRatings).evaluate().toSet();
    final mountedBadges = find.byType(CinemaResourceBadge).evaluate().toSet();
    final home = tester.element(find.byType(CinemaHomePage));
    expect(mountedCards.length, greaterThanOrEqualTo(6));
    expect(mountedBadges.length, greaterThanOrEqualTo(6));
    var cardRebuilds = 0;
    var badgeRebuilds = 0;
    var homeRebuilds = 0;
    final previousBuild = debugOnRebuildDirtyWidget;
    final frameMicros = <int>[];
    debugOnRebuildDirtyWidget = (element, builtOnce) {
      previousBuild?.call(element, builtOnce);
      // Flutter's builtOnce flag is only maintained when verbose rebuild
      // printing is enabled. Track the actual settled Elements instead so the
      // probe distinguishes updates from newly mounted cache-extent children.
      if (mountedCards.contains(element)) cardRebuilds++;
      if (mountedBadges.contains(element)) badgeRebuilds++;
      if (identical(element, home)) homeRebuilds++;
    };
    try {
      final gesture = await tester.startGesture(const Offset(1100, 500));
      for (var frame = 0; frame < 48; frame++) {
        final stopwatch = Stopwatch()..start();
        await gesture.moveBy(const Offset(0, -2));
        await tester.pump(const Duration(milliseconds: 16));
        frameMicros.add(stopwatch.elapsedMicroseconds);
      }
      await gesture.up();
    } finally {
      debugOnRebuildDirtyWidget = previousBuild;
    }
    frameMicros.sort();
    debugPrint(
      'HOME_SCROLL_PROFILE: frames=${frameMicros.length} '
      'tracked_cards=${mountedCards.length} '
      'card_rebuilds=$cardRebuilds badge_rebuilds=$badgeRebuilds '
      'home_rebuilds=$homeRebuilds '
      'debug_host_p50_us=${frameMicros[frameMicros.length ~/ 2]} '
      'debug_host_p95_us=${frameMicros[(frameMicros.length * .95).floor()]}',
    );
    expect(position.pixels, greaterThan(1050));
    expect(
      cardRebuilds,
      0,
      reason: 'Scrolling must not update every already-mounted poster card.',
    );
    expect(badgeRebuilds, 0);
    expect(homeRebuilds, 0);
    await tester.pumpAndSettle();
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

  testWidgets(
    'retry after an initial failure fetches again and restores cards',
    (tester) async {
      repository.failBrowse = true;
      await mount(tester);
      expect(find.text('暂时未能连接'), findsOneWidget);
      expect(find.text('电影测试作品'), findsNothing);
      final failedRequests = repository.filteredRequests.length;
      repository.failBrowse = false;
      await tester.tap(find.text('重新尝试'));
      await tester.pumpAndSettle();
      expect(repository.filteredRequests.length, greaterThan(failedRequests));
      expect(find.text('电影测试作品'), findsWidgets);
      expect(find.text('暂时未能连接'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

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
    'failed filter switch cannot show cards from the previous selection',
    (tester) async {
      await mount(tester);
      repository.failBrowse = true;
      catalogDiscovery.fail = true;
      await selectYear(tester, '2020');
      await tester.pumpAndSettle();
      expect(find.text('电影测试作品'), findsNothing);
      expect(find.text('暂时未能连接'), findsOneWidget);
    },
  );

  testWidgets('all enabled sources merge into one card per work', (
    tester,
  ) async {
    const second = CinemaSource(
      id: 'second',
      name: '另一个片源',
      kind: CinemaSourceKind.maccms,
      url: 'https://second.invalid/api',
    );
    const disabled = CinemaSource(
      id: 'disabled',
      name: '停用的片源',
      kind: CinemaSourceKind.maccms,
      url: 'https://disabled.invalid/api',
      enabled: false,
    );
    await tester.runAsync(() async {
      await store.saveSource(second);
      await store.saveSource(disabled);
    });
    await mount(tester);
    expect(repository.filteredRequests.map((r) => r.source).toSet(), {
      'fixture',
      'second',
    });
    expect(find.text('1 部作品'), findsOneWidget);
    await tester.tap(find.byTooltip('片源状态'));
    await tester.pumpAndSettle();
    expect(find.text('测试目录 · 1'), findsOneWidget);
    expect(find.text('另一个片源 · 1'), findsOneWidget);
    expect(find.text('停用的片源'), findsNothing);
    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButton<String> &&
            widget.items!.any((item) => item.value == _source.id),
      ),
      findsNothing,
    );
    expect(find.text('年份'), findsNothing);
    expect(find.text('地区'), findsNothing);
    expect(find.text('类型'), findsNothing);
  });

  testWidgets(
    'year selection queries older catalogues and excludes stale replies',
    (tester) async {
      await mount(tester);
      await selectYear(tester, '2020');
      await tester.pumpAndSettle();
      expect(repository.filteredRequests.last.year, '2020');
      expect(catalogDiscovery.calls.last.year, '2020');
      expect(find.text('2020年作品'), findsWidgets);
      expect(find.text('电影测试作品'), findsNothing);

      final pending = repository.delayedYears['2021'] = Completer<CinemaPage>();
      await selectYear(tester, '2021');
      // Do not settle while the deliberately delayed catalogue is loading.
      final selector = find.byKey(const ValueKey('cinema-filter-年份-2021'));
      await tester.tap(selector);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('2022').last);
      await tester.tap(find.text('2022').last);
      await tester.pumpAndSettle();
      expect(find.text('2022年作品'), findsWidgets);
      pending.complete(
        const CinemaPage(
          items: [
            CinemaTitle(
              id: 'late',
              sourceId: 'fixture',
              title: '过期的2021年作品',
              year: '2021',
              category: '剧情片',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2022年作品'), findsWidgets);
      expect(find.text('过期的2021年作品'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'blocked short-drama labels and works never appear in unified series',
    (tester) async {
      repository.blockedEntry = true;
      await mount(tester);
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(find.text('擦边短剧'), findsNothing);
      expect(find.text('应被屏蔽的作品'), findsNothing);
      expect(
        repository.filteredRequests.map((r) => r.category),
        isNot(contains('90')),
      );
      expect(find.text('0 部作品'), findsOneWidget);
    },
  );

  testWidgets('an unavailable provider leaves other providers usable', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.saveSource(
        const CinemaSource(
          id: 'offline',
          name: '失败片源',
          kind: CinemaSourceKind.maccms,
          url: 'https://offline.invalid/api',
        ),
      ),
    );
    repository.failedSources.add('offline');
    await mount(tester);
    expect(find.text('电影测试作品'), findsWidgets);
    await tester.tap(find.byTooltip('片源状态'));
    await tester.pumpAndSettle();
    expect(find.text('失败片源 · 暂不可用'), findsOneWidget);
    expect(find.text('1 个片源暂时不可用，已保留其他片源内容'), findsOneWidget);
    await tester.tapAt(const Offset(12, 12));
    await tester.pumpAndSettle();
    expect(find.text('暂时未能连接'), findsNothing);
  });

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
