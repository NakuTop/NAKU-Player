import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_poster_palette.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lamp retains sampled blue hue at a visible lightness', () {
    const blue = Color(0xFF124494);
    final lamp = HSLColor.fromColor(cinemaPosterLampColor([blue, blue, blue]));
    final source = HSLColor.fromColor(blue);
    expect(lamp.hue, closeTo(source.hue, .75));
    expect(lamp.saturation, closeTo(source.saturation, .01));
    expect(lamp.lightness, closeTo(.68, .01));
  });
  test('neutral or unavailable artwork does not invent a warm accent', () {
    expect(cinemaPosterLampColor([]), cinemaNeutralLampColor);
    final gray = cinemaPosterLampColor([const Color(0xFF353535)]);
    expect(gray.r, closeTo(gray.g, .001));
    expect(gray.g, closeTo(gray.b, .001));
  });
  test('neutral lettering cannot displace a sampled poster hue', () {
    final tint = cinemaPosterLampColor([
      const Color(0xFFCCCCCC),
      const Color(0xFF235A97),
      const Color(0xFF999999),
    ]);
    expect(tint.b, greaterThan(tint.r));
    expect(tint.b, greaterThan(tint.g));
  });

  test(
    'palette comes from three artwork regions without changing ownership',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      const colors = [Color(0xFFDD4422), Color(0xFF2288BB), Color(0xFF448833)];
      for (var i = 0; i < colors.length; i++) {
        canvas.drawRect(
          Rect.fromLTWH(i * 120, 0, 120, 240),
          Paint()..color = colors[i],
        );
      }
      // Letterboxing and a bright neutral strip must not wash out the palette.
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 360, 10),
        Paint()..color = const Color(0xFF000000),
      );
      canvas.drawRect(
        const Rect.fromLTWH(0, 230, 360, 10),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(360, 240);
      picture.dispose();
      addTearDown(image.dispose);
      final palette = await cinemaPosterPalette(image);
      expect(palette.length, 3);
      for (var i = 0; i < colors.length; i++) {
        expect((palette[i].r - colors[i].r).abs(), lessThan(.025));
        expect((palette[i].g - colors[i].g).abs(), lessThan(.025));
        expect((palette[i].b - colors[i].b).abs(), lessThan(.025));
      }
      final clone = image.clone();
      expect(clone.width, 360);
      clone.dispose();
    },
  );

  test(
    'empty black artwork keeps neutral frost rather than inventing color',
    () async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawPaint(Paint()..color = const Color(0xFF000000));
      final picture = recorder.endRecording();
      final image = await picture.toImage(20, 20);
      picture.dispose();
      addTearDown(image.dispose);
      expect(await cinemaPosterPalette(image), isEmpty);
    },
  );
}
