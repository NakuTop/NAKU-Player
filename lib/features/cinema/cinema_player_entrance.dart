import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Observed playback milestones, never a byte or time based percentage.
enum CinemaPlayerLoadStage { connecting, opening, waitingForFrame }

/// The playback gate supplies readiness; this surface never starts a request or
/// substitutes a fixed timer for it. The media subtree remains mounted through
/// every phase, including darkness, cancellation and a replacement generation.
class CinemaPlayerEntrance extends StatefulWidget {
  const CinemaPlayerEntrance({
    super.key,
    required this.generation,
    required this.ready,
    this.hasError = false,
    this.enabled = true,
    this.animateOnEntry = true,
    this.reduceMotion = false,
    this.loadStage = CinemaPlayerLoadStage.connecting,
    this.lampColor = const Color(0xFFFFF2DE),
    this.lampReady = true,
    this.onReveal,
    this.onCancel,
    required this.child,
  });

  final int generation;
  final bool ready, hasError, enabled, reduceMotion;

  /// False keeps an already-visible surface idle until [closeForExit] is
  /// requested, without ever running the entry lamp or its sound callback.
  final bool animateOnEntry;
  final CinemaPlayerLoadStage loadStage;
  final Color lampColor;
  final bool lampReady;
  final VoidCallback? onReveal, onCancel;
  final Widget child;

  @override
  State<CinemaPlayerEntrance> createState() => CinemaPlayerEntranceState();
}

enum _EntrancePhase {
  closing,
  waiting,
  lighting,
  complete,
  cancelled,
  exiting,
  exited,
}

class CinemaPlayerEntranceState extends State<CinemaPlayerEntrance>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _closeDuration = Duration(milliseconds: 500);
  static const _lightDuration = Duration(milliseconds: 1550);
  late final AnimationController _animation, _lampAnimation, _breathing;
  late final Listenable _paintAnimation;
  double _lampTarget = .10, _revealLampExtent = .10, _revealBreath = 1;
  static const _lampSpring = SpringDescription(
    mass: 1,
    stiffness: 324,
    damping: 36,
  );
  _EntrancePhase _phase = _EntrancePhase.complete;
  bool _initialized = false;
  bool _foreground = true, _environmentAllowsMotion = true;
  int _frameCount = 0;
  bool _revealed = false, _cancelNotified = false;
  bool _disposed = false;
  Completer<void>? _exitCompleter;

  /// Internal source retries continue the same entrance until media is visible.
  bool get hasRevealedPlayback =>
      widget.enabled &&
      (_phase == _EntrancePhase.complete ||
          (_phase == _EntrancePhase.cancelled && widget.ready));

  @visibleForTesting
  String get debugPhase => _phase.name;
  @visibleForTesting
  bool get debugIsAnimating =>
      _animation.isAnimating ||
      _lampAnimation.isAnimating ||
      _breathing.isAnimating;
  @visibleForTesting
  int get debugGeneration => widget.generation;
  @visibleForTesting
  int get debugFrameCount => _frameCount;
  @visibleForTesting
  double get debugProgress => _animation.value;
  @visibleForTesting
  CinemaPlayerLoadStage get debugLoadStage => widget.loadStage;
  @visibleForTesting
  double get debugLampExtent => _waitingInDark
      ? _lampAnimation.value
      : _phase == _EntrancePhase.lighting
      ? _lightingExtent(_revealLampExtent, _animation.value)
      : 0;
  @visibleForTesting
  double get debugLampVelocity => _lampAnimation.velocity;
  @visibleForTesting
  double get debugLampTarget => _lampTarget;
  @visibleForTesting
  bool get debugIsBreathing => _breathing.isAnimating;
  @visibleForTesting
  double get debugBreathBrightness => _breathing.isAnimating ? _breathScale : 1;
  double get _breathScale => _breathBrightness(_breathing.value);

  void _syncBreathing() {
    final needed =
        _allowed &&
        widget.lampReady &&
        _waitingInDark &&
        _phase == _EntrancePhase.waiting;
    if (needed && !_breathing.isAnimating) {
      _breathing.repeat();
    } else if (!needed) {
      _breathing.stop();
    }
  }

  bool get _waitingInDark =>
      widget.animateOnEntry &&
      widget.enabled &&
      !widget.hasError &&
      !widget.ready &&
      _exitCompleter == null &&
      (_phase == _EntrancePhase.waiting || _phase == _EntrancePhase.cancelled);

  bool get _allowed =>
      !_disposed &&
      widget.enabled &&
      !widget.hasError &&
      !widget.reduceMotion &&
      _foreground &&
      _environmentAllowsMotion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = !_isBackground(lifecycle);
    _animation = AnimationController(vsync: this, duration: _closeDuration)
      ..addStatusListener(_statusChanged)
      ..addListener(_countFrame);
    _lampAnimation = AnimationController(vsync: this)..addListener(_countFrame);
    _breathing = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..addListener(_countFrame);
    _paintAnimation = Listenable.merge([
      _animation,
      _lampAnimation,
      _breathing,
    ]);
  }

  void _countFrame() => _frameCount++;

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _environmentAllowsMotion =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    if (!_initialized) {
      _initialized = true;
      _startGeneration();
    } else if (!_allowed) {
      _cancel();
    }
  }

  @override
  void didUpdateWidget(CinemaPlayerEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_exitCompleter != null) {
      if (!_allowed) _finishExit();
      return;
    }
    if (oldWidget.generation != widget.generation ||
        oldWidget.animateOnEntry != widget.animateOnEntry) {
      _startGeneration();
      return;
    }
    if (oldWidget.loadStage != widget.loadStage) _retargetLamp();
    if (!_allowed) {
      _cancel();
    } else if (_phase == _EntrancePhase.waiting && widget.ready) {
      _light();
    } else if (_phase == _EntrancePhase.lighting && !widget.ready) {
      _notifyCancel();
      _animation.stop();
      _lampAnimation.value = _lampTarget;
      setState(() => _phase = _EntrancePhase.waiting);
    }
    _syncBreathing();
  }

  void _retargetLamp() {
    if (!widget.animateOnEntry) return;
    // Milestones constrain the destination, never an elapsed-time estimate.
    // Preserve the current position and velocity when a newer observation
    // arrives mid-curve. A critically damped filament cannot bounce or retreat.
    final target = math.max(_lampTarget, _lampExtent(widget.loadStage));
    if (target == _lampTarget) return;
    _lampTarget = target;
    if (!_allowed || _phase == _EntrancePhase.cancelled) {
      _lampAnimation.value = target;
      return;
    }
    if (_phase != _EntrancePhase.closing && _phase != _EntrancePhase.waiting) {
      return;
    }
    final start = _lampAnimation.value;
    final velocity = _lampAnimation.velocity.clamp(0.0, 18 * (target - start));
    _lampAnimation.animateWith(
      SpringSimulation(
        _lampSpring,
        start,
        target,
        velocity,
        snapToEnd: true,
        tolerance: const Tolerance(distance: .0004, velocity: .01),
      ),
    );
  }

  void _startGeneration() {
    if (_exitCompleter != null) return;
    _notifyCancel();
    _revealed = false;
    _cancelNotified = false;
    _animation.stop();
    _lampAnimation.stop();
    _breathing.stop();
    _breathing.value = 0;
    _revealBreath = 1;
    _lampTarget = widget.animateOnEntry ? _lampExtent(widget.loadStage) : 0;
    _lampAnimation.value = _lampTarget;
    _revealLampExtent = _lampTarget;
    _animation.value = 0;
    _phase = !widget.animateOnEntry
        ? _EntrancePhase.complete
        : _allowed
        ? _EntrancePhase.closing
        : _EntrancePhase.cancelled;
    if (widget.animateOnEntry && _allowed) {
      _animation.duration = _closeDuration;
      _animation.forward();
    }
    setState(() {});
  }

  void _statusChanged(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_phase == _EntrancePhase.exiting) {
      _finishExit();
      return;
    }
    if (_phase == _EntrancePhase.closing) {
      if (widget.ready && _allowed) {
        _light();
      } else {
        setState(() => _phase = _EntrancePhase.waiting);
        _syncBreathing();
      }
    } else if (_phase == _EntrancePhase.lighting) {
      setState(() => _phase = _EntrancePhase.complete);
    }
  }

  void _light() {
    if (_exitCompleter != null ||
        !widget.animateOnEntry ||
        !_allowed ||
        !widget.ready) {
      return;
    }
    _animation.stop();
    // Continue from the lamp that was actually painted. A fast first frame
    // must not jump the lamp to the final waiting milestone before it reveals.
    _revealLampExtent = _lampAnimation.value;
    _revealBreath = _breathing.isAnimating ? _breathScale : 1;
    _breathing.stop();
    _lampAnimation.stop();
    setState(() => _phase = _EntrancePhase.lighting);
    _animation.duration = _lightDuration;
    _animation.forward(from: 0);
    if (!_revealed) {
      _revealed = true;
      widget.onReveal?.call();
    }
  }

  void _notifyCancel() {
    if (_cancelNotified ||
        (!_revealed &&
            ![
              _EntrancePhase.closing,
              _EntrancePhase.waiting,
              _EntrancePhase.lighting,
            ].contains(_phase))) {
      return;
    }
    _cancelNotified = true;
    widget.onCancel?.call();
  }

  void _cancel() {
    _notifyCancel();
    if (_exitCompleter != null) {
      _finishExit();
      return;
    }
    _animation.stop();
    _lampAnimation.stop();
    _breathing.stop();
    final phase = widget.animateOnEntry
        ? _EntrancePhase.cancelled
        : _EntrancePhase.complete;
    if (_phase != phase) {
      setState(() => _phase = phase);
    }
  }

  /// Closes the visible media once, without starting the lamp or sound hook.
  /// The caller owns pause/history/navigation. Darkness remains until it pops
  /// this route, and a late source generation cannot start another entrance.
  Future<void> closeForExit({bool animate = true}) {
    final existing = _exitCompleter;
    if (existing != null) return existing.future;
    final completion = _exitCompleter = Completer<void>();
    final canAnimate =
        animate && _allowed && widget.ready && _phase != _EntrancePhase.waiting;
    _notifyCancel();
    _animation.stop();
    _lampAnimation.stop();
    _breathing.stop();
    if (canAnimate) {
      setState(() => _phase = _EntrancePhase.exiting);
      _animation.duration = _closeDuration;
      _animation.forward(from: 0);
    } else {
      _finishExit();
    }
    return completion.future;
  }

  void _finishExit({bool rebuild = true}) {
    final completion = _exitCompleter;
    if (completion == null) return;
    _animation.stop();
    _lampAnimation.stop();
    _breathing.stop();
    final changed = _phase != _EntrancePhase.exited;
    _phase = _EntrancePhase.exited;
    if (rebuild && !_disposed && mounted && changed) setState(() {});
    if (!completion.isCompleted) completion.complete();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = !_isBackground(state);
    if (!_foreground) _cancel();
    // Returning to the foreground must not replay a late reveal. Only a new
    // media generation is allowed to start another entrance.
  }

  @override
  void dispose() {
    _notifyCancel();
    _disposed = true;
    _finishExit(rebuild: false);
    WidgetsBinding.instance.removeObserver(this);
    _animation
      ..removeStatusListener(_statusChanged)
      ..removeListener(_countFrame)
      ..dispose();
    _lampAnimation
      ..removeListener(_countFrame)
      ..dispose();
    _breathing
      ..removeListener(_countFrame)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final contracting =
        _phase == _EntrancePhase.closing || _phase == _EntrancePhase.exiting;
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        AnimatedBuilder(
          // Filament interpolation and illumination only repaint the overlay;
          // their frames leave the media's layout and controls untouched.
          animation: contracting
              ? _animation
              : const AlwaysStoppedAnimation<double>(1),
          child: widget.child,
          builder: (context, child) {
            final progress = _animation.value;
            var x = 1.0, y = 1.0;
            if (contracting) {
              y = math.max(
                .001,
                math.pow(1 - _smooth(0, .66, progress), 2.2).toDouble(),
              );
              x = math.max(.001, 1 - _smooth(.48, .96, progress));
              if (progress > .94) y *= 1 - _smooth(.94, 1, progress);
            }
            return Transform(
              key: const ValueKey('cinema-player-entrance-content'),
              alignment: Alignment.center,
              transformHitTests: false,
              transform: Matrix4.diagonal3Values(x, y, 1),
              child: child,
            );
          },
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                key: ValueKey('cinema-player-entrance-${_phase.name}'),
                painter: _EntrancePainter(
                  _phase,
                  lampColor: widget.lampColor,
                  transition: _animation,
                  filament: _lampAnimation,
                  breathing: _breathing,
                  breathe: _breathing.isAnimating,
                  revealBreath: _revealBreath,
                  repaint: _paintAnimation,
                  revealLampExtent: _revealLampExtent,
                  waitingInDark: _waitingInDark,
                  showLoadLamp: _foreground && widget.lampReady,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

double _smooth(double start, double end, double value) {
  final t = ((value - start) / (end - start)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

class _EntrancePainter extends CustomPainter {
  _EntrancePainter(
    this.phase, {
    required this.lampColor,
    required this.transition,
    required this.filament,
    required this.breathing,
    required this.breathe,
    required this.revealBreath,
    required Listenable repaint,
    required this.revealLampExtent,
    required this.waitingInDark,
    required this.showLoadLamp,
  }) : super(repaint: repaint);
  final _EntrancePhase phase;
  final Color lampColor;
  final Animation<double> transition, filament, breathing;
  final bool breathe;
  final double revealLampExtent, revealBreath;
  final bool waitingInDark, showLoadLamp;
  double get progress => transition.value;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    switch (phase) {
      case _EntrancePhase.closing:
      case _EntrancePhase.exiting:
        _close(canvas, size);
      case _EntrancePhase.waiting:
        canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
        if (showLoadLamp) _waitingLamp(canvas, size);
      case _EntrancePhase.exited:
        canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      case _EntrancePhase.lighting:
        _light(canvas, size);
      case _EntrancePhase.complete:
        break;
      case _EntrancePhase.cancelled:
        // Reduced motion skips decoration, not the real first-frame gate.
        // Keep an unready media child and its controls behind the black field.
        if (waitingInDark) {
          canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
          if (showLoadLamp) _waitingLamp(canvas, size);
        }
        break;
    }
  }

  void _close(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final pulse = _smooth(.30, .57, progress) * (1 - _smooth(.82, 1, progress));
    if (pulse <= 0) return;
    final contraction = 1 - _smooth(.55, .98, progress);
    final lineRadius = math.min(size.width * .24, 180.0) * contraction;
    final line = Paint()
      ..color = const Color(0xFFD3F8FF).withValues(alpha: pulse * .65)
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 1.4);
    canvas.drawLine(
      center - Offset(lineRadius, 0),
      center + Offset(lineRadius, .35),
      line,
    );
    const angles = [.04, .71, 1.84, 2.72, 3.51, 4.43, 5.58];
    const lengths = [1.0, .46, .78, .37, .64, .31, .52];
    final radius = 30 * (1 - _smooth(.60, .98, progress));
    for (var index = 0; index < angles.length; index++) {
      final direction = Offset(
        math.cos(angles[index]),
        math.sin(angles[index]),
      );
      final endpoint = center + direction * (radius * lengths[index]);
      canvas.drawLine(
        center,
        endpoint,
        Paint()
          ..color = const Color(0xFFEAFBFF).withValues(alpha: pulse * .72)
          ..strokeWidth = index.isEven ? .8 : .5
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawCircle(
      center,
      3.8 * pulse,
      Paint()
        ..color = const Color(0xFFE6FAFF).withValues(alpha: pulse * .72)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
    );
  }

  void _ellipse(
    Canvas canvas,
    Offset center,
    double xRadius,
    double yRadius,
    Paint paint,
  ) {
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(xRadius, yRadius);
    canvas.drawCircle(Offset.zero, 1, paint);
    canvas.restore();
  }

  void _light(Canvas canvas, Size size) {
    // One continuous energy curve drives the filament, its nearby spill and
    // the ambient exposure. Separate timed ignition/cone/curtain segments made
    // this feel like three animations even after the first frame was ready.
    final energy = _smooth(0, 1, progress);
    final globalRelease = energy * energy;
    final illumination = 1 - math.pow(1 - energy, 1.7).toDouble();
    final bounds = Offset.zero & size;
    final origin = Offset(size.width * .5, size.height * .065);
    final fieldCenter = Offset(origin.dx, origin.dy + size.height * .055);
    // The field occupies the same physical footprint throughout the reveal.
    // Brightness grows inside its elliptical falloff; no horizontal curtain
    // sweeps down the screen, and the bottom receives less direct light.
    // Paint the elliptical exposure directly. The former full-window
    // saveLayer + dstOut pass allocated an offscreen surface every frame.
    final shade = 1 - globalRelease;
    final fieldTransform = Matrix4.diagonal3Values(
      size.width * .76,
      size.height * 1.22,
      1,
    )..setTranslationRaw(fieldCenter.dx, fieldCenter.dy, 0);
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            Colors.black.withValues(alpha: shade * (1 - illumination)),
            Colors.black.withValues(alpha: shade * (1 - illumination * .91)),
            Colors.black.withValues(alpha: shade * (1 - illumination * .40)),
            Colors.black.withValues(alpha: shade),
          ],
          const [0, .19, .76, 1],
          TileMode.clamp,
          fieldTransform.storage,
        ),
    );
    if (!showLoadLamp) return;
    final baseGlow = _lampGlow(revealLampExtent) * revealBreath;
    final lamp =
        (baseGlow + (1 - baseGlow) * energy) * (1 - energy * energy * energy);
    if (lamp <= 0) return;
    final tubeHalfWidth =
        size.width * .34 * _lightingExtent(revealLampExtent, progress);
    _waitingSpill(
      canvas,
      size,
      revealBreath,
      opacity: (1 - energy) * (1 - energy),
    );
    _tube(
      canvas,
      origin,
      tubeHalfWidth,
      lamp,
      haloScale: ui.lerpDouble(.55 + 1.45 * revealBreath, 1, energy)!,
    );
    _ellipse(
      canvas,
      fieldCenter,
      size.width * .72,
      size.height * 1.16,
      Paint()
        ..blendMode = BlendMode.screen
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            lampColor.withValues(alpha: .07 * lamp * energy),
            lampColor.withValues(alpha: .025 * lamp * energy),
            Colors.transparent,
          ],
          const [0, .42, 1],
        ),
    );
  }

  void _waitingLamp(Canvas canvas, Size size) {
    // A 40%-100% breath expands the poster-colored spill over opaque black.
    // Only observed milestones own length; the unready media stays covered.
    final brightness = breathe ? _breathBrightness(breathing.value) : 1.0;
    _waitingSpill(canvas, size, brightness);
    _tube(
      canvas,
      Offset(size.width * .5, size.height * .065),
      size.width * .34 * filament.value,
      _lampGlow(filament.value) * brightness,
      haloScale: .55 + 1.45 * brightness,
    );
  }

  void _waitingSpill(
    Canvas canvas,
    Size size,
    double brightness, {
    double opacity = 1,
  }) {
    if (brightness <= 0 || opacity <= 0) return;
    final spread = math.pow(brightness, .7).toDouble();
    _ellipse(
      canvas,
      Offset(size.width * .5, size.height * .11),
      size.width * (.12 + .68 * spread),
      size.height * (.10 + .98 * spread),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            lampColor.withValues(alpha: .16 * brightness * opacity),
            lampColor.withValues(alpha: .065 * brightness * opacity),
            Colors.transparent,
          ],
          const [0, .38, 1],
        ),
    );
  }

  void _tube(
    Canvas canvas,
    Offset origin,
    double tubeHalfWidth,
    double lamp, {
    double haloScale = 1,
  }) {
    if (lamp <= 0) return;
    for (final (blur, alpha, width) in const [
      (24.0, .32, 14.0),
      (9.0, .52, 8.0),
      (2.0, .85, 4.6),
      (0.0, 1.0, 2.8),
    ]) {
      final paint = Paint()
        ..color = lampColor.withValues(alpha: alpha * lamp)
        ..strokeWidth = blur > 0 ? width * haloScale : width
        ..strokeCap = StrokeCap.round;
      if (blur > 0) {
        paint.maskFilter = ui.MaskFilter.blur(
          ui.BlurStyle.normal,
          blur * haloScale,
        );
      }
      canvas.drawLine(
        origin - Offset(tubeHalfWidth, 0),
        origin + Offset(tubeHalfWidth, 0),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_EntrancePainter oldDelegate) =>
      oldDelegate.lampColor != lampColor ||
      oldDelegate.phase != phase ||
      oldDelegate.transition != transition ||
      oldDelegate.filament != filament ||
      oldDelegate.breathing != breathing ||
      oldDelegate.breathe != breathe ||
      oldDelegate.revealBreath != revealBreath ||
      oldDelegate.revealLampExtent != revealLampExtent ||
      oldDelegate.waitingInDark != waitingInDark ||
      oldDelegate.showLoadLamp != showLoadLamp;
}

double _lampExtent(CinemaPlayerLoadStage stage) => switch (stage) {
  CinemaPlayerLoadStage.connecting => .10,
  CinemaPlayerLoadStage.opening => .34,
  CinemaPlayerLoadStage.waitingForFrame => .64,
};

double _lampGlow(double extent) => .44 + .46 * extent;

// Keep the filament visible through a 40%-100% breath. This decorative light
// never advances the load milestone or first frame.
double _breathBrightness(double phase) =>
    .4 + .6 * _smooth(.04, .96, .5 + .5 * math.cos(2 * math.pi * phase));

double _lightingExtent(double initial, double progress) =>
    initial + (1 - initial) * _smooth(0, 1, progress);
