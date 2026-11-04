import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/material.dart';

abstract base class BaseDanmakuPainter extends CustomPainter {
  final int length;
  final List<DanmakuItem> danmakuItems;
  final double fontSize;
  final int fontWeight;
  final double strokeWidth;
  final double devicePixelRatio;
  final bool running;
  final double _initialTick;
  final double Function()? tickReader;
  double get tick => tickReader?.call() ?? _initialTick;

  static final Paint _paint = Paint()..filterQuality = FilterQuality.low;

  const BaseDanmakuPainter({
    required this.length,
    required this.danmakuItems,
    required this.fontSize,
    required this.fontWeight,
    required this.strokeWidth,
    required this.devicePixelRatio,
    required this.running,
    required double tick,
    this.tickReader,
    super.repaint,
  }) : _initialTick = tick;

  static void paintImg(
    Canvas canvas,
    DanmakuItem item,
    double dx,
    double dy,
    double devicePixelRatio,
  ) {
    final img = item.image!;
    if (devicePixelRatio == 1.0) {
      canvas.drawImage(img, Offset(dx, dy), _paint);
    } else {
      final src = Rect.fromLTWH(
        0,
        0,
        img.width.toDouble(),
        img.height.toDouble(),
      );
      final dst = Rect.fromLTWH(dx, dy, item.width, item.height);
      canvas.drawImageRect(img, src, dst, _paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    DanmakuItem? suspended;
    for (final item in danmakuItems) {
      if (item.expired) continue;
      if (item.suspend) {
        suspended = item;
      } else {
        paintDanmaku(canvas, size, item);
      }
    }
    if (suspended != null) paintDanmaku(canvas, size, suspended);
  }

  void paintDanmaku(Canvas canvas, Size size, DanmakuItem item);

  @override
  bool shouldRepaint(covariant BaseDanmakuPainter oldDelegate) {
    return (running && length != 0) ||
        oldDelegate.length != length ||
        oldDelegate.fontSize != fontSize ||
        oldDelegate.fontWeight != fontWeight ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.devicePixelRatio != devicePixelRatio;
  }
}
