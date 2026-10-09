import 'dart:async';

import 'package:flutter/material.dart';

/// Keeps catalogue enrichment out of drag, momentum and trackpad scroll frames.
/// This notifier deliberately does not rebuild the scroll view or its children.
class CinemaScrollActivity extends ValueNotifier<bool> {
  CinemaScrollActivity() : super(false);

  Timer? _settle;
  Completer<void>? _idle;

  void begin() {
    _settle?.cancel();
    _idle ??= Completer<void>();
    value = true;
  }

  void end() {
    _settle?.cancel();
    // Trackpad/wheel input can emit multiple short start/end pairs.
    _settle = Timer(const Duration(milliseconds: 120), reset);
  }

  void reset() {
    _settle?.cancel();
    value = false;
    _idle?.complete();
    _idle = null;
  }

  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();

  @override
  void dispose() {
    _settle?.cancel();
    _idle?.complete();
    _idle = null;
    super.dispose();
  }
}

class CinemaScrollActivityScope extends InheritedWidget {
  const CinemaScrollActivityScope({
    super.key,
    required this.activity,
    required super.child,
  });

  final CinemaScrollActivity activity;

  static CinemaScrollActivity? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CinemaScrollActivityScope>()
      ?.activity;

  @override
  bool updateShouldNotify(CinemaScrollActivityScope oldWidget) =>
      activity != oldWidget.activity;
}

/// Only the catalogue's primary viewport controls the enrichment schedule.
class CinemaScrollNotifications extends StatelessWidget {
  const CinemaScrollNotifications({
    super.key,
    required this.activity,
    required this.child,
  });

  final CinemaScrollActivity activity;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.depth != 0) return false;
          if (notification is ScrollStartNotification ||
              notification is ScrollUpdateNotification) {
            activity.begin();
          } else if (notification is ScrollEndNotification) {
            activity.end();
          }
          return false;
        },
        child: CinemaScrollActivityScope(activity: activity, child: child),
      );
}
