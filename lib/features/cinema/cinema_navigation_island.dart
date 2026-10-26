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
  });

  final T value;
  final List<(T, IconData, String)> destinations;
  final ValueChanged<T> onChanged;
  final Key Function(T) keyFor;

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

  int get _selected =>
      widget.destinations.indexWhere((entry) => entry.$1 == widget.value);
  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _position.stop();
      _position.value = math.max(0, _selected).toDouble();
    }
  }

  @override
  void didUpdateWidget(CinemaNavigationIsland<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sameOrder = listEquals(
      oldWidget.destinations.map((entry) => entry.$1).toList(),
      widget.destinations.map((entry) => entry.$1).toList(),
    );
    if (oldWidget.value != widget.value || !sameOrder) {
      // Pointer coordinates and spring positions refer to the old ID order.
      // A canceled gesture's remaining move/up events must not select a new ID.
      _dragging = false;
      _settle(_selected);
    }
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
    if (index < 0 || index >= widget.destinations.length) return;
    _settle(index);
    if (widget.destinations[index].$1 != widget.value) {
      widget.onChanged(widget.destinations[index].$1);
    }
  }

  void _start(DragStartDetails details) {
    _position.stop();
    _dragging = true;
    if (_selected < 0) {
      _position.value = ((details.localPosition.dx - 7) / _segmentWidth - .5)
          .clamp(0.0, widget.destinations.length - 1.0);
    }
    _grabOffset =
        details.localPosition.dx - 7 - (_position.value + .5) * _segmentWidth;
  }

  void _drag(DragUpdateDetails details) {
    if (!_dragging) return;
    final raw =
        (details.localPosition.dx - 7 - _grabOffset) / _segmentWidth - .5;
    final last = widget.destinations.length - 1.0;
    // Gentle resistance at the ends, without moving the labels or hit areas.
    _position.value = raw < 0
        ? -math.min(.12, -raw * .15)
        : raw > last
        ? last + math.min(.12, (raw - last) * .15)
        : raw;
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
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
            _segmentWidth =
                (constraints.maxWidth - 6) / widget.destinations.length;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
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
              onHorizontalDragCancel: () {
                _dragging = false;
                _settle(_selected);
              },
              child: Stack(
                children: [
                  AnimatedBuilder(
                    animation: _position,
                    builder: (_, _) => _selected < 0 && !_dragging
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
                              child: TextButton(
                                key: widget.keyFor(widget.destinations[i].$1),
                                onPressed: () => _commit(i),
                                style: TextButton.styleFrom(
                                  foregroundColor: _selected == i
                                      ? CinemaTheme.text
                                      : CinemaTheme.muted,
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
                                ),
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
