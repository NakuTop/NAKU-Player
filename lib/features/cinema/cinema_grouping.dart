import 'cinema_models.dart';

/// One search card, retaining each source's own identity and playback data.
class CinemaTitleGroup {
  CinemaTitleGroup({
    required this.key,
    required Iterable<CinemaTitle> variants,
    String preferredSourceId = 'maccms-modu',
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

  CinemaTitle get representative =>
      variants
          .where((title) => title.sourceId == _preferredSourceId)
          .firstOrNull ??
      variants.first;
}

/// Conservatively groups only compatible works in first-appearance order.
/// Repeated source/id pairs keep their first occurrence. Preferred sources only
/// choose the representative; they never reorder groups or discard variants.
List<CinemaTitleGroup> groupCinemaTitles(
  Iterable<CinemaTitle> items, {
  String preferredSourceId = 'maccms-modu',
}) {
  final groups = <_Group>[];
  final byName = <String, List<_Group>>{};
  final seen = <(String, String)>{};
  for (final title in items) {
    if (!seen.add((title.sourceId, title.id))) continue;
    final candidate = _Candidate(title);
    final possible = (byName[candidate.name] ?? const <_Group>[])
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
    } else {
      // Ambiguous candidates stay separate rather than bridging two identities.
      final group = _Group(candidate);
      groups.add(group);
      byName.putIfAbsent(candidate.name, () => []).add(group);
    }
  }
  return [
    for (final group in groups)
      CinemaTitleGroup(
        key: group.variants.first.key,
        variants: group.variants,
        preferredSourceId: preferredSourceId,
      ),
  ];
}

enum _Kind { movie, series, anime, documentary, commentary, unknown }

class _Candidate {
  _Candidate(this.title)
    : name = _normalizeName(title.title),
      doubanId = title.doubanId.trim(),
      kind = _kind(title.category),
      year = _year(title.year, _kind(title.category));

  final CinemaTitle title;
  final String name;
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
    if (name.isEmpty || name != candidate.name) return false;
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
    if (doubanId.isNotEmpty && doubanId == candidate.doubanId) return true;
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

String _normalizeName(String value) {
  var name = value.trim().toLowerCase();
  const language = r'(?:原声版|普通话版|国语版|英语版)';
  name = name.replaceFirst(
    RegExp(
      r'\s*(?:[（(]\s*' +
          language +
          r'\s*[）)]|\[\s*' +
          language +
          r'\s*\]|【\s*' +
          language +
          r'\s*】|' +
          language +
          r')\s*$',
    ),
    '',
  );
  name = name.replaceAll(RegExp(r'\s+'), '');
  return name.replaceAllMapped(RegExp(r'第([一二三四五六七八九十0-9]{1,3})季'), (match) {
    final number = _seasonNumber(match[1]!);
    return number == null ? match[0]! : '第$number季';
  });
}

int? _seasonNumber(String text) {
  final arabic = int.tryParse(text);
  if (arabic != null) return arabic >= 1 && arabic <= 99 ? arabic : null;
  const digits = {
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (text == '十') return 10;
  if (digits.containsKey(text)) return digits[text];
  if (RegExp(r'^十[一二三四五六七八九]$').hasMatch(text)) {
    return 10 + digits[text[1]]!;
  }
  if (RegExp(r'^[二三四五六七八九]十[一二三四五六七八九]?$').hasMatch(text)) {
    return digits[text[0]]! * 10 + (text.length == 3 ? digits[text[2]]! : 0);
  }
  return null;
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
  final value = text.trim();
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
