import 'package:flutter/material.dart';

/// Short, compositor-friendly TV movement. The system's Reduce Motion wins.
abstract final class CinemaTVMotion {
  static const focus = Duration(milliseconds: 160);
  static const panel = Duration(milliseconds: 180);
  static const page = Duration(milliseconds: 200);
  static const curve = Curves.easeOutCubic;
  static Duration duration(BuildContext context, Duration value) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : value;
}

class CinemaTVPageTransitions extends PageTransitionsBuilder {
  const CinemaTVPageTransitions();
  @override
  Duration get transitionDuration => CinemaTVMotion.page;
  @override
  Duration get reverseTransitionDuration => CinemaTVMotion.focus;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curved = animation.drive(CurveTween(curve: CinemaTVMotion.curve));
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: curved.drive(
          Tween(begin: const Offset(.025, 0), end: Offset.zero),
        ),
        child: child,
      ),
    );
  }
}
