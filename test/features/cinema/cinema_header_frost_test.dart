import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_appearance.dart';
import 'package:kazumi/features/cinema/cinema_header_frost.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

class _Checkerboard extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    for (var y = 0; y < size.height; y += 8) {
      for (var x = 0; x < size.width; x += 8) {
        canvas.drawRect(
          Rect.fromLTWH(x.toDouble(), y.toDouble(), 8, 8),
          Paint()
            ..color = (x ~/ 8 + y ~/ 8).isEven ? Colors.white : Colors.black,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_Checkerboard oldDelegate) => false;
}

class _MemoryAppearance extends CinemaAppearance {
  _MemoryAppearance() : super(observeNativeAccessibility: false);
  double density = .35;
  bool reduced = false;
  @override
  double get effectiveBackgroundOpacity => reduced ? 1 : density;
  @override
  bool get reduceTransparency => reduced;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> flush() async {}
  void update({double? opacity, bool? reduce}) {
    density = opacity ?? density;
    reduced = reduce ?? reduced;
    notifyListeners();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> capture(WidgetTester tester) async => (await tester.runAsync(
    () => tester
        .renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('frost-raster')),
        )
        .toImage(pixelRatio: 1),
  ))!;

  Future<ByteData> pixels(WidgetTester tester, ui.Image image) async =>
      (await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      ))!;

  int red(ByteData bytes, int x, int y) => bytes.getUint8((y * 256 + x) * 4);

  Future<ui.Image> raster(
    WidgetTester tester, {
    bool frost = true,
    bool? reduceTransparency,
    bool foreground = false,
    VoidCallback? onBackgroundTap,
    CinemaAppearance? appearance,
  }) async {
    tester.view.physicalSize = const Size(256, 160);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: appearance == null
            ? null
            : (context, child) =>
                  CinemaAppearanceScope(appearance: appearance, child: child!),
        home: RepaintBoundary(
          key: const ValueKey('frost-raster'),
          child: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onBackgroundTap,
                child: CustomPaint(painter: _Checkerboard()),
              ),
              if (frost)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: CinemaHeaderFrost(
                    reduceTransparency: reduceTransparency,
                  ),
                ),
              if (foreground)
                const Positioned(
                  top: 16,
                  left: 16,
                  width: 56,
                  height: 20,
                  child: ColoredBox(color: Color(0xFF00FF00)),
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return capture(tester);
  }

  testWidgets(
    'header frost blurs actual checker pixels and fades its lower edge',
    (tester) async {
      final raw = await raster(tester, frost: false);
      final plain = await pixels(tester, raw);
      final image = await raster(tester);
      final rendered = await pixels(tester, image);
      int contrast(ByteData bytes, int y) =>
          (red(bytes, 100, y) - red(bytes, 108, y)).abs();
      expect(contrast(plain, 24), 255);
      // The header contains genuine mixed backdrop pixels, not only a dark tint.
      expect(contrast(rendered, 24), lessThan(12));
      expect(red(rendered, 100, 24), greaterThan(20));
      expect(contrast(rendered, 108), greaterThan(contrast(rendered, 88)));
      expect(contrast(rendered, 111), greaterThan(235));
      expect(contrast(rendered, 112), 255);
      final contrastBeforeEdge = contrast(rendered, 111);
      expect(255 - contrastBeforeEdge, lessThan(20));
      const output = String.fromEnvironment('NAKU_HEADER_FROST_OUTPUT');
      if (output.isNotEmpty) {
        await tester.runAsync(() async {
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File(output);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
        });
      }
      raw.dispose();
      image.dispose();
    },
  );

  testWidgets(
    'frost leaves foreground sharp and passes taps without a ticker',
    (tester) async {
      var taps = 0;
      final image = await raster(
        tester,
        foreground: true,
        onBackgroundTap: () => taps++,
      );
      final rendered = await pixels(tester, image);
      for (final x in [16, 32, 71]) {
        final offset = (24 * 256 + x) * 4;
        expect(rendered.getUint8(offset), 0);
        expect(rendered.getUint8(offset + 1), 255);
        expect(rendered.getUint8(offset + 2), 0);
        expect(rendered.getUint8(offset + 3), 255);
      }
      expect(red(rendered, 15, 24), greaterThan(20));
      await tester.tapAt(const Offset(120, 30));
      await tester.pumpAndSettle();
      expect(taps, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.binding.transientCallbackCount, 0);
      image.dispose();
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('scoped opacity and accessibility update the live header', (
    tester,
  ) async {
    final appearance = _MemoryAppearance();
    final initial = await raster(tester, appearance: appearance);
    final initialPixels = await pixels(tester, initial);
    final element = tester.element(find.byType(CinemaHeaderFrost));
    appearance.update(opacity: .9);
    await tester.pump();
    final denser = await capture(tester);
    expect(
      red(await pixels(tester, denser), 100, 24),
      lessThan(red(initialPixels, 100, 24)),
    );
    expect(tester.element(find.byType(CinemaHeaderFrost)), same(element));
    appearance.update(reduce: true);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    final solid = await capture(tester);
    expect(red(await pixels(tester, solid), 100, 24), 9);
    expect(appearance.density, .9);
    appearance.update(reduce: false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(tester.element(find.byType(CinemaHeaderFrost)), same(element));
    initial.dispose();
    denser.dispose();
    solid.dispose();
    await tester.pumpWidget(const SizedBox());
    appearance.dispose();
    expect(tester.takeException(), isNull);
  });
}
