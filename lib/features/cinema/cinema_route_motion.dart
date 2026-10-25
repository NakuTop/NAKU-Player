import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A quiet focus reveal for ordinary Mac pages. Dedicated playback motion stays
/// in the player; the previous page is never translated or blurred.
class CinemaPageTransitionsBuilder extends PageTransitionsBuilder {
  const CinemaPageTransitionsBuilder();
  static const playerRouteName = 'naku-native-player';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 260);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 200);

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.isFirst || route.settings.name == playerRouteName) {
      return child;
    }
    return CinemaRouteMotion(animation: animation, child: child);
  }
}

class CinemaRouteMotion extends StatelessWidget {
  const CinemaRouteMotion({
    super.key,
    required this.animation,
    required this.child,
  });
  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: animation,
    child: RepaintBoundary(child: child),
    builder: (context, child) {
      final reduce = MediaQuery.disableAnimationsOf(context);
      final t = reduce ? 1.0 : Curves.easeOutCubic.transform(animation.value);
      final blur = 7 * (1 - t);
      return ImageFiltered(
        enabled: blur > .01,
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Opacity(opacity: t, child: child),
      );
    },
  );
}
