import 'cinema_playback_buffer.dart';

/// Optional network work may use spare TV bandwidth only after the current
/// video has both a real wall-clock reserve and sustained playback progress.
/// This never gates opening a stream, initial rendition selection or recovery.
class CinemaTVBackgroundPolicy {
  CinemaTVBackgroundPolicy({
    this.minimumReserve = const Duration(seconds: 30),
    this.stableFor = const Duration(seconds: 8),
    this.progressGap = const Duration(seconds: 3),
  });
  final Duration minimumReserve, stableFor, progressGap;
  Duration? _healthySince, _lastProgressAt, _lastAt, _lastPosition;
  bool allowed = false;

  void reset() {
    allowed = false;
    _healthySince = _lastProgressAt = _lastAt = _lastPosition = null;
  }

  bool update({
    required Duration now,
    required Duration position,
    required Duration bufferedUntil,
    required bool ready,
    required bool playing,
    required bool buffering,
    required bool foreground,
    required bool interacting,
    double rate = 1,
    bool completed = false,
  }) {
    final previousAt = _lastAt, previousPosition = _lastPosition;
    final elapsed = previousAt == null ? Duration.zero : now - previousAt;
    final jump =
        previousPosition != null &&
        (position < previousPosition ||
            (position - previousPosition).inMilliseconds >
                elapsed.inMilliseconds * CinemaPlaybackBufferPolicy(rate).rate +
                    2000);
    if (elapsed.isNegative || jump) reset();
    if (elapsed > progressGap) _healthySince = null;
    if (previousPosition != null && position > previousPosition && !jump) {
      _lastProgressAt = now;
    }
    _lastAt = now;
    _lastPosition = position;
    final reserve = CinemaPlaybackBufferPolicy(
      rate,
    ).remainingSeconds(position, bufferedUntil);
    final eligible =
        ready &&
        playing &&
        !buffering &&
        foreground &&
        !interacting &&
        !completed &&
        reserve >= minimumReserve.inMilliseconds / 1000;
    if (!eligible ||
        _lastProgressAt == null ||
        now - _lastProgressAt! > progressGap) {
      allowed = false;
      _healthySince = null;
      return false;
    }
    _healthySince ??= now;
    return allowed = now - _healthySince! >= stableFor;
  }
}
