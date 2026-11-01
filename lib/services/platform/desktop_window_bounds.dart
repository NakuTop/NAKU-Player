import 'dart:math' as math;
import 'dart:ui';

import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

bool _usable(Rect rect) =>
    rect.left.isFinite &&
    rect.top.isFinite &&
    rect.width.isFinite &&
    rect.height.isFinite &&
    rect.width > 0 &&
    rect.height > 0;

/// Screen frames are logical work areas, excluding the Dock and menu bar.
/// Preserve the original placement when possible, including negative monitors.
Rect clampDesktopWindowBounds(Rect requested, List<Rect> workAreas) {
  final areas = workAreas.where(_usable).toList();
  if (areas.isEmpty) throw ArgumentError('No usable display work area');
  var area = areas.first;
  if (_usable(requested)) {
    var bestOverlap = -1.0;
    var nearest = double.infinity;
    for (final candidate in areas) {
      final intersection = candidate.intersect(requested);
      final overlap = intersection.isEmpty
          ? 0.0
          : intersection.width * intersection.height;
      final distance = (candidate.center - requested.center).distanceSquared;
      if (overlap > bestOverlap ||
          (overlap == bestOverlap && distance < nearest)) {
        area = candidate;
        bestOverlap = overlap;
        nearest = distance;
      }
    }
  }
  final width = math.min(
    _usable(requested) ? requested.width : 1000.0,
    area.width,
  );
  final height = math.min(
    _usable(requested) ? requested.height : 700.0,
    area.height,
  );
  final left = _usable(requested)
      ? requested.left.clamp(area.left, area.right - width)
      : area.center.dx - width / 2;
  final top = _usable(requested)
      ? requested.top.clamp(area.top, area.bottom - height)
      : area.center.dy - height / 2;
  return Rect.fromLTWH(left.toDouble(), top.toDouble(), width, height);
}

/// Re-query screens when leaving PiP: a saved display may have disconnected.
Future<void> restoreDesktopWindowBounds(Rect requested) async {
  List<Rect> workAreas;
  try {
    final displays = await screenRetriever.getAllDisplays();
    workAreas = displays
        .where((display) => display.visiblePosition != null)
        .map(
          (display) =>
              display.visiblePosition! & (display.visibleSize ?? display.size),
        )
        .where(_usable)
        .toList();
  } catch (_) {
    workAreas = const [];
  }
  if (workAreas.isEmpty) {
    // Leave the currently visible PiP geometry usable if display discovery
    // fails. Expanding to the old size could hide its title bar on a small
    // screen. A primary-display query used by center() may still succeed.
    await windowManager.setMinimumSize(const Size(320, 180));
    try {
      await windowManager.center();
    } catch (_) {
      // Preserve the current position rather than applying stale coordinates.
    }
    return;
  }
  final bounds = clampDesktopWindowBounds(requested, workAreas);
  await windowManager.setMinimumSize(
    Size(math.min(800, bounds.width), math.min(600, bounds.height)),
  );
  await windowManager.setBounds(bounds);
}
