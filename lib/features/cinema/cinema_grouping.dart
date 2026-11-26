import 'cinema_movie_versions.dart';
import 'cinema_catalog_categories.dart';
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
    var selected = primary ?? representative;
    if (cinemaVarietyCategory(selected.category)) {
      if (cinemaVarietyEdition.hasMatch(selected.title)) {
        final regular = variants
            .where((t) => !cinemaVarietyEdition.hasMatch(t.title))
            .firstOrNull;
        if (regular != null)
          selected = CinemaTitle.fromJson({
            ...selected.toJson(),
            'title': regular.title,
          });
      }
      final labelled = variants
          .map((v) => cinemaSeasonName(_editionBase(v.title)))
          .nonNulls
          .firstOrNull;
      if (labelled != null &&
          (cinemaSeasonName(selected.title) == null ||
              cinemaVarietyEdition.hasMatch(selected.title))) {
        selected = CinemaTitle.fromJson({
          ...selected.toJson(),
          'title': '${labelled.work} 第${labelled.number}季',
        });
      }
    }
    final concrete = variants
        .where((t) => !cinemaIsSeasonProjection(t))
        .toList();
    // Old stored projections may still carry the box set's last-season IDs.
    final base = cinemaIsSeasonProjection(selected)
        ? CinemaTitle.fromJson({
            ...selected.toJson(),
            'doubanId': '',
            'imdbId': '',
            'rottenTomatoesId': '',
            'sourceDoubanScore': null,
            'year': '',
            'releaseDateText': '',
            'poster':
                concrete
                    .map((t) => t.poster)
                    .where((p) => p.isNotEmpty)
                    .firstOrNull ??
                selected.poster,
          })
        : selected;
    Set<String> identities(String Function(CinemaTitle) read) => concrete
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
      final scores = concrete
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
      if (year != 0) return year;
      // Resolve source editions before attaching an older public suggestion.
      final metadata = (a.sourceId == 'douban-discovery' ? 1 : 0).compareTo(
        b.sourceId == 'douban-discovery' ? 1 : 0,
      );
      return metadata != 0 ? metadata : order[a.key]!.compareTo(order[b.key]!);
    });
  final varietyNames = _varietySeasonNames(prioritized);
  for (final title in prioritized) {
    final candidate = _Candidate(title, varietyNames[title.key]);
    final lookup = {
      candidate.name,
      candidate.regionalName,
      ...candidate.aliases,
    };
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

enum _Kind { movie, series, variety, anime, documentary, commentary, unknown }

Set<String> _credits(String value) => value
    .split(RegExp(r'[,，、/|;；]|(?<=[\u3400-\u9fff])\s+(?=[\u3400-\u9fff])'))
    .map(
      (s) => cinemaIdentityTypography(
        s,
      ).toLowerCase().replaceAll(RegExp(r'[\s·・.]+'), ''),
    )
    .where(
      (s) =>
          s.length >= 2 &&
          !const {
            '未知',
            '暂无',
            '不详',
            '佚名',
            '待定',
            '未提供',
            'unknown',
            'null',
          }.contains(s),
    )
    .toSet();

_Kind _entryKind(CinemaTitle title) =>
    title.sourceId == 'douban-discovery' && cinemaVarietyCategory(title.genres)
    ? _Kind.variety
    : _kind(title.category);

String _editionBase(String name) =>
    name.replaceFirst(cinemaVarietyEdition, '').trim();

Map<String, String> _varietySeasonNames(Iterable<CinemaTitle> titles) {
  final numbered = <String, List<(CinemaTitle, String)>>{};
  final unresolved = <CinemaTitle>[];
  final names = <String, String>{};
  final shows = titles.where((t) => _entryKind(t) == _Kind.variety).toList();
  final evidence = <String, Map<String, CinemaSeasonName>>{};
  String key(String s) => cinemaGroupedWorkTitleKey(s, '');
  void record(String name, CinemaSeasonName season) {
    (evidence[key(name)] ??= {})['${key(season.work)}#${season.number}'] =
        season;
  }

  for (final t in shows) {
    final base = _editionBase(t.title),
        explicit = cinemaSeasonName(base),
        alias = cinemaVarietyAliasSeason(t);
    if (explicit != null)
      record('${explicit.work}${explicit.number}', explicit);
    if (alias != null && key(alias.work) != key(explicit?.work ?? base)) {
      record(explicit?.work ?? base, alias);
    }
  }
  for (final t in shows) {
    final base = _editionBase(t.title);
    final direct = cinemaSeasonName(base);
    final peers = evidence[key(direct?.work ?? base)]?.values
        .where((s) => direct == null || s.number == direct.number)
        .toList();
    final season =
        cinemaVarietyAliasSeason(t) ??
        (peers?.length == 1 ? peers!.single : null) ??
        direct;
    if (season == null) {
      unresolved.add(t);
      continue;
    }
    final label = '${season.work} 第${season.number}季';
    names[t.key] = label;
    (numbered[cinemaGroupedWorkTitleKey(season.work, '')] ??= []).add((
      t,
      label,
    ));
  }
  for (final t in unresolved) {
    final base = _editionBase(t.title),
        day = RegExp(r'(?:19|20)\d{6}').firstMatch(t.remarks)?.group(0);
    final matches = <String, String>{};
    for (final (peer, name)
        in numbered[cinemaGroupedWorkTitleKey(base, '')] ??
            const <(CinemaTitle, String)>[]) {
      if (t.doubanId.isNotEmpty &&
          peer.doubanId.isNotEmpty &&
          t.doubanId != peer.doubanId) {
        continue;
      }
      if (t.year.isNotEmpty && peer.year.isNotEmpty && t.year != peer.year) {
        continue;
      }
      if ((t.year.isNotEmpty && t.year == peer.year) ||
          (day != null &&
              peer.remarks.contains(day) &&
              _credits(t.actors).intersection(_credits(peer.actors)).length >=
                  2)) {
        matches[cinemaGroupedWorkTitleKey(name, '')] = name;
      }
    }
    if (matches.length == 1) {
      names[t.key] = matches.values.single;
    } else if (t.year.isNotEmpty) {
      names[t.key] = base;
    }
  }
  return names;
}

class _Candidate {
  _Candidate(this.title, [String? identityName])
    : season = cinemaSeasonName(identityName ?? title.title)?.number,
      name = cinemaGroupedWorkTitleKey(identityName ?? title.title, title.year),
      doubanId = cinemaIsSeasonProjection(title) ? '' : title.doubanId.trim(),
      kind = _entryKind(title),
      year = cinemaIsSeasonProjection(title)
          ? null
          : _year(title.year, _kind(title.category)) ??
                (_kind(title.category) == _Kind.anime &&
                        cinemaIsEdgerunnersTitle(title.title, title.year)
                    ? 2022
                    : null);

  final CinemaTitle title;
  final int? season;
  final String name;
  late final aliases = cinemaTitleAliases(
    title.aliases,
  ).map((alias) => cinemaGroupedWorkTitleKey(alias, title.year)).toSet();
  final String doubanId;
  final _Kind kind;
  final int? year;
  late final regionalName = kind == _Kind.movie && doubanId.isNotEmpty
      ? cinemaGroupedWorkTitleKey(
          cinemaRegionalTitle(title.title, title.year),
          title.year,
        )
      : name;
}

class _Group {
  _Group(_Candidate candidate)
    : season = candidate.season,
      name = candidate.name,
      doubanId = candidate.doubanId,
      kind = candidate.kind,
      year = candidate.year,
      variants = [candidate.title];

  final int? season;
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
      if (kind == _Kind.variety &&
          candidate.kind == kind &&
          (this.season != null || name.endsWith('季')) &&
          this.season == candidate.season &&
          name == candidate.name &&
          (year! - candidate.year!).abs() == 1) {
        if (doubanId.isNotEmpty && doubanId == candidate.doubanId) return true;
        return variants.any(
          (v) =>
              _credits(
                v.actors,
              ).intersection(_credits(candidate.title.actors)).length >=
              2,
        );
      }
      if (kind != _Kind.movie ||
          candidate.kind != _Kind.movie ||
          (year! - candidate.year!).abs() != 1) {
        return false;
      }
      // Regional release dates may straddle a year. Require the same subject
      // and name, or a member already verified with this exact name and year.
      return variants.any((v) {
        final known = _Candidate(v);
        if (known.year != null &&
            (known.year! - candidate.year!).abs() == 1 &&
            known.regionalName == candidate.regionalName &&
            known.regionalName.isNotEmpty &&
            _credits(
              v.director,
            ).intersection(_credits(candidate.title.director)).isNotEmpty &&
            (known.doubanId.isNotEmpty &&
                    known.doubanId == candidate.doubanId ||
                _credits(
                      v.actors,
                    ).intersection(_credits(candidate.title.actors)).length >=
                    2)) {
          return true;
        }
        return known.name == candidate.name && known.year == candidate.year ||
            known.doubanId.isNotEmpty &&
                known.doubanId == candidate.doubanId &&
                known.regionalName == candidate.regionalName &&
                (known.regionalName != known.name ||
                    candidate.regionalName != candidate.name ||
                    known.title.releaseDateText.contains(
                      '${candidate.year}-',
                    ) ||
                    candidate.title.releaseDateText.contains('${known.year}-'));
      });
    }
    final season = candidate.season;
    final sameSeason = this.season == season;
    if (kind == _Kind.variety && candidate.kind == kind && !sameSeason) {
      return false;
    }
    final exactSeason =
        season != null &&
        sameSeason &&
        name.isNotEmpty &&
        name == candidate.name;
    if (kind != _Kind.unknown &&
        candidate.kind != _Kind.unknown &&
        kind != candidate.kind) {
      if ({kind, candidate.kind}.containsAll({_Kind.variety, _Kind.series}) &&
          sameSeason &&
          name == candidate.name &&
          doubanId.isNotEmpty &&
          doubanId == candidate.doubanId &&
          (candidate.title.sourceId == 'douban-discovery' ||
              variants.first.sourceId == 'douban-discovery')) {
        return true;
      }
      // Older subject suggestions stored every TV series as a movie.
      // Repair those rows only with a corroborating, same-season native entry.
      if (candidate.title.sourceId == 'douban-discovery' &&
          candidate.kind == _Kind.movie &&
          (kind == _Kind.series || kind == _Kind.anime) &&
          sameSeason &&
          name.isNotEmpty &&
          name == candidate.name &&
          year != null &&
          year == candidate.year &&
          doubanId.isNotEmpty &&
          doubanId == candidate.doubanId &&
          variants.any(
            (v) =>
                v.sourceId != 'douban-discovery' &&
                (exactSeason || v.routes.any((r) => r.episodes.length > 1)),
          )) {
        return true;
      }
      // Some catalogues file a TV anime under series. A shared season subject
      // resolves that disagreement without merging films or adaptations.
      return exactSeason &&
          {kind, candidate.kind}.containsAll({_Kind.series, _Kind.anime}) &&
          (doubanId.isNotEmpty && doubanId == candidate.doubanId ||
              variants.any((v) => _kind(v.category) == candidate.kind));
    }
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
    if (exactSeason &&
        (kind == _Kind.series ||
            kind == _Kind.anime ||
            kind == _Kind.variety) &&
        candidate.kind == kind) {
      return true;
    }
    if (exactSeason &&
        (kind == _Kind.unknown || candidate.kind == _Kind.unknown) &&
        variants.any((v) => v.sourceId == candidate.title.sourceId)) {
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
  final name = value
      .trim()
      .replaceAll('劇', '剧')
      .replaceAll('國', '国')
      .replaceAll('歐', '欧')
      .replaceAll('電', '电');
  if (RegExp('解说|解說|影评|影評|说电影|說电影').hasMatch(name)) return _Kind.commentary;
  if (cinemaVarietyCategory(name)) return _Kind.variety;
  if (RegExp('纪录|记录片').hasMatch(name)) return _Kind.documentary;
  if (RegExp('动漫|动画|動漫|動畫').hasMatch(name)) return _Kind.anime;
  if (const {
    '现代都市',
    '現代都市',
    '年代穿越',
    '反转爽剧',
    '反轉爽劇',
    '古装仙侠',
    '古裝仙俠',
    '女频恋爱',
    '女頻戀愛',
    '脑洞悬疑',
    '腦洞懸疑',
  }.contains(name)) {
    return _Kind.series;
  }
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
  final value = cinemaIdentityTypography(cinemaCatalogYear(text)).trim();
  if (RegExp(r'^[1-9][0-9]{3}$').hasMatch(value)) return int.parse(value);
  if (kind != _Kind.series && kind != _Kind.anime && kind != _Kind.variety) {
    return null;
  }
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
