import 'cinema_grouping.dart';
import 'cinema_models.dart';

/// Resolve known external identities before incomplete source metadata. This
/// prevents a no-ID entry encountered first from bridging two conflicting IDs.
/// The existing catalogue rules still preserve season, year and media kind.
List<CinemaTitleGroup> groupCinemaLibraryTitles(Iterable<CinemaTitle> values) {
  final titles = values.toList();
  final order = <String, int>{};
  for (var i = 0; i < titles.length; i++) {
    order.putIfAbsent(titles[i].key, () => i);
  }
  final prioritized = titles.indexed.toList()
    ..sort((a, b) {
      final left = a.$2.doubanId.trim().isNotEmpty ? 0 : 1;
      final right = b.$2.doubanId.trim().isNotEmpty ? 0 : 1;
      return left == right ? a.$1.compareTo(b.$1) : left.compareTo(right);
    });
  final groups = groupCinemaTitles(prioritized.map((item) => item.$2));
  final reordered = groups.map((group) {
    final variants = group.variants.toList()
      ..sort((a, b) => order[a.key]!.compareTo(order[b.key]!));
    return CinemaTitleGroup(key: variants.first.key, variants: variants);
  }).toList();
  reordered.sort((a, b) => order[a.key]!.compareTo(order[b.key]!));
  return reordered;
}
