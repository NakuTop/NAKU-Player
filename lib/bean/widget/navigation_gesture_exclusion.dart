import 'package:flutter/widgets.dart';

/// A control owns horizontal movement; application page gestures must yield.
class NavigationGestureExclusion extends StatelessWidget {
  const NavigationGestureExclusion({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => MetaData(
    metaData: this,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}
