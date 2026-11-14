import 'dart:async';

import 'cinema_grouping.dart';
import 'cinema_models.dart';
import 'cinema_media_identity.dart';
import 'cinema_repository.dart';
import 'cinema_seasons.dart';

/// Discover additional compatible variants without blocking the initial detail.
/// Three source requests at a time; errors leave other sources usable.
Stream<List<CinemaTitle>> discoverCinemaWorkSources({
  required CinemaTitle anchor,
  required List<CinemaTitle> known,
  required Iterable<CinemaSource> sources,
  required CinemaRepository repository,
  required bool Function() isCurrent,
  void Function(CinemaSource source, Object error)? onSourceError,
  void Function(CinemaSource source)? onSourceChecked,
  Duration? maxDuration,
}) async* {
  if (anchor.isDirectMedia) return;
  // Some providers catalog verified theatrical films under their ethics label.
  // Only an exact official name and release year can supply the missing kind.
  CinemaTitle classify(CinemaTitle item) {
    if (anchor.sourceId != 'douban-discovery' ||
        anchor.category != '电影' ||
        item.category != '伦理片' ||
        !RegExp(r'^\d{4}$').hasMatch(anchor.year) ||
        item.year != anchor.year ||
        (item.doubanId.isNotEmpty && item.doubanId != anchor.doubanId))
      return item;
    String name(String value) => cinemaGroupedWorkTitleKey(
      value.replaceFirst(RegExp(r'[（(](?:完整版|未删减版)[）)]$'), ''),
      anchor.year,
    );
    final official = {
      name(anchor.title),
      ...cinemaTitleAliases(anchor.aliases).map(name),
    };
    return official.contains(name(item.title))
        ? item.copyWith(
            category: anchor.category,
            doubanId: anchor.doubanId,
            aliases: [
              item.aliases,
              anchor.title,
              anchor.aliases,
            ].where((s) => s.isNotEmpty).join(' / '),
          )
        : item;
  }

  final variants = groupCinemaTitles([
    anchor,
    ...known,
  ]).first.variants.toList();
  final choices = sources
      .where((s) => s.enabled && s.kind == CinemaSourceKind.maccms)
      .toList();
  final end = maxDuration == null ? null : DateTime.now().add(maxDuration);
  for (var offset = 0; offset < choices.length && isCurrent(); offset += 3) {
    if (end != null && !DateTime.now().isBefore(end)) {
      onSourceError?.call(choices[offset], TimeoutException('本轮片源检查已到时限'));
      return;
    }
    final results = await Future.wait(
      choices.skip(offset).take(3).map((source) async {
        final result = <CinemaTitle>[];
        try {
          final perSource = DateTime.now().add(const Duration(seconds: 18));
          final deadline = end != null && end.isBefore(perSource)
              ? end
              : perSource;
          List<CinemaTitle> matches() => groupCinemaTitles([anchor, ...result])
              .first
              .variants
              .where((t) => t.sourceId == source.id && t.key != anchor.key)
              .toList();
          final pages = <String, int>{};
          Object? failure;
          for (var page = 1; page <= 3 && isCurrent(); page++) {
            for (final query in cinemaWorkQueries(anchor)) {
              if (!isCurrent() || page > (pages[query] ?? 1)) continue;
              final remaining = deadline.difference(DateTime.now());
              if (remaining <= Duration.zero) break;
              try {
                final found = await repository
                    .search(source, query, page: page)
                    .timeout(
                      remaining < const Duration(seconds: 6)
                          ? remaining
                          : const Duration(seconds: 6),
                    );
                pages[query] = found.pageCount;
                result.addAll(
                  found.items
                      .where((t) => t.sourceId == source.id)
                      .map(classify),
                );
              } catch (error) {
                pages[query] = 0;
                failure ??= error;
              }
            }
            if (matches().any((t) => cinemaVariantQuality(t) > 0)) break;
          }
          if (failure != null)
            onSourceError?.call(source, failure);
          else
            onSourceChecked?.call(source);
          return result;
        } catch (error) {
          onSourceError?.call(source, error);
          // A later page may fail after an earlier page found usable variants.
          return result;
        }
      }),
    );
    if (!isCurrent()) return;
    final grouped = groupCinemaTitles([
      anchor,
      ...variants,
      ...results.expand((r) => r),
    ]);
    final matched = grouped
        .firstWhere((g) => g.variants.any((v) => v.key == anchor.key))
        .variants;
    variants
      ..clear()
      ..addAll(matched);
    yield List.unmodifiable(variants);
  }
}
