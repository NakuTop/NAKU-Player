import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// A local pool of light; the chip retains its original size and hit target.
class CinemaSourceGlow extends StatelessWidget {
  const CinemaSourceGlow({
    super.key,
    required this.active,
    required this.dimmed,
    required this.color,
    required this.reduceMotion,
    required this.child,
  });

  final bool active, dimmed, reduceMotion;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 650),
    curve: Curves.easeOutCubic,
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: dimmed ? .26 : 0),
      borderRadius: BorderRadius.circular(8),
    ),
    child: TweenAnimationBuilder<double>(
      tween: Tween(end: active ? 1 : 0),
      duration: reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, strength, child) => CustomPaint(
        painter: _SourceGlowPainter(color, strength),
        child: child,
      ),
      child: child,
    ),
  );
}

class _SourceGlowPainter extends CustomPainter {
  const _SourceGlowPainter(this.color, this.strength);
  final Color color;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (strength <= 0 || size.isEmpty) return;
    final rect = (Offset.zero & size).deflate(2);
    // Broad shadow separates the light from the poster without dimming text.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.inflate(9), const Radius.circular(13)),
      Paint()
        ..color = Colors.black.withValues(alpha: .48 * strength)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );
    final base = HSLColor.fromColor(color);
    final tint = base
        .withSaturation(base.saturation.clamp(.28, .5))
        .withLightness(.68)
        .toColor();
    final secondary = base
        .withHue((base.hue + 32) % 360)
        .withSaturation(.38)
        .withLightness(.62)
        .toColor();
    final perimeter = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)));
    final metric = perimeter.computeMetrics().first;
    // Unequal feathered arcs leave quiet gaps, instead of a uniform neon frame.
    for (final arc in [(0.02, .38, .72), (.51, .82, .68), (.88, .98, .42)]) {
      final segment = metric.extractPath(
        metric.length * arc.$1,
        metric.length * arc.$2,
      );
      canvas.drawPath(
        segment,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 12
          ..color = (arc.$1 > .5 ? secondary : tint).withValues(
            alpha: arc.$3 * strength,
          )
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
      canvas.drawPath(
        segment,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, [
            tint.withValues(alpha: .8 * strength),
            tint.withValues(alpha: .12 * strength),
          ])
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.7),
      );
    }
  }

  @override
  bool shouldRepaint(_SourceGlowPainter oldDelegate) =>
      color != oldDelegate.color || strength != oldDelegate.strength;
}
