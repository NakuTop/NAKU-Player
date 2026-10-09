import 'cinema_filters.dart';
import 'cinema_grouping.dart';
import 'cinema_models.dart';

/// One destination's derived catalogue. Callers replace the input list when
/// its contents change. Score updates only re-sort; they never re-group works.
class CinemaCatalogViewCache {
  List<CinemaTitle>? _items;
  (String, String, String, bool)? _filterKey;
  (CinemaCatalogSort?, String, int)? _sortKey;
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
    int ratingRevision = 0,
    double? Function(CinemaTitle)? scoreOf,
  }) {
    final filterKey = (filters.year, filters.region, filters.genre, grouped);
    if (!identical(_items, items) || _filterKey != filterKey) {
      _items = items;
      _filterKey = filterKey;
      final filtered = items.where(filters.matches).toList();
      _groups = grouped ? groupCinemaTitles(filtered) : const [];
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
    );
    if (_sortKey == sortKey && _view != null) return _view!;
    _sortKey = sortKey;
    final visible = sort == null
        ? _representatives
        : sortCinemaTitles(_representatives, sort, scoreOf: scoreOf);
    return _view = CinemaCatalogView(
      groups: _groups,
      representatives: _representatives,
      visible: visible,
      variants: _variants,
      indices: {for (var i = 0; i < visible.length; i++) visible[i].key: i},
    );
  }
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
