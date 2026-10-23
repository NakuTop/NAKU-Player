import 'dart:async';

import 'cinema_grouping.dart';
import 'cinema_models.dart';
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
          for (final query in cinemaWorkQueries(anchor)) {
            for (var page = 1; page <= 3 && isCurrent(); page++) {
              final remaining = deadline.difference(DateTime.now());
              if (remaining <= Duration.zero) {
                throw TimeoutException('片源查询超时');
              }
              final found = await repository
                  .search(source, query, page: page)
                  .timeout(remaining);
              if (!isCurrent()) return <CinemaTitle>[];
              result.addAll(found.items.where((t) => t.sourceId == source.id));
              if (matches().any((t) => cinemaVariantQuality(t) > 0)) {
                onSourceChecked?.call(source);
                return result;
              }
              if (found.page >= found.pageCount) break;
            }
            if (!isCurrent()) break;
            if (matches().isNotEmpty) break;
          }
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
