import 'dart:async';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import '../cinema_models.dart';
import '../cinema_playback_candidates.dart';
import '../cinema_sync_session.dart';

CinemaTitle cinemaAnimeSyncTitle(
  BangumiItem subject,
  String episodeName, {
  String url = '',
}) => CinemaTitle(
  id: '${subject.id}',
  sourceId: 'bangumi',
  title: subject.nameCn.isNotEmpty ? subject.nameCn : subject.name,
  year: subject.airDate.length >= 4 ? subject.airDate.substring(0, 4) : '',
  category: '动漫',
  routes: [
    CinemaRoute(
      name: 'anime',
      episodes: [CinemaEpisode(name: episodeName, url: url)],
    ),
  ],
);

/// Uses only Kazumi's anime rules. Search results must match a Bangumi alias
/// exactly, and the episode is selected by its label, never array index.
Future<OnlineVideoPlaybackArgs?> resolveCinemaAnimeInvitation({
  required CinemaSyncMedia media,
  required List<Plugin> plugins,
  required bool Function() isCurrent,
  int positionSeconds = 0,
  Future<BangumiItem?> Function(int)? loadSubject,
}) async {
  final id = media.animeId;
  if (id == null || !isCurrent()) return null;
  final subject = await (loadSubject ?? BangumiApi.getBangumiInfoByID)(id);
  if (subject == null || !isCurrent()) return null;
  String key(String text) => text.toLowerCase().replaceAll(
    RegExp(r'[\s\p{P}\p{S}]', unicode: true),
    '',
  );
  final aliases = [
    subject.nameCn,
    subject.name,
    ...subject.alias,
  ].where((s) => s.trim().isNotEmpty).toSet();
  final exact = aliases.map(key).toSet();
  final anchor = cinemaAnimeSyncTitle(subject, media.episodeName);
  const source = CinemaSource(
    id: 'bangumi',
    name: '动漫',
    kind: CinemaSourceKind.kazumi,
    url: '',
  );
  final current = CinemaPlaybackCandidate(
    title: anchor,
    source: source,
    routeIndex: 0,
    episodeIndex: 0,
  );
  final token = RuleCancelToken();
  final deadline = Timer(const Duration(seconds: 40), token.cancel);
  try {
    for (final plugin in plugins.take(8)) {
      for (final alias in aliases.take(2)) {
        if (!isCurrent() || token.isCancelled) return null;
        try {
          final result = await plugin.queryBangumi(
            alias,
            shouldRethrow: true,
            cancelToken: token,
          );
          for (final match
              in result.data
                  .where((s) => exact.contains(key(s.name)))
                  .take(2)) {
            final roads = await plugin.queryChapterRoads(
              match.src,
              cancelToken: token,
            );
            if (!isCurrent() || token.isCancelled) return null;
            for (var r = 0; r < roads.length; r++) {
              final road = roads[r];
              final target = anchor.copyWith(
                routes: [
                  CinemaRoute(
                    name: road.name,
                    episodes: [
                      for (var i = 0; i < road.data.length; i++)
                        CinemaEpisode(
                          name: i < road.identifier.length
                              ? road.identifier[i]
                              : '',
                          url: plugin.buildFullUrl(road.data[i]),
                        ),
                    ],
                  ),
                ],
              );
              final episode = cinemaMatchPlaybackEpisode(
                current: current,
                target: target,
                routeIndex: 0,
              );
              if (episode == null) continue;
              return OnlineVideoPlaybackArgs(
                bangumiItem: subject,
                plugin: plugin,
                title: match.name,
                src: match.src,
                roads: roads,
                initialEpisode: episode + 1,
                initialRoad: r,
                initialOffset: positionSeconds,
              );
            }
          }
        } catch (_) {
          /* Try the next installed anime rule. */
        }
      }
    }
    return null;
  } finally {
    deadline.cancel();
    token.cancel();
  }
}
