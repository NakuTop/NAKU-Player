import 'package:flutter/material.dart';

/// A sidebar destination becomes usable at its final position immediately.
/// Keep one isolated pane: no whole-grid movement, opacity or outgoing copy.
/// Local Material hover/selection feedback remains independent of navigation.
class CinemaPaneTransition extends StatelessWidget {
  const CinemaPaneTransition({
    super.key,
    required this.destination,
    required this.child,
  });

  final Object destination;
  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: RepaintBoundary(key: ValueKey(destination), child: child),
  );
}
