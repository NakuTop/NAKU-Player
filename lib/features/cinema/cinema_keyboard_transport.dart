import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Temporary transport belongs to one media instance. Commands are serialized
/// so a late speed change cannot win over key release or affect the next video.
class CinemaKeyboardTransport extends ChangeNotifier {
  CinemaKeyboardTransport({
    required this.player,
    required this.setTemporaryRate,
    required this.skipSeconds,
    this.forwardRate = 2,
    this.onSeek,
    this.canResume,
  });

  final Player player;
  final Future<void> Function(double) setTemporaryRate;
  final int skipSeconds;
  final double forwardRate;
  final VoidCallback? onSeek;
  final bool Function()? canResume;
  int _direction = 0, _revision = 0;
  bool _held = false, _closed = false, _wasPlaying = false, _seekBusy = false;
  double _previousRate = 1;
  Timer? _timer;
  final _clock = Stopwatch();
  Duration _anchor = Duration.zero;
  Future<void> _tail = Future<void>.value();

  String get label => !_held
      ? ''
      : _direction > 0
      ? '$forwardRate× 快进'
      : '2× 回退';

  Future<void> press(int direction) async {
    if (_closed || _direction == direction) return;
    await release(cancel: true);
    if (_closed) return;
    _direction = direction;
    _held = false;
    _previousRate = player.state.rate;
    _wasPlaying = player.state.playing;
  }

  Future<void> hold(int direction) {
    if (_closed || _direction != direction || _held) return Future.value();
    _held = true;
    final revision = ++_revision;
    notifyListeners();
    return _enqueue(() async {
      if (!_current(revision)) return;
      if (direction > 0) {
        await setTemporaryRate(forwardRate);
        if (_current(revision) && !_wasPlaying) await player.play();
      } else {
        await player.pause();
        if (!_current(revision)) return;
        _anchor = player.state.position;
        _clock
          ..reset()
          ..start();
        _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (!_current(revision) || _seekBusy) return;
          _seekBusy = true;
          unawaited(
            _enqueue(() async {
              try {
                if (!_current(revision)) return;
                final micros =
                    (_anchor.inMicroseconds - _clock.elapsedMicroseconds * 2)
                        .clamp(0, _anchor.inMicroseconds);
                onSeek?.call();
                await player.seek(Duration(microseconds: micros));
              } finally {
                _seekBusy = false;
              }
            }),
          );
        });
      }
    });
  }

  bool _current(int revision) => !_closed && _held && revision == _revision;

  Future<void> release({bool cancel = false}) {
    if (_direction == 0) return _tail;
    final direction = _direction, held = _held;
    final previousRate = _previousRate, wasPlaying = _wasPlaying;
    _direction = 0;
    _held = false;
    ++_revision;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    if (!_closed) notifyListeners();
    return _enqueue(() async {
      if (held) {
        if (direction > 0) await setTemporaryRate(previousRate);
        if (wasPlaying && (canResume?.call() ?? true)) {
          await player.play();
        } else {
          await player.pause();
        }
      } else if (!cancel && !_closed) {
        final state = player.state;
        var micros =
            state.position.inMicroseconds + direction * skipSeconds * 1000000;
        micros = micros.clamp(
          0,
          state.duration.inMicroseconds > 0
              ? state.duration.inMicroseconds
              : micros.abs(),
        );
        onSeek?.call();
        await player.seek(Duration(microseconds: micros));
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _tail.catchError((Object _) {}).then((_) => action());
    // A backend closing during focus loss must not produce an unhandled future.
    _tail = next.catchError((Object _) {});
    return _tail;
  }

  Future<void> close() async {
    if (_closed) return;
    final ending = release(cancel: true);
    _closed = true;
    await ending;
    super.dispose();
  }
}
