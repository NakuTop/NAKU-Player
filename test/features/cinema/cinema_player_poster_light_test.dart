import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_player_entrance.dart';
import 'package:kazumi/features/cinema/cinema_player_poster_light.dart';
import 'package:kazumi/features/cinema/cinema_poster_palette.dart';

class _Poster extends ImageStreamCompleter {
  void complete(ui.Image image) => setImage(ImageInfo(image: image.clone()));
  void fail() => reportError(exception: StateError('fixture'), silent: true);
}

Future<ui.Image> solidPoster(Color color) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawPaint(Paint()..color = color);
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 48);
  picture.dispose();
  return image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => PaintingBinding.instance.imageCache.clear());

  testWidgets('poster color arrives without restarting the loading entrance', (
    tester,
  ) async {
    final provider = MemoryImage(Uint8List.fromList([1]));
    final poster = _Poster();
    PaintingBinding.instance.imageCache.putIfAbsent(provider, () => poster);
    Color? color;
    final stage = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: stage,
          child: CinemaPlayerPosterLight(
            posterUrl: 'fixture-blue',
            image: provider,
            builder: (_, tint, resolved) {
              color = tint;
              return CinemaPlayerEntrance(
                generation: 7,
                ready: false,
                lampColor: tint,
                lampReady: resolved,
                child: const ColoredBox(color: Colors.green),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 501));
    await tester.pump();
    final entrance = tester.state<CinemaPlayerEntranceState>(
      find.byType(CinemaPlayerEntrance),
    );
    final extent = entrance.debugLampExtent;
    expect(color, cinemaNeutralLampColor);
    expect(entrance.debugPhase, 'waiting');
    final image = await tester.runAsync(
      () => solidPoster(const Color(0xFF1459C7)),
    );
    addTearDown(image!.dispose);
    poster.complete(image);
    for (var i = 0; i < 20 && color == cinemaNeutralLampColor; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(color!.b, greaterThan(color!.r));
    expect(color!.b, greaterThan(color!.g));
    expect(entrance.debugGeneration, 7);
    expect(entrance.debugPhase, 'waiting');
    expect(entrance.debugLampExtent, extent);
    expect(
      tester
          .widget<CinemaPlayerEntrance>(find.byType(CinemaPlayerEntrance))
          .lampColor,
      color,
    );
    await tester.runAsync(() async {
      final boundary =
          stage.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final rendered = await boundary.toImage();
      final pixels = (await rendered.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final at =
          (((rendered.height * .065).floor() * rendered.width) +
              rendered.width ~/ 2) *
          4;
      expect(pixels.getUint8(at + 2), greaterThan(pixels.getUint8(at)));
      rendered.dispose();
    });
    final folder = Platform.environment['NAKU_QA_SCREENSHOTS'];
    if (folder != null) {
      for (var frame = 0; frame < 20; frame++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          final boundary =
              stage.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final rendered = await boundary.toImage();
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await Directory(folder).create(recursive: true);
          await File(
            '$folder/poster-lamp-${frame.toString().padLeft(2, '0')}.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
      }
    }
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'undecoded poster does not display a neutral lamp before its tint',
    (tester) async {
      final provider = MemoryImage(Uint8List.fromList([9]));
      final poster = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(provider, () => poster);
      final stage = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: RepaintBoundary(
            key: stage,
            child: CinemaPlayerPosterLight(
              posterUrl: 'pending',
              image: provider,
              builder: (_, tint, resolved) => CinemaPlayerEntrance(
                generation: 0,
                ready: false,
                lampColor: tint,
                lampReady: resolved,
                child: const ColoredBox(color: Colors.green),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 501));
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            stage.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        var light = 0;
        for (var at = 0; at < data.length; at += 4) {
          light += data[at] + data[at + 1] + data[at + 2];
        }
        image.dispose();
        expect(
          light,
          0,
          reason:
              'the first visible lamp must already have its resolved poster tint',
        );
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a replaced posters late decode cannot overwrite the current tint',
    (tester) async {
      final oldProvider = MemoryImage(Uint8List.fromList([2]));
      final newProvider = MemoryImage(Uint8List.fromList([3]));
      final old = _Poster(), current = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(oldProvider, () => old);
      PaintingBinding.instance.imageCache.putIfAbsent(
        newProvider,
        () => current,
      );
      Color? tint;
      Widget host(ImageProvider image, String url) => MaterialApp(
        home: CinemaPlayerPosterLight(
          posterUrl: url,
          image: image,
          builder: (_, color, resolved) {
            tint = color;
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(host(oldProvider, 'old'));
      await tester.pumpWidget(host(newProvider, 'new'));
      final blue = await tester.runAsync(() => solidPoster(Colors.blue));
      final green = await tester.runAsync(() => solidPoster(Colors.green));
      addTearDown(blue!.dispose);
      addTearDown(green!.dispose);
      current.complete(green);
      for (var i = 0; i < 20 && tint == cinemaNeutralLampColor; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tint!.g, greaterThan(tint!.b));
      final expected = tint;
      old.complete(blue);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      expect(tint, expected);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing or failed poster keeps neutral light without delaying the child',
    (tester) async {
      final provider = MemoryImage(Uint8List.fromList([4]));
      final poster = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(provider, () => poster);
      Color? tint;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaPlayerPosterLight(
            posterUrl: 'failed',
            image: provider,
            builder: (_, color, resolved) {
              tint = color;
              return const Text('player ready');
            },
          ),
        ),
      );
      expect(find.text('player ready'), findsOneWidget);
      poster.fail();
      await tester.pump();
      expect(tint, cinemaNeutralLampColor);
      expect(find.text('player ready'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'a timed-out poster locks its visible fallback against late colors',
    (tester) async {
      final provider = MemoryImage(Uint8List.fromList([10]));
      final poster = _Poster();
      PaintingBinding.instance.imageCache.putIfAbsent(provider, () => poster);
      Color? tint;
      bool? ready;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaPlayerPosterLight(
            posterUrl: 'timeout',
            image: provider,
            builder: (_, color, resolved) {
              tint = color;
              ready = resolved;
              return const Text('media keeps loading');
            },
          ),
        ),
      );
      expect(ready, false);
      expect(find.text('media keeps loading'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(ready, true);
      expect(tint, cinemaNeutralLampColor);
      final blue = await tester.runAsync(() => solidPoster(Colors.blue));
      addTearDown(blue!.dispose);
      poster.complete(blue);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      expect(tint, cinemaNeutralLampColor);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
