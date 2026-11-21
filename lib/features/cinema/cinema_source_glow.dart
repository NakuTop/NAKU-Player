import 'dart:ui' as ui;
import 'dart:async';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart' show listEquals;
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
    this.original = false,
    this.inline = false,
    this.palette = const [],
  });

  final bool active, dimmed, reduceMotion, original, inline;
  final Color color;
  final List<Color> palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (inline && original) {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          if (active)
            Positioned(
              left: -_lightInset.left,
              right: -_lightInset.right,
              top: -_lightInset.top,
              bottom: -_lightInset.bottom,
              child: IgnorePointer(
                child: _OriginalGlow(
                  active: true,
                  animate: !reduceMotion,
                  color: color,
                  palette: palette,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          child,
        ],
      );
    }
    return original
        ? _OriginalGlow(
            color: color,
            palette: palette,
            animate: active && !reduceMotion,
            active: active,
            child: child,
          )
        : AnimatedContainer(
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 650),
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
}

class _OriginalGlow extends StatefulWidget {
  const _OriginalGlow({
    required this.color,
    required this.animate,
    required this.palette,
    required this.active,
    required this.child,
  });
  final Color color;
  final List<Color> palette;
  final bool animate, active;
  final Widget child;
  @override
  State<_OriginalGlow> createState() => _OriginalGlowState();
}

const _lightInset = EdgeInsets.symmetric(horizontal: 29, vertical: 22);

class _OriginalGlowState extends State<_OriginalGlow>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static final Future<ui.FragmentProgram?> _program = _loadProgram();
  static Future<ui.FragmentProgram?> _loadProgram() async {
    try {
      return await ui.FragmentProgram.fromAsset(
        'shaders/cinema_original_silk.frag',
      );
    } catch (_) {
      return null;
    }
  }

  final _seconds = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker((elapsed) {
    final frame = elapsed.inMicroseconds * 30 ~/ Duration.microsecondsPerSecond;
    if (_lastFrame == frame) return;
    _lastFrame = frame;
    _seconds.value =
        _startedAt + elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  });
  int _lastFrame = -1;
  double _startedAt = 0, _paletteAt = 0;
  late List<Color> _from, _to;
  ui.FragmentShader? _shader;
  bool _onscreen = true;
  bool _tickersEnabled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _from = _to = _OriginalLight._silkColors(widget.color, widget.palette);
    final state = WidgetsBinding.instance.lifecycleState;
    _onscreen = state == null || state == AppLifecycleState.resumed;
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    final program = await _program;
    if (!mounted || program == null) return;
    final shader = program.fragmentShader();
    setState(() => _shader = shader);
    _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.animate && _shader != null && _onscreen && _tickersEnabled) {
      if (!_ticker.isActive) {
        _startedAt = _seconds.value;
        _lastFrame = -1;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _onscreen = state == AppLifecycleState.resumed;
    _updateAnimation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickersEnabled = TickerMode.valuesOf(context).enabled;
    _updateAnimation();
  }

  @override
  void didUpdateWidget(_OriginalGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.color != widget.color ||
        !listEquals(oldWidget.palette, widget.palette)) {
      final next = _OriginalLight._silkColors(widget.color, widget.palette);
      _from = _ticker.isActive
          ? _mixSilk(_from, _to, _seconds.value - _paletteAt)
          : next;
      _to = next;
      _paletteAt = _seconds.value;
    }
    if (!widget.animate) _from = _to;
    _updateAnimation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _seconds.dispose();
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _OriginalLight(
        widget.active,
        _from,
        _to,
        _paletteAt,
        _shader,
        _seconds,
      ),
      child: Padding(
        padding: _lightInset,
        child: RepaintBoundary(child: widget.child),
      ),
    ),
  );
}

List<Color> _mixSilk(List<Color> from, List<Color> to, double seconds) {
  if (identical(from, to) || seconds >= .9) return to;
  if (seconds <= 0) return from;
  final blend = Curves.easeInOut.transform(seconds / .9);
  return [
    for (var i = 0; i < to.length; i++) Color.lerp(from[i], to[i], blend)!,
  ];
}

class _OriginalLight extends CustomPainter {
  _OriginalLight(
    this.active,
    this.from,
    this.to,
    this.paletteAt,
    this.shader,
    this.seconds,
  ) : super(repaint: seconds);
  final bool active;
  final List<Color> from, to;
  final double paletteAt;
  final ui.FragmentShader? shader;
  final ValueNotifier<double> seconds;

  // Keep all three highlights in the same family as the artwork, even when
  // the poster is almost monochrome or contains a strongly contrasting accent.
  static List<Color> _silkColors(Color seed, List<Color> palette) {
    final base = HSLColor.fromColor(seed);
    final swatches = palette
        .map(HSLColor.fromColor)
        .where(
          (c) => c.saturation > .16 && c.lightness > .12 && c.lightness < .93,
        );
    final hue =
        base.saturation > .13 && base.lightness > .10 && base.lightness < .94
        ? base.hue
        : swatches.firstOrNull?.hue ?? 198.0;
    final warm = hue < 72 || hue > 336;
    double low = warm ? -42 : -30, high = warm ? 29 : 56;
    for (final swatch in swatches) {
      final difference = (swatch.hue - hue + 540) % 360 - 180;
      if (difference < low) low = difference.clamp(-46, low);
      if (difference > high) high = difference.clamp(high, warm ? 42 : 64);
    }
    Color tint(double offset, double saturation, double lightness) =>
        HSLColor.fromAHSL(
          1,
          (hue + offset + 360) % 360,
          saturation,
          lightness,
        ).toColor();
    return [tint(low, .57, .67), tint(0, .51, .76), tint(high, .52, .72)];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!active) return;
    final bounds = Offset.zero & size;
    final chip = _lightInset.deflateRect(bounds);
    if (chip.isEmpty) return;
    final effect = shader;
    final colors = _mixSilk(from, to, seconds.value - paletteAt);
    if (effect == null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(chip, Radius.circular(chip.height / 2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..shader = ui.Gradient.linear(chip.topLeft, chip.bottomRight, [
            colors.first.withValues(alpha: .27),
            colors.last.withValues(alpha: .34),
          ])
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      return;
    }
    effect
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, _lightInset.left)
      ..setFloat(3, _lightInset.top)
      ..setFloat(4, seconds.value);
    var index = 5;
    for (final color in colors) {
      effect.setFloat(index++, color.r);
      effect.setFloat(index++, color.g);
      effect.setFloat(index++, color.b);
    }
    canvas.drawRect(bounds, Paint()..shader = effect);
  }

  @override
  bool shouldRepaint(_OriginalLight old) =>
      old.active != active ||
      old.shader != shader ||
      old.seconds != seconds ||
      old.from != from ||
      old.to != to ||
      old.paletteAt != paletteAt;
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
