import 'cinema_swipe_navigation.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import 'cinema_theme.dart';

/// A single frosted navigation surface. The thumb follows the pointer, then
/// settles into its destination; intermediate cells do not navigate the app.
class CinemaNavigationIsland<T extends Object> extends StatefulWidget {
  const CinemaNavigationIsland({
    super.key,
    required this.value,
    required this.destinations,
    required this.onChanged,
    required this.keyFor,
    this.swipeProgress,
  });

  final T value;
  final List<(T, IconData, String)> destinations;
  final ValueChanged<T> onChanged;
  final Key Function(T) keyFor;

  /// Page displacement in destination units: positive previews the previous
  /// destination. This only moves the thumb; it never changes the selection.
  final ValueListenable<double>? swipeProgress;

  @override
  State<CinemaNavigationIsland<T>> createState() =>
      _CinemaNavigationIslandState<T>();
}

class _CinemaNavigationIslandState<T extends Object>
    extends State<CinemaNavigationIsland<T>>
    with SingleTickerProviderStateMixin {
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: math.max(0, _selected).toDouble(),
  );
  bool _dragging = false;
  double _segmentWidth = 104;
  double _grabOffset = 0;
  double _externalPreview = 0;
  bool _externalNeedsReset = false;
  final _momentumUntil = <int, Duration>{};
  Timer? _wheelEnd;
  bool _streamActive = false;
  bool _streamWheel = false;
  int _streamAxis = 0; // 0: undecided, 1: horizontal, 2: vertical.
  int _streamDevice = 0;
  int _streamAnchor = 0;
  Duration _lastEventTime = Duration.zero;
  Offset _streamPan = Offset.zero;
  double _streamDistance = 0;

  int get _selected =>
      widget.destinations.indexWhere((entry) => entry.$1 == widget.value);
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void initState() {
    super.initState();
    widget.swipeProgress?.addListener(_previewPageSwipe);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion &&
        !_dragging &&
        !_streamActive &&
        _externalPreview == 0) {
      _position.stop();
      _position.value = math.max(0, _selected).toDouble();
    }
    if ((widget.swipeProgress?.value ?? 0) != 0) _previewPageSwipe();
  }

  @override
  void didUpdateWidget(CinemaNavigationIsland<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.swipeProgress != widget.swipeProgress) {
      oldWidget.swipeProgress?.removeListener(_previewPageSwipe);
      widget.swipeProgress?.addListener(_previewPageSwipe);
      _externalPreview = 0;
      _externalNeedsReset = false;
    }
    final sameOrder = listEquals(
      oldWidget.destinations.map((entry) => entry.$1).toList(),
      widget.destinations.map((entry) => entry.$1).toList(),
    );
    if (oldWidget.value != widget.value || !sameOrder) {
      // Pointer coordinates and spring positions refer to the old ID order.
      // A canceled gesture's remaining move/up events must not select a new ID.
      _dragging = false;
      _clearStream();
      _externalPreview = 0;
      _externalNeedsReset = (widget.swipeProgress?.value ?? 0) != 0;
      _settle(_selected);
    }
  }

  void _previewPageSwipe() {
    final progress = (widget.swipeProgress?.value ?? 0).clamp(-1.0, 1.0);
    if (_externalNeedsReset) {
      if (progress == 0) _externalNeedsReset = false;
      return;
    }
    if (_dragging || _streamActive || _selected < 0) return;
    if (progress == 0) {
      if (_externalPreview == 0) return;
      _externalPreview = 0;
      // Keep the current physical position. On commit the parent changes the
      // selected ID in the same frame; on cancellation this returns home.
      _settle(_selected);
      return;
    }
    _externalPreview = progress;
    _position.stop();
    _position.value = (_selected - progress).clamp(
      0.0,
      math.max(0, widget.destinations.length - 1).toDouble(),
    );
  }

  void _settle(int index) {
    index = math.max(0, index);
    if (_reduceMotion) {
      _position.value = index.toDouble();
    } else {
      _position.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 420, damping: 40),
          _position.value,
          index.toDouble(),
          0,
          tolerance: const Tolerance(distance: .001, velocity: .01),
        ),
      );
    }
  }

  void _commit(int index) {
    _dragging = false;
    _clearStream();
    if (index < 0 || index >= widget.destinations.length) return;
    _settle(index);
    if (widget.destinations[index].$1 != widget.value) {
      widget.onChanged(widget.destinations[index].$1);
    }
  }

  void _start(DragStartDetails details) {
    if (widget.destinations.isEmpty) return;
    _clearStream();
    _position.stop();
    setState(() => _dragging = true);
    final thumbCenter = 3 + (_position.value + .5) * _segmentWidth;
    final grabbedThumb =
        _selected >= 0 &&
        (details.localPosition.dx - thumbCenter).abs() <= _segmentWidth / 2;
    if (!grabbedThumb) {
      _position.value = ((details.localPosition.dx - 3) / _segmentWidth - .5)
          .clamp(0.0, widget.destinations.length - 1.0);
    }
    _grabOffset =
        details.localPosition.dx - 3 - (_position.value + .5) * _segmentWidth;
  }

  void _drag(DragUpdateDetails details) {
    if (!_dragging) return;
    final raw =
        (details.localPosition.dx - 3 - _grabOffset) / _segmentWidth - .5;
    final last = widget.destinations.length - 1.0;
    // Gentle resistance at the ends, without moving the labels or hit areas.
    _position.value = raw < 0
        ? -math.min(.12, -raw * .15)
        : raw > last
        ? last + math.min(.12, (raw - last) * .15)
        : raw;
  }

  void _cancelDrag() {
    if (!_dragging) return;
    setState(() => _dragging = false);
    _settle(_selected);
  }

  bool _startStream(PointerEvent event, {required bool wheel}) {
    if (_dragging || widget.destinations.isEmpty) return false;
    // A native pan/zoom start is an explicit new finger gesture. Only wheel
    // streams need quiet time to distinguish a new gesture from inertia.
    if (wheel &&
        event.timeStamp < (_momentumUntil[event.device] ?? Duration.zero)) {
      _momentumUntil[event.device] =
          event.timeStamp + const Duration(milliseconds: 450);
      return false;
    }
    _position.stop();
    _streamActive = true;
    _streamWheel = wheel;
    _streamAxis = 0;
    _streamDevice = event.device;
    _streamAnchor = _selected;
    _streamPan = Offset.zero;
    _streamDistance = 0;
    _lastEventTime = event.timeStamp;
    return true;
  }

  void _moveStream(Offset delta) {
    if (!_streamActive) return;
    _streamPan += delta;
    // Scrub the thumb in the physical direction of the finger, just like a
    // direct mouse drag. Wheel deltas are normalized by _wheel below.
    var movement = delta.dx;
    if (_streamAxis == 0) {
      if (_streamPan.dy.abs() > 8 &&
          _streamPan.dy.abs() > _streamPan.dx.abs() * 1.2) {
        _streamAxis = 2;
      } else if (_streamPan.dx.abs() > 8 &&
          _streamPan.dx.abs() > _streamPan.dy.abs() * 1.5) {
        setState(() => _streamAxis = 1);
        movement = _streamPan.dx;
      }
    }
    if (_streamAxis != 1) return;
    _streamDistance = (_streamDistance + movement).clamp(
      -_segmentWidth * 1.15,
      _segmentWidth * 1.15,
    );
    final anchor = _streamAnchor >= 0
        ? _streamAnchor.toDouble()
        : _streamDistance >= 0
        ? 0.0
        : widget.destinations.length - 1.0;
    final raw = anchor + _streamDistance / _segmentWidth;
    final last = widget.destinations.length - 1.0;
    _position.value = raw < 0
        ? -math.min(.12, -raw * .15)
        : raw > last
        ? last + math.min(.12, (raw - last) * .15)
        : raw;
  }

  void _clearStream() {
    _wheelEnd?.cancel();
    _wheelEnd = null;
    _streamActive = false;
    _streamAxis = 0;
  }

  void _finishStream({bool cancel = false}) {
    if (!_streamActive) return;
    final deliberate =
        !cancel &&
        _streamAxis == 1 &&
        _streamDistance.abs() >= _segmentWidth * .5;
    final direction = _streamDistance >= 0 ? 1 : -1;
    final target = _streamAnchor < 0
        ? (direction > 0 ? 0 : widget.destinations.length - 1)
        : (_streamAnchor + direction).clamp(0, widget.destinations.length - 1);
    if (deliberate) {
      _momentumUntil[_streamDevice] =
          _lastEventTime + const Duration(milliseconds: 450);
    }
    setState(_clearStream);
    if (deliberate) {
      _commit(target);
    } else {
      _settle(_selected);
    }
  }

  void _wheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || (_streamActive && !_streamWheel)) {
      return;
    }
    if (!_streamActive && !_startStream(event, wheel: true)) return;
    _lastEventTime = event.timeStamp;
    _moveStream(-event.scrollDelta);
    _wheelEnd?.cancel();
    _wheelEnd = Timer(const Duration(milliseconds: 125), _finishStream);
  }

  Color _labelColor(int index) {
    final visible =
        _selected >= 0 || _dragging || (_streamActive && _streamAxis == 1);
    final proximity = visible
        ? (1 - (_position.value - index).abs()).clamp(0.0, 1.0)
        : 0.0;
    return Color.lerp(CinemaTheme.muted, CinemaTheme.text, proximity)!;
  }

  @override
  void dispose() {
    widget.swipeProgress?.removeListener(_previewPageSwipe);
    _wheelEnd?.cancel();
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CinemaSwipeExclusion(
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerCancel: (_) => _cancelDrag(),
      onPointerSignal: _wheel,
      onPointerPanZoomStart: (event) => _startStream(event, wheel: false),
      onPointerPanZoomUpdate: (event) {
        if (!_streamActive || _streamWheel) return;
        _lastEventTime = event.timeStamp;
        if ((event.scale - 1).abs() > .02 || event.rotation.abs() > .03) {
          _finishStream(cancel: true);
          return;
        }
        _moveStream(event.panDelta);
      },
      onPointerPanZoomEnd: (_) => _finishStream(),
      child: _buildIsland(context),
    ),
  );

  Widget _buildIsland(BuildContext context) => Focus(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final direction = event.logicalKey == LogicalKeyboardKey.arrowRight
          ? 1
          : event.logicalKey == LogicalKeyboardKey.arrowLeft
          ? -1
          : 0;
      if (direction == 0) return KeyEventResult.ignored;
      if (widget.destinations.isEmpty) return KeyEventResult.ignored;
      final target = _selected < 0
          ? (direction > 0 ? 0 : widget.destinations.length - 1)
          : (_selected + direction).clamp(0, widget.destinations.length - 1);
      _commit(target);
      return KeyEventResult.handled;
    },
    child: CinemaGlass(
      radius: 29,
      padding: const EdgeInsets.all(4),
      child: SizedBox(
        width: math.min(
          widget.destinations.length * 104.0,
          MediaQuery.sizeOf(context).width - 48,
        ),
        height: 52,
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (widget.destinations.isEmpty) return const SizedBox.shrink();
            _segmentWidth =
                (constraints.maxWidth - 6) / widget.destinations.length;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              supportedDevices: const {
                PointerDeviceKind.mouse,
                PointerDeviceKind.touch,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
              },
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: _start,
              onHorizontalDragUpdate: _drag,
              onHorizontalDragEnd: (_) {
                if (!_dragging) return;
                _commit(
                  _position.value.round().clamp(
                    0,
                    widget.destinations.length - 1,
                  ),
                );
              },
              onHorizontalDragCancel: _cancelDrag,
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _position,
                    builder: (_, _) =>
                        _selected < 0 &&
                            !_dragging &&
                            !(_streamActive && _streamAxis == 1)
                        ? const SizedBox.shrink()
                        : Positioned(
                            left: 3 + _position.value * _segmentWidth,
                            top: 3,
                            bottom: 3,
                            width: _segmentWidth,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                key: const ValueKey('cinema-navigation-thumb'),
                                decoration: BoxDecoration(
                                  color: const Color(0x22FFFFFF),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                              ),
                            ),
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Row(
                      children: [
                        for (var i = 0; i < widget.destinations.length; i++)
                          Expanded(
                            child: Semantics(
                              selected: _selected == i,
                              child: AnimatedBuilder(
                                animation: _position,
                                builder: (_, _) => TextButton(
                                  key: widget.keyFor(widget.destinations[i].$1),
                                  onPressed: () => _commit(i),
                                  style: TextButton.styleFrom(
                                    foregroundColor: _labelColor(i),
                                    backgroundColor: Colors.transparent,
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 16,
                                      horizontal: 7,
                                    ),
                                    shape: const StadiumBorder(),
                                    textStyle: TextStyle(
                                      fontSize: 12,
                                      fontWeight: _selected == i
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                  ).copyWith(animationDuration: Duration.zero),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(widget.destinations[i].$2, size: 18),
                                      const SizedBox(width: 6),
                                      Text(widget.destinations[i].$3),
                                    ],
                                  ),
                                ),
                              ),
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
