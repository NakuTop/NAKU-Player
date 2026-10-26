import 'package:flutter/gestures.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_artwork_backdrop.dart';
import 'package:kazumi/features/cinema/cinema_featured_wall.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

class _Artwork extends CinemaDetailArtworkRepository {
  final identities = <String>[];
  CinemaDetailArtwork result = const CinemaDetailArtwork(url: '');
  @override
  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) async {
    identities.add(identity.imdbId);
    return result;
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
    ImageProvider Function(CinemaDetailArtwork, int)? artworkImageProvider,
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
                  RepaintBoundary(
                    key: const ValueKey('hero-page-raster'),
                    child: CinemaFeaturedWall(
                      titles: titles,
                      onOpen: onOpen ?? (_) {},
                      topInset: topInset,
                      artworkRepository: artworkRepository,
                      artworkChanges: artworkChanges,
                      artworkIdentity: artworkIdentity,
                      statusBuilder: statusBuilder,
                      artworkImageProvider: artworkImageProvider,
                    ),
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
    'hero reserves full-width cinema composition and short windows can scroll',
    (tester) async {
      await mount(tester, topInset: 90);
      expect(
        tester.getSize(find.byType(CinemaFeaturedWall)).height,
        closeTo(1280 * 9 / 16 + 90 + 52, .01),
      );
      expect(find.text('查看影片').hitTestable(), findsOneWidget);
      await mount(tester, height: 480, topInset: 90);
      expect(
        tester.getSize(find.byType(CinemaFeaturedWall)).height,
        closeTo(1280 * 9 / 16 + 90 + 52, .01),
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('查看影片').first),
        alignment: .7,
      );
      await tester.pumpAndSettle();
      expect(find.text('查看影片').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  const marks = [
    Color(0xFFE24A40),
    Color(0xFF36C586),
    Color(0xFF4269E2),
    Color(0xFFF2BE42),
  ];
  Future<Uint8List> markedImage(Size size, {bool blank = false}) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = blank ? Colors.white : const Color(0xFFC4BBB0),
    );
    for (final (i, fraction)
        in (blank ? <double>[] : [.1, .3, .7, .9]).indexed) {
      canvas.drawRect(
        Rect.fromLTWH(
          size.width * (fraction - .04),
          0,
          size.width * .08,
          size.height,
        ),
        Paint()..color = marks[i],
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      size.width.toInt(),
      size.height.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    picture.dispose();
    image.dispose();
    return bytes!.buffer.asUint8List();
  }

  testWidgets(
    'bright full-width art keeps a local dark title bed without dimming the whole image',
    (tester) async {
      final bytes = (await tester.runAsync(
        () => markedImage(const Size(320, 180), blank: true),
      ))!;
      final repository = _Artwork()
        ..result = const CinemaDetailArtwork(
          url: 'memory://white-fixture',
          width: 1920,
          height: 1080,
          highResolution: true,
        );
      await mount(
        tester,
        topInset: 68,
        artworkRepository: repository,
        artworkImageProvider: (_, _) => MemoryImage(bytes),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pumpAndSettle();
      final title = find.text('泰坦尼克号').first;
      final titleRect = tester.getRect(title);
      final boundaryFinder = find.byKey(const ValueKey('hero-page-raster'));
      final origin = tester.getTopLeft(boundaryFinder);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        boundaryFinder,
      );
      final raster = (await tester.runAsync(
        () => boundary.toImage(pixelRatio: 1),
      ))!;
      final pixels = (await tester.runAsync(
        () => raster.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;
      final y = (titleRect.center.dy - origin.dy).floor();
      int red(int x) => pixels.getUint8((y * raster.width + x) * 4);
      expect(
        red((titleRect.left - origin.dx - 12).floor()),
        lessThan(105),
        reason:
            'The text bed must retain contrast against an all-white poster.',
      );
      expect(
        red(1100),
        greaterThan(235),
        reason: 'Unrelated image content stays bright.',
      );
      raster.dispose();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  for (final (name, original) in [
    ('hd-wide', const Size(320, 180)),
    ('cinema-wide', const Size(480, 200)),
    ('portrait', const Size(180, 320)),
  ]) {
    for (final windowHeight in [860.0, 480.0]) {
      testWidgets(
        '$name actual hero canvas fills horizontal edges at window height $windowHeight',
        (tester) async {
          final bytes = (await tester.runAsync(() => markedImage(original)))!;
          final repository = _Artwork()
            ..result = CinemaDetailArtwork(
              url: 'memory://hero-fixture',
              width: original.width.toInt() * 6,
              height: original.height.toInt() * 6,
              highResolution: true,
            );
          await mount(
            tester,
            height: windowHeight,
            topInset: 68,
            artworkRepository: repository,
            artworkImageProvider: (_, _) => MemoryImage(bytes),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pumpAndSettle();
          final backdropFinder = find.byType(CinemaArtworkBackdrop);
          final backdrop = tester.widget<CinemaArtworkBackdrop>(backdropFinder);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find
                .descendant(
                  of: backdropFinder,
                  matching: find.byType(RepaintBoundary),
                )
                .first,
          );
          final raster = (await tester.runAsync(
            () => boundary.toImage(pixelRatio: 1),
          ))!;
          final pixels = (await tester.runAsync(
            () => raster.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          expect(raster.width, 1280);
          final actualSize = Size(
            raster.width.toDouble(),
            raster.height.toDouble(),
          );
          final pictureRect = cinemaArtworkCompositionRect(
            source: original,
            viewport: actualSize,
            insets: backdrop.contentInsets,
            alignment: backdrop.alignment,
          );
          final y = pictureRect.center.dy.floor();
          List<int> rgb(int x) => [
            for (var c = 0; c < 3; c++)
              pixels.getUint8((y * raster.width + x) * 4 + c),
          ];
          if (name != 'portrait') {
            final centers = <double>[];
            for (final color in marks) {
              final target = [
                (color.r * 255).round(),
                (color.g * 255).round(),
                (color.b * 255).round(),
              ];
              final matching = <int>[];
              for (var x = 0; x < raster.width; x++) {
                final pixel = rgb(x);
                if (List.generate(
                  3,
                  (c) => (pixel[c] - target[c]).abs() <= 2,
                ).every((same) => same)) {
                  matching.add(x);
                }
              }
              expect(
                matching,
                isNotEmpty,
                reason: 'Every original interior marker must be painted.',
              );
              centers.add((matching.first + matching.last + 1) / 2);
            }
            // Infer the source-to-canvas transform from observed native pixels,
            // rather than trusting the layout helper's returned rectangle.
            final paintedWidth = (centers.last - centers.first) / .8;
            final paintedLeft = centers.first - paintedWidth * .1;
            expect(paintedLeft, closeTo(0, 2));
            expect(paintedLeft + paintedWidth, closeTo(raster.width, 2));
            expect(
              pictureRect.height / pictureRect.width,
              closeTo(original.height / original.width, .00001),
            );
          } else {
            expect(
              pictureRect.height / pictureRect.width,
              closeTo(original.height / original.width, .00001),
            );
            expect(
              raster.height,
              lessThan(1000),
              reason:
                  'A portrait must not reserve a full-width portrait-height page.',
            );
            for (final x in [0, raster.width - 1]) {
              final edge = rgb(x);
              expect(
                edge.reduce((a, b) => a + b),
                greaterThan(240),
                reason:
                    'The clamped edge field fills both ends, with no black side bank.',
              );
            }
          }
          const output = String.fromEnvironment(
            'NAKU_HERO_FULLWIDTH_RASTER_DIR',
          );
          if (output.isNotEmpty) {
            await tester.runAsync(() async {
              final png = await raster.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/$name-${windowHeight.toInt()}.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            });
          }
          raster.dispose();
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

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
