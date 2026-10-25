import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'cinema_theme.dart';

/// A passive background for a floating header. Place foreground controls after
/// it in the enclosing Stack so their pixels and hit targets stay untouched.
class CinemaHeaderFrost extends StatelessWidget {
  const CinemaHeaderFrost({
    super.key,
    this.height = 112,
    this.opacity,
    this.reduceTransparency,
  });

  final double height;
  final double? opacity;
  final bool? reduceTransparency;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: CinemaAppearanceScope.of(context),
    builder: (context, _) {
      final appearance = CinemaAppearanceScope.of(context);
      final solid = reduceTransparency ?? appearance.reduceTransparency;
      final density = opacity ?? appearance.effectiveBackgroundOpacity;
      final scrim = CustomPaint(painter: _Feather(density, solid: solid));
      return IgnorePointer(
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: ClipRect(
            child: solid
                ? scrim
                : BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    blendMode: BlendMode.srcOver,
                    child: scrim,
                  ),
          ),
        ),
      );
    },
  );
}

class _Feather extends CustomPainter {
  const _Feather(this.opacity, {required this.solid});
  final double opacity;
  final bool solid;

  static const _stops = [0.0, .62, .74, .85, .95, 1.0];
  static const _strength = [1.0, 1.0, .90, .50, .10, 0.0];

  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    const ink = Color(0xFF09090B);
    if (solid) {
      // Accessibility gets an opaque, unfiltered area beneath the 68px controls.
      // Only the decorative tail below that area fades into the body.
      canvas.drawRect(
        bounds,
        Paint()
          ..shader = ui.Gradient.linear(
            Offset.zero,
            Offset(0, size.height),
            _strength.map((alpha) => ink.withValues(alpha: alpha)).toList(),
            _stops,
          ),
      );
      return;
    }
    final density = opacity.clamp(0.0, 1.0);
    canvas.drawRect(
      bounds,
      Paint()
        ..color = ink.withValues(
          alpha: density >= .999 ? 1 : .22 + .52 * density,
        ),
    );
    // Mask inside BackdropFilter's backdrop layer. A ShaderMask above the
    // filter creates a transparent saveLayer on Skia and loses the real input.
    // dstIn here feathers both the filtered pixels and the tint together.
    canvas.drawRect(
      bounds,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          _strength
              .map((alpha) => Colors.white.withValues(alpha: alpha))
              .toList(),
          _stops,
        ),
    );
  }

  @override
  bool shouldRepaint(_Feather oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.solid != solid;
}
