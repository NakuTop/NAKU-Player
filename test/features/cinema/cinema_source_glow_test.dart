import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_source_glow.dart';

void main() {
  testWidgets(
    'the original chip has moving poster-coloured light and respects reduced motion',
    (tester) async {
      const boundary = ValueKey('glow-fixture');
      await tester.runAsync(() async {
        await (FontLoader(
          'PosterTest',
        )..addFont(rootBundle.load('assets/fonts/MiSans-Regular.ttf'))).load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        await ui.FragmentProgram.fromAsset('shaders/cinema_original_silk.frag');
      });
      Future<void> mount(
        bool reduced, {
        Color seed = const Color(0xff4aa99d),
        bool onstage = true,
      }) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: 'PosterTest',
          ),
          home: Scaffold(
            backgroundColor: const Color(0xff18191b),
            body: Center(
              child: RepaintBoundary(
                key: boundary,
                child: ColoredBox(
                  color: const Color(0xff191a1d),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: TickerMode(
                      enabled: onstage,
                      child: CinemaSourceGlow(
                        original: true,
                        active: true,
                        dimmed: false,
                        reduceMotion: reduced,
                        color: seed,
                        child: ActionChip(
                          onPressed: () {},
                          shape: const StadiumBorder(),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: .12),
                          ),
                          backgroundColor: const Color(0xDC222329),
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          avatar: const Icon(
                            Icons.high_quality_outlined,
                            color: Color(0xD8F5F5F7),
                            size: 17,
                          ),
                          label: const Text(
                            '原画 · 3840×2160',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<Uint8List> screenshot(String name, {double ratio = 2}) async {
        final paint = tester
            .getRect(find.byType(CinemaSourceGlow))
            .shift(-tester.getTopLeft(find.byKey(boundary)));
        return (await tester.runAsync(() async {
          final image = await tester
              .renderObject<RenderRepaintBoundary>(find.byKey(boundary))
              .toImage(pixelRatio: ratio);
          try {
            const dir = String.fromEnvironment('NAKU_DETAIL_RASTER');
            if (dir.isNotEmpty) {
              final png = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              await File(
                '$dir/$name.png',
              ).writeAsBytes(png!.buffer.asUint8List());
            }
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!.buffer.asUint8List();
            final left = (paint.left * ratio).round(),
                top = (paint.top * ratio).round();
            final right = (paint.right * ratio).round() - 1,
                bottom = (paint.bottom * ratio).round() - 1;
            var edgeError = 0;
            void inspect(int x, int y) {
              final i = (y * image.width + x) * 4;
              const background = [25, 26, 29];
              for (var c = 0; c < 3; c++) {
                final error = (pixels[i + c] - background[c]).abs();
                if (error > edgeError) edgeError = error;
              }
            }

            for (var x = left; x <= right; x++) {
              inspect(x, top);
              inspect(x, bottom);
            }
            for (var y = top; y <= bottom; y++) {
              inspect(left, y);
              inspect(right, y);
            }
            expect(
              edgeError,
              lessThanOrEqualTo(1),
              reason: 'Light should vanish before each paint boundary.',
            );
            return pixels;
          } finally {
            image.dispose();
          }
        }))!;
      }

      int changed(Uint8List a, Uint8List b) {
        expect(a.length, b.length);
        int pixels = 0;
        for (int i = 0; i < a.length; i += 4) {
          if ((a[i] - b[i]).abs() +
                  (a[i + 1] - b[i + 1]).abs() +
                  (a[i + 2] - b[i + 2]).abs() >
              16) {
            pixels++;
          }
        }
        return pixels;
      }

      await mount(false);
      await tester.pump();
      final first = await screenshot('original-glow-a');
      await tester.pump(const Duration(milliseconds: 2250));
      final second = await screenshot('original-glow-b');
      expect(changed(first, second), greaterThan(150));
      await tester.pump(const Duration(milliseconds: 6750));
      final nine = await screenshot('original-glow-nine');
      expect(changed(first, nine), greaterThan(150));
      await tester.pump(const Duration(milliseconds: 33));
      final adjacent = await screenshot('original-glow-next');
      expect(changed(nine, adjacent), lessThan(changed(first, nine)));
      await screenshot('original-glow-standard', ratio: 1);
      await mount(false, onstage: false);
      final hidden = await screenshot('original-glow-hidden');
      await tester.pump(const Duration(seconds: 10));
      expect(changed(hidden, await screenshot('original-glow-hidden-b')), 0);
      await mount(false);
      await tester.pump(const Duration(milliseconds: 50));
      final priorPalette = await screenshot('original-glow-before-palette');
      await mount(false, seed: const Color(0xffc18563));
      expect(
        changed(priorPalette, await screenshot('original-glow-start-palette')),
        0,
      );
      await tester.pump(const Duration(milliseconds: 950));
      expect(
        changed(priorPalette, await screenshot('original-glow-warm')),
        greaterThan(150),
      );
      await mount(true);
      final still = await screenshot('original-glow-still');
      await tester.pump(const Duration(seconds: 3));
      expect(changed(still, await screenshot('original-glow-still-b')), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
