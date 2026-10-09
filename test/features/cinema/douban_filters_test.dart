import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_page.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/features/cinema/douban/douban_themes.dart';

const _categories = [
  DoubanCategoryGroup(name: '类型', tags: ['科幻', '喜剧']),
  DoubanCategoryGroup(name: '地区', tags: ['美国', '中国大陆']),
];
const _tvCategories = [
  DoubanCategoryGroup(
    name: '类型',
    groupName: '形式',
    groups: {
      '电视剧': ['科幻', '喜剧'],
      '综艺': ['真人秀', '音乐'],
    },
  ),
  DoubanCategoryGroup(name: '地区', tags: ['美国', '中国大陆']),
];
const _sorts = [
  DoubanSort(name: 'T', text: '综合排序', isDefault: true),
  DoubanSort(name: 'U', text: '近期热度'),
  DoubanSort(name: 'R', text: '首映时间'),
  DoubanSort(name: 'S', text: '高分优先'),
];

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(
        options.path.endsWith('filter_tags')
            ? {
                'tags': [
                  {
                    'type': '年代',
                    'tags': ['全部', '2024'],
                  },
                ],
              }
            : {'items': [], 'total': 0},
      ),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

typedef _Request = ({
  DoubanKind kind,
  DoubanFilters filters,
  List<String> tags,
  String? sort,
  int start,
  CancelToken? token,
});

class _Repository extends DoubanRepository {
  final requests = <_Request>[];
  final filterRequests = <DoubanKind>[];
  Completer<DoubanResultPage>? pending, pendingAppend;
  bool manyItems = false, failPage = false, failFilters = false;
  List<String> recommendedTags = ['旅行', '摄影'];
  List<DoubanCategoryGroup>? categoryOverride;
  List<DoubanTagGroup>? tagGroupOverride;
  final themeRequests =
      <({DoubanKind kind, String? seed, CancelToken? token})>[];
  List<String> discoveredThemes = [];
  Completer<List<String>>? pendingThemes;
  bool failThemes = false;

  @override
  Future<List<String>> discoverThemes({
    required DoubanKind kind,
    String? seed,
    CancelToken? cancelToken,
  }) async {
    themeRequests.add((kind: kind, seed: seed, token: cancelToken));
    if (failThemes) throw const DoubanException('themes offline');
    if (kind == DoubanKind.movie && pendingThemes != null) {
      return pendingThemes!.future;
    }
    return discoveredThemes;
  }

  DoubanResultPage result(
    DoubanKind kind, {
    int start = 0,
    String suffix = '',
  }) => DoubanResultPage(
    items: [
      for (
        var i = start == 0 ? 1 : 2;
        i <=
            (manyItems
                ? 30
                : start == 0
                ? 2
                : 3);
        i++
      )
        DoubanTitle(
          id: '${kind.index + 1}$i',
          title: '${kind.label}作品$i$suffix',
          kind: kind,
          year: '2024',
          score: 8.2,
        ),
    ],
    start: start,
    nextStart: start + 20,
    hasMore: start == 0,
    sorts: _sorts,
    categoryGroups:
        categoryOverride ??
        (kind == DoubanKind.movie ? _categories : _tvCategories),
    tags: recommendedTags,
  );

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
    requests.add((
      kind: kind,
      filters: filters,
      tags: List.of(tags),
      sort: sort,
      start: start,
      token: cancelToken,
    ));
    if (failPage) throw const DoubanException('fixture offline');
    if (filters.genre == '科幻' && pending != null) return pending!.future;
    if (start > 0 && pendingAppend != null) return pendingAppend!.future;
    return result(kind, start: start);
  }

  @override
  Future<List<DoubanTagGroup>> tagGroups({
    required DoubanKind kind,
    DoubanFilters filters = const DoubanFilters(),
    CancelToken? cancelToken,
  }) async {
    filterRequests.add(kind);
    if (failFilters) throw const DoubanException('filters offline');
    return tagGroupOverride ??
        [
          const DoubanTagGroup(
            name: '年代',
            tags: ['全部', '2024', '2023', '2010年代'],
          ),
          if (kind == DoubanKind.tv)
            const DoubanTagGroup(name: '平台', tags: ['全部', 'Netflix', 'HBO']),
        ];
  }
}

void main() {
  test(
    'official category taxonomy is distinct from recommendations and TV forms',
    () {
      final groups = parseDoubanCategoryGroups([
        {
          'type': '地区',
          'data': [
            {'text': '全部'},
            {'text': '美国'},
            {'text': '美国'},
          ],
        },
        {
          'type': '类型',
          'tag_groups': '形式',
          'data': [
            {
              'text': '类型',
              'tags': ['不限类型', '全部剧集', '全部综艺'],
            },
            {
              'text': '电视剧',
              'tags': ['科幻', '喜剧'],
            },
            {
              'text': '综艺',
              'tags': ['音乐'],
            },
          ],
        },
        {'type': 'broken', 'data': 'not a list'},
      ]);
      expect(groups.map((group) => group.name), ['类型', '地区']);
      expect(groups.first.groups.keys, ['电视剧', '综艺']);
      expect(groups.first.options(format: '电视剧'), ['科幻', '喜剧']);
      expect(groups.first.options(), ['科幻', '喜剧', '音乐']);
      expect(groups.last.tags, ['美国']);
    },
  );

  test('movie grouped selections are real official query parameters', () async {
    final adapter = _Adapter();
    final repo = DoubanRepository(dio: Dio()..httpClientAdapter = adapter);
    const filters = DoubanFilters(genre: '科幻', region: '美国', year: '2024');
    await repo.browse(
      kind: DoubanKind.movie,
      filters: filters,
      tags: const ['旅行'],
      sort: 'S',
      start: 20,
    );
    final request = adapter.requests.single;
    expect(request.uri.path, '/rexxar/api/v2/movie/recommend');
    expect(jsonDecode(request.uri.queryParameters['selected_categories']!), {
      '类型': '科幻',
      '地区': '美国',
    });
    expect(request.uri.queryParameters['tags'], '科幻,美国,2024,旅行');
    expect(request.uri.queryParameters['sort'], 'S');
    expect(request.uri.queryParameters['start'], '20');
    expect(request.headers['Referer'], DoubanKind.movie.pageUrl);
  });

  test(
    'TV format, region, year and platform survive genre changes independently',
    () async {
      final adapter = _Adapter();
      final repo = DoubanRepository(dio: Dio()..httpClientAdapter = adapter);
      const filters = DoubanFilters(
        format: '电视剧',
        genre: '科幻',
        region: '美国',
        year: '2024',
        platform: 'Netflix',
      );
      await repo.browse(kind: DoubanKind.tv, filters: filters);
      expect(
        jsonDecode(
          adapter.requests.last.uri.queryParameters['selected_categories']!,
        ),
        {'类型': '科幻', '地区': '美国', '形式': '电视剧'},
      );
      expect(
        adapter.requests.last.uri.queryParameters['tags'],
        '科幻,美国,2024,Netflix',
      );
      await repo.tagGroups(
        kind: DoubanKind.tv,
        filters: filters.copyWith(genre: '喜剧'),
      );
      expect(
        adapter.requests.last.uri.path,
        '/rexxar/api/v2/tv/recommend/filter_tags',
      );
      expect(
        jsonDecode(
          adapter.requests.last.uri.queryParameters['selected_categories']!,
        ),
        {'类型': '喜剧', '地区': '美国', '形式': '电视剧'},
      );
      await repo.browse(
        kind: DoubanKind.tv,
        filters: filters.copyWith(genre: ''),
      );
      expect(
        adapter.requests.last.uri.queryParameters['tags'],
        '电视剧,美国,2024,Netflix',
      );
    },
  );

  test(
    'all resets omit tags; delimiter injection is rejected before requesting',
    () async {
      final adapter = _Adapter();
      final repo = DoubanRepository(dio: Dio()..httpClientAdapter = adapter);
      await repo.browse(kind: DoubanKind.movie);
      expect(
        adapter.requests.single.uri.queryParameters['selected_categories'],
        '{}',
      );
      expect(
        adapter.requests.single.uri.queryParameters.containsKey('tags'),
        isFalse,
      );
      await expectLater(
        repo.browse(
          kind: DoubanKind.movie,
          filters: const DoubanFilters(year: '2024,2023'),
        ),
        throwsA(isA<DoubanException>()),
      );
      expect(adapter.requests, hasLength(1));
    },
  );

  test(
    'real card metadata supports search without inventing ambiguous cast',
    () {
      final raw = {
        'id': '42',
        'title': '测试',
        'original_title': 'Original Title',
        'type': 'movie',
        'card': 'subject',
        'year': '2024',
        'card_subtitle': '2024 / 美国 加拿大 / 科幻 冒险 / 导演 / English Actor 中文演员',
      };
      final title = DoubanTitle.fromJson(raw, DoubanKind.movie)!;
      expect(title.originalTitle, 'Original Title');
      expect(title.regions, ['美国', '加拿大']);
      expect(title.genres, ['科幻', '冒险']);
      expect(title.actors, ['English Actor 中文演员']);
      expect(
        DoubanTitle.fromJson({
          ...raw,
          'card_subtitle': '2024 / 美国 / 剧情 / 可能是演员或导演',
        }, DoubanKind.movie)!.actors,
        isEmpty,
      );
      final explicit = DoubanTitle.fromJson({
        ...raw,
        'actors': [
          {'name': 'English Actor'},
          {'name': '中文演员'},
        ],
      }, DoubanKind.movie)!;
      expect(explicit.actors, ['English Actor', '中文演员']);
    },
  );

  Future<void> mount(
    WidgetTester tester,
    _Repository repo, {
    double width = 1000,
    ValueChanged<DoubanTitle>? onSelect,
    DoubanThemeCatalog? themeCatalog,
    DoubanBrowseSession? session,
  }) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: DoubanPage(
          repository: repo,
          session: session,
          themeCatalog: themeCatalog ?? DoubanThemeCatalog(),
          onSelect: onSelect ?? (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String group, String value) async {
    await tester.ensureVisible(find.byKey(ValueKey('douban-filter-$group')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('douban-filter-$group')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(value).last);
    await tester.pump(const Duration(milliseconds: 300));
  }

  String selected(WidgetTester tester, String group) => tester
      .widget<DropdownButton<String>>(
        find.byKey(ValueKey('douban-filter-$group')),
      )
      .value!;

  testWidgets(
    'stable filters combine independently and keep exploration in its own group',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      expect(find.text('风格与主题'), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-theme-旅行')), findsOneWidget);
      final genreMenu = tester.widget<DropdownButton<String>>(
        find.byKey(const ValueKey('douban-filter-genre')),
      );
      expect(genreMenu.items!.map((item) => item.value), isNot(contains('旅行')));
      await choose(tester, 'genre', '科幻');
      await choose(tester, 'region', '美国');
      await choose(tester, 'year', '2024');
      await tester.tap(find.byKey(const ValueKey('douban-sort-S')));
      await tester.pumpAndSettle();
      expect(repo.requests.last.filters.genre, '科幻');
      expect(repo.requests.last.filters.region, '美国');
      expect(repo.requests.last.filters.year, '2024');
      expect(repo.requests.last.sort, 'S');
      expect(repo.requests.last.start, 0);
      await choose(tester, 'genre', '喜剧');
      expect(selected(tester, 'region'), '美国');
      expect(selected(tester, 'year'), '2024');
      expect(repo.requests.last.sort, 'S');
      await tester.tap(find.byKey(const ValueKey('douban-reset-filters')));
      await tester.pumpAndSettle();
      expect(repo.requests.last.filters.isEmpty, isTrue);
      expect(repo.requests.last.sort, isNull);
      expect(selected(tester, 'genre'), '');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected themes combine with filters and survive changing recommendations and kind',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      await choose(tester, 'genre', '科幻');
      await tester.tap(find.byKey(const ValueKey('douban-theme-旅行')));
      await tester.pumpAndSettle();
      expect(repo.requests.last.filters.genre, '科幻');
      expect(repo.requests.last.tags, ['旅行']);
      repo.recommendedTags = ['孤独'];
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('douban-theme-旅行')))
            .selected,
        isTrue,
      );
      expect(find.byKey(const ValueKey('douban-theme-孤独')), findsOneWidget);
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('douban-theme-孤独')));
      await tester.pumpAndSettle();
      expect(repo.requests.last.tags, ['孤独']);
      expect(repo.requests.last.filters.isEmpty, isTrue);
      final calls = repo.requests.length;
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('douban-theme-旅行')))
            .selected,
        isTrue,
      );
      expect(repo.requests, hasLength(calls));
      await tester.tap(find.byKey(const ValueKey('douban-reset-filters')));
      await tester.pumpAndSettle();
      expect(repo.requests.last.filters.isEmpty, isTrue);
      expect(repo.requests.last.tags, isEmpty);
    },
  );

  testWidgets(
    'movie and TV retain filters, results, sort and separate scroll offsets',
    (tester) async {
      final repo = _Repository()..manyItems = true;
      await mount(tester, repo);
      await choose(tester, 'genre', '科幻');
      await tester.tap(find.byKey(const ValueKey('douban-sort-S')));
      await tester.pumpAndSettle();
      final view = find.byType(CustomScrollView);
      double offset() =>
          tester.widget<CustomScrollView>(view).controller!.offset;
      await tester.drag(view, const Offset(0, -650));
      await tester.pumpAndSettle();
      final movieOffset = offset();
      expect(movieOffset, greaterThan(500));
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(offset(), 0);
      await choose(tester, 'format', '电视剧');
      await choose(tester, 'platform', 'Netflix');
      await tester.drag(view, const Offset(0, -300));
      await tester.pumpAndSettle();
      final tvOffset = offset();
      final calls = repo.requests.length;
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(offset(), closeTo(movieOffset, 1));
      expect(repo.requests, hasLength(calls));
      await tester.drag(view, const Offset(0, 1200));
      await tester.pumpAndSettle();
      expect(selected(tester, 'genre'), '科幻');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('douban-sort-S')))
            .selected,
        isTrue,
      );
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      expect(offset(), closeTo(tvOffset, 1));
      await tester.drag(view, const Offset(0, 800));
      await tester.pumpAndSettle();
      expect(selected(tester, 'format'), '电视剧');
      expect(selected(tester, 'platform'), 'Netflix');
      expect(repo.requests, hasLength(calls));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pagination retains query, deduplicates cards, and filter change starts over',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      await choose(tester, 'year', '2024');
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(repo.requests.last.start, 20);
      expect(repo.requests.last.filters.year, '2024');
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-12')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-13')), findsOneWidget);
      await choose(tester, 'year', '2023');
      await tester.pumpAndSettle();
      expect(repo.requests.last.start, 0);
      expect(find.byKey(const ValueKey('douban-13')), findsNothing);
    },
  );

  testWidgets(
    'old filter requests are canceled and cannot replace a newer selection',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      final pending = repo.pending = Completer<DoubanResultPage>();
      await choose(tester, 'genre', '科幻');
      final oldToken = repo.requests.last.token!;
      await choose(tester, 'genre', '喜剧');
      await tester.pumpAndSettle();
      expect(oldToken.isCancelled, isTrue);
      pending.complete(repo.result(DoubanKind.movie, suffix: '旧请求'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'genre'), '喜剧');
      expect(find.textContaining('旧请求'), findsNothing);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
    },
  );

  testWidgets('offscreen requests finish only in their original kind', (
    tester,
  ) async {
    final repo = _Repository();
    await mount(tester, repo);
    final pending = repo.pending = Completer<DoubanResultPage>();
    await choose(tester, 'genre', '科幻');
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    pending.complete(repo.result(DoubanKind.movie, suffix: '后台完成'));
    await tester.pumpAndSettle();
    expect(find.textContaining('后台完成'), findsNothing);
    final calls = repo.requests.length;
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(find.text('电影作品1后台完成'), findsOneWidget);
    expect(repo.requests, hasLength(calls));
  });

  testWidgets(
    'refresh failure preserves usable cards and available filter groups',
    (tester) async {
      final repo = _Repository();
      DoubanTitle? opened;
      await mount(tester, repo, onSelect: (value) => opened = value);
      await choose(tester, 'year', '2024');
      repo.failPage = true;
      repo.failFilters = true;
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      expect(selected(tester, 'year'), '2024');
      expect(find.textContaining('已保留现有作品'), findsOneWidget);
      expect(find.textContaining('部分筛选项'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('douban-11')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('douban-11')));
      expect(opened!.id, '11');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial taxonomy and a failed year endpoint do not block available results',
    (tester) async {
      final repo = _Repository()
        ..categoryOverride = [_categories.first]
        ..failFilters = true;
      await mount(tester, repo);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('douban-filter-genre')),
            )
            .onChanged,
        isNotNull,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('douban-filter-region')),
            )
            .onChanged,
        isNull,
      );
      expect(
        tester
            .widget<DropdownButton<String>>(
              find.byKey(const ValueKey('douban-filter-year')),
            )
            .onChanged,
        isNull,
      );
      repo.failFilters = false;
      await tester.tap(find.text('重试筛选项'));
      await tester.pumpAndSettle();
      await choose(tester, 'year', '2024');
      expect(repo.requests.last.filters.year, '2024');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial later taxonomy keeps every observed genre region and year option',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      await choose(tester, 'region', '中国大陆');
      repo.categoryOverride = const [
        DoubanCategoryGroup(name: '类型', tags: ['纪录片']),
        DoubanCategoryGroup(name: '地区', tags: ['英国']),
      ];
      repo.tagGroupOverride = const [
        DoubanTagGroup(name: '年代', tags: ['全部', '1990年代']),
      ];
      await tester.tap(find.byTooltip('刷新'));
      await tester.pumpAndSettle();
      List<String?> values(String name) => tester
          .widget<DropdownButton<String>>(
            find.byKey(ValueKey('douban-filter-$name')),
          )
          .items!
          .map((item) => item.value)
          .toList();
      expect(values('genre'), containsAll(['科幻', '喜剧', '纪录片']));
      expect(values('region'), containsAll(['美国', '中国大陆', '英国']));
      expect(values('year'), containsAll(['2024', '2023', '2010年代', '1990年代']));
      expect(selected(tester, 'region'), '中国大陆');
      await choose(tester, 'genre', '科幻');
      expect(repo.requests.last.filters.genre, '科幻');
      expect(repo.requests.last.filters.region, '中国大陆');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'more themes preserves the board, selections and scroll while keeping topics beyond forty',
    (tester) async {
      final repo = _Repository()
        ..manyItems = true
        ..recommendedTags = [for (var i = 0; i < 45; i++) '主题$i'];
      await mount(tester, repo);
      expect(repo.themeRequests, hasLength(2));
      await choose(tester, 'year', '2024');
      await tester.tap(find.byKey(const ValueKey('douban-theme-主题0')));
      await tester.pumpAndSettle();
      final pages = repo.requests.length;
      final view = find.byType(CustomScrollView);
      final scroll = tester.widget<CustomScrollView>(view).controller!;
      scroll.jumpTo(80);
      await tester.pumpAndSettle();
      final offset = scroll.offset;
      final pending = repo.pendingThemes = Completer<List<String>>();
      await tester.tap(find.byKey(const ValueKey('douban-more-themes')));
      await tester.pump();
      expect(repo.requests, hasLength(pages));
      expect(repo.themeRequests, hasLength(3));
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('douban-more-themes')),
            )
            .onPressed,
        isNull,
      );
      pending.complete(['新主题', '主题0']);
      await tester.pumpAndSettle();
      expect(repo.requests, hasLength(pages));
      expect(scroll.offset, closeTo(offset, 1));
      expect(selected(tester, 'year'), '2024');
      expect(find.byKey(const ValueKey('douban-theme-新主题')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-theme-主题44')), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('douban-theme-主题0')))
            .selected,
        isTrue,
      );
      expect(find.textContaining('新增 1 个主题'), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'theme discovery failures and old context completions preserve usable content',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo);
      repo.failThemes = true;
      await tester.tap(find.byKey(const ValueKey('douban-more-themes')));
      await tester.pumpAndSettle();
      expect(find.textContaining('现有主题和作品仍可使用'), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-theme-旅行')), findsOneWidget);
      repo.failThemes = false;
      final pending = repo.pendingThemes = Completer<List<String>>();
      await tester.tap(find.byKey(const ValueKey('douban-more-themes')));
      await tester.pump();
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      pending.complete(['电影新主题']);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('douban-theme-电影新主题')), findsNothing);
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('douban-theme-电影新主题')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopening the board retains discovered themes in the session catalogue',
    (tester) async {
      final catalog = DoubanThemeCatalog();
      final repo = _Repository()..discoveredThemes = ['之前发现的主题'];
      await mount(tester, repo, themeCatalog: catalog);
      expect(
        find.byKey(const ValueKey('douban-theme-之前发现的主题')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      final newRepo = _Repository()..recommendedTags = ['本次推荐'];
      await mount(tester, newRepo, themeCatalog: catalog);
      expect(
        find.byKey(const ValueKey('douban-theme-之前发现的主题')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('douban-theme-本次推荐')), findsOneWidget);
    },
  );

  testWidgets(
    'closing and reopening preserves both kinds and never reloads completed pages',
    (tester) async {
      final session = DoubanBrowseSession();
      final themes = DoubanThemeCatalog();
      final repo = _Repository()..manyItems = true;
      await mount(tester, repo, session: session, themeCatalog: themes);
      await choose(tester, 'genre', '科幻');
      await choose(tester, 'year', '2024');
      await tester.tap(find.byKey(const ValueKey('douban-sort-S')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('douban-theme-旅行')));
      await tester.pumpAndSettle();
      final movieScroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      movieScroll.jumpTo(640);
      await tester.pumpAndSettle();
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      await choose(tester, 'format', '电视剧');
      await choose(tester, 'year', '2023');
      await tester.tap(find.text('风格与主题'));
      await tester.pumpAndSettle();
      final tvScroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      tvScroll.jumpTo(420);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());

      final offline = _Repository()
        ..failPage = true
        ..failFilters = true
        ..failThemes = true;
      await mount(tester, offline, session: session, themeCatalog: themes);
      final active = tester.widget<SegmentedButton<DoubanKind>>(
        find.byType(SegmentedButton<DoubanKind>),
      );
      expect(active.selected, {DoubanKind.tv});
      final restoredTv = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(restoredTv, isNot(same(tvScroll)));
      expect(restoredTv.offset, closeTo(420, 1));
      restoredTv.jumpTo(0);
      await tester.pumpAndSettle();
      expect(selected(tester, 'format'), '电视剧');
      expect(selected(tester, 'year'), '2023');
      expect(find.byKey(const ValueKey('douban-theme-旅行')), findsNothing);
      await tester.tap(find.text('电影'));
      await tester.pumpAndSettle();
      final restoredMovie = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      expect(restoredMovie, isNot(same(movieScroll)));
      expect(restoredMovie.offset, closeTo(640, 1));
      restoredMovie.jumpTo(0);
      await tester.pumpAndSettle();
      expect(selected(tester, 'genre'), '科幻');
      expect(selected(tester, 'year'), '2024');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('douban-sort-S')))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<FilterChip>(find.byKey(const ValueKey('douban-theme-旅行')))
            .selected,
        isTrue,
      );
      expect(offline.requests, isEmpty);
      expect(offline.filterRequests, isEmpty);
      expect(offline.themeRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopening resumes an interrupted selection and ignores disposed route results',
    (tester) async {
      final session = DoubanBrowseSession();
      final repo = _Repository();
      await mount(tester, repo, session: session);
      final oldResponse = repo.pending = Completer<DoubanResultPage>();
      await choose(tester, 'genre', '科幻');
      final token = repo.requests.last.token!;
      await tester.pumpWidget(const SizedBox());
      expect(token.isCancelled, isTrue);
      final nextRepo = _Repository();
      await mount(tester, nextRepo, session: session);
      expect(nextRepo.requests, hasLength(1));
      expect(nextRepo.requests.single.filters.genre, '科幻');
      expect(nextRepo.requests.single.start, 0);
      oldResponse.complete(repo.result(DoubanKind.movie, suffix: '已销毁页面结果'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已销毁页面结果'), findsNothing);
      expect(selected(tester, 'genre'), '科幻');
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reopening resumes interrupted pagination at its previous cursor',
    (tester) async {
      final session = DoubanBrowseSession();
      final repo = _Repository();
      await mount(tester, repo, session: session);
      final pending = repo.pendingAppend = Completer<DoubanResultPage>();
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      expect(repo.requests.last.start, 20);
      await tester.pumpWidget(const SizedBox());
      final resumed = _Repository();
      await mount(tester, resumed, session: session);
      expect(resumed.requests, hasLength(1));
      expect(resumed.requests.single.start, 20);
      pending.complete(repo.result(DoubanKind.movie, start: 20, suffix: '旧分页'));
      await tester.pumpAndSettle();
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.textContaining('旧分页'), findsNothing);
      expect(find.byKey(const ValueKey('douban-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('douban-13')), findsOneWidget);
      expect(resumed.filterRequests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'interrupted theme discovery resumes even when page restoration fails',
    (tester) async {
      final session = DoubanBrowseSession();
      final repo = _Repository();
      await mount(tester, repo, session: session);
      final themeResponse = repo.pendingThemes = Completer<List<String>>();
      await tester.tap(find.byKey(const ValueKey('douban-more-themes')));
      await tester.pump();
      final pageResponse = repo.pending = Completer<DoubanResultPage>();
      await choose(tester, 'genre', '科幻');
      await tester.pumpWidget(const SizedBox());
      final resumed = _Repository()
        ..failPage = true
        ..discoveredThemes = ['恢复后主题'];
      await mount(tester, resumed, session: session);
      expect(resumed.requests, hasLength(1));
      expect(resumed.themeRequests, hasLength(1));
      expect(find.byKey(const ValueKey('douban-theme-恢复后主题')), findsOneWidget);
      expect(find.textContaining('fixture offline'), findsWidgets);
      themeResponse.complete(['旧会话主题']);
      pageResponse.complete(repo.result(DoubanKind.movie));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('douban-theme-旧会话主题')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('theme panel can collapse and reopen after nested scrolling', (
    tester,
  ) async {
    final repo = _Repository()
      ..recommendedTags = [for (var i = 0; i < 180; i++) '主题$i'];
    await mount(tester, repo);
    final inner = find.byType(SingleChildScrollView);
    await tester.drag(inner, const Offset(0, -500));
    await tester.pumpAndSettle();
    final originalOffset = tester
        .widget<SingleChildScrollView>(inner)
        .controller!
        .offset;
    expect(originalOffset, greaterThan(0));
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('风格与主题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('风格与主题'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
      expect(
        tester.widget<SingleChildScrollView>(inner).controller!.offset,
        closeTo(originalOffset, 1),
      );
    }
    await tester.tap(find.text('剧集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('风格与主题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('电影'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
  });

  testWidgets(
    'all discovered themes can be revealed and selected beyond the compact viewport',
    (tester) async {
      final repo = _Repository()
        ..recommendedTags = [for (var i = 0; i < 280; i++) '多元主题$i'];
      await mount(tester, repo);
      final calls = repo.requests.length;
      await tester.tap(find.byKey(const ValueKey('douban-show-all-themes')));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsNothing);
      expect(repo.requests, hasLength(calls));
      final last = find.byKey(const ValueKey('douban-theme-多元主题279'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(repo.requests.last.tags, ['多元主题279']);
      expect(tester.widget<FilterChip>(last).selected, isTrue);
      await tester.ensureVisible(
        find.byKey(const ValueKey('douban-show-all-themes')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('douban-show-all-themes')));
      await tester.pumpAndSettle();
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);
    },
  );

  testWidgets(
    'TV forms clear only incompatible genres and compact filters wrap',
    (tester) async {
      final repo = _Repository();
      await mount(tester, repo, width: 560);
      await tester.tap(find.text('剧集'));
      await tester.pumpAndSettle();
      await choose(tester, 'format', '电视剧');
      await choose(tester, 'genre', '科幻');
      await choose(tester, 'year', '2024');
      await choose(tester, 'format', '综艺');
      await tester.pumpAndSettle();
      expect(selected(tester, 'genre'), '');
      expect(selected(tester, 'year'), '2024');
      await choose(tester, 'genre', '真人秀');
      expect(repo.requests.last.filters.format, '综艺');
      expect(repo.requests.last.filters.genre, '真人秀');
      expect(tester.takeException(), isNull);
    },
  );
}
