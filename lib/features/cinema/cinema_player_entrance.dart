import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

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
    this.reduceMotion = false,
    this.loadStage = CinemaPlayerLoadStage.connecting,
    this.onReveal,
    this.onCancel,
    required this.child,
  });

  final int generation;
  final bool ready, hasError, enabled, reduceMotion;
  final CinemaPlayerLoadStage loadStage;
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _closeDuration = Duration(milliseconds: 500);
  static const _lightDuration = Duration(milliseconds: 1550);
  late final AnimationController _animation;
  _EntrancePhase _phase = _EntrancePhase.complete;
  bool _initialized = false;
  bool _foreground = true, _environmentAllowsMotion = true;
  int _frameCount = 0;
  bool _revealed = false, _cancelNotified = false;
  bool _disposed = false;
  Completer<void>? _exitCompleter;

  @visibleForTesting
  String get debugPhase => _phase.name;
  @visibleForTesting
  bool get debugIsAnimating => _animation.isAnimating;
  @visibleForTesting
  int get debugGeneration => widget.generation;
  @visibleForTesting
  int get debugFrameCount => _frameCount;
  @visibleForTesting
  double get debugProgress => _animation.value;
  @visibleForTesting
  CinemaPlayerLoadStage get debugLoadStage => widget.loadStage;
  @visibleForTesting
  double get debugLampExtent =>
      _waitingInDark ? _lampExtent(widget.loadStage) : 0;

  bool get _waitingInDark =>
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
    if (oldWidget.generation != widget.generation) {
      _startGeneration();
      return;
    }
    if (!_allowed) {
      _cancel();
    } else if (_phase == _EntrancePhase.waiting && widget.ready) {
      _light();
    } else if (_phase == _EntrancePhase.lighting && !widget.ready) {
      _notifyCancel();
      _animation.stop();
      setState(() => _phase = _EntrancePhase.waiting);
    }
  }

  void _startGeneration() {
    if (_exitCompleter != null) return;
    _notifyCancel();
    _revealed = false;
    _cancelNotified = false;
    _animation.stop();
    _animation.value = 0;
    _phase = _allowed ? _EntrancePhase.closing : _EntrancePhase.cancelled;
    if (_allowed) {
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
      }
    } else if (_phase == _EntrancePhase.lighting) {
      setState(() => _phase = _EntrancePhase.complete);
    }
  }

  void _light() {
    if (_exitCompleter != null || !_allowed || !widget.ready) return;
    _animation.stop();
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
    if (_phase != _EntrancePhase.cancelled) {
      setState(() => _phase = _EntrancePhase.cancelled);
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _animation,
    child: widget.child,
    builder: (context, child) {
      final progress = _animation.value;
      var x = 1.0, y = 1.0;
      if (_phase == _EntrancePhase.closing ||
          _phase == _EntrancePhase.exiting) {
        y = math.max(
          .001,
          math.pow(1 - _smooth(0, .66, progress), 2.2).toDouble(),
        );
        x = math.max(.001, 1 - _smooth(.48, .96, progress));
        if (progress > .94) y *= 1 - _smooth(.94, 1, progress);
      }
      return Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.black),
          Transform(
            key: const ValueKey('cinema-player-entrance-content'),
            alignment: Alignment.center,
            transformHitTests: false,
            transform: Matrix4.diagonal3Values(x, y, 1),
            child: child,
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  key: ValueKey('cinema-player-entrance-${_phase.name}'),
                  painter: _EntrancePainter(
                    _phase,
                    progress,
                    widget.loadStage,
                    waitingInDark: _waitingInDark,
                    showLoadLamp: _foreground,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

double _smooth(double start, double end, double value) {
  final t = ((value - start) / (end - start)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

class _EntrancePainter extends CustomPainter {
  const _EntrancePainter(
    this.phase,
    this.progress,
    this.loadStage, {
    required this.waitingInDark,
    required this.showLoadLamp,
  });
  final _EntrancePhase phase;
  final double progress;
  final CinemaPlayerLoadStage loadStage;
  final bool waitingInDark, showLoadLamp;

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
    final globalRelease = _smooth(.79, 1, progress);
    final illumination = _smooth(.10, .84, progress);
    final bounds = Offset.zero & size;
    final origin = Offset(size.width * .5, size.height * .065);
    final fieldCenter = Offset(origin.dx, origin.dy + size.height * .055);
    // The field occupies the same physical footprint throughout the reveal.
    // Brightness grows inside its elliptical falloff; no horizontal curtain
    // sweeps down the screen, and the bottom receives less direct light.
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(
      bounds,
      Paint()..color = Colors.black.withValues(alpha: 1 - globalRelease),
    );
    _ellipse(
      canvas,
      fieldCenter,
      size.width * .76,
      size.height * 1.22,
      Paint()
        ..blendMode = BlendMode.dstOut
        ..shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [
            Colors.black.withValues(alpha: illumination),
            Colors.black.withValues(alpha: illumination * .91),
            Colors.black.withValues(alpha: illumination * .40),
            Colors.transparent,
          ],
          const [0, .19, .76, 1],
        ),
    );
    canvas.restore();
    final energizing = _smooth(0, .47, progress);
    final baseGlow = _lampGlow(loadStage);
    final lamp =
        (baseGlow + (1 - baseGlow) * energizing) *
        (1 - _smooth(.78, 1, progress));
    if (lamp <= 0) return;
    final baseExtent = _lampExtent(loadStage);
    final tubeHalfWidth =
        size.width * .34 * (baseExtent + (1 - baseExtent) * energizing);
    _tube(canvas, origin, tubeHalfWidth, lamp);
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
            const Color(0xFFFFEDD2).withValues(alpha: .07 * lamp),
            const Color(0xFFFFEDD2).withValues(alpha: .025 * lamp),
            Colors.transparent,
          ],
          const [0, .42, 1],
        ),
    );
  }

  void _waitingLamp(Canvas canvas, Size size) {
    // A static, subdued partial tube reports only the last known milestone.
    // No timed fill, light cone, continuous ticker or sound runs while waiting.
    _tube(
      canvas,
      Offset(size.width * .5, size.height * .065),
      size.width * .34 * _lampExtent(loadStage),
      _lampGlow(loadStage),
    );
  }

  void _tube(Canvas canvas, Offset origin, double tubeHalfWidth, double lamp) {
    for (final (blur, alpha, width) in const [
      (18.0, .19, 7.0),
      (6.0, .32, 3.0),
      (0.0, .94, 1.3),
    ]) {
      final paint = Paint()
        ..color = const Color(0xFFFFF2DE).withValues(alpha: alpha * lamp)
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round;
      if (blur > 0) {
        paint.maskFilter = ui.MaskFilter.blur(ui.BlurStyle.normal, blur);
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
      oldDelegate.phase != phase ||
      oldDelegate.progress != progress ||
      oldDelegate.loadStage != loadStage ||
      oldDelegate.waitingInDark != waitingInDark ||
      oldDelegate.showLoadLamp != showLoadLamp;
}

double _lampExtent(CinemaPlayerLoadStage stage) => switch (stage) {
  CinemaPlayerLoadStage.connecting => .10,
  CinemaPlayerLoadStage.opening => .34,
  CinemaPlayerLoadStage.waitingForFrame => .64,
};

double _lampGlow(CinemaPlayerLoadStage stage) => switch (stage) {
  CinemaPlayerLoadStage.connecting => .12,
  CinemaPlayerLoadStage.opening => .22,
  CinemaPlayerLoadStage.waitingForFrame => .34,
};
