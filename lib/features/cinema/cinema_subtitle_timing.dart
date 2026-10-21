/// A subtitle timestamp maps to media time as source * scale + offset.
/// Positive offset displays captions later. Scale handles gradual FPS drift;
/// different edits with missing scenes still require a matching subtitle cut.
class CinemaSubtitleTiming {
  const CinemaSubtitleTiming({this.scale = 1, this.offsetSeconds = 0});
  final double scale, offsetSeconds;

  Duration mediaTime(Duration source) => Duration(
    microseconds: (source.inMicroseconds * scale + offsetSeconds * 1000000)
        .round(),
  );
  Duration subtitleTime(Duration media) => Duration(
    microseconds: ((media.inMicroseconds - offsetSeconds * 1000000) / scale)
        .round(),
  );

  CinemaSubtitleTiming withOffset(double seconds) {
    if (!seconds.isFinite || seconds.abs() > 21600) {
      throw const FormatException('字幕偏移应在前后 6 小时以内');
    }
    return CinemaSubtitleTiming(scale: scale, offsetSeconds: seconds);
  }

  CinemaSubtitleTiming align({
    required Duration subtitle,
    required Duration media,
  }) => withOffset(
    (media.inMicroseconds - subtitle.inMicroseconds * scale) / 1000000,
  );

  factory CinemaSubtitleTiming.fromAnchors({
    required Duration firstSubtitle,
    required Duration firstMedia,
    required Duration secondSubtitle,
    required Duration secondMedia,
  }) {
    final sourceSpan = secondSubtitle - firstSubtitle;
    final mediaSpan = secondMedia - firstMedia;
    if (sourceSpan.inMilliseconds < 30000 || mediaSpan.inMilliseconds < 30000) {
      throw const FormatException('第二处对白须在第一处之后至少 30 秒，间隔越长越适合校正漂移');
    }
    final scale = mediaSpan.inMicroseconds / sourceSpan.inMicroseconds;
    if (!scale.isFinite || scale < .5 || scale > 2) {
      throw const FormatException('两处对白差异过大，请检查是否选中了同一集、同一版本');
    }
    return CinemaSubtitleTiming(
      scale: scale,
    ).align(subtitle: firstSubtitle, media: firstMedia);
  }
}
