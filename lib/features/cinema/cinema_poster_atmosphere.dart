import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Slow, low-light poster color diffusing inside the caller's frosted surface.
///
/// This transparent layer adds neither a backdrop filter nor an image sample.
/// The caller retains its existing charcoal tint, blur and feathered boundary.
class CinemaPosterAtmosphere extends StatefulWidget {
  const CinemaPosterAtmosphere({
    super.key,
    this.palette,
    this.active = true,
    this.child,
  });

  /// Up to three already sampled poster colors. An absent palette stays neutral.
  final List<Color>? palette;
  final bool active;
  final Widget? child;

  @override
  CinemaPosterAtmosphereState createState() => CinemaPosterAtmosphereState();
}

class CinemaPosterAtmosphereState extends State<CinemaPosterAtmosphere>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _frame = _AtmosphereFrame();
  late final Ticker _ticker;
  Duration _lastFrame = Duration.zero;
  bool _foreground = true, _motionAllowed = true;

  bool get _canAnimate => widget.active && _foreground && _motionAllowed;

  @override
  void initState() {
    super.initState();
    _frame.changePalette(widget.palette, animate: false);
    _ticker = createTicker(_tick);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncTicker();
  }

  @override
  void didUpdateWidget(CinemaPosterAtmosphere oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.palette, widget.palette)) {
      _frame.changePalette(widget.palette, animate: _canAnimate);
    }
    _syncTicker();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncTicker();
  }

  void _syncTicker() {
    if (_canAnimate) {
      if (!_ticker.isActive) {
        _lastFrame = Duration.zero;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
      _lastFrame = Duration.zero;
    }
  }

  void _tick(Duration elapsed) {
    final previous = _lastFrame;
    _lastFrame = elapsed;
    // Ticker already measures from start. Its first callback can legitimately
    // contain elapsed time when it was started during the preceding build.
    _frame.advance((elapsed - previous).inMicroseconds / 1000000);
  }

  @visibleForTesting
  ({bool running, double phase}) get debugSnapshot =>
      (running: _ticker.isActive, phase: _frame.phase);

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      painter: _AtmospherePainter(_frame),
      child: widget.child == null
          ? const SizedBox.expand()
          : RepaintBoundary(child: widget.child),
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }
}

class _AtmosphereFrame extends ChangeNotifier {
  static const _neutral = [
    Color(0xFF50535A),
    Color(0xFF41454B),
    Color(0xFF535458),
  ];
  static const _cycleSeconds = 24.0;
  double phase = 0, _paletteBlend = 1;
  List<Color> colors = _neutral, _from = _neutral, _target = _neutral;

  void changePalette(List<Color>? palette, {required bool animate}) {
    final supplied = palette?.take(3).map((color) {
      final hsl = HSLColor.fromColor(color);
      final softened = hsl
          .withSaturation(hsl.saturation.clamp(0.0, .62))
          .withLightness(hsl.lightness.clamp(.18, .42))
          .toColor();
      // Stronger local opacity must not produce a bright reading surface.
      // Scale channels together so the poster hue survives the luminance cap.
      final peak = math.max(softened.r, math.max(softened.g, softened.b));
      final scale = peak > .47 ? .47 / peak : 1.0;
      return softened.withValues(
        alpha: 1,
        red: softened.r * scale,
        green: softened.g * scale,
        blue: softened.b * scale,
      );
    }).toList();
    final next = supplied == null || supplied.isEmpty
        ? _neutral
        : List<Color>.generate(3, (index) => supplied[index % supplied.length]);
    if (listEquals(next, _target)) return;
    _from = colors;
    _target = next;
    _paletteBlend = animate ? 0 : 1;
    if (!animate) colors = next;
    notifyListeners();
  }

  void advance(double seconds) {
    if (seconds <= 0) return;
    phase = (phase + seconds / _cycleSeconds) % 1;
    if (_paletteBlend < 1) {
      _paletteBlend = (_paletteBlend + seconds / .6).clamp(0.0, 1.0);
      final blend = Curves.easeInOut.transform(_paletteBlend);
      colors = List<Color>.generate(
        3,
        (index) => Color.lerp(_from[index], _target[index], blend)!,
      );
    }
    notifyListeners();
  }
}

class _AtmospherePainter extends CustomPainter {
  _AtmospherePainter(this.frame) : super(repaint: frame);
  final _AtmosphereFrame frame;
  static const _stops = [0.0, .20, .64, 1.0];
  static const _centerX = [.15, .79, .48];
  static const _centerY = [.32, .76, .50];
  static const _radius = [.92, .78, 1.08];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    final angle = frame.phase * math.pi * 2;
    // Long reviews must not move every color center below the visible screen.
    // Three broad, asymmetric fields stay near the poster's reading surface;
    // their outer tails dissolve into the caller's neutral charcoal below.
    final fieldHeight = math.min(size.height, size.width * .85);
    final baseRadius = size.width * .43;
    final paint = Paint();
    for (var index = 0; index < 3; index++) {
      final turn = angle + index * math.pi * 2 / 3;
      final center = Offset(
        size.width * (_centerX[index] + .25 * math.sin(turn)),
        fieldHeight * (_centerY[index] + .24 * math.cos(turn + .45)),
      );
      final radius = baseRadius * (_radius[index] + .10 * math.sin(turn + 1.1));
      final color = frame.colors[index];
      final strength = .29 + .025 * math.sin(turn - .7);
      paint.shader = ui.Gradient.radial(center, radius, [
        color.withValues(alpha: strength),
        color.withValues(alpha: strength * .72),
        color.withValues(alpha: strength * .20),
        color.withValues(alpha: 0),
      ], _stops);
      canvas.drawRect(bounds, paint);
    }
  }

  @override
  bool shouldRepaint(_AtmospherePainter oldDelegate) =>
      oldDelegate.frame != frame;
}
