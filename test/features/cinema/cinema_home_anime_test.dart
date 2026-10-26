import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_navigation_preferences.dart';
import 'package:kazumi/features/cinema/cinema_startup_preferences.dart';

class _Repository extends CinemaRepository {
  int searches = 0, browses = 0;
  @override
  Future<List<CinemaCategory>> categories(CinemaSource source) async =>
      const [];
  @override
  Future<CinemaPage> browse(
    CinemaSource source, {
    String? categoryId,
    int page = 1,
  }) async {
    browses++;
    return const CinemaPage(items: []);
  }

  @override
  Future<CinemaPage> search(
    CinemaSource source,
    String keyword, {
    int page = 1,
  }) async {
    searches++;
    return const CinemaPage(items: []);
  }
}

class _AnimeStateProbe extends StatefulWidget {
  const _AnimeStateProbe({
    required this.active,
    required this.onMount,
    required this.onDispose,
  });
  final bool active;
  final VoidCallback onMount, onDispose;
  @override
  State<_AnimeStateProbe> createState() => _AnimeStateProbeState();
}

class _AnimeStateProbeState extends State<_AnimeStateProbe> {
  final input = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  void dispose() {
    input.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(widget.active ? '动漫前台' : '动漫已隐藏'),
      TextField(key: const ValueKey('anime-search-probe'), controller: input),
    ],
  );
}

void main() {
  late Directory directory;
  late CinemaStore store;
  late CinemaNavigationPreferences navigation;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-anime-home-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [
        CinemaSource(
          id: 'movie-api',
          name: '影视接口',
          kind: CinemaSourceKind.maccms,
          url: 'https://example.com/api',
        ),
      ],
    );
    await store.load();
    navigation = CinemaNavigationPreferences(
      readValue: () => false,
      writeValue: (_) async {},
    );
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    navigation.dispose();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'one lazy anime entry retains its page and avoids source search',
    (tester) async {
      await navigation.setShowAnime(true);
      final repository = _Repository();
      var mounts = 0, disposals = 0;
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaHomePage(
            store: store,
            navigationPreferences: navigation,
            repository: repository,
            enableWatchTogether: false,
            enableSearchDiscovery: false,
            animePageBuilder: (_, active) => _AnimeStateProbe(
              active: active,
              onMount: () => mounts++,
              onDispose: () => disposals++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(mounts, 0);
      expect(find.text('Bangumi 动漫目录'), findsNothing);
      final initialBrowses = repository.browses;
      Finder entry(String label, String section) => Platform.isMacOS
          ? find.byKey(ValueKey('cinema-destination-$section'))
          : find.widgetWithText(ListTile, label);
      await tester.tap(entry('动漫', 'anime'));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(find.text('动漫前台'), findsOneWidget);
      expect(
        find.byType(TextField),
        findsNWidgets(Platform.isMacOS ? 2 : 1),
        reason: 'Mac keeps unified movie/series search alongside anime search.',
      );
      expect(find.text('片源目录'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('anime-search-probe')),
        '赛博朋克',
      );
      await tester.tap(entry('电影', 'movies'));
      await tester.pumpAndSettle();
      expect(disposals, 0);
      expect(find.text('动漫前台'), findsNothing);
      expect(
        tester
            .widget<_AnimeStateProbe>(
              find.byType(_AnimeStateProbe, skipOffstage: false),
            )
            .active,
        isFalse,
      );
      await tester.tap(entry('动漫', 'anime'));
      await tester.pumpAndSettle();
      expect(mounts, 1);
      expect(find.text('赛博朋克'), findsOneWidget);
      expect(repository.browses, initialBrowses);
      expect(repository.searches, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(disposals, 1);
    },
  );

  Future<void> mountNavigation(
    WidgetTester tester, {
    double width = 1280,
    CinemaStartupTarget startup = const CinemaStartupTarget(),
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          repository: _Repository(),
          navigationPreferences: navigation,
          initialStartup: startup,
          enableWatchTogether: false,
          enableSearchDiscovery: false,
          animePageBuilder: (_, active) => Text(active ? '动漫功能可用' : '动漫保留'),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openCompactNavigation(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu_rounded).first);
    await tester.pumpAndSettle();
  }

  bool selectedDestination(WidgetTester tester, String section) {
    final destination = find.byKey(ValueKey('cinema-destination-$section'));
    final widget = tester.widget(destination);
    if (widget is ListTile) return widget.selected;
    final selectedSemantics = find.ancestor(
      of: destination,
      matching: find.byWidgetPredicate(
        (widget) => widget is Semantics && widget.properties.selected != null,
      ),
    );
    return tester
        .widget<Semantics>(selectedSemantics.first)
        .properties
        .selected!;
  }

  for (final width in [1280.0, 600.0]) {
    testWidgets(
      'anime entry is opt-in and visible destinations keep their identity at width $width',
      (tester) async {
        await mountNavigation(tester, width: width);
        if (width < 800) await openCompactNavigation(tester);
        expect(
          find.byKey(const ValueKey('cinema-destination-anime')),
          findsNothing,
        );
        await tester.tap(
          find.byKey(const ValueKey('cinema-destination-series')),
        );
        await tester.pumpAndSettle();
        if (width < 800) await openCompactNavigation(tester);
        expect(selectedDestination(tester, 'series'), isTrue);
        expect(selectedDestination(tester, 'movies'), isFalse);
        await tester.tap(
          find.byKey(const ValueKey('cinema-destination-favorites')),
        );
        await tester.pumpAndSettle();
        expect(find.text('我的收藏'), findsWidgets);
        expect(find.text('动漫功能可用'), findsNothing);
        await navigation.setShowAnime(true);
        await tester.pumpAndSettle();
        if (width < 800) await openCompactNavigation(tester);
        expect(selectedDestination(tester, 'favorites'), isTrue);
        expect(
          find.byKey(const ValueKey('cinema-destination-anime')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const ValueKey('cinema-destination-anime')),
        );
        await tester.pumpAndSettle();
        expect(find.text('动漫功能可用'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'hidden anime deep link remains usable without opting other pages in',
    (tester) async {
      await mountNavigation(
        tester,
        startup: const CinemaStartupTarget(section: CinemaStartupSection.anime),
      );
      expect(navigation.showAnime, isFalse);
      expect(find.text('动漫功能可用'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cinema-destination-anime')),
        findsOneWidget,
      );
      expect(selectedDestination(tester, 'anime'), isTrue);
      expect(selectedDestination(tester, 'movies'), isFalse);
      await tester.tap(find.byKey(const ValueKey('cinema-destination-movies')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cinema-destination-anime')),
        findsNothing,
      );
      expect(find.text('动漫功能可用'), findsNothing);
      expect(navigation.showAnime, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
