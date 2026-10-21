import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Audition a short preceding segment, then pause again. The candidate anchor
/// is its adjustable start, not the delayed moment the user pressed Pause.
class CinemaSubtitleReplay extends ChangeNotifier {
  CinemaSubtitleReplay(this.player);
  final Player player;
  Duration? start, end;
  bool listening = false, busy = false;
  String? error;
  Timer? _poll, _timeout;
  double? _originalRate;
  int _generation = 0;
  bool _disposed = false;
  bool _observedStart = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> capture() async {
    await stop();
    final now = player.state.position;
    start = now - const Duration(seconds: 3);
    if (start!.isNegative) start = Duration.zero;
    end = now > const Duration(milliseconds: 200)
        ? now
        : const Duration(seconds: 3);
    error = null;
    _notify();
  }

  Future<void> shift(Duration delta) async {
    if (start == null || end == null) await capture();
    final value = start! + delta;
    start = value.isNegative ? Duration.zero : value;
    if (start! >= end! - const Duration(milliseconds: 150)) {
      start = end! - const Duration(milliseconds: 150);
    }
    await play();
  }

  Future<void> play() async {
    if (busy || _disposed) return;
    if (start == null || end == null) await capture();
    await stop();
    if (_disposed) return;
    final generation = ++_generation;
    busy = true;
    error = null;
    _originalRate = player.state.rate;
    _observedStart = false;
    _notify();
    try {
      await player.setRate(.75);
      if (_disposed || generation != _generation) return;
      await player.seek(start!);
      if (_disposed || generation != _generation) return;
      await player.play();
      if (_disposed || generation != _generation) return;
      listening = true;
      _poll = Timer.periodic(const Duration(milliseconds: 60), (_) {
        if (_disposed || generation != _generation) return;
        final current = player.state.position;
        if (current < end! - const Duration(milliseconds: 100)) {
          _observedStart = true;
        }
        if (_observedStart && current >= end!) unawaited(stop());
      });
      _timeout = Timer(const Duration(seconds: 12), () => unawaited(stop()));
    } catch (_) {
      error = '回听未能开始，请确认影片可以播放后重试';
      await stop();
    } finally {
      if (generation == _generation) busy = false;
      _notify();
    }
  }

  Future<void> stop() async {
    ++_generation;
    _poll?.cancel();
    _timeout?.cancel();
    _poll = _timeout = null;
    final rate = _originalRate;
    _originalRate = null;
    final ownedPlayback = listening || rate != null;
    listening = busy = false;
    if (ownedPlayback) {
      try {
        await player.pause();
      } catch (_) {
        /* Media may have changed. */
      }
      if (rate != null) {
        try {
          await player.setRate(rate);
        } catch (_) {
          /* Media may have changed. */
        }
      }
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}
