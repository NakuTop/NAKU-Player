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
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: CinemaFilterBar(
              value: filters,
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
                          key: const PageStorageKey('cinema-history-scroll'),
                          padding: const EdgeInsets.all(28),
                          itemCount: records.length,
                          separatorBuilder: (_, _) => const Divider(height: 25),
                          itemBuilder: (context, index) {
                            final entry = records[index];
                            final movie = entry.cinema, animation = entry.anime;
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
                              child: ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: SizedBox(
                                  width: 48,
                                  child: poster(title, 48, 68),
                                ),
                                title: Text(title.title),
                                subtitle: Text(
                                  '${animation == null ? sourceName(title.sourceId) : '动漫 · ${animation.adapterName}'}  ·  $episode  ·  ${seconds ~/ 60} 分钟',
                                ),
                                trailing: const Icon(
                                  Icons.play_circle_outline_rounded,
                                  color: CinemaTheme.copper,
                                ),
                                onTap: () => movie == null
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
                    padding: const EdgeInsets.all(28),
                    itemCount: movies.length + favorites.length,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 190,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 24,
                          childAspectRatio: .51,
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
}
