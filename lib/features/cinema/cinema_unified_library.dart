import 'package:flutter/material.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/bean/card/bangumi_card.dart';
import 'anime/cinema_anime_library.dart';
import 'cinema_filters.dart';
import 'cinema_library_actions.dart';
import 'cinema_models.dart';
import 'cinema_store.dart';
import 'cinema_theme.dart';

class CinemaUnifiedLibrary extends StatelessWidget {
  const CinemaUnifiedLibrary({
    super.key,
    required this.store,
    required this.anime,
    required this.history,
    required this.filters,
    required this.onFilters,
    required this.titleCard,
    required this.poster,
    required this.onCinemaPlay,
    required this.onAnimePlay,
    required this.sourceName,
  });
  final CinemaStore store;
  final CinemaAnimeLibrary? anime;
  final bool history;
  final CinemaFilters filters;
  final ValueChanged<CinemaFilters> onFilters;
  final Widget Function(CinemaTitle) titleCard;
  final Widget Function(CinemaTitle, double?, double?) poster;
  final ValueChanged<CinemaHistory> onCinemaPlay;
  final ValueChanged<History> onAnimePlay;
  final String Function(String) sourceName;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([store, ?anime]),
    builder: (context, _) {
      final animeFavorites = anime?.favorites ?? [];
      final animeHistory = anime?.history ?? [];
      final items = history
          ? [
              ...store.history.map((h) => h.title),
              ...animeHistory.map((h) => animeLibraryTitle(h.bangumiItem)),
            ]
          : [
              ...store.favorites,
              ...animeFavorites.map((h) => animeLibraryTitle(h.bangumiItem)),
            ];
      final movies = store.favorites.where(filters.matches).toList();
      final favorites = animeFavorites
          .where((h) => filters.matches(animeLibraryTitle(h.bangumiItem)))
          .toList();
      final records =
          <({CinemaHistory? cinema, History? anime, DateTime time})>[
            for (final h in store.history)
              if (filters.matches(h.title))
                (cinema: h, anime: null, time: h.updatedAt),
            for (final h in animeHistory)
              if (filters.matches(animeLibraryTitle(h.bangumiItem)))
                (cinema: null, anime: h, time: h.lastWatchTime),
          ]..sort((a, b) => b.time.compareTo(a.time));
      return LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 620;
          final inset = compact ? 18.0 : 32.0;
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                child: CinemaFilterBar(
                  value: filters,
                  compact: true,
                  items: items,
                  onChanged: onFilters,
                  scope: history ? '电影、剧集与动漫历史' : '电影、剧集与动漫收藏',
                ),
              ),
              Expanded(
                child: history
                    ? records.isEmpty
                          ? const Center(child: Text('暂无观看记录'))
                          : ListView.separated(
                              key: const PageStorageKey(
                                'cinema-history-scroll',
                              ),
                              padding: EdgeInsets.fromLTRB(
                                inset,
                                14,
                                inset,
                                32,
                              ),
                              itemCount: records.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final entry = records[index];
                                final movie = entry.cinema,
                                    animation = entry.anime;
                                final title =
                                    movie?.title ??
                                    animeLibraryTitle(animation!.bangumiItem);
                                final episode = movie != null
                                    ? '第 ${movie.episodeIndex + 1} 集'
                                    : animation!.lastWatchEpisodeName.isEmpty
                                    ? '第 ${animation.lastWatchEpisode} 话'
                                    : animation.lastWatchEpisodeName;
                                final seconds =
                                    movie?.positionSeconds ??
                                    animation!
                                        .progresses[animation.lastWatchEpisode]
                                        ?.progress
                                        .inSeconds ??
                                    0;
                                return CinemaLibraryActions(
                                  key: ValueKey('history-actions:${title.key}'),
                                  store: store,
                                  title: title,
                                  history: true,
                                  removeOverride: animation == null
                                      ? null
                                      : () => anime!.removeHistory(
                                          animation.bangumiItem,
                                        ),
                                  child: _LibraryHistoryRow(
                                    title: title.title,
                                    cover: poster(
                                      title,
                                      compact ? 66 : 82,
                                      compact ? 94 : 116,
                                    ),
                                    coverWidth: compact ? 66 : 82,
                                    episode: episode,
                                    source: animation == null
                                        ? sourceName(title.sourceId)
                                        : '动漫 · ${animation.adapterName}',
                                    position: seconds,
                                    duration: movie?.durationSeconds ?? 0,
                                    onPlay: () => movie == null
                                        ? onAnimePlay(animation!)
                                        : onCinemaPlay(movie),
                                  ),
                                );
                              },
                            )
                    : movies.isEmpty && favorites.isEmpty
                    ? const Center(child: Text('暂无收藏'))
                    : GridView.builder(
                        key: const PageStorageKey('cinema-favorites-scroll'),
                        padding: EdgeInsets.fromLTRB(inset, 14, inset, 32),
                        itemCount: movies.length + favorites.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              crossAxisSpacing: 22,
                              mainAxisSpacing: 28,
                              childAspectRatio: .56,
                            ),
                        itemBuilder: (context, index) {
                          if (index < movies.length) {
                            final title = movies[index];
                            return CinemaLibraryActions(
                              key: ValueKey('favorite-actions:${title.key}'),
                              store: store,
                              title: title,
                              child: titleCard(title),
                            );
                          }
                          final entry = favorites[index - movies.length];
                          final title = animeLibraryTitle(entry.bangumiItem);
                          return CinemaLibraryActions(
                            key: ValueKey('favorite-actions:${title.key}'),
                            store: store,
                            title: title,
                            removeOverride: () =>
                                anime!.removeFavorite(entry.bangumiItem),
                            child: BangumiCardV(
                              bangumiItem: entry.bangumiItem,
                              enableHero: false,
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      );
    },
  );
}

class _LibraryHistoryRow extends StatelessWidget {
  const _LibraryHistoryRow({
    required this.title,
    required this.cover,
    required this.coverWidth,
    required this.episode,
    required this.source,
    required this.position,
    required this.duration,
    required this.onPlay,
  });
  final String title, episode, source;
  final Widget cover;
  final double coverWidth;
  final int position, duration;
  final VoidCallback onPlay;

  String get _time {
    final value = Duration(seconds: position);
    final minutes = value.inMinutes;
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Row(
          children: [
            SizedBox(
              width: coverWidth,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: cover,
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '$episode · $_time',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CinemaTheme.text,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Tooltip(
                    message: source,
                    child: Text(
                      source,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CinemaTheme.muted,
                      ),
                    ),
                  ),
                  if (duration > 0) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: 240,
                      child: LinearProgressIndicator(
                        value: (position / duration).clamp(0.0, 1.0),
                        minHeight: 2,
                        color: const Color(0xBFFFFFFF),
                        backgroundColor: const Color(0x18FFFFFF),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '继续播放',
              onPressed: onPlay,
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: CinemaTheme.text,
              ),
              style: IconButton.styleFrom(
                backgroundColor: const Color(0x10FFFFFF),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
