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
}) async* {
  if (anchor.isDirectMedia) return;
  final variants = groupCinemaTitles([
    anchor,
    ...known,
  ]).first.variants.toList();
  final searched = variants.map((v) => v.sourceId).toSet();
  final choices = sources
      .where(
        (s) =>
            s.enabled &&
            s.kind == CinemaSourceKind.maccms &&
            !searched.contains(s.id),
      )
      .toList();
  for (var offset = 0; offset < choices.length && isCurrent(); offset += 3) {
    final results = await Future.wait(
      choices.skip(offset).take(3).map((source) async {
        try {
          final result = <CinemaTitle>[];
          final deadline = DateTime.now().add(const Duration(seconds: 18));
          bool matches() => groupCinemaTitles([
            anchor,
            ...result,
          ]).first.variants.any((t) => t.sourceId == source.id);
          for (final query in cinemaWorkQueries(anchor)) {
            for (var page = 1; page <= 3 && isCurrent(); page++) {
              final remaining = deadline.difference(DateTime.now());
              if (remaining <= Duration.zero) return result;
              final found = await repository
                  .search(source, query, page: page)
                  .timeout(remaining);
              if (!isCurrent()) return <CinemaTitle>[];
              result.addAll(found.items.where((t) => t.sourceId == source.id));
              if (matches()) return result;
              if (found.page >= found.pageCount) break;
            }
            if (!isCurrent()) break;
          }
          return result;
        } catch (_) {
          return <CinemaTitle>[];
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
