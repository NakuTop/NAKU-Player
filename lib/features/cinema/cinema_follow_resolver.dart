import 'dart:async';

import 'cinema_models.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_repository.dart';
import 'cinema_sync_session.dart';

/// Resolve peer metadata against sources the local user already enabled.
/// Peer messages never choose an endpoint or provide a media URL.
Future<CinemaPlaybackCandidate?> resolveCinemaPeerPlayback({
  required CinemaSyncMedia media,
  required Iterable<CinemaSource> sources,
  required CinemaRepository repository,
  required bool Function() isCurrent,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final choices = sources.where((source) => source.enabled).toList();
  if (choices.isEmpty || !isCurrent()) return null;
  final result = Completer<CinemaPlaybackCandidate?>();
  var cursor = 0;
  var active = choices.length.clamp(1, 3);
  bool current() => !result.isCompleted && isCurrent();

  Future<void> worker() async {
    try {
      while (current() && cursor < choices.length) {
        final source = choices[cursor++];
        try {
          final page = await repository
              .search(source, media.title)
              .timeout(timeout);
          if (!current()) break;
          for (final title in page.items) {
            if (!current()) break;
            // Search metadata can omit episode routes; fetch details only for
            // a plausible work, avoiding unrelated provider entries.
            final anchor = CinemaTitle(
              id: media.identity,
              sourceId: 'sync-peer',
              title: media.title,
              year: media.year,
              category: media.category,
              doubanId: media.doubanId,
            );
            if (title.sourceId != source.id ||
                !cinemaSamePlaybackWork(anchor, title)) {
              continue;
            }
            final detail = title.routes.isNotEmpty
                ? title
                : await repository.detail(source, title).timeout(timeout);
            if (!current()) break;
            if (detail.sourceId != source.id) continue;
            for (var route = 0; route < detail.routes.length; route++) {
              final episodes = detail.routes[route].episodes;
              final matches = [
                for (var episode = 0; episode < episodes.length; episode++)
                  if (media.matches(detail, episodes[episode])) episode,
              ];
              if (matches.length != 1) continue;
              final episode = matches.single;
              // The local source must supply a usable URL even when peer
              // metadata matches. The player retains its normal URL checks.
              try {
                requireHttpUrl(episodes[episode].url);
              } catch (_) {
                continue;
              }
              result.complete(
                CinemaPlaybackCandidate(
                  title: detail,
                  source: source,
                  routeIndex: route,
                  episodeIndex: episode,
                ),
              );
              return;
            }
          }
        } catch (_) {
          // One unavailable provider doesn't delay another successful worker.
        }
      }
    } finally {
      active--;
      if (active == 0 && !result.isCompleted) result.complete(null);
    }
  }

  for (var i = 0; i < choices.length.clamp(1, 3); i++) {
    unawaited(worker());
  }
  return result.future.timeout(
    timeout,
    onTimeout: () {
      if (!result.isCompleted) result.complete(null);
      return null;
    },
  );
}
