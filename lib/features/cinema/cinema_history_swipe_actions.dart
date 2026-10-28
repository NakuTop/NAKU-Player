import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/navigation_gesture_exclusion.dart';

import 'cinema_theme.dart';
import 'cinema_swipe_navigation.dart';

/// A closed history row's first left swipe only exposes its delete action. The
/// next left swipe, or a right swipe, can hand off to adjacent-page navigation.
/// Deleting always requires an explicit button press and uses the caller's undo.
class CinemaHistorySwipeActions extends StatefulWidget {
  const CinemaHistorySwipeActions({
    super.key,
    required this.child,
    required this.onDelete,
  });

  final Widget child;
  final Future<bool> Function() onDelete;

  @override
  State<CinemaHistorySwipeActions> createState() =>
      _CinemaHistorySwipeActionsState();
}

class _HistorySwipeScope {
  _CinemaHistorySwipeActionsState? active;
  final momentumUntil = <int, Duration>{};
  final verticalWheelUntil = <int, Duration>{};

  void activate(_CinemaHistorySwipeActionsState row) {
    if (identical(active, row)) return;
    active?._close();
    active = row;
  }

  void close() => active?._close();
}

enum _SwipeAxis { pending, horizontal, vertical }

enum _SwipePurpose { pending, row, back, forward }

class _CinemaHistorySwipeActionsState extends State<CinemaHistorySwipeActions>
    with SingleTickerProviderStateMixin {
  static const _extent = 92.0;
  static final _scopes = Expando<_HistorySwipeScope>();
  late final _motion = AnimationController(
    vsync: this,
    lowerBound: -_extent,
    upperBound: 0,
    value: 0,
  );
  late _HistorySwipeScope _scope;
  bool _hasScope = false;
  ScrollPosition? _scrollPosition;
  Timer? _wheelEnd;
  _SwipeAxis _axis = _SwipeAxis.pending;
  _SwipePurpose _purpose = _SwipePurpose.pending;
  CinemaSwipeNavigationIntent? _navigation;
  bool _tracking = false;
  bool _deleting = false;
  bool _nativeStream = false;
  double _startOffset = 0;
  double _distance = 0;
  int _device = 0;
  Duration _lastEvent = Duration.zero;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scrollable = Scrollable.maybeOf(context);
    final key = scrollable ?? ModalRoute.of(context) ?? context;
    final next = _scopes[key] ??= _HistorySwipeScope();
    if (_hasScope && !identical(_scope, next)) {
      if (_tracking) _guardMomentum();
      if (identical(_scope.active, this)) _scope.active = null;
      _wheelEnd?.cancel();
      _cancelNavigation(defer: true);
      _tracking = false;
      _motion.value = 0;
    }
    if (_scrollPosition != scrollable?.position) {
      _scrollPosition?.isScrollingNotifier.removeListener(_onScrolling);
      _scrollPosition = scrollable?.position;
      _scrollPosition?.isScrollingNotifier.addListener(_onScrolling);
    }
    _scope = next;
    _hasScope = true;
    if (MediaQuery.disableAnimationsOf(context) && _motion.isAnimating) {
      _motion.value = _motion.value < -_extent / 2 ? -_extent : 0;
    }
  }

  void _onScrolling() {
    if (_scrollPosition?.isScrollingNotifier.value == true) _scope.close();
  }

  bool _momentum(PointerEvent event) {
    if (event.timeStamp >=
        (_scope.momentumUntil[event.device] ?? Duration.zero)) {
      return false;
    }
    _scope.momentumUntil[event.device] =
        event.timeStamp + const Duration(milliseconds: 450);
    return true;
  }

  void _begin({PointerEvent? event}) {
    if (_deleting) return;
    if (_tracking) _finish(cancel: true);
    _motion.stop();
    _tracking = true;
    _startOffset = _motion.value;
    _distance = 0;
    _axis = _SwipeAxis.pending;
    _purpose = _SwipePurpose.pending;
    _navigation = CinemaSwipeNavigationIntent.maybeOf(context);
    _nativeStream = event != null;
    if (event != null) {
      _device = event.device;
      _lastEvent = event.timeStamp;
    }
  }

  void _move(double delta) {
    if (!_tracking || _deleting) return;
    _distance += delta;
    if (_purpose == _SwipePurpose.pending) {
      if (_distance.abs() < 10) return;
      final startedOpen = _startOffset < -_extent / 2;
      _purpose = _distance > 0 && _navigation?.canBack == true
          ? _SwipePurpose.back
          : _distance < 0 && startedOpen && _navigation?.canForward == true
          ? _SwipePurpose.forward
          : _SwipePurpose.row;
      _scope.activate(this);
    }
    if (_purpose == _SwipePurpose.row) {
      _motion.value = (_startOffset + _distance).clamp(-_extent, 0.0);
    } else {
      final preview = _purpose == _SwipePurpose.back
          ? _distance.clamp(0.0, 260.0)
          : _distance.clamp(-260.0, 0.0);
      _navigation?.preview(
        preview,
        device: _nativeStream ? _device : null,
        timeStamp: _nativeStream ? _lastEvent : null,
        owner: this,
      );
      if (_purpose == _SwipePurpose.back) {
        _motion.value = (_startOffset + preview).clamp(-_extent, 0.0);
      }
    }
  }

  void _settle(bool open) {
    final target = open ? -_extent : 0.0;
    if (open) {
      _scope.activate(this);
    } else if (identical(_scope.active, this)) {
      _scope.active = null;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      _motion.value = target;
    } else {
      _motion.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
      );
    }
  }

  void _finish({bool cancel = false, double velocity = 0}) {
    _wheelEnd?.cancel();
    if (!_tracking) return;
    _tracking = false;
    _guardMomentum();
    final startedOpen = _startOffset < -_extent / 2;
    final navigation = _navigation;
    _navigation = null;
    final navigating =
        _purpose == _SwipePurpose.back || _purpose == _SwipePurpose.forward;
    final correctDirection = _purpose == _SwipePurpose.back
        ? _distance > 0
        : _distance < 0;
    final commit =
        navigating &&
        !cancel &&
        correctDirection &&
        (_distance.abs() >= 105 ||
            (_distance.abs() >= 48 &&
                velocity.abs() > 650 &&
                velocity.sign == _distance.sign));
    final rowOpen = commit
        ? false
        : cancel
        ? startedOpen
        : _purpose == _SwipePurpose.back
        ? startedOpen && _distance < 32
        : _purpose == _SwipePurpose.forward
        ? startedOpen
        : startedOpen
        ? _distance < 32
        : _distance <= -32;
    _settle(rowOpen);
    if (navigating) navigation?.finish(commit: commit, owner: this);
    _purpose = _SwipePurpose.pending;
  }

  void _close() {
    _wheelEnd?.cancel();
    if (_tracking) _guardMomentum();
    _cancelNavigation();
    _tracking = false;
    _settle(false);
  }

  void _cancelNavigation({bool defer = false}) {
    final navigation = _navigation;
    final navigating =
        _purpose == _SwipePurpose.back || _purpose == _SwipePurpose.forward;
    _navigation = null;
    _purpose = _SwipePurpose.pending;
    if (navigation == null || !navigating) return;
    if (defer) {
      scheduleMicrotask(() => navigation.finish(owner: this));
    } else {
      navigation.finish(owner: this);
    }
  }

  void _guardMomentum() {
    if (_nativeStream) {
      _scope.momentumUntil[_device] =
          _lastEvent + const Duration(milliseconds: 450);
    }
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || _deleting) return;
    final delta = event.scrollDelta;
    if (event.timeStamp <
        (_scope.verticalWheelUntil[event.device] ?? Duration.zero)) {
      _scope.verticalWheelUntil[event.device] =
          event.timeStamp + const Duration(milliseconds: 125);
      return;
    }
    if (delta.dy.abs() > delta.dx.abs() || delta.dx.abs() < 2) {
      if (delta.dy.abs() > 2) {
        _scope.verticalWheelUntil[event.device] =
            event.timeStamp + const Duration(milliseconds: 125);
        _scope.close();
      }
      if (_tracking) _finish(cancel: true);
      return;
    }
    if (delta.dx.abs() < delta.dy.abs() * 1.5) {
      _scope.verticalWheelUntil[event.device] =
          event.timeStamp + const Duration(milliseconds: 125);
      if (_tracking) _finish(cancel: true);
      return;
    }
    // Own the whole horizontal signal, including its small vertical component.
    // Letting the ancestor ListView consume dy would scroll and close this row.
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {});
    if (!_tracking) {
      if (_momentum(event)) return;
      _begin(event: event);
    }
    _lastEvent = event.timeStamp;
    _move(-delta.dx);
    _wheelEnd?.cancel();
    _wheelEnd = Timer(const Duration(milliseconds: 125), _finish);
  }

  void _panStart(PointerPanZoomStartEvent event) {
    // A new phased trackpad sequence means the fingers lifted and returned.
    // Unlike an unphased wheel tail, this is fresh user intent.
    if (!_deleting) _begin(event: event);
  }

  void _panUpdate(PointerPanZoomUpdateEvent event) {
    if (!_tracking) return;
    _lastEvent = event.timeStamp;
    if ((event.scale - 1).abs() > .02 || event.rotation.abs() > .03) {
      _finish(cancel: true);
      return;
    }
    if (_axis == _SwipeAxis.pending) {
      final pan = event.pan;
      if (pan.dy.abs() > 10 && pan.dy.abs() > pan.dx.abs() * 1.2) {
        _axis = _SwipeAxis.vertical;
        _finish(cancel: true);
        _scope.close();
        return;
      }
      if (pan.dx.abs() < 10 || pan.dx.abs() < pan.dy.abs() * 1.5) return;
      _axis = _SwipeAxis.horizontal;
      _move(pan.dx);
    } else if (_axis == _SwipeAxis.horizontal) {
      _move(event.panDelta.dx);
    }
  }

  Future<void> _delete() async {
    if (_deleting) return;
    _wheelEnd?.cancel();
    _cancelNavigation();
    _tracking = false;
    setState(() => _deleting = true);
    try {
      await widget.onDelete();
    } catch (_) {
      // The caller reports storage failures. Keep the row usable for a retry.
    } finally {
      if (mounted) {
        setState(() => _deleting = false);
        _close();
      }
    }
  }

  @override
  void dispose() {
    _wheelEnd?.cancel();
    if (_tracking) _guardMomentum();
    _cancelNavigation(defer: true);
    _scrollPosition?.isScrollingNotifier.removeListener(_onScrolling);
    if (identical(_scope.active, this)) _scope.active = null;
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => NavigationGestureExclusion(
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerSignal: _wheel,
      onPointerPanZoomStart: _panStart,
      onPointerPanZoomUpdate: _panUpdate,
      onPointerPanZoomEnd: (_) => _finish(),
      onPointerCancel: (_) => _finish(cancel: true),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: const {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.stylus,
          PointerDeviceKind.invertedStylus,
          PointerDeviceKind.trackpad,
        },
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (event) {
          if (event.kind != PointerDeviceKind.trackpad) _begin();
        },
        onHorizontalDragUpdate: (event) {
          if (!_nativeStream) _move(event.delta.dx);
        },
        onHorizontalDragEnd: (event) {
          if (!_nativeStream) {
            _finish(velocity: event.primaryVelocity ?? 0);
          }
        },
        onHorizontalDragCancel: () => _finish(cancel: true),
        child: AnimatedBuilder(
          animation: _motion,
          child: RepaintBoundary(child: widget.child),
          builder: (context, child) {
            final revealed = -_motion.value;
            return ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                children: [
                  if (revealed > .5)
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: revealed,
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.centerRight,
                          minWidth: _extent,
                          maxWidth: _extent,
                          child: SizedBox(
                            width: _extent,
                            height: double.infinity,
                            child: TextButton(
                              key: const ValueKey('cinema-history-delete'),
                              onPressed: _deleting ? null : _delete,
                              style: TextButton.styleFrom(
                                foregroundColor: CinemaTheme.copper,
                                backgroundColor: CinemaTheme.copper.withValues(
                                  alpha: .18,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: _deleting
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: CinemaTheme.copper,
                                      ),
                                    )
                                  : const Tooltip(
                                      message: '删除记录',
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.delete_outline_rounded,
                                              size: 21,
                                            ),
                                            SizedBox(height: 4),
                                            Text(
                                              '删除记录',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  Transform.translate(
                    key: const ValueKey('cinema-history-swipe-offset'),
                    offset: Offset(_motion.value, 0),
                    child: Stack(
                      children: [
                        child!,
                        if (revealed > .5)
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _close,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}
