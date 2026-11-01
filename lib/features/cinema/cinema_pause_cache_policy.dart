import 'dart:async';

/// Short pauses keep their warm cache. A prolonged pause limits additional
/// read-ahead, without shrinking/evicting the user's existing byte budget.
/// Startup and buffering must always be allowed to obtain enough media.
final class CinemaPauseCachePolicy {
  CinemaPauseCachePolicy({
    required this.onChanged,
    this.grace = const Duration(seconds: 30),
  });
  final Future<void> Function(bool conserving) onChanged;
  final Duration grace;
  Timer? _timer;
  Future<void> _tail = Future.value();
  bool conserving = false;
  bool _closed = false;

  void update({
    required bool playing,
    required bool buffering,
    required bool ready,
    required bool backgrounded,
    required bool enabled,
    bool lowPowerMode = false,
  }) {
    if (_closed) return;
    if (!enabled || playing || buffering || !ready) {
      _timer?.cancel();
      _timer = null;
      _set(false);
    } else if (backgrounded || lowPowerMode) {
      _timer?.cancel();
      _timer = null;
      _set(true);
    } else if (!conserving) {
      _timer ??= Timer(grace, () {
        _timer = null;
        _set(true);
      });
    }
  }

  void _set(bool value) {
    if (_closed || value == conserving) return;
    conserving = value;
    _tail = _tail
        .then((_) async {
          if (!_closed && conserving == value) await onChanged(value);
        })
        .catchError((Object _) {
          // Optional cache tuning must not prevent playback. A later transition
          // can recover if an older native bridge rejects a property.
        });
  }

  Future<void> get settled => _tail;
  void close() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
