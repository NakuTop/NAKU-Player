/// A confirmed ad break on the original VOD timeline.
typedef CinemaHlsAdBreak = ({Duration start, Duration end});

List<CinemaHlsAdBreak> cinemaHlsAdBreaks(String manifest) {
  final lines = manifest.split('\n').map((line) => line.trim()).toList();
  if (lines.first != '#EXTM3U' ||
      !lines.contains('#EXT-X-ENDLIST') ||
      lines.any(
        (line) =>
            line.startsWith('#EXT-X-STREAM-INF:') ||
            line.startsWith('#EXT-X-SKIP:') ||
            line == '#EXT-X-I-FRAMES-ONLY',
      )) {
    return const [];
  }
  final breaks = <CinemaHlsAdBreak>[];
  double time = 0;
  double? segment, start, announced;
  bool needsFollowingSegment = false;
  for (final line in lines) {
    if (line == '#EXT-X-CUE-OUT' || line.startsWith('#EXT-X-CUE-OUT:')) {
      if (start != null || segment != null) return const [];
      start = time;
      final value = line.split(':').last.replaceFirst('DURATION=', '');
      announced = line == '#EXT-X-CUE-OUT' ? null : double.tryParse(value);
      if (line.contains(':') &&
          (announced == null || !announced.isFinite || announced <= 0)) {
        return const [];
      }
    } else if (line == '#EXT-X-CUE-IN') {
      if (start == null || segment != null) return const [];
      final length = time - start;
      if (length > 0 &&
          length <= 180 &&
          (announced == null || (length - announced).abs() <= 0.5)) {
        breaks.add((
          start: Duration(microseconds: (start * 1e6).round()),
          end: Duration(microseconds: (time * 1e6).round()),
        ));
        needsFollowingSegment = true;
      }
      start = null;
    } else if (line.startsWith('#EXTINF:')) {
      if (segment != null) return const [];
      segment = double.tryParse(line.substring(8).split(',').first);
      if (segment == null || !segment.isFinite || segment <= 0) return const [];
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      if (segment == null) return const [];
      needsFollowingSegment = false;
      time += segment;
      segment = null;
    }
  }
  if (start != null || segment != null) return const [];
  if (needsFollowingSegment) breaks.removeLast();
  return List.unmodifiable(breaks);
}
