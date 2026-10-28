import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:kazumi/services/platform/naku_device.dart';

/// A local native glass surface. Light moves across the material underneath its
/// contents; text, hit targets and the surrounding layout never bend or move.
///
/// Disable [blur] for repeated items such as a poster wall. Accessibility values
/// can be supplied by the appearance model; MediaQuery is also respected here.
class CinemaOpticalGlass extends StatefulWidget {
  const CinemaOpticalGlass({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding = EdgeInsets.zero,
    this.blur = true,
    this.fluted = false,
    this.interactive = true,
    this.opacity = .47,
    this.reduceTransparency = false,
    this.reduceMotion = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool blur, interactive, reduceTransparency, reduceMotion;

  /// Retained for source compatibility. All surfaces now use unpatterned frost.
  final bool fluted;
  final double opacity;

  @override
  State<CinemaOpticalGlass> createState() => CinemaOpticalGlassState();
}

class CinemaOpticalGlassState extends State<CinemaOpticalGlass>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final _field = _OpticalField();
  late final Ticker _ticker;
  Duration? _lastFrame;
  bool _foreground = true, _tickerEnabled = true, _reduced = false;
  bool _hovered = false, _focused = false;

  @visibleForTesting
  bool get debugIsAnimating => _ticker.isActive;
  @visibleForTesting
  Offset get debugLightPosition => _field.position;
  @visibleForTesting
  double get debugLightIntensity => _field.intensity;
  @visibleForTesting
  double get debugRippleAge => _field.rippleAge;

  bool get _canAnimate =>
      !NakuDevice.isTV &&
      widget.interactive &&
      _foreground &&
      _tickerEnabled &&
      !_reduced;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _reduced =
        widget.reduceMotion ||
        widget.reduceTransparency ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    _syncActivity();
  }

  @override
  void didUpdateWidget(CinemaOpticalGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _reduced =
        widget.reduceMotion ||
        widget.reduceTransparency ||
        MediaQuery.maybeOf(context)?.disableAnimations == true;
    _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncActivity();
  }

  void _syncActivity() {
    if (!_canAnimate) {
      _ticker.stop();
      _lastFrame = null;
      _field.settle(clear: !_foreground || !widget.interactive);
    } else if (_field.isMoving) {
      _start();
    }
  }

  void _start() {
    if (!_canAnimate || _ticker.isActive) return;
    _lastFrame = null;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    if (!_canAnimate) {
      _syncActivity();
      return;
    }
    final previous = _lastFrame;
    _lastFrame = elapsed;
    final dt = previous == null
        ? 1 / 60
        : ((elapsed - previous).inMicroseconds / 1000000).clamp(.001, .05);
    _field.step(dt);
    if (!_field.isMoving) {
      _ticker.stop();
      _lastFrame = null;
    }
  }

  Offset _normalized(Offset localPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.isEmpty) {
      return const Offset(.5, .5);
    }
    return Offset(
      (localPosition.dx / box.size.width).clamp(0.0, 1.0),
      (localPosition.dy / box.size.height).clamp(0.0, 1.0),
    );
  }

  void _aim(Offset position) {
    if (!widget.interactive || !_foreground || !_tickerEnabled) return;
    _field.target = _normalized(position);
    _field.targetIntensity = _hovered || _focused ? 1 : 0;
    if (_reduced) {
      _field.settle();
    } else {
      _start();
    }
  }

  void _focus(bool value) {
    _focused = value;
    if (!widget.interactive) return;
    _field.targetIntensity = _hovered || _focused ? 1 : 0;
    if (value && !_hovered) _field.target = const Offset(.5, .25);
    if (_reduced) {
      _field.settle();
    } else {
      _start();
    }
  }

  void _press(PointerDownEvent event) {
    if (!widget.interactive || !_foreground || !_tickerEnabled) return;
    _field.target = _normalized(event.localPosition);
    if (_reduced) {
      _field.settle();
      return;
    }
    _field.ripplePosition = _field.target;
    _field.rippleAge = 0;
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (NakuDevice.isTV) {
      return Container(
        padding: widget.padding,
        decoration: BoxDecoration(
          color: const Color(0xFF19191D),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
        child: widget.child,
      );
    }
    final opaque = widget.reduceTransparency || widget.opacity >= .999;
    final radius = BorderRadius.circular(widget.radius);
    final content = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GlassBasePainter(
                  opacity: widget.opacity,
                  opaque: opaque,
                ),
              ),
            ),
          ),
        ),
        if (widget.interactive && !opaque)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(painter: _GlassLightPainter(_field)),
              ),
            ),
          ),
        Material(
          type: MaterialType.transparency,
          child: Padding(padding: widget.padding, child: widget.child),
        ),
      ],
    );
    final panel = ClipRRect(
      borderRadius: radius,
      child:
          widget.blur &&
              !opaque &&
              Theme.of(context).platform != TargetPlatform.windows
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: content,
            )
          : content,
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: _focus,
      child: MouseRegion(
        opaque: false,
        onEnter: (event) {
          _hovered = true;
          _aim(event.localPosition);
        },
        onHover: (event) => _aim(event.localPosition),
        onExit: (event) {
          _hovered = false;
          _aim(event.localPosition);
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _press,
          child: panel,
        ),
      ),
    );
  }
}

class _OpticalField extends ChangeNotifier {
  Offset position = const Offset(.5, .35), target = const Offset(.5, .35);
  Offset velocity = Offset.zero, ripplePosition = const Offset(.5, .5);
  double intensity = 0, targetIntensity = 0, intensityVelocity = 0;
  double rippleAge = 1;
  static const rippleDuration = .76;

  bool get isMoving =>
      (position - target).distance > .0004 ||
      velocity.distance > .002 ||
      (intensity - targetIntensity).abs() > .001 ||
      intensityVelocity.abs() > .004 ||
      rippleAge < rippleDuration;

  void settle({bool clear = false}) {
    position = target;
    velocity = Offset.zero;
    intensity = clear ? 0 : targetIntensity;
    if (clear) targetIntensity = 0;
    intensityVelocity = 0;
    rippleAge = 1;
    notifyListeners();
  }

  // Closed-form critically damped response: a large input or slow frame cannot
  // produce the overshoot that makes a glass reflection feel springy/rubbery.
  void step(double dt) {
    const omega = 17.0;
    final decay = math.exp(-omega * dt);
    final displacement = position - target;
    final flow = velocity + displacement * omega;
    position = target + (displacement + flow * dt) * decay;
    velocity = (velocity - flow * (omega * dt)) * decay;
    final delta = intensity - targetIntensity;
    final flowIntensity = intensityVelocity + omega * delta;
    intensity = (targetIntensity + (delta + flowIntensity * dt) * decay).clamp(
      0.0,
      1.0,
    );
    intensityVelocity =
        (intensityVelocity - omega * flowIntensity * dt) * decay;
    rippleAge += dt;
    if (!isMoving) {
      position = target;
      velocity = Offset.zero;
      intensity = targetIntensity;
      intensityVelocity = 0;
    }
    notifyListeners();
  }
}

class _GlassBasePainter extends CustomPainter {
  const _GlassBasePainter({required this.opacity, required this.opaque});
  final double opacity;
  final bool opaque;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final alpha = opacity.clamp(0.0, 1.0);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(
              0xFF202022,
            ).withValues(alpha: opaque ? 1 : .15 + alpha * .49),
            const Color(
              0xFF141416,
            ).withValues(alpha: opaque ? 1 : .13 + alpha * .47),
          ],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassBasePainter oldDelegate) =>
      oldDelegate.opacity != opacity || oldDelegate.opaque != opaque;
}

class _GlassLightPainter extends CustomPainter {
  _GlassLightPainter(this.field) : super(repaint: field);
  final _OpticalField field;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final center = Offset(
      field.position.dx * size.width,
      field.position.dy * size.height,
    );
    final energy = field.intensity;
    if (energy > .001) {
      final distanceToEdge = math.min(
        math.min(field.position.dx, 1 - field.position.dx),
        math.min(field.position.dy, 1 - field.position.dy),
      );
      final grazing = 1 - (distanceToEdge / .36).clamp(0.0, 1.0);
      final reach = math.min(size.longestSide * .65, 360.0).clamp(60.0, 360.0);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            center,
            reach,
            [
              const Color(
                0xFFF5F5F7,
              ).withValues(alpha: energy * (.045 + grazing * .015)),
              Colors.white.withValues(alpha: energy * .018),
              Colors.transparent,
            ],
            [0, .30, 1],
          ),
      );
      // A narrow neutral reflection follows the same flow as the diffuse lobe.
      // Both sit beneath the content and fade without leaving a perimeter line.
      final normal = Offset(
        (field.position.dx - .5) * 12,
        (field.position.dy - .5) * 8,
      );
      canvas.drawCircle(
        center + normal,
        reach * .29,
        Paint()
          ..shader = ui.Gradient.radial(
            center + normal,
            reach * .29,
            [
              Colors.white.withValues(alpha: energy * .035),
              Colors.white.withValues(alpha: energy * .010),
              Colors.transparent,
            ],
            [0, .32, 1],
          ),
      );
    }
    if (field.rippleAge >= _OpticalField.rippleDuration) return;
    final progress = (field.rippleAge / _OpticalField.rippleDuration).clamp(
      0.0,
      1.0,
    );
    final origin = Offset(
      field.ripplePosition.dx * size.width,
      field.ripplePosition.dy * size.height,
    );
    final rippleRadius =
        6 + math.sqrt(progress) * math.min(size.longestSide * .72, 320.0);
    final fade = math.pow(1 - progress, 2).toDouble();
    canvas.drawCircle(
      origin,
      rippleRadius,
      Paint()
        ..shader = ui.Gradient.radial(
          origin,
          rippleRadius,
          [
            Colors.white.withValues(alpha: .055 * fade),
            Colors.white.withValues(alpha: .026 * fade),
            Colors.transparent,
          ],
          [0, .42, 1],
        ),
    );
  }

  @override
  bool shouldRepaint(_GlassLightPainter oldDelegate) =>
      oldDelegate.field != field;
}
