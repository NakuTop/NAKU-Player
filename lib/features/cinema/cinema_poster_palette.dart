import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Sample once per decoded artwork, with a small bounded readback. The caller
/// retains ownership of [image]; no full-size pixel buffer is ever requested.
Future<List<Color>> cinemaPosterPalette(ui.Image image) async {
  const width = 36, height = 24;
  final source = image.clone();
  ui.Picture? picture;
  ui.Image? thumbnail;
  try {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      const Rect.fromLTWH(0, 0, 36, 24),
      Paint()..filterQuality = FilterQuality.low,
    );
    picture = recorder.endRecording();
    thumbnail = await picture.toImage(width, height);
    final pixels = await thumbnail.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    if (pixels == null) return const [];
    final sums = List.generate(3, (_) => List<double>.filled(4, 0));
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final offset = (y * width + x) * 4;
        if (pixels.getUint8(offset + 3) < 128) continue;
        final rgb = [
          for (var c = 0; c < 3; c++) pixels.getUint8(offset + c) / 255,
        ];
        final high = rgb.reduce((a, b) => a > b ? a : b);
        final low = rgb.reduce((a, b) => a < b ? a : b);
        // Ignore letterboxes and bright neutral lettering, retaining neutral
        // tones in the actual composition rather than inventing accent colors.
        if (high < .08 || (low > .92 && high - low < .08)) continue;
        final weight = .25 + (high - low) * .75;
        final bucket = sums[x ~/ 12];
        for (var c = 0; c < 3; c++) {
          bucket[c] += rgb[c] * weight;
        }
        bucket[3] += weight;
      }
    }
    final valid = sums.where((sum) => sum[3] > 0).toList();
    if (valid.isEmpty) return const [];
    return List.unmodifiable([
      for (final sum in sums)
        Color.from(
          alpha: 1,
          red: (sum[3] == 0 ? valid.first[0] / valid.first[3] : sum[0] / sum[3])
              .clamp(0.0, 1.0),
          green:
              (sum[3] == 0 ? valid.first[1] / valid.first[3] : sum[1] / sum[3])
                  .clamp(0.0, 1.0),
          blue:
              (sum[3] == 0 ? valid.first[2] / valid.first[3] : sum[2] / sum[3])
                  .clamp(0.0, 1.0),
        ),
    ]);
  } finally {
    thumbnail?.dispose();
    picture?.dispose();
    source.dispose();
  }
}
