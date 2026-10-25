import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_featured_wall.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

class _Artwork extends CinemaDetailArtworkRepository {
  final identities = <String>[];
  @override
  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) async {
    identities.add(identity.imdbId);
    return const CinemaDetailArtwork(url: '');
  }
}

const _titles = [
  CinemaTitle(id: 'titanic', sourceId: 'fixture', title: '泰坦尼克号', year: '1997'),
  CinemaTitle(
    id: 'interstellar',
    sourceId: 'fixture',
    title: '星际穿越',
    year: '2014',
  ),
  CinemaTitle(id: 'arrival', sourceId: 'fixture', title: '降临', year: '2016'),
  CinemaTitle(id: 'dune', sourceId: 'fixture', title: '沙丘', year: '2021'),
];

void main() {
  Future<void> mount(
    WidgetTester tester, {
    ValueChanged<CinemaTitle>? onOpen,
    bool reduced = false,
    bool tickerEnabled = true,
    bool offscreen = false,
    List<CinemaTitle> titles = _titles,
    ScrollController? scrollController,
    double height = 860,
    double topInset = 0,
    CinemaDetailArtworkRepository? artworkRepository,
    Listenable? artworkChanges,
    RatingIdentity Function(CinemaTitle)? artworkIdentity,
    Widget Function(CinemaTitle)? statusBuilder,
  }) async {
    tester.view.physicalSize = Size(1280, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(1280, height),
            disableAnimations: reduced,
          ),
          child: TickerMode(
            enabled: tickerEnabled,
            child: SingleChildScrollView(
              controller: scrollController,
              child: Column(
                children: [
                  if (offscreen) const SizedBox(height: 1000),
                  CinemaFeaturedWall(
                    titles: titles,
                    onOpen: onOpen ?? (_) {},
                    topInset: topInset,
                    artworkRepository: artworkRepository,
                    artworkChanges: artworkChanges,
                    artworkIdentity: artworkIdentity,
                    statusBuilder: statusBuilder,
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  PageController pages(WidgetTester tester) => tester
      .widget<PageView>(find.byKey(const ValueKey('cinema-featured-pages')))
      .controller!;

  testWidgets(
    'late identity events upgrade artwork without unrelated hero rebuilds',
    (tester) async {
      final artwork = _Artwork();
      final first = ChangeNotifier(), second = ChangeNotifier();
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      var imdb = '';
      var builds = 0;
      Future<void> install(Listenable changes) => mount(
        tester,
        artworkRepository: artwork,
        artworkChanges: changes,
        artworkIdentity: (_) => RatingIdentity(imdbId: imdb),
        statusBuilder: (_) {
          builds++;
          return const SizedBox.shrink();
        },
      );
      await install(first);
      await tester.pumpAndSettle();
      expect(artwork.identities, ['', '']);
      imdb = 'tt0120338';
      first.notifyListeners();
      await tester.pumpAndSettle();
      expect(artwork.identities, ['', '', 'tt0120338', 'tt0120338']);
      final settledBuilds = builds;
      first.notifyListeners();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        builds,
        settledBuilds,
        reason: 'An unchanged identity does not repaint the hero.',
      );
      expect(artwork.identities, hasLength(4));
      await install(second);
      await tester.pumpAndSettle();
      imdb = 'tt0903747';
      first.notifyListeners();
      await tester.pump();
      expect(artwork.identities, hasLength(4));
      second.notifyListeners();
      await tester.pumpAndSettle();
      expect(artwork.identities.skip(4), ['tt0903747', 'tt0903747']);
      await tester.pumpWidget(const SizedBox());
      second.notifyListeners();
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'hero fills most of the first screen and adapts to short windows',
    (tester) async {
      await mount(tester, topInset: 90);
      expect(
        tester.getSize(find.byType(CinemaFeaturedWall)).height,
        closeTo(860 * .76, .01),
      );
      expect(find.text('查看影片').hitTestable(), findsOneWidget);
      await mount(tester, height: 480, topInset: 90);
      expect(
        tester.getSize(find.byType(CinemaFeaturedWall)).height,
        closeTo(480 * .76, .01),
      );
      expect(find.text('查看影片').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('artwork keeps the normal arrow during hover and drag', (
    tester,
  ) async {
    await mount(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(600, 100));
    await mouse.moveTo(const Offset(620, 120));
    await tester.pump();
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    await mouse.down(const Offset(620, 120));
    await mouse.moveBy(const Offset(-180, 0));
    await tester.pump(const Duration(milliseconds: 80));
    expect(
      tester.binding.mouseTracker.debugDeviceActiveCursor(1),
      SystemMouseCursors.basic,
    );
    expect(pages(tester).page, greaterThan(.05));
    await mouse.up();
    await mouse.removePointer();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a short slow drag follows the pointer and settles back', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CinemaFeaturedWall)),
    );
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveBy(const Offset(-200, 0));
    await tester.pump(const Duration(seconds: 1));
    final partial = pages(tester).page!;
    expect(partial, greaterThan(.15));
    expect(partial, lessThan(.4));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pages(tester).page, closeTo(0, .001));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a fast flick advances and reversing before settling stays coherent',
    (tester) async {
      final opened = <CinemaTitle>[];
      await mount(tester, onOpen: opened.add);
      final hero = find.byType(CinemaFeaturedWall);
      await tester.fling(hero, const Offset(-400, 0), 1600);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.fling(hero, const Offset(750, 0), 1900);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(0, .001));
      expect(opened, isEmpty);
      await tester.tap(find.text('查看影片').hitTestable());
      expect(opened, [_titles.first]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'trackpad pan zoom follows horizontally and snaps to the next title',
    (tester) async {
      await mount(tester);
      final center = tester.getCenter(find.byType(CinemaFeaturedWall));
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(center);
      await gesture.panZoomUpdate(center, pan: const Offset(-50, 0));
      await tester.pump(const Duration(milliseconds: 30));
      await gesture.panZoomUpdate(center, pan: const Offset(-850, 0));
      await tester.pump(const Duration(milliseconds: 100));
      expect(pages(tester).page, greaterThan(.5));
      await gesture.panZoomEnd();
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      expect(find.text('星际穿越').hitTestable(), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'horizontal wheel input tracks deltas and settles after its stream',
    (tester) async {
      await mount(tester);
      final center = tester.getCenter(find.byType(CinemaFeaturedWall));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(350, 0)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      final first = pages(tester).page!;
      expect(first, closeTo(350 / 1280, .001));
      await tester.sendEventToBinding(
        PointerScrollEvent(position: center, scrollDelta: const Offset(450, 0)),
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(pages(tester).page, closeTo(800 / 1280, .001));
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a vertical wheel over the artwork scrolls the containing wall', (
    tester,
  ) async {
    final scroll = ScrollController();
    await mount(tester, scrollController: scroll);
    final center = tester.getCenter(find.byType(CinemaFeaturedWall));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: center, scrollDelta: const Offset(0, 230)),
    );
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(230, .01));
    expect(pages(tester).page, closeTo(0, .001));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
  });

  testWidgets(
    'keyboard arrows select pages and focus pauses automatic rotation',
    (tester) async {
      await mount(tester);
      Focus.of(tester.element(find.byType(PageView))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      await tester.pump(const Duration(seconds: 20));
      expect(pages(tester).page, closeTo(1, .001));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(0, .001));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pausing during a wheel gesture cannot leave a half-visible page',
    (tester) async {
      await mount(tester);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byType(CinemaFeaturedWall)),
          scrollDelta: const Offset(800, 0),
        ),
      );
      await tester.pump(const Duration(milliseconds: 30));
      expect(pages(tester).page, closeTo(.625, .001));
      await mount(tester, tickerEnabled: false);
      await tester.pump();
      expect(pages(tester).page, closeTo(1, .001));
      await mount(tester);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh preserves the selected work and shrinking clears stale pages',
    (tester) async {
      final opened = <CinemaTitle>[];
      await mount(tester, onOpen: opened.add);
      await tester.tap(find.byTooltip('查看降临'));
      await tester.pumpAndSettle();
      await mount(tester, titles: [_titles[2], _titles[0]], onOpen: opened.add);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(0, .001));
      expect(find.text('降临').hitTestable(), findsOneWidget);
      await tester.tap(find.text('查看影片').hitTestable());
      expect(opened, [_titles[2]]);
      await mount(tester, titles: [_titles.first]);
      await tester.pumpAndSettle();
      expect(find.text('泰坦尼克号').hitTestable(), findsOneWidget);
      await mount(tester, titles: []);
      await tester.pumpAndSettle();
      expect(find.byType(PageView), findsNothing);
      await mount(tester);
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(0, .001));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('mouse drag reveals the next artwork without opening it', (
    tester,
  ) async {
    final opened = <CinemaTitle>[];
    await mount(tester, onOpen: opened.add);
    final hero = find.byType(CinemaFeaturedWall);
    final gesture = await tester.startGesture(
      tester.getCenter(hero),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(-850, 0));
    await tester.pump(const Duration(milliseconds: 120));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('星际穿越').hitTestable(), findsOneWidget);
    expect(opened, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'dragging from the action button changes pages without opening details',
    (tester) async {
      final opened = <CinemaTitle>[];
      await mount(tester, onOpen: opened.add);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('查看影片')),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(-100, 0));
      await tester.pump(const Duration(milliseconds: 50));
      await gesture.moveBy(const Offset(-750, 0));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      expect(opened, isEmpty);
      await tester.tap(find.text('查看影片').hitTestable());
      expect(opened, [_titles[1]]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'vertical touch drag scrolls the parent without changing artwork',
    (tester) async {
      final scroll = ScrollController();
      await mount(tester, scrollController: scroll);
      await tester.drag(find.byType(CinemaFeaturedWall), const Offset(0, -250));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(150));
      expect(pages(tester).page, closeTo(0, .001));
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'Shift wheel changes artworks without vertical parent scrolling',
    (tester) async {
      final scroll = ScrollController();
      await mount(tester, scrollController: scroll);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          kind: PointerDeviceKind.mouse,
          position: tester.getCenter(find.byType(CinemaFeaturedWall)),
          scrollDelta: const Offset(0, 850),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpAndSettle();
      expect(pages(tester).page, closeTo(1, .001));
      expect(scroll.offset, 0);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
    },
  );

  testWidgets(
    'manual selection opens that exact work and preserves its identity',
    (tester) async {
      final opened = <CinemaTitle>[];
      await mount(tester, onOpen: opened.add);
      await tester.tap(find.byTooltip('查看星际穿越'));
      await tester.pumpAndSettle();
      expect(find.text('星际穿越'), findsOneWidget);
      expect(find.text('泰坦尼克号'), findsNothing);
      await tester.tap(find.text('查看影片'));
      expect(opened, [_titles[1]]);
      expect(opened.single.key, _titles[1].key);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('nine-second rotation pauses on hover and while backgrounded', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.text('星际穿越'), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1260, 800));
    await mouse.moveTo(const Offset(600, 100));
    await tester.pump(const Duration(seconds: 18));
    expect(find.text('星际穿越'), findsOneWidget);
    await mouse.moveTo(const Offset(1260, 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 18));
    expect(find.text('星际穿越'), findsOneWidget);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.text('降临'), findsOneWidget);
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion and disabled ticker keep the current artwork', (
    tester,
  ) async {
    await mount(tester, reduced: true);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('泰坦尼克号'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await mount(tester, tickerEnabled: false);
    await tester.pump(const Duration(minutes: 1));
    expect(find.text('泰坦尼克号'), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an offscreen hero does not skip works before it becomes visible',
    (tester) async {
      await mount(tester, offscreen: true);
      await tester.pump(const Duration(seconds: 18));
      expect(find.text('泰坦尼克号'), findsOneWidget);
      await tester.ensureVisible(find.byType(CinemaFeaturedWall));
      await tester.pump(const Duration(seconds: 9));
      await tester.pumpAndSettle();
      expect(find.text('星际穿越'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
