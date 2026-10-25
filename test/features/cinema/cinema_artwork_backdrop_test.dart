import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_artwork_backdrop.dart';

void main() {
  test(
    'short hero preserves the extension bank reserved for the fixed header',
    () {
      final rect = cinemaArtworkCompositionRect(
        source: const Size(1920, 1080),
        viewport: const Size(1280, 365),
        insets: const EdgeInsets.fromLTRB(24, 80, 24, 40),
      );
      expect(rect.top, greaterThanOrEqualTo(80));
      expect(rect.bottom, lessThanOrEqualTo(325));
      expect(rect.width / rect.height, closeTo(1920 / 1080, .00001));
    },
  );
  const cornerColors = [
    Color(0xFFE24A40),
    Color(0xFF36C586),
    Color(0xFF4269E2),
    Color(0xFFF2BE42),
  ];
  Future<Uint8List> compositionFixture(Size source) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Offset.zero & source,
      Paint()..color = const Color(0xFF9A8F84),
    );
    canvas.drawRect(
      Rect.fromLTWH(0, 0, source.width * .12, source.height),
      Paint()..color = cornerColors[0],
    );
    canvas.drawRect(
      Rect.fromLTWH(source.width * .88, 0, source.width * .12, source.height),
      Paint()..color = cornerColors[2],
    );
    final marker = source.shortestSide * .2;
    for (final (i, point) in [
      Offset.zero,
      Offset(source.width - marker, 0),
      Offset(0, source.height - marker),
      Offset(source.width - marker, source.height - marker),
    ].indexed) {
      canvas.drawRect(
        Rect.fromLTWH(point.dx, point.dy, marker, marker),
        Paint()..color = cornerColors[i],
      );
    }
    canvas.drawCircle(
      source.center(Offset.zero),
      source.shortestSide * .18,
      Paint()..color = const Color(0xFFF0E3C8),
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      source.width.toInt(),
      source.height.toInt(),
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    return png!.buffer.asUint8List();
  }

  for (final (orientation, source) in [
    ('landscape', const Size(320, 180)),
    ('portrait', const Size(180, 320)),
  ]) {
    for (final (window, viewport) in [
      ('wide', const Size(1120, 640)),
      ('narrow', const Size(520, 760)),
      ('short', const Size(680, 440)),
    ]) {
      testWidgets(
        '$orientation composition keeps all four corners in $window window',
        (tester) async {
          tester.view.physicalSize = viewport;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final bytes = await tester.runAsync(() => compositionFixture(source));
          const alignment = Alignment(.4, -.2);
          final rect = cinemaArtworkCompositionRect(
            source: source,
            viewport: viewport,
            alignment: alignment,
          );
          expect(rect.width / rect.height, closeTo(source.aspectRatio, .0001));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(viewport.width));
          expect(rect.bottom, lessThanOrEqualTo(viewport.height));
          await tester.pumpWidget(
            MaterialApp(
              home: RepaintBoundary(
                key: const ValueKey('composition-raster'),
                child: ColoredBox(
                  color: const Color(0xFF1B1B1F),
                  child: CinemaArtworkBackdrop(
                    image: MemoryImage(bytes!),
                    alignment: alignment,
                    featherSides: true,
                  ),
                ),
              ),
            ),
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 40)),
          );
          await tester.pump();
          final image = (await tester.runAsync(
            () => tester
                .renderObject<RenderRepaintBoundary>(
                  find.byKey(const ValueKey('composition-raster')),
                )
                .toImage(pixelRatio: 1),
          ))!;
          final data = (await tester.runAsync(
            () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
          ))!;
          List<int> pixel(Offset point) {
            final offset =
                (point.dy.floor() * image.width + point.dx.floor()) * 4;
            return [for (var i = 0; i < 3; i++) data.getUint8(offset + i)];
          }

          final inset = source.shortestSide * .07;
          final points = [
            Offset(inset, inset),
            Offset(source.width - inset, inset),
            Offset(inset, source.height - inset),
            Offset(source.width - inset, source.height - inset),
          ];
          for (final (i, point) in points.indexed) {
            final actual = pixel(
              Offset(
                rect.left + point.dx / source.width * rect.width,
                rect.top + point.dy / source.height * rect.height,
              ),
            );
            final color = cornerColors[i];
            final expected = [
              (color.r * 255).round(),
              (color.g * 255).round(),
              (color.b * 255).round(),
            ];
            for (var c = 0; c < 3; c++) {
              expect(
                actual[c],
                closeTo(expected[c], 3),
                reason:
                    'Corner $i must survive fitting and every feather mask.',
              );
            }
          }
          // The extension begins with the exact border colour, then scatters
          // outward. It must not expose a dark rectangular frame around the art.
          final left = pixel(Offset(rect.left - 2, rect.center.dy));
          final right = pixel(Offset(rect.right + 2, rect.center.dy));
          expect(left[0] - left[1], greaterThan(70));
          expect(right[2] - right[0], greaterThan(70));
          const output = String.fromEnvironment('NAKU_ARTWORK_RASTER_DIR');
          if (output.isNotEmpty) {
            await tester.runAsync(() async {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$output/$orientation-$window.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            });
          }
          image.dispose();
          await tester.pumpWidget(const SizedBox());
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('sharp art, Gaussian field and window edges remain separate', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bytes = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      for (var y = 0; y < 360; y += 12) {
        for (var x = 0; x < 320; x += 12) {
          canvas.drawRect(
            Rect.fromLTWH(x.toDouble(), y.toDouble(), 12, 12),
            Paint()
              ..color = (x ~/ 12).isEven
                  ? const Color(0xFFFFC060)
                  : const Color(0xFF102050),
          );
        }
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(320, 360);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      return png!.buffer.asUint8List();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: RepaintBoundary(
          key: const ValueKey('art-raster'),
          child: ColoredBox(
            color: const Color(0xFF48484B),
            child: CinemaArtworkBackdrop(image: MemoryImage(bytes!)),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    final image = await tester.runAsync(
      () => tester
          .renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('art-raster')),
          )
          .toImage(pixelRatio: 1),
    );
    final pixels = (await tester.runAsync(
      () => image!.toByteData(format: ui.ImageByteFormat.rawRgba),
    ))!;
    int red(int x, int y) => pixels.getUint8((y * 320 + x) * 4);
    int contrast(int y) => (red(150, y) - red(162, y)).abs();
    expect(
      contrast(145),
      greaterThan(150),
      reason: 'The main picture stays sharp.',
    );
    expect(
      contrast(344),
      lessThan(12),
      reason:
          'The picture ends at y=304; beyond its 32px seam only diffuse source colors remain.',
    );
    expect(contrast(320), lessThan(contrast(145)));
    expect(
      contrast(320),
      greaterThan(contrast(344)),
      reason:
          'The seam progressively mixes the exact border into the diffuse field.',
    );
    expect(
      (red(156, 344) - 72).abs(),
      greaterThan(4),
      reason: 'The Gaussian field must survive the sharp mask.',
    );
    expect((red(156, 0) - 72).abs(), lessThanOrEqualTo(3));
    expect((red(156, 359) - 72).abs(), lessThanOrEqualTo(3));
    for (var y = 336; y < 359; y++) {
      expect(
        (red(156, y + 1) - red(156, y)).abs(),
        lessThanOrEqualTo(3),
        reason: 'No hard lower edge at row $y.',
      );
    }
    const output = String.fromEnvironment('NAKU_ARTWORK_RASTER');
    if (output.isNotEmpty) {
      await tester.runAsync(() async {
        final png = await image!.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(png!.buffer.asUint8List());
      });
    }
    image!.dispose();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
