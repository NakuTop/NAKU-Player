import 'package:flutter/material.dart';

/// One live destination, with a small incoming movement. Keeping an outgoing
/// poster grid would paint both translucent pages and retain stale callbacks.
class CinemaPaneTransition extends StatefulWidget {
  const CinemaPaneTransition({
    super.key,
    required this.destination,
    required this.child,
  });

  final Object destination;
  final Widget child;

  @override
  State<CinemaPaneTransition> createState() => _CinemaPaneTransitionState();
}

class _CinemaPaneTransitionState extends State<CinemaPaneTransition>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    value: 1,
  );
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion) _controller.value = 1;
  }

  @override
  void didUpdateWidget(CinemaPaneTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.destination != widget.destination) {
      if (_reduceMotion) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: _controller,
      // Animation frames only update the transform, never the poster grid.
      child: RepaintBoundary(
        key: ValueKey(widget.destination),
        child: widget.child,
      ),
      builder: (context, child) => Transform.translate(
        offset: Offset(
          0,
          6 * (1 - Curves.easeOutCubic.transform(_controller.value)),
        ),
        child: child,
      ),
    ),
  );
}
