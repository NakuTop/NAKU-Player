import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Native coarse-to-fine rendering driven by real detail resource readiness.
///
/// The child remains visible, accessible and interactive. The field has no
/// forced loading duration. The real child is sampled at a gradually higher
/// resolution during the wait. Readiness permits one soft assembly and glow;
/// all filters and animation then stop. No captured screenshot is retained.
class CinemaNeonDecode extends StatefulWidget {
  const CinemaNeonDecode({
    super.key,
    required this.loading,
    required this.child,
    this.progress,
    this.regional = false,
  });

  final bool loading;
  final Widget child;

  /// When true, only descendant [CinemaNeonRegion] widgets still awaiting their
  /// own resource are filtered. Already available controls stay sharp.
  final bool regional;

  /// Real source-search progress, when available. The decorative reveal also
  /// unfolds slowly when no determinate progress is available; it is never
  /// presented as a percentage or a claim that the request is complete.
  final double? progress;

  @override
  CinemaNeonDecodeState createState() => CinemaNeonDecodeState();
}

class CinemaNeonDecodeState extends State<CinemaNeonDecode>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _revealSeconds = 8.0;
  final _signal = _DecodeFrame();
  late final Ticker _ticker;
  Duration _lastFrame = Duration.zero;
  Timer? _settleTimer;
  bool _visible = false;
  bool _motionAllowed = true;
  bool _foreground = true;
  bool _hasRevealSession = false;
  static const _settleDuration = Duration(milliseconds: 520);
  double _settleElapsed = 0;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    WidgetsBinding.instance.addObserver(this);
    _signal.requestFrames = _ensureFrames;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionAllowed =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncEnvironment();
  }

  @override
  void didUpdateWidget(CinemaNeonDecode oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading != oldWidget.loading) {
      if (widget.loading) {
        _hasRevealSession = false;
        if (_motionAllowed && _foreground) _begin();
      } else if (_visible) {
        _finish();
      } else {
        _hasRevealSession = false;
      }
    } else if (widget.loading) {
      _updateProgress();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncEnvironment();
  }

  void _syncEnvironment() {
    if (!_motionAllowed || !_foreground) {
      _stop();
    } else if (widget.loading && !_visible) {
      _begin();
    }
  }

  void _updateProgress() {
    final previousReveal = _signal.reveal;
    final value = widget.progress;
    if (value != null && value.isFinite) {
      _signal.progress = math.max(_signal.progress, value.clamp(0.0, 1.0));
    }
    _advanceReveal();
    if (_signal.enabled && previousReveal != _signal.reveal) _signal.redraw();
    _ensureFrames();
  }

  void _advanceReveal() {
    // This decorative phase is separate from source progress. Once sampling
    // reaches its pending limit, the material remains visible without a ticker.
    // Only a real regional-ready event or final assembly needs to wake it.
    final t = (_signal.elapsed / _revealSeconds).clamp(0.0, 1.0);
    final ambient = .90 * (1 - math.pow(1 - t, 1.7));
    _signal.reveal = math.max(
      _signal.reveal,
      math.max(ambient, _signal.progress),
    );
  }

  @visibleForTesting
  ({
    bool visible,
    bool running,
    bool settling,
    double sourceProgress,
    double visualReveal,
    double opacity,
    double pixelSize,
    double blurSigma,
    double assembly,
    bool filtersEnabled,
    double elapsed,
    int generation,
  })
  get debugSnapshot => (
    visible: _visible,
    running: _ticker.isActive,
    settling: _signal.settling,
    sourceProgress: _signal.progress,
    visualReveal: _signal.reveal,
    opacity: _signal.opacity,
    pixelSize: _visible ? _signal.pixelSize : 1,
    blurSigma: _visible ? _signal.blurSigma : 0,
    assembly: _signal.assembly,
    filtersEnabled: _visible,
    elapsed: _signal.elapsed,
    generation: _generation,
  );

  void _begin() {
    _pauseFrames();
    _settleTimer?.cancel();
    _settleTimer = null;
    _settleElapsed = 0;
    if (!_hasRevealSession) {
      _generation++;
      _signal
        ..elapsed = 0
        ..animateUntil = _signal.clock
        ..progress = 0
        ..reveal = 0
        ..seed = (_generation * 2654435761) & 0x7fffffff;
      _hasRevealSession = true;
    }
    _signal
      ..opacity = 1
      ..assembly = 0
      ..settling = false;
    _updateProgress();
    _signal.enabled = true;
    if (!_visible) setState(() => _visible = true);
    _signal.redraw();
    _ensureFrames();
  }

  bool get _needsFrames =>
      _signal.settling ||
      (widget.loading && _signal.reveal < .9) ||
      _signal.clock + .000001 < _signal.animateUntil;

  void _pauseFrames() {
    _ticker.stop();
    _lastFrame = Duration.zero;
  }

  void _ensureFrames() {
    if (!mounted ||
        !_foreground ||
        !_motionAllowed ||
        !_signal.enabled ||
        !_needsFrames) {
      _pauseFrames();
      return;
    }
    if (_ticker.isActive) return;
    _lastFrame = Duration.zero;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    if (!mounted || !_foreground || !_motionAllowed || !_signal.enabled) {
      _pauseFrames();
      return;
    }
    // Follow actual display frames, including 120 Hz panels. A delayed frame
    // advances once by its elapsed time instead of queueing 42 ms timer work.
    // Each resumed ticker starts a fresh time base, excluding hidden time.
    final dt = (elapsed - _lastFrame).inMicroseconds / 1000000;
    _lastFrame = elapsed;
    _signal.clock += dt;
    if (_signal.settling) {
      _settleElapsed += dt;
      final t = (_settleElapsed / (_settleDuration.inMicroseconds / 1000000))
          .clamp(0.0, 1.0);
      _signal.assembly = t;
      _signal.opacity = 1 - t * t * (3 - 2 * t);
    } else {
      _signal.elapsed = math.min(_revealSeconds, _signal.elapsed + dt);
      _advanceReveal();
    }
    _signal.redraw();
    if (!_needsFrames) _pauseFrames();
  }

  void _finish() {
    // Only the parent's real resource gate permits the last pixels to assemble.
    // The data is already usable: this non-blocking 520 ms material finish never
    // extends the underlying request, disables controls, or replays the wait.
    _settleElapsed = 0;
    _signal
      ..assemblyFromPixelSize = _signal.pixelSize
      ..assemblyFromBlurSigma = _signal.blurSigma
      ..assembly = 0
      ..settling = true;
    _ensureFrames();
    final generation = _generation;
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDuration, () {
      if (mounted && generation == _generation && !widget.loading) {
        _hasRevealSession = false;
        _stop();
      }
    });
  }

  void _stop() {
    _pauseFrames();
    _settleTimer?.cancel();
    _settleTimer = null;
    _signal.enabled = false;
    _signal.redraw();
    if (_visible && mounted) setState(() => _visible = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _settleTimer?.cancel();
    _signal.requestFrames = null;
    _signal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _CinemaDecodeScope(
    frame: _signal,
    child: AnimatedBuilder(
      animation: _signal,
      child: widget.regional
          ? widget.child
          : CinemaNeonRegion(ready: !widget.loading, child: widget.child),
      builder: (context, child) => _ContentAssemblyGlow(
        gain: _visible && _signal.settling
            ? 1 + .045 * math.sin(_signal.assembly * math.pi)
            : 1,
        child: child!,
      ),
    ),
  );
}

class _CinemaDecodeScope extends InheritedWidget {
  const _CinemaDecodeScope({required this.frame, required super.child});
  final _DecodeFrame frame;

  @override
  bool updateShouldNotify(_CinemaDecodeScope oldWidget) =>
      oldWidget.frame != frame;
}

/// A single live subtree whose own resource controls when it becomes clear.
///
/// Rounded cells come from the subtree's original sampled colors. No screenshot,
/// duplicated child, painted tile colors, lines, or decorative overlay is used.
class CinemaNeonRegion extends StatefulWidget {
  const CinemaNeonRegion({super.key, required this.ready, required this.child});
  final bool ready;
  final Widget child;

  @override
  CinemaNeonRegionState createState() => CinemaNeonRegionState();
}

class CinemaNeonRegionState extends State<CinemaNeonRegion> {
  _DecodeFrame? _frame;
  double? _readyAt;
  double _readyPixel = 1, _readyBlur = 0, _readyDuration = .22;
  _RoundedContentPixels _clipper = _RoundedContentPixels(1);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context
        .dependOnInheritedWidgetOfExactType<_CinemaDecodeScope>()
        ?.frame;
    if (!identical(next, _frame)) {
      _frame = next;
      _readyAt = null;
    }
  }

  @override
  void didUpdateWidget(CinemaNeonRegion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.ready) {
      _readyAt = null;
    } else if (!oldWidget.ready && (_frame?.enabled ?? false)) {
      final frame = _frame!;
      _readyAt = frame.clock;
      _readyPixel = frame.pixelSize;
      _readyBlur = frame.blurSigma;
      _readyDuration = frame.settling ? .52 : .22;
      frame.animateFor(_readyDuration);
    }
  }

  ({bool filtered, double pixelSize, double blurSigma}) _values() {
    final frame = _frame;
    if (frame == null || !frame.enabled) {
      return (filtered: false, pixelSize: 1, blurSigma: 0);
    }
    if (!widget.ready) {
      return (
        filtered: true,
        pixelSize: frame.pixelSize,
        blurSigma: frame.blurSigma,
      );
    }
    if (_readyAt == null) {
      return (filtered: false, pixelSize: 1, blurSigma: 0);
    }
    final t = ((frame.clock - _readyAt!) / _readyDuration).clamp(0.0, 1.0);
    final ease = t * t * (3 - 2 * t);
    return (
      filtered: t < 1,
      pixelSize: _readyPixel + (1 - _readyPixel) * ease,
      blurSigma: _readyBlur * (1 - ease),
    );
  }

  @visibleForTesting
  ({bool filtered, double pixelSize, double blurSigma}) get debugSnapshot =>
      _values();

  @override
  Widget build(BuildContext context) {
    final frame = _frame;
    if (frame == null) return widget.child;
    return AnimatedBuilder(
      animation: frame,
      // Only filter parameters and the rounded clip are updated on a frame.
      // The real child stays in one place, including after loading completes.
      child: RepaintBoundary(child: widget.child),
      builder: (context, child) {
        final values = _values();
        final clipPitch = (values.pixelSize * 2).round() / 2;
        if (_clipper.pitch != clipPitch) {
          _clipper = _RoundedContentPixels(clipPitch, previous: _clipper);
        }
        return ImageFiltered(
          enabled: values.filtered && values.blurSigma > .01,
          imageFilter: ui.ImageFilter.blur(
            sigmaX: values.blurSigma,
            sigmaY: values.blurSigma,
          ),
          child: ClipPath(
            clipBehavior: values.filtered ? Clip.antiAlias : Clip.none,
            clipper: _clipper,
            child: ImageFiltered(
              enabled: values.filtered && values.pixelSize > 1.01,
              imageFilter: _samplingFilter(values.pixelSize),
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _RoundedContentPixels extends CustomClipper<Path> {
  _RoundedContentPixels(this.pitch, {_RoundedContentPixels? previous})
    : _cachedSize = previous?._cachedSize,
      _cachedCell = previous?._cachedCell,
      _cachedPath = previous?._cachedPath;
  final double pitch;
  Size? _cachedSize;
  double? _cachedCell;
  Path? _cachedPath;

  @override
  Path getClip(Size size) {
    final cell = pitch < 2 || size.isEmpty
        ? 0.0
        : math.max(pitch, math.sqrt(size.width * size.height / 5000));
    if (_cachedSize == size && _cachedCell == cell && _cachedPath != null) {
      return _cachedPath!;
    }
    final path = Path();
    if (cell == 0) {
      path.addRect(Offset.zero & size);
    } else {
      final radius = Radius.circular(cell * .22);
      for (var y = 0.0; y < size.height; y += cell) {
        for (var x = 0.0; x < size.width; x += cell) {
          path.addRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(
                x,
                y,
                math.min(cell, size.width - x),
                math.min(cell, size.height - y),
              ),
              radius,
            ),
          );
        }
      }
    }
    _cachedSize = size;
    _cachedCell = cell;
    _cachedPath = path;
    return path;
  }

  @override
  bool shouldReclip(_RoundedContentPixels oldClipper) =>
      oldClipper.pitch != pitch;
}

class _ContentAssemblyGlow extends SingleChildRenderObjectWidget {
  const _ContentAssemblyGlow({required this.gain, required super.child});
  final double gain;

  @override
  _RenderContentAssemblyGlow createRenderObject(BuildContext context) =>
      _RenderContentAssemblyGlow(gain);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderContentAssemblyGlow renderObject,
  ) => renderObject.gain = gain;
}

class _RenderContentAssemblyGlow extends RenderProxyBox {
  _RenderContentAssemblyGlow(this._gain);
  double _gain;
  bool get _active => _gain > 1.00001;

  set gain(double value) {
    if (_gain == value) return;
    final wasActive = _active;
    _gain = value;
    if (wasActive != _active) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null && _active;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (!_active) {
      layer = null;
      super.paint(context, offset);
      return;
    }
    // One gentle gain pulse uses original content colors. It introduces no
    // colored rectangles or white overlay and leaves no filter layer at idle.
    layer = context.pushColorFilter(
      offset,
      ColorFilter.matrix([
        _gain,
        0,
        0,
        0,
        0,
        0,
        _gain,
        0,
        0,
        0,
        0,
        0,
        _gain,
        0,
        0,
        0,
        0,
        0,
        1,
        0,
      ]),
      super.paint,
      oldLayer: layer is ColorFilterLayer ? layer as ColorFilterLayer : null,
    );
  }
}

Float64List _scaleMatrix(double scale) => Float64List.fromList([
  scale,
  0,
  0,
  0,
  0,
  scale,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  0,
  1,
]);

ui.ImageFilter _samplingFilter(double pixelSize) => ui.ImageFilter.compose(
  outer: ui.ImageFilter.matrix(
    _scaleMatrix(pixelSize),
    filterQuality: FilterQuality.none,
  ),
  inner: ui.ImageFilter.matrix(
    _scaleMatrix(1 / pixelSize),
    filterQuality: FilterQuality.low,
  ),
);

class _DecodeFrame extends ChangeNotifier {
  double elapsed = 0;
  double clock = 0;
  bool enabled = false;
  double animateUntil = 0;
  VoidCallback? requestFrames;
  double progress = 0;
  double reveal = 0;
  double opacity = 1;
  double assembly = 0;
  double assemblyFromPixelSize = 32;
  double assemblyFromBlurSigma = 7;
  bool settling = false;
  int seed = 1;

  double get _refinement {
    final t = (reveal / .9).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }

  double get _assemblyEase => assembly * assembly * (3 - 2 * assembly);

  double get pixelSize => settling
      ? assemblyFromPixelSize + (1 - assemblyFromPixelSize) * _assemblyEase
      : 32 - 29 * _refinement;

  double get blurSigma => settling
      ? assemblyFromBlurSigma * (1 - _assemblyEase)
      : 7 - 6.55 * _refinement;

  void animateFor(double seconds) {
    if (!enabled) return;
    animateUntil = math.max(animateUntil, clock + seconds);
    requestFrames?.call();
  }

  void redraw() => notifyListeners();
}
