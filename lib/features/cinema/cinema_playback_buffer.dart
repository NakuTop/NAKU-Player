/// Cache durations are media seconds; prefetch decisions use wall-clock seconds.
class CinemaPlaybackBufferPolicy {
  CinemaPlaybackBufferPolicy(double rate)
    : rate = rate.isFinite && rate > 0 ? rate.clamp(.25, 8).toDouble() : 1;
  final double rate;
  double remainingSeconds(Duration position, Duration bufferedUntil) =>
      ((bufferedUntil - position).inMilliseconds / 1000 / rate).clamp(
        0,
        double.infinity,
      );
  bool mayWarmNext(Duration position, Duration bufferedUntil) =>
      remainingSeconds(position, bufferedUntil) >= 20;
  int prefetchSeconds(int base) =>
      (base * rate.clamp(1, 8)).ceil().clamp(base, 900);

  /// A rate change may overlap a slow pause/resume write. Only the pause
  /// controller owns these time horizons after player initialization.
  Map<String, String> rateProperties(int bufferBytes) =>
      nativeProperties(bufferBytes)
        ..remove('cache-secs')
        ..remove('demuxer-readahead-secs');

  Map<String, String> nativeProperties(
    int bufferBytes, {
    bool conserving = false,
  }) {
    final total = bufferBytes.clamp(2 * 1024 * 1024, 256 * 1024 * 1024);
    final backwards = (total ~/ 16).clamp(512 * 1024, 16 * 1024 * 1024);
    // Keep reading while paused and playing until the byte budget or EOF.
    // A 30-second horizon used to make a large selected cache mostly unused.
    final seconds = conserving ? 1 : 86400;
    final refillSeconds = (5 * rate).ceil().clamp(3, 20);
    return {
      'cache': 'yes',
      'cache-secs': '$seconds',
      'demuxer-readahead-secs': '$seconds',
      'demuxer-max-bytes': '$total',
      'demuxer-max-back-bytes': '$backwards',
      'demuxer-hysteresis-secs': '0',
      'demuxer-thread': 'yes',
      'cache-pause': 'yes',
      'cache-pause-initial': 'yes',
      'cache-pause-wait': '$refillSeconds',
    };
  }
}
