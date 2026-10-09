import 'package:flutter/material.dart';

/// The gesture arena delays a single tap until a possible double tap is ruled
/// out. Controls remain descendants, so clicking a button never toggles playback.
class CinemaVideoGestures extends StatelessWidget {
  const CinemaVideoGestures({
    super.key,
    required this.child,
    required this.onTogglePlayback,
    required this.onToggleFullscreen,
  });
  final Widget child;
  final VoidCallback onTogglePlayback, onToggleFullscreen;
  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTogglePlayback,
    onDoubleTap: onToggleFullscreen,
    child: child,
  );
}
