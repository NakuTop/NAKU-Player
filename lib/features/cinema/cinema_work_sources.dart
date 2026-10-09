import 'cinema_grouping.dart';
import 'cinema_models.dart';
import 'cinema_repository.dart';

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
  final keyword = anchor.title
      .replaceFirst(RegExp(r'\s*[（(]?(?:原声版|普通话版|国语版|英语版)[）)]?\s*$'), '')
      .trim();
  for (var offset = 0; offset < choices.length && isCurrent(); offset += 3) {
    final results = await Future.wait(
      choices.skip(offset).take(3).map((source) async {
        try {
          return (await repository
                  .search(source, keyword)
                  .timeout(const Duration(seconds: 18)))
              .items;
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
