import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_scroll_activity.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';

const _source = CinemaSource(
  id: 'rating-source',
  name: '评分测试片源',
  kind: CinemaSourceKind.maccms,
  url: 'https://rating.example/api',
);

CinemaTitle _title(String id) => CinemaTitle(
  id: id,
  sourceId: _source.id,
  title: '测试电影$id',
  category: '剧情片',
  categoryId: '1',
  year: '${DateTime.now().year}',
);

class _Catalogue extends CinemaRepository {
  _Catalogue(this.items);
  final List<CinemaTitle> items;
  int detailCalls = 0, browseCalls = 0;
  final detailKeys = <String>[];
  Future<CinemaPage> Function(int page)? onBrowse;

  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async => const [
    CinemaCategory(id: '1', name: '剧情片'),
  ];

  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browseCalls++;
    if (onBrowse != null) return onBrowse!(page);
    return CinemaPage(items: items, total: items.length);
  }

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
  }) async => CinemaPage(items: items, total: items.length);

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    detailCalls++;
    detailKeys.add(title.key);
    return title;
  }
}

class _Ratings extends CinemaRatingsRepository {
  final notifier = ChangeNotifier();
  final cache = <String, CinemaRatings>{};
  final cardCalls = <String, int>{};
  int detailCalls = 0;

  @override
  Listenable get changes => notifier;

  @override
  CinemaRatings? peek(CinemaTitle title) => cache[title.id];

  void setScores(
    String id,
    Map<String, double?> scores, {
    bool notify = false,
    RatingIdentity? identity,
  }) {
    cache[id] = CinemaRatings(
      identity: identity ?? cache[id]?.identity ?? const RatingIdentity(),
      ratings: [
        for (final entry in scores.entries)
          CinemaRating(
            provider: entry.key,
            value: entry.value,
            scale: entry.key == '烂番茄' ? 100 : 10,
            note: 'fixture',
            verified: true,
          ),
      ],
      message: 'fixture',
    );
    if (notify) notifier.notifyListeners();
  }

  @override
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) async {
    cardCalls.update(title.id, (value) => value + 1, ifAbsent: () => 1);
    return peek(title) ??
        const CinemaRatings(
          identity: RatingIdentity(),
          ratings: [],
          message: 'fixture',
        );
  }

  @override
  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) async {
    detailCalls++;
    return peek(title) ??
        const CinemaRatings(
          identity: RatingIdentity(),
          ratings: [],
          message: 'fixture',
        );
  }
}

class _Discovery extends CinemaSearchDiscoveryRepository {
  @override
  Future<CinemaSearchDiscovery> search(
    String keyword, {
    CancelToken? cancelToken,
  }) async => CinemaSearchDiscovery(
    titles: [
      for (final id in ['1291546', '1292052'])
        CinemaDiscoveryTitle(
          id: id,
          title: '相关作品$id',
          year: '${DateTime.now().year}',
          kind: 'movie',
        ),
    ],
  );
}

class _NavigationObserver extends NavigatorObserver {
  final pushed = <Route<dynamic>>[];
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late _Ratings ratings;
  late _Catalogue catalogue;
  final navKey = GlobalKey<NavigatorState>();
  late _NavigationObserver navigation;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('home-rating-sort-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: [_source],
    );
    await store.load();
    ratings = _Ratings();
    catalogue = _Catalogue([
      _title('A'),
      _title('B'),
      _title('C'),
      _title('D'),
    ]);
    navigation = _NavigationObserver();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    ratings.notifier.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    CinemaSearchDiscoveryRepository? discovery,
  }) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [navigation],
        home: CinemaHomePage(
          store: store,
          repository: catalogue,
          ratingsRepository: ratings,
          enableWatchTogether: false,
          searchDiscovery: discovery,
          enableSearchDiscovery: discovery != null,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectRatingSort(WidgetTester tester) async {
    final chip = find.byKey(const ValueKey('catalog-sort-rating'));
    expect(chip, findsOneWidget);
    await tester.tap(chip);
    await tester.pumpAndSettle();
    expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
  }

  Future<void> ensureProviderVisible(WidgetTester tester) async {
    final menu = find.byKey(const ValueKey('catalog-rating-provider'));
    await Scrollable.ensureVisible(tester.element(menu), alignment: .35);
    await tester.pumpAndSettle();
    expect(menu.hitTestable(), findsOneWidget);
  }

  Future<void> selectProvider(WidgetTester tester, String provider) async {
    await ensureProviderVisible(tester);
    final menu = find.byKey(const ValueKey('catalog-rating-provider'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    final option = find
        .descendant(
          of: find.byWidgetPredicate(
            (widget) =>
                widget is DropdownMenuItem<String> && widget.value == provider,
          ),
          matching: find.text(provider),
        )
        .hitTestable();
    expect(option, findsOneWidget, reason: 'The provider menu must be open.');
    await tester.tap(option);
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<String>>(menu).value, provider);
  }

  Finder card(String id) =>
      find.byKey(ValueKey('title-card:${_source.id}::$id'));

  List<String> visualOrder(WidgetTester tester, List<String> ids) {
    final positions = [
      for (final id in ids) (id: id, position: tester.getTopLeft(card(id))),
    ];
    positions.sort((a, b) {
      final row = a.position.dy.compareTo(b.position.dy);
      return row == 0 ? a.position.dx.compareTo(b.position.dx) : row;
    });
    return positions.map((item) => item.id).toList();
  }

  testWidgets('movie and series homes start with all years and recent hot', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('全部年份'), findsWidgets);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('catalog-sort-popular')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.text('剧集').first);
    await tester.pumpAndSettle();
    expect(find.text('全部年份'), findsWidgets);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('catalog-sort-popular')),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets(
    'rating chip sorts by the chosen provider and leaves missing scores last',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5, 'IMDb': 6.5, '烂番茄': 95});
      ratings.setScores('B', {'豆瓣': 7.0, 'IMDb': 9.0, '烂番茄': null});
      ratings.setScores('C', {'豆瓣': null, 'IMDb': null, '烂番茄': 80});
      ratings.setScores('D', {'豆瓣': 6.0, 'IMDb': 7.5, '烂番茄': 0});
      await mount(tester);
      await selectRatingSort(tester);
      // Resource badges hydrate these four route-less source cards once.
      // Changing rating providers must not trigger additional detail work.
      final resourceHydration = List<String>.of(catalogue.detailKeys);
      expect(
        resourceHydration,
        unorderedEquals(catalogue.items.map((title) => title.key)),
      );
      expect(catalogue.detailCalls, 4);
      expect(ratings.detailCalls, 0);
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      await selectProvider(tester, 'IMDb');
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['B', 'D', 'A', 'C']);
      await selectProvider(tester, '烂番茄');
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'C', 'D', 'B']);
      expect(catalogue.detailKeys, resourceHydration);
      expect(catalogue.detailCalls, resourceHydration.length);
      expect(ratings.detailCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unrelated scores and identity notifications keep the home viewport intact',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5, 'IMDb': 7.0});
      ratings.setScores('B', {'豆瓣': 7.0});
      ratings.setScores('C', {'豆瓣': null});
      ratings.setScores('D', {'豆瓣': 6.0});
      await mount(tester);
      await selectRatingSort(tester);
      CustomScrollView viewport() =>
          tester.widget<CustomScrollView>(find.byType(CustomScrollView));
      final original = viewport();

      ratings.setScores('not-displayed', {'豆瓣': 10.0}, notify: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(identical(viewport(), original), isTrue);

      ratings.setScores('A', {'豆瓣': 8.5, 'IMDb': 9.5}, notify: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(identical(viewport(), original), isTrue);
      expect(
        find.descendant(of: card('A'), matching: find.textContaining('9.5')),
        findsOneWidget,
        reason: 'The card keeps its own shared-cache subscription.',
      );

      ratings.setScores(
        'A',
        {'豆瓣': 8.5, 'IMDb': 9.5},
        identity: const RatingIdentity(imdbId: 'tt0120338'),
        notify: true,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(identical(viewport(), original), isTrue);

      ratings.setScores('A', {'豆瓣': 8.7, 'IMDb': 9.5}, notify: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(identical(viewport(), original), isFalse);
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      expect(
        find.descendant(of: card('A'), matching: find.textContaining('8.7')),
        findsOneWidget,
        reason: 'A score change matters even when it keeps the same order.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discovery metadata scores independently reorder the related works row',
    (tester) async {
      ratings.setScores('1291546', {'豆瓣': 8.0});
      ratings.setScores('1292052', {'豆瓣': 6.0});
      await mount(tester, discovery: _Discovery());
      await selectRatingSort(tester);
      await tester.enterText(find.byType(TextField).first, '相关作品');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('discovery-title:1291546'));
      final second = find.byKey(const ValueKey('discovery-title:1292052'));
      await Scrollable.ensureVisible(tester.element(first), alignment: .35);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(first).dx,
        lessThan(tester.getTopLeft(second).dx),
      );
      final viewport = tester.widget<CustomScrollView>(
        find.byType(CustomScrollView),
      );
      ratings.setScores('1292052', {'豆瓣': 9.0}, notify: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        identical(
          tester.widget<CustomScrollView>(find.byType(CustomScrollView)),
          viewport,
        ),
        isFalse,
      );
      expect(
        tester.getTopLeft(second).dx,
        lessThan(tester.getTopLeft(first).dx),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background rating changes reorder the home grid without opening details',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5});
      ratings.setScores('B', {'豆瓣': 7.0});
      ratings.setScores('C', {'豆瓣': null});
      ratings.setScores('D', {'豆瓣': 6.0});
      await mount(tester);
      await selectRatingSort(tester);
      final resourceHydration = List<String>.of(catalogue.detailKeys);
      expect(
        resourceHydration,
        unorderedEquals(catalogue.items.map((title) => title.key)),
      );
      expect(catalogue.detailCalls, 4);
      expect(ratings.detailCalls, 0);
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      ratings.setScores('C', {'豆瓣': 9.6}, notify: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['C', 'A', 'B', 'D']);
      expect(
        find.descendant(of: card('C'), matching: find.textContaining('9.6')),
        findsOneWidget,
      );
      expect(catalogue.detailKeys, resourceHydration);
      expect(catalogue.detailCalls, resourceHydration.length);
      expect(ratings.detailCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'rating results do not reorder a scrolling grid and catch up after idle',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5});
      ratings.setScores('B', {'豆瓣': 7.0});
      ratings.setScores('C', {'豆瓣': null});
      ratings.setScores('D', {'豆瓣': 6.0});
      await mount(tester);
      await selectRatingSort(tester);
      final activity = tester
          .widget<CinemaScrollNotifications>(
            find.byType(CinemaScrollNotifications),
          )
          .activity;
      activity.begin();
      for (var i = 0; i < 20; i++) {
        ratings.setScores('C', {'豆瓣': 9.6}, notify: true);
      }
      await tester.pump(const Duration(milliseconds: 800));
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      activity.end();
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['C', 'A', 'B', 'D']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a pending score refresh cannot reorder during a scrolling layout rebuild',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5});
      ratings.setScores('B', {'豆瓣': 7.0});
      ratings.setScores('C', {'豆瓣': null});
      ratings.setScores('D', {'豆瓣': 6.0});
      await mount(tester);
      await selectRatingSort(tester);
      final activity = tester
          .widget<CinemaScrollNotifications>(
            find.byType(CinemaScrollNotifications),
          )
          .activity;
      ratings.setScores('C', {'豆瓣': 9.6}, notify: true);
      activity.begin();
      tester.view.physicalSize = const Size(1300, 1000);
      await tester.pump(const Duration(milliseconds: 800));
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      activity.end();
      await tester.pump(const Duration(milliseconds: 121));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['C', 'A', 'B', 'D']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a new search releases preload work from the replaced viewport', (
    tester,
  ) async {
    catalogue = _Catalogue([for (var i = 0; i < 60; i++) _title('影片$i')]);
    await mount(tester);
    await selectRatingSort(tester);
    final activity = tester
        .widget<CinemaScrollNotifications>(
          find.byType(CinemaScrollNotifications),
        )
        .activity;
    final oldViewport = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .key;
    activity.begin();
    final before = Map<String, int>.of(ratings.cardCalls);
    tester
        .widget<DropdownButton<String>>(
          find.byKey(const ValueKey('catalog-rating-provider')),
        )
        .onChanged!('IMDb');
    await tester.pump(const Duration(milliseconds: 500));
    expect(
      ratings.cardCalls,
      before,
      reason: 'Preload waits during scrolling.',
    );
    await tester.enterText(find.byType(TextField).first, '新搜索');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).key,
      isNot(oldViewport),
    );
    expect(activity.value, isFalse);
    expect(
      ratings.cardCalls['影片59'],
      greaterThan(before['影片59']!),
      reason: 'The new search resumes the selected provider even offscreen.',
    );
    final after = Map<String, int>.of(ratings.cardCalls);
    await tester.pump(const Duration(seconds: 2));
    expect(
      ratings.cardCalls,
      after,
      reason: 'Completed preload does not loop.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rating preloading covers offscreen loaded works and settles after rebuilds',
    (tester) async {
      catalogue = _Catalogue([for (var i = 0; i < 60; i++) _title('影片$i')]);
      for (final item in catalogue.items) {
        ratings.setScores(item.id, const {
          '豆瓣': null,
          'IMDb': null,
          '烂番茄': null,
        });
      }
      await mount(tester);
      expect(
        card('影片59'),
        findsNothing,
        reason: 'The last loaded work has no visible card.',
      );
      expect(
        ratings.cardCalls.length,
        0,
        reason: 'Recent-hot browse does not prefetch source rating order.',
      );
      await selectRatingSort(tester);
      // Position the viewport before recording card work. Revealing the sort
      // control can legitimately mount new cards with their own cache reads.
      await ensureProviderVisible(tester);
      final browses = catalogue.browseCalls;
      expect(
        ratings.cardCalls.keys.toSet(),
        catalogue.items.map((item) => item.id).toSet(),
      );
      expect(card('影片59'), findsNothing);
      final calls = Map<String, int>.of(ratings.cardCalls);
      await tester.pump(const Duration(seconds: 3));
      ratings.notifier.notifyListeners();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(
        ratings.cardCalls,
        calls,
        reason: 'Score notifications do not restart a completed batch.',
      );
      await selectProvider(tester, 'IMDb');
      await selectProvider(tester, '烂番茄');
      final allProviders = Map<String, int>.of(ratings.cardCalls);
      expect(allProviders, {
        for (final entry in calls.entries) entry.key: entry.value + 2,
      }, reason: 'Each newly selected provider gets one bounded preload.');
      await selectProvider(tester, '豆瓣');
      await selectProvider(tester, 'IMDb');
      expect(
        ratings.cardCalls,
        allProviders,
        reason: 'Switching back reuses completed work for that provider.',
      );
      expect(
        catalogue.browseCalls,
        browses,
        reason: 'Changing local score order reuses the loaded catalogue.',
      );
      expect(ratings.cardCalls.values.every((count) => count <= 4), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('two preload workers safely finish an odd number of works', (
    tester,
  ) async {
    catalogue = _Catalogue([_title('A'), _title('B'), _title('C')]);
    await mount(tester);
    await selectRatingSort(tester);
    expect(ratings.cardCalls.keys.toSet(), {'A', 'B', 'C'});
    final completed = Map<String, int>.of(ratings.cardCalls);
    await tester.pump(const Duration(seconds: 2));
    expect(ratings.cardCalls, completed);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Douban board uses the same themed route as ordinary pages', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('豆瓣榜单'));
    final route = navigation.pushed.last;
    expect(route, isA<MaterialPageRoute<void>>());
    expect(route.settings.name, isNot('naku-native-player'));
    navKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(CinemaHomePage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
