import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_artwork_backdrop.dart';

void main() {
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
      contrast(320),
      lessThan(12),
      reason: 'Below the sharp image only diffuse source colors remain.',
    );
    expect(
      (red(156, 320) - 72).abs(),
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
