import 'dart:io';
import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_theme.dart';

/// The enclosing tile keeps the same hit target, focus node and layout.
class CinemaPosterLift extends StatefulWidget {
  const CinemaPosterLift({
    super.key,
    required this.child,
    this.radius = 9,
    this.enabled = true,
  });
  final Widget child;
  final double radius;
  final bool enabled;

  @override
  State<CinemaPosterLift> createState() => _CinemaPosterLiftState();
}

class _CinemaPosterLiftState extends State<CinemaPosterLift> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isMacOS || NakuDevice.isTV) return widget.child;
    final reduced =
        MediaQuery.disableAnimationsOf(context) ||
        CinemaAppearanceScope.of(context).reduceMotion;
    final focused = Focus.maybeOf(context)?.hasPrimaryFocus ?? false;
    final selected = widget.enabled && (_hovered || focused);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: selected ? 1 : 0),
        curve: Curves.easeOutCubic,
        duration: reduced
            ? Duration.zero
            : Duration(milliseconds: selected ? 210 : 180),
        child: RepaintBoundary(child: widget.child),
        builder: (context, amount, child) {
          final radius = BorderRadius.circular(widget.radius);
          return Transform.translate(
            offset: Offset(0, reduced ? 0 : -4.5 * amount),
            transformHitTests: false,
            child: Transform.scale(
              scale: 1 + (reduced ? 0 : .042 * amount),
              transformHitTests: false,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: radius,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: .18 + .22 * amount),
                      blurRadius: 7 + 12 * amount,
                      spreadRadius: -2,
                      offset: Offset(0, 3 + 7 * amount),
                    ),
                    if (amount > 0)
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .29 * amount),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                  ],
                ),
                child: DecoratedBox(
                  position: DecorationPosition.foreground,
                  decoration: BoxDecoration(
                    borderRadius: radius,
                    border: Border.all(
                      color: Colors.white.withValues(
                        alpha: .045 + .21 * amount,
                      ),
                      width: .85,
                    ),
                  ),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
