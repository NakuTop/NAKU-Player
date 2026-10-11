import 'package:kazumi/services/video_source/video_source_format.dart';
import 'cinema_models.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

bool cinemaUsesDirectMedia(
  CinemaSource source,
  CinemaRoute route,
  CinemaEpisode episode,
) =>
    source.kind == CinemaSourceKind.direct ||
    episode.isDirect ||
    (source.kind == CinemaSourceKind.maccms &&
        RegExp(
          r'm3u8|\bmp4\b|\bhls\b|\bdirect\b',
          caseSensitive: false,
        ).hasMatch(route.name));

/// Use the same URL, format hint and headers for playback and offline queues.
Future<({String url, VideoSourceFormat format, Map<String, String> headers})>
resolveCinemaMedia({
  required CinemaSource source,
  required CinemaRoute route,
  required CinemaEpisode episode,
  required Future<VideoSource> Function(String url, bool legacy) resolve,
}) async {
  final page = requireHttpUrl(episode.url);
  final headers = Map<String, String>.of(source.headers);
  if (cinemaUsesDirectMedia(source, route, episode)) {
    return (
      url: page.toString(),
      headers: headers,
      format: page.path.toLowerCase().endsWith('.m3u8')
          ? VideoSourceFormat.hls
          : VideoSourceFormat.auto,
    );
  }
  final result = await resolve(
    page.toString(),
    source.rule?['useLegacyParser'] == true,
  );
  if (!headers.keys.any((key) => key.toLowerCase() == 'referer')) {
    headers['Referer'] = page.toString();
  }
  return (
    url: requireHttpUrl(result.url).toString(),
    format: result.format,
    headers: headers,
  );
}
