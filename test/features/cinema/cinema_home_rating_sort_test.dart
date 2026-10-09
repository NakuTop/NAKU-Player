import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

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
  year: '2024',
);

class _Catalogue extends CinemaRepository {
  _Catalogue(this.items);
  final List<CinemaTitle> items;
  int detailCalls = 0, browseCalls = 0;

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
    return CinemaPage(items: items, total: items.length);
  }

  @override
  Future<CinemaTitle> detail(CinemaSource source, CinemaTitle title) async {
    detailCalls++;
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
  }) {
    cache[id] = CinemaRatings(
      identity: const RatingIdentity(),
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

  Future<void> mount(WidgetTester tester) async {
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
          enableSearchDiscovery: false,
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

  Future<void> selectProvider(WidgetTester tester, String provider) async {
    final menu = find.byKey(const ValueKey('catalog-rating-provider'));
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text(provider).last);
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

  testWidgets(
    'rating chip sorts by the chosen provider and leaves missing scores last',
    (tester) async {
      ratings.setScores('A', {'豆瓣': 8.5, 'IMDb': 6.5, '烂番茄': 95});
      ratings.setScores('B', {'豆瓣': 7.0, 'IMDb': 9.0, '烂番茄': null});
      ratings.setScores('C', {'豆瓣': null, 'IMDb': null, '烂番茄': 80});
      ratings.setScores('D', {'豆瓣': 6.0, 'IMDb': 7.5, '烂番茄': 0});
      await mount(tester);
      await selectRatingSort(tester);
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'B', 'D', 'C']);
      await selectProvider(tester, 'IMDb');
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['B', 'D', 'A', 'C']);
      await selectProvider(tester, '烂番茄');
      expect(visualOrder(tester, ['A', 'B', 'C', 'D']), ['A', 'C', 'D', 'B']);
      expect(catalogue.detailCalls, 0);
      expect(ratings.detailCalls, 0);
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
      expect(catalogue.detailCalls, 0);
      expect(ratings.detailCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

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
      expect(ratings.cardCalls.length, lessThan(60));
      final browses = catalogue.browseCalls;
      await selectRatingSort(tester);
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
      await selectProvider(tester, 'IMDb');
      await selectProvider(tester, '烂番茄');
      expect(
        ratings.cardCalls,
        calls,
        reason: 'Sort refreshes do not restart completed preload batches.',
      );
      expect(
        catalogue.browseCalls,
        browses,
        reason: 'Changing local score order reuses the loaded catalogue.',
      );
      expect(ratings.cardCalls.values.every((count) => count <= 2), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Douban board route has no forward or reverse visual transition',
    (tester) async {
      await mount(tester);
      await tester.tap(find.text('豆瓣榜单'));
      final route = navigation.pushed.last;
      expect(route, isA<PageRouteBuilder<void>>());
      final page = route as PageRouteBuilder<void>;
      expect(page.transitionDuration, Duration.zero);
      expect(page.reverseTransitionDuration, Duration.zero);
      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.byType(CinemaHomePage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
