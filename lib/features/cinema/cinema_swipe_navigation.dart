import 'package:kazumi/bean/widget/navigation_gesture_exclusion.dart';
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

typedef CinemaSwipeExclusion = NavigationGestureExclusion;

/// Browser-like navigation without taking vertical scrolling or mouse drags.
/// Nested horizontal viewports, text editing and sliders retain their gestures.
class CinemaSwipeNavigation extends StatefulWidget {
  const CinemaSwipeNavigation({
    super.key,
    required this.child,
    this.onBack,
    this.onForward,
    this.enabled = true,
    this.edgeOnly = false,
  });
  final Widget child;
  final VoidCallback? onBack;
  final VoidCallback? onForward;
  final bool enabled;
  final bool edgeOnly;

  @override
  State<CinemaSwipeNavigation> createState() => _CinemaSwipeNavigationState();
}

class _CinemaSwipeNavigationState extends State<CinemaSwipeNavigation>
    with SingleTickerProviderStateMixin {
  // Trackpad momentum must not navigate the page revealed by the first swipe.
  static final _momentumUntil = <int, Duration>{};
  int _device = 0;
  Duration _lastEventTime = Duration.zero;
  bool _trackpadStream = false;
  late final _motion = AnimationController.unbounded(vsync: this);
  Timer? _wheelEnd;
  bool _tracking = false;
  double _distance = 0;
  Offset _pan = Offset.zero;

  bool _blocked(PointerEvent event) {
    if (!widget.enabled) return true;
    if ((event is PointerScrollEvent || event is PointerPanZoomStartEvent) &&
        event.timeStamp < (_momentumUntil[event.device] ?? Duration.zero)) {
      _momentumUntil[event.device] =
          event.timeStamp + const Duration(milliseconds: 450);
      return true;
    }
    if (widget.edgeOnly && event.localPosition.dx > 56) return true;
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    return result.path.any((entry) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is CinemaSwipeExclusion) {
        return true;
      }
      if (target is RenderEditable) return true;
      if (target is RenderSemanticsAnnotations &&
          (target.properties.slider == true ||
              target.properties.textField == true)) {
        return true;
      }
      if (target is RenderViewport &&
          axisDirectionToAxis(target.axisDirection) == Axis.horizontal) {
        return true;
      }
      if (target is RenderShrinkWrappingViewport &&
          axisDirectionToAxis(target.axisDirection) == Axis.horizontal) {
        return true;
      }
      return false;
    });
  }

  void _begin(PointerEvent event) {
    _device = event.device;
    _lastEventTime = event.timeStamp;
    _trackpadStream =
        event is PointerScrollEvent || event is PointerPanZoomStartEvent;
    _motion.stop();
    _distance = 0;
    _pan = Offset.zero;
    _tracking = true;
  }

  void _move(double dx) {
    if (!_tracking) return;
    _distance = (_distance + dx).clamp(-260.0, 260.0);
    final allowed = _distance > 0
        ? widget.onBack != null
        : widget.onForward != null;
    _motion.value = allowed ? _distance.clamp(-150.0, 150.0) : _distance * .12;
  }

  void _finish({bool cancel = false, double velocity = 0}) {
    _wheelEnd?.cancel();
    if (!_tracking) return;
    _tracking = false;
    final action = _distance > 0 ? widget.onBack : widget.onForward;
    final committed =
        !cancel &&
        action != null &&
        (_distance.abs() >= 105 ||
            (_distance.abs() >= 48 && velocity.abs() > 650));
    if (committed) {
      if (_trackpadStream) {
        _momentumUntil[_device] =
            _lastEventTime + const Duration(milliseconds: 450);
      }
      action();
    }
    _motion.animateTo(
      0,
      duration: const Duration(milliseconds: 190),
      curve: Curves.easeOutCubic,
    );
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta;
    if (delta.dx.abs() < 2 || delta.dx.abs() < delta.dy.abs() * 1.8) {
      if (_tracking) _finish(cancel: true);
      return;
    }
    if (!_tracking) {
      if (_blocked(event)) return;
      _begin(event);
    }
    _lastEventTime = event.timeStamp;
    _move(-delta.dx);
    _wheelEnd?.cancel();
    _wheelEnd = Timer(const Duration(milliseconds: 125), _finish);
  }

  @override
  void dispose() {
    _wheelEnd?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerSignal: _wheel,
    onPointerDown: (event) {
      if (event.kind == PointerDeviceKind.touch && !_blocked(event)) {
        _begin(event);
      }
    },
    onPointerUp: (_) => scheduleMicrotask(() {
      if (mounted && _tracking) _finish(cancel: true);
    }),
    onPointerCancel: (_) => _finish(cancel: true),
    onPointerPanZoomStart: (event) {
      if (!_blocked(event)) _begin(event);
    },
    onPointerPanZoomUpdate: (event) {
      if (!_tracking) return;
      _lastEventTime = event.timeStamp;
      if ((event.scale - 1).abs() > .02 || event.rotation.abs() > .03) {
        _finish(cancel: true);
        return;
      }
      _pan = event.pan;
      if (_pan.dy.abs() > _pan.dx.abs() * 1.2 && _pan.dy.abs() > 12) {
        _finish(cancel: true);
      } else if (_pan.dx.abs() > _pan.dy.abs() * 1.5) {
        _move(event.panDelta.dx);
      }
    },
    onPointerPanZoomEnd: (_) => _finish(),
    child: GestureDetector(
      behavior: HitTestBehavior.translucent,
      supportedDevices: const {PointerDeviceKind.touch},
      onHorizontalDragUpdate: (event) => _move(event.delta.dx),
      onHorizontalDragEnd: (event) =>
          _finish(velocity: event.primaryVelocity ?? 0),
      onHorizontalDragCancel: () => _finish(cancel: true),
      child: AnimatedBuilder(
        animation: _motion,
        child: RepaintBoundary(child: widget.child),
        builder: (context, child) {
          final progress = (_motion.value.abs() / 105).clamp(0.0, 1.0);
          final right = _motion.value >= 0;
          final reduced = MediaQuery.disableAnimationsOf(context);
          return Stack(
            fit: StackFit.passthrough,
            children: [
              Transform.translate(
                offset: Offset(reduced ? 0 : _motion.value * .16, 0),
                child: child,
              ),
              if (progress > .01)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Align(
                      alignment: right
                          ? Alignment.centerLeft
                          : Alignment.centerRight,
                      child: Opacity(
                        opacity: progress,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0xE026292E),
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: const [
                                BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 20,
                                ),
                              ],
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(11),
                              child: Icon(
                                right
                                    ? Icons.arrow_back_rounded
                                    : Icons.arrow_forward_rounded,
                                key: const ValueKey('cinema-swipe-feedback'),
                                size: 20,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );
}
