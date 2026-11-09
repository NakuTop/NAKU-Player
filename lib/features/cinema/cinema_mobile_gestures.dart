import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Phone gestures share an arena with the real buttons and seek bar. A hold
/// never starts playback, and every interruption releases its temporary rate.
class CinemaMobileGestures extends StatefulWidget {
  const CinemaMobileGestures({
    super.key,
    required this.child,
    required this.onTap,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onHoldStart,
    required this.onHoldEnd,
    this.holdLabel = '2×',
    this.controlsInsets = EdgeInsets.zero,
  });
  final Widget child;
  final VoidCallback onTap, onTogglePlayback, onHoldEnd;
  final ValueChanged<int> onSeek;
  final bool Function() onHoldStart;
  final String holdLabel;
  final EdgeInsets controlsInsets;
  @override
  State<CinemaMobileGestures> createState() => _CinemaMobileGesturesState();
}

class _CinemaMobileGesturesState extends State<CinemaMobileGestures>
    with WidgetsBindingObserver {
  double _doubleX = .5;
  bool _holding = false;
  String? _feedback;
  Timer? _feedbackTimer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  bool _allowed(Offset position) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final point = box.globalToLocal(position);
    return point.dy >= widget.controlsInsets.top &&
        point.dy < box.size.height - widget.controlsInsets.bottom;
  }

  void _show(String text) {
    _feedbackTimer?.cancel();
    setState(() => _feedback = text);
    _feedbackTimer = Timer(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  void _end() {
    if (!_holding) return;
    _holding = false;
    widget.onHoldEnd();
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _end();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _feedbackTimer?.cancel();
    if (_holding) widget.onHoldEnd();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      TapGestureRecognizer:
          GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
            TapGestureRecognizer.new,
            (recognizer) => recognizer.onTap = widget.onTap,
          ),
      _MobileDoubleTap: GestureRecognizerFactoryWithHandlers<_MobileDoubleTap>(
        _MobileDoubleTap.new,
        (recognizer) {
          recognizer.allowed = _allowed;
          recognizer.onDoubleTapDown = (details) {
            final box = context.findRenderObject() as RenderBox;
            _doubleX =
                box.globalToLocal(details.globalPosition).dx / box.size.width;
          };
          recognizer.onDoubleTap = () {
            if (_doubleX < .33) {
              widget.onSeek(-10);
              _show('后退 10 秒');
            } else if (_doubleX > .67) {
              widget.onSeek(10);
              _show('前进 10 秒');
            } else {
              widget.onTogglePlayback();
            }
          };
        },
      ),
      _MobileLongPress: GestureRecognizerFactoryWithHandlers<_MobileLongPress>(
        _MobileLongPress.new,
        (recognizer) {
          recognizer.allowed = _allowed;
          recognizer.onLongPressStart = (_) {
            _holding = widget.onHoldStart();
            if (_holding) setState(() {});
          };
          recognizer.onLongPressEnd = (_) => _end();
          recognizer.onLongPressCancel = _end;
        },
      ),
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_holding || _feedback != null)
          IgnorePointer(
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xB3222225),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Text(
                    _holding ? '${widget.holdLabel} 快进中' : _feedback!,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _MobileDoubleTap extends DoubleTapGestureRecognizer {
  bool Function(Offset)? allowed;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (allowed?.call(event.position) ?? false) && super.isPointerAllowed(event);
}

class _MobileLongPress extends LongPressGestureRecognizer {
  _MobileLongPress() : super(duration: const Duration(milliseconds: 450));
  bool Function(Offset)? allowed;
  @override
  bool isPointerAllowed(PointerDownEvent event) =>
      (allowed?.call(event.position) ?? false) && super.isPointerAllowed(event);
}

/// Serializes rapid press/release against the asynchronous playback engine.
/// Only the rate is borrowed; pause, backgrounding and source changes retain
/// ownership of playing state.
class CinemaMobileHoldRate {
  CinemaMobileHoldRate({
    required this.isPlaying,
    required this.readRate,
    required this.setRate,
    this.rate = 2,
  });
  final bool Function() isPlaying;
  final double Function() readRate;
  final Future<void> Function(double) setRate;
  final double rate;
  Future<void> _pending = Future.value();
  double? _original;
  bool _closed = false, _releasing = false;
  bool start() {
    if (_closed || _original != null || !isPlaying()) return false;
    _original = readRate();
    _queue(rate > _original! ? rate : _original!);
    return true;
  }

  void _queue(double value) {
    _pending = _pending.then((_) => setRate(value)).catchError((Object _) {});
  }

  Future<void> release() {
    if (!_releasing && _original != null) {
      _releasing = true;
      _queue(_original!);
      _pending = _pending.then((_) {
        _original = null;
        _releasing = false;
      });
    }
    return _pending;
  }

  Future<void> close() {
    _closed = true;
    return release();
  }
}
