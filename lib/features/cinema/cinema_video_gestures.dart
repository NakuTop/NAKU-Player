import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

/// The gesture arena delays a single tap until a possible double tap is ruled
/// out. Controls remain descendants, so clicking a button never toggles playback.
class CinemaVideoGestures extends StatelessWidget {
  const CinemaVideoGestures({
    super.key,
    required this.child,
    required this.onTogglePlayback,
    required this.onToggleFullscreen,
    this.controlsInsets = EdgeInsets.zero,
  });
  final Widget child;
  final VoidCallback onTogglePlayback, onToggleFullscreen;
  final EdgeInsets controlsInsets;
  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (recognizer) => recognizer.onTap = onTogglePlayback,
          ),
      _VideoDoubleTap: GestureRecognizerFactoryWithHandlers<_VideoDoubleTap>(
        _VideoDoubleTap.new,
        (recognizer) {
          recognizer.onDoubleTap = onToggleFullscreen;
          recognizer.allowed = (position) {
            final box = context.findRenderObject();
            if (box is! RenderBox || !box.hasSize) return false;
            final point = box.globalToLocal(position);
            return point.dy >= controlsInsets.top &&
                point.dy < box.size.height - controlsInsets.bottom;
          };
        },
      ),
    },
    child: child,
  );
}

/// Toolbar taps must not wait in the video's double-click gesture arena.
class _VideoDoubleTap extends DoubleTapGestureRecognizer {
  bool Function(Offset)? allowed;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (allowed?.call(event.position) ?? false) && super.isPointerAllowed(event);
}
