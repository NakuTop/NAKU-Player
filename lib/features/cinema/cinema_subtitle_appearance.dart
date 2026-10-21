import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Flutter renders media-kit text subtitles. Configure that renderer rather
/// than setting mpv font properties which do not affect the Flutter overlay.
class CinemaSubtitleAppearance {
  const CinemaSubtitleAppearance({this.fontSize = 32, this.bottom = 24});
  factory CinemaSubtitleAppearance.from(Object? value) {
    final map = value is Map ? value : const {};
    double number(String key, double fallback, double min, double max) {
      final raw = map[key];
      return raw is num && raw.isFinite
          ? raw.toDouble().clamp(min, max)
          : fallback;
    }

    return CinemaSubtitleAppearance(
      fontSize: number('fontSize', 32, 18, 64),
      bottom: number('bottom', 24, 0, 160),
    );
  }
  final double fontSize, bottom;
  Map<String, double> toJson() => {'fontSize': fontSize, 'bottom': bottom};
  SubtitleViewConfiguration get configuration => configurationFor();
  SubtitleViewConfiguration configurationFor({bool visible = true}) =>
      SubtitleViewConfiguration(
        visible: visible,
        style: const SubtitleViewConfiguration().style.copyWith(
          fontSize: fontSize,
        ),
        padding: EdgeInsets.fromLTRB(16, 0, 16, bottom),
      );
}
