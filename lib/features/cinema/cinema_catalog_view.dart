import 'cinema_filters.dart';
import 'cinema_grouping.dart';
import 'cinema_media_identity.dart';
import 'cinema_models.dart';

/// One destination's derived catalogue. Callers replace the input list when
/// its contents change. Score updates only re-sort; they never re-group works.
class CinemaCatalogViewCache {
  List<CinemaTitle>? _items;
  (String, String, String, bool, String)? _filterKey;
  (CinemaCatalogSort?, String, int, String)? _sortKey;
  List<CinemaTitle> _representatives = const [];
  List<CinemaTitleGroup> _groups = const [];
  Map<String, List<CinemaTitle>> _variants = const {};
  CinemaCatalogView? _view;

  CinemaCatalogView resolve({
    required List<CinemaTitle> items,
    required CinemaFilters filters,
    required bool grouped,
    CinemaCatalogSort? sort,
    String provider = '',
    String search = '',
    List<String> sourcePriority = const [],
    int ratingRevision = 0,
    double? Function(CinemaTitle)? scoreOf,
  }) {
    final filterKey = (
      filters.year,
      filters.region,
      filters.genre,
      grouped,
      sourcePriority.join('|'),
    );
    if (!identical(_items, items) || _filterKey != filterKey) {
      _items = items;
      _filterKey = filterKey;
      final filtered = items.where(filters.matches).toList();
      _groups = grouped
          ? groupCinemaTitles(filtered, sourcePriority: sourcePriority)
          : const [];
      _representatives = grouped
          ? _groups.map((group) => group.catalogTitle).toList()
          : filtered;
      _variants = {
        for (final group in _groups) group.catalogTitle.key: group.variants,
      };
      _sortKey = null;
    }
    final sortKey = (
      sort,
      sort == CinemaCatalogSort.rating ? provider : '',
      sort == CinemaCatalogSort.rating ? ratingRevision : 0,
      search,
    );
    if (_sortKey == sortKey && _view != null) return _view!;
    _sortKey = sortKey;
    var visible = sort == null
        ? _representatives
        : sortCinemaTitles(_representatives, sort, scoreOf: scoreOf);
    if (search.trim().isNotEmpty) {
      visible = rankCinemaSearch(visible, search, variants: _variants);
    }
    return _view = CinemaCatalogView(
      groups: _groups,
      representatives: _representatives,
      visible: visible,
      variants: _variants,
      indices: {for (var i = 0; i < visible.length; i++) visible[i].key: i},
    );
  }
}

/// Relevance belongs to a work. The existing catalogue order breaks ties
/// between families, while numbered seasons within a family stay together.
List<CinemaTitle> rankCinemaSearch(
  List<CinemaTitle> titles,
  String query, {
  Map<String, List<CinemaTitle>> variants = const {},
}) {
  final requested = cinemaSeasonName(query);
  final needle = cinemaSearchKey(requested?.work ?? query);
  if (needle.isEmpty) return titles;
  final familyOrder = <String, int>{};
  final rows = titles.indexed.map((entry) {
    final (index, title) = entry;
    var tier = 8, distance = 0, season = 0, family = title.key;
    for (final variant in [title, ...?variants[title.key]]) {
      final name = cinemaCleanWorkTitle(variant.title, variant.year);
      final numbered = cinemaSeasonName(name);
      final extra = RegExp(
        '解说|解說|影评|影評|预告|預告|花絮',
      ).hasMatch('${variant.category} $name');
      for (final candidate in [name, ...cinemaTitleAliases(variant.aliases)]) {
        final parsed = cinemaSeasonName(candidate);
        final base = cinemaSearchKey(parsed?.work ?? candidate);
        if (base.isEmpty) continue;
        final number = numbered?.number ?? parsed?.number ?? 0;
        final exact =
            base == needle ||
            cinemaSameSearchTitle(
              parsed?.work ?? candidate,
              requested?.work ?? query,
              variant.year,
            );
        final match = exact
            ? (requested == null || number == requested.number ? 0 : 1)
            : base.startsWith(needle)
            ? 2
            : base.contains(needle)
            ? 3
            : 6;
        final rank = extra ? match + 4 : match;
        final gap = match >= 6 || exact
            ? 0
            : (base.length - needle.length).abs();
        if (rank < tier || rank == tier && gap < distance) {
          tier = rank;
          distance = gap;
          season = number;
          family = exact
              ? needle
              : match < 6
              ? base
              : title.key;
        }
      }
    }
    final order = familyOrder.putIfAbsent(family, () => index);
    return (
      title: title,
      tier: tier,
      gap: distance,
      family: order,
      season: season,
      index: index,
    );
  }).toList();
  rows.sort((a, b) {
    if (a.tier != b.tier) return a.tier.compareTo(b.tier);
    if (a.gap != b.gap) return a.gap.compareTo(b.gap);
    if (a.family != b.family) return a.family.compareTo(b.family);
    if (a.season != b.season) return a.season.compareTo(b.season);
    return a.index.compareTo(b.index);
  });
  return rows.map((r) => r.title).toList();
}

class CinemaCatalogView {
  const CinemaCatalogView({
    required this.groups,
    required this.representatives,
    required this.visible,
    required this.variants,
    required this.indices,
  });
  final List<CinemaTitleGroup> groups;
  final List<CinemaTitle> representatives, visible;
  final Map<String, List<CinemaTitle>> variants;
  final Map<String, int> indices;
}
