import 'cinema_nas_media.dart';
import 'cinema_sync_session.dart';
import 'cinema_playback_candidates.dart';

/// Resolve through the viewer's own authenticated library and permissions.
/// Never reuse the other account's NAS resource URL or namespace.
Future<CinemaPlaybackCandidate?> resolveCinemaNASPeerPlayback({
  required CinemaSyncMedia media,
  required String namespace,
  required bool Function() isCurrent,
  CinemaNASClient? client,
}) async {
  if (namespace.isEmpty || !isCurrent()) return null;
  final nas = client ?? CinemaNASClient();
  try {
    await nas.call('ensure', {'namespace': namespace});
    if (!isCurrent()) return null;
    final catalog = await nas.call('catalog', {
      'page': 1,
      'library': 0,
      'keyword': media.title,
    });
    if (!isCurrent()) return null;
    for (final row in nasRows(catalog['video_arr']).take(8)) {
      if (!isCurrent()) return null;
      if (![1, 2].contains(nasInt(row['type']))) continue;
      final detail = await nas.call('details', {
        'id': nasInt(row['ug_video_info_id']),
        'library': nasInt(row['media_lib_set_id']),
        'tv': nasInt(row['type']) == 2,
      });
      if (!isCurrent()) return null;
      final title = createCinemaNASTitle(
        namespace: namespace,
        row: row,
        files: nasFiles(detail),
        detail: detail,
      );
      for (var r = 0; r < title.routes.length; r++) {
        for (var e = 0; e < title.routes[r].episodes.length; e++) {
          if (media.matches(title, title.routes[r].episodes[e])) {
            return CinemaPlaybackCandidate(
              title: title,
              source: cinemaNASSource,
              routeIndex: r,
              episodeIndex: e,
            );
          }
        }
      }
    }
  } catch (_) {
    // Permission denial and missing library entries retain source fallback.
  }
  return null;
}
