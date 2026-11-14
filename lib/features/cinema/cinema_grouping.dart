import 'cinema_movie_versions.dart';
import 'cinema_models.dart';
import 'cinema_media_identity.dart';
import 'cinema_seasons.dart';

/// One search card, retaining each source's own identity and playback data.
class CinemaTitleGroup {
  CinemaTitleGroup({
    required this.key,
    required Iterable<CinemaTitle> variants,
    String preferredSourceId = 'maccms-feifan',
    this.sourcePriority = const [],
  }) : variants = List.unmodifiable(variants),
       _preferredSourceId = preferredSourceId {
    if (this.variants.isEmpty) {
      throw ArgumentError.value(
        variants,
        'variants',
        'A group cannot be empty',
      );
    }
  }

  final String key;
  final List<CinemaTitle> variants;
  final String _preferredSourceId;
  final List<String> sourcePriority;

  CinemaTitle get representative => orderCinemaVariants(variants, [
    ...sourcePriority,
    _preferredSourceId,
  ]).first;

  /// Keep the preferred playback source while sharing only unambiguous rating
  /// identities from variants that already passed the work identity checks.
  /// The original variants remain untouched for playback and persistence.
  late final CinemaTitle catalogTitle = _catalogTitle();

  CinemaTitle _catalogTitle({CinemaTitle? primary}) {
    final base = primary ?? representative;
    Set<String> identities(String Function(CinemaTitle) read) => variants
        .map(read)
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    final douban = identities((title) => title.doubanId);
    final imdb = identities((title) => title.imdbId);
    final rotten = identities((title) => title.rottenTomatoesId);
    // A conflicting external ID means the purported variants need inspection.
    // Never transfer a different provider's identity through that conflict.
    if ([douban, imdb, rotten].any((ids) => ids.length > 1)) return base;
    final doubanId = douban.firstOrNull ?? '';
    double? score = base.sourceDoubanScore;
    if (score == null && doubanId.isNotEmpty) {
      final scores = variants
          .where((title) => title.doubanId.trim() == doubanId)
          .map((title) => title.sourceDoubanScore)
          .whereType<double>()
          .where((value) => value.isFinite && value > 0 && value <= 10)
          .toSet();
      if (scores.length == 1) score = scores.single;
    }
    final imdbId = imdb.firstOrNull ?? '';
    final rottenId = rotten.firstOrNull ?? '';
    final years = identities((title) => title.year);
    final year = base.year.isEmpty && years.length == 1
        ? years.single
        : base.year;
    if (base.year == year &&
        base.doubanId == doubanId &&
        base.imdbId == imdbId &&
        base.rottenTomatoesId == rottenId &&
        base.sourceDoubanScore == score) {
      return base;
    }
    return base.copyWith(
      year: year,
      doubanId: doubanId,
      imdbId: imdbId,
      rottenTomatoesId: rottenId,
      sourceDoubanScore: score,
    );
  }
}

/// A refreshed source detail may omit IDs that were already resolved for its
/// card. Preserve those IDs only when the same conservative grouping rules
/// confirm the work; keep all newly loaded source content and playback routes.
CinemaTitle inheritCinemaRatingMetadata(
  CinemaTitle detail,
  CinemaTitle anchor,
) {
  if (!_Group(_Candidate(detail)).accepts(_Candidate(anchor))) return detail;
  return CinemaTitleGroup(
    key: detail.key,
    variants: [detail, anchor],
    preferredSourceId: detail.sourceId,
  )._catalogTitle(primary: detail);
}

/// Conservatively groups only compatible works in first-appearance order.
/// Repeated source/id pairs keep their first occurrence. Preferred sources only
/// choose the representative; they never reorder groups or discard variants.
List<CinemaTitleGroup> groupCinemaTitles(
  Iterable<CinemaTitle> items, {
  String preferredSourceId = 'maccms-feifan',
  List<String> sourcePriority = const [],
}) {
  final groups = <_Group>[];
  final byName = <String, List<_Group>>{};
  final unique = <String, CinemaTitle>{};
  for (final title in items) {
    unique.putIfAbsent(title.key, () => title);
  }
  final order = {
    for (final (index, title) in unique.values.indexed) title.key: index,
  };
  // Resolve ordinary editions and stronger identities first so incomplete
  // metadata or season projections cannot arbitrarily pick a conflicting work.
  final prioritized = unique.values.toList()
    ..sort((a, b) {
      final projection = (cinemaIsSeasonProjection(a) ? 1 : 0).compareTo(
        cinemaIsSeasonProjection(b) ? 1 : 0,
      );
      if (projection != 0) return projection;
      final identity = (b.doubanId.trim().isNotEmpty ? 1 : 0).compareTo(
        a.doubanId.trim().isNotEmpty ? 1 : 0,
      );
      if (identity != 0) return identity;
      final year = (_year(b.year, _kind(b.category)) != null ? 1 : 0).compareTo(
        _year(a.year, _kind(a.category)) != null ? 1 : 0,
      );
      return year != 0 ? year : order[a.key]!.compareTo(order[b.key]!);
    });
  for (final title in prioritized) {
    final candidate = _Candidate(title);
    final lookup = {candidate.name, ...candidate.aliases};
    final possible = lookup
        .expand((key) => byName[key] ?? const <_Group>[])
        .toSet()
        .where((group) => group.accepts(candidate))
        .toList();
    final exactIdMatches = candidate.doubanId.isEmpty
        ? const <_Group>[]
        : possible
              .where((group) => group.doubanId == candidate.doubanId)
              .toList();
    final matches = exactIdMatches.isNotEmpty ? exactIdMatches : possible;
    if (matches.length == 1) {
      matches.single.add(candidate);
      for (final key in lookup) {
        final bucket = byName.putIfAbsent(key, () => []);
        if (!bucket.contains(matches.single)) bucket.add(matches.single);
      }
    } else {
      // Ambiguous candidates stay separate rather than bridging two identities.
      final group = _Group(candidate);
      groups.add(group);
      for (final key in lookup) {
        byName.putIfAbsent(key, () => []).add(group);
      }
    }
  }
  final result = groups.map((group) {
    group.variants.sort((a, b) => order[a.key]!.compareTo(order[b.key]!));
    return CinemaTitleGroup(
      key: group.variants.first.key,
      variants: group.variants,
      preferredSourceId: preferredSourceId,
      sourcePriority: sourcePriority,
    );
  }).toList();
  return result..sort((a, b) => order[a.key]!.compareTo(order[b.key]!));
}

enum _Kind { movie, series, anime, documentary, commentary, unknown }

class _Candidate {
  _Candidate(this.title)
    : name = cinemaGroupedWorkTitleKey(title.title, title.year),
      doubanId = title.doubanId.trim(),
      kind = _kind(title.category),
      year =
          _year(title.year, _kind(title.category)) ??
          (_kind(title.category) == _Kind.anime &&
                  cinemaIsEdgerunnersTitle(title.title, title.year)
              ? 2022
              : null);

  final CinemaTitle title;
  final String name;
  late final aliases = cinemaTitleAliases(
    title.aliases,
  ).map((alias) => cinemaGroupedWorkTitleKey(alias, title.year)).toSet();
  final String doubanId;
  final _Kind kind;
  final int? year;
}

class _Group {
  _Group(_Candidate candidate)
    : name = candidate.name,
      doubanId = candidate.doubanId,
      kind = candidate.kind,
      year = candidate.year,
      variants = [candidate.title];

  final String name;
  String doubanId;
  _Kind kind;
  int? year;
  final List<CinemaTitle> variants;

  bool accepts(_Candidate candidate) {
    if (candidate.title.isDirectMedia || variants.first.isDirectMedia) {
      return candidate.title.key == variants.first.key;
    }

    if (doubanId.isNotEmpty &&
        candidate.doubanId.isNotEmpty &&
        doubanId != candidate.doubanId) {
      return false;
    }
    if (year != null && candidate.year != null && year != candidate.year) {
      return false;
    }
    if (kind != _Kind.unknown &&
        candidate.kind != _Kind.unknown &&
        kind != candidate.kind) {
      return false;
    }
    final sameSeason =
        cinemaSeasonName(variants.first.title)?.number ==
        cinemaSeasonName(candidate.title.title)?.number;
    if (name.isEmpty || name != candidate.name) {
      return sameSeason &&
          kind == candidate.kind &&
          kind != _Kind.unknown &&
          year != null &&
          year == candidate.year &&
          (candidate.aliases.contains(name) ||
              cinemaTitleAliases(variants.first.aliases).any(
                (alias) =>
                    cinemaGroupedWorkTitleKey(alias, variants.first.year) ==
                    candidate.name,
              ));
    }
    if (doubanId.isNotEmpty && doubanId == candidate.doubanId) return true;
    if (kind == _Kind.series &&
        candidate.kind == _Kind.series &&
        (cinemaIsSeasonProjection(candidate.title) ||
            variants.any(cinemaIsSeasonProjection)) &&
        RegExp(r'第[0-9]+季$').hasMatch(name)) {
      return true;
    }
    return year != null &&
        year == candidate.year &&
        kind != _Kind.unknown &&
        kind == candidate.kind;
  }

  void add(_Candidate candidate) {
    variants.add(candidate.title);
    if (doubanId.isEmpty) doubanId = candidate.doubanId;
    year ??= candidate.year;
    if (kind == _Kind.unknown) kind = candidate.kind;
  }
}

_Kind _kind(String value) {
  final name = value.trim();
  if (RegExp('解说|影评|说电影').hasMatch(name)) return _Kind.commentary;
  if (RegExp('纪录|记录片').hasMatch(name)) return _Kind.documentary;
  if (RegExp('动漫|动画').hasMatch(name)) return _Kind.anime;
  if (RegExp(
    '电视剧|连续剧|剧集|国产剧|大陆剧|内地剧|欧美剧|美国剧|英国剧|美剧|日剧|韩剧|日本剧|韩国剧|香港剧|港澳剧|台湾剧|海外剧|泰国剧|泰剧|Netflix自制剧|短剧',
    caseSensitive: false,
  ).hasMatch(name)) {
    return _Kind.series;
  }
  if (RegExp(
    '电影|动作片|喜剧片|爱情片|科幻片|恐怖片|剧情片|战争片|悬疑片|犯罪片|奇幻片|冒险片|惊悚片',
  ).hasMatch(name)) {
    return _Kind.movie;
  }
  return _Kind.unknown;
}

int? _year(String text, _Kind kind) {
  final value = cinemaIdentityTypography(text).trim();
  if (RegExp(r'^[1-9][0-9]{3}$').hasMatch(value)) return int.parse(value);
  if (kind != _Kind.series && kind != _Kind.anime) return null;
  final range = RegExp(
    r'^([1-9][0-9]{3})\s*[-–—]\s*([1-9][0-9]{3})?$',
  ).firstMatch(value);
  if (range == null) return null;
  final first = int.parse(range[1]!);
  final last = int.tryParse(range[2] ?? '');
  return last == null || last >= first ? first : null;
}

/// User source order comes first; editions within that source use quality labels.
List<CinemaTitle> orderCinemaVariants(
  Iterable<CinemaTitle> values,
  Iterable<String> ids,
) {
  final priority = <String, int>{};
  for (final id in ids) {
    priority.putIfAbsent(id, () => priority.length);
  }
  final entries = values.toList().indexed.toList()
    ..sort((a, b) {
      final source = (priority[a.$2.sourceId] ?? priority.length).compareTo(
        priority[b.$2.sourceId] ?? priority.length,
      );
      if (source != 0) return source;
      final quality = cinemaVariantQuality(
        b.$2,
      ).compareTo(cinemaVariantQuality(a.$2));
      return quality == 0 ? a.$1.compareTo(b.$1) : quality;
    });
  return entries.map((e) => e.$2).toList();
}

int cinemaVariantQuality(CinemaTitle title) =>
    title.sourceId == 'douban-discovery'
    ? -100
    : cinemaVersionQuality('${title.title} ${title.remarks} ${title.category}');
