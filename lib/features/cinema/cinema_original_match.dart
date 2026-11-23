import 'dart:math' as math;
import 'cinema_media_identity.dart';

String originalNameKey(String s) => cinemaIdentityTypography(
  s,
).toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

final _quality = RegExp(
  r'(?:^|[^a-z0-9])(?:2160p|4k|uhd)(?![a-z0-9])|超高清',
  caseSensitive: false,
);
final _unsuitable = RegExp(
  r'(?:^|[^a-z0-9])(?:sample|trailer|featurettes?|extras?|up[ ._-]?scal(?:e[d]?|ing)|hdcam|camrip|telesync)(?![a-z0-9])|花絮|预告|預告|升频|升頻',
  caseSensitive: false,
);
// "UHD BluRay 1080p" describes the disc used for a lower-resolution encode.
final _lowerResolution = RegExp(
  r'(?:^|[^a-z0-9])(?:(?:360|480|540|576|720|1080|1440)[pi]|(?:1280x720|1920x1080|2560x1440))(?![a-z0-9])',
  caseSensitive: false,
);
final _year = RegExp(r'(?<!\d)((?:18|19|20)\d{2})(?!\d)');
const _digits = r'[0-9零一二两兩三四五六七八九十百]+';
final _scope = RegExp(
  r'(?<![a-z0-9])(?:s(?:eason[ ._-]*)?(\d{1,2})(?:[ ._-]*e(?:pisode[ ._-]*)?(\d{1,4}))?|(\d{1,2})x(\d{1,4}))(?![a-z0-9])|第\s*(' +
      _digits +
      r')\s*季(?:[ ._-]*第\s*(' +
      _digits +
      r')\s*[集话話])?',
  caseSensitive: false,
);
final _episodeOnly = RegExp(
  r'(?:第\s*(' +
      _digits +
      r')\s*[集话話]|(?<![a-z0-9])(?:ep(?:isode)?|e)[ ._-]*(\d{1,4})(?![a-z0-9]))',
  caseSensitive: false,
);
final _multiple = RegExp(
  r'(?:e\d{1,4}|第\s*\d+\s*集)\s*(?:[-~至到]\s*(?:e|第)?\d|e\d)|s\d{1,2}\s*[-~]\s*s?\d',
  caseSensitive: false,
);
final _seasonRange = RegExp(
  r'(?<![a-z0-9])s(\d{1,2})\s*[-~–]\s*s(\d{1,2})(?![a-z0-9])',
  caseSensitive: false,
);
final _video = RegExp(
  r'\.(?:mkv|mp4|m4v|mov|webm|ts|m2ts)$',
  caseSensitive: false,
);

final _releaseGroup = RegExp(r'^\s*[\[【][^\[\]【】\r\n]{1,64}[\]】]\s*');
final _numberedFileEpisode = RegExp(
  r'(?:\[(\d{2,3})(?:v\d+)?\]|\s+[-–]\s+(\d{2,3})(?:v\d+)?)(?=\s*\[|\s*$|\.(?:mkv|mp4|m4v)$)',
  caseSensitive: false,
);
RegExpMatch? _groupedEpisode(String name) {
  if (!_releaseGroup.hasMatch(name)) return null;
  final found = _numberedFileEpisode.allMatches(name);
  return found.length == 1 ? found.first : null;
}

// Some encoders append "(2160p x265 10bit S95 Group)" to an episode. Its
// encoding tag cannot contradict an explicit episode outside the technical block.
final _encoderBlock = RegExp(r'[\[(][^\])\r\n]{1,160}[\])]');
final _encoderSetting = RegExp(
  r'((?:8|10|12)[ ._-]*bit[ ._-]+)s[5-9]\d(?=[ ._-]+[a-z])',
  caseSensitive: false,
);
String _episodeIdentity(String text) {
  if (!text.contains('(') && !text.contains('[')) return text;
  return text.replaceAllMapped(_encoderBlock, (block) {
    final tag = block[0]!;
    if (!_quality.hasMatch(tag) ||
        !_encoderSetting.hasMatch(tag) ||
        !_scope
            .allMatches(text.substring(0, block.start))
            .any((m) => _numbers(m).episode != null)) {
      return tag;
    }
    return tag.replaceAllMapped(_encoderSetting, (m) => m[1]!);
  });
}

bool originalVideoFilename(String name) => _video.hasMatch(name);
bool originalExcludedRelease(String name) => _unsuitable.hasMatch(name);
bool originalLowerResolution(String name) => _lowerResolution.hasMatch(name);

int? originalNumber(String? s) {
  if (s == null || s.isEmpty) return null;
  final plain = int.tryParse(s);
  if (plain != null) return plain;
  const digits = '零一二三四五六七八九';
  int total = 0, digit = 0;
  for (final c in s.replaceAll('两', '二').replaceAll('兩', '二').split('')) {
    if (c == '百' || c == '十') {
      total += math.max(digit, 1) * (c == '百' ? 100 : 10);
      digit = 0;
    } else {
      digit = digits.indexOf(c);
      if (digit < 0) return null;
    }
  }
  return total + digit;
}

({int season, int? episode}) _numbers(RegExpMatch m) => (
  season: originalNumber(m[1] ?? m[3] ?? m[5])!,
  episode: originalNumber(m[2] ?? m[4] ?? m[6]),
);

({int? season, int? episode}) originalEpisode(String text) {
  text = _episodeIdentity(cinemaIdentityTypography(text.trim()));
  if (_multiple.hasMatch(text) || _unsuitable.hasMatch(text)) {
    return (season: null, episode: null);
  }
  final matches = _scope.allMatches(text).toList();
  if (matches.length > 1) return (season: null, episode: null);
  final s = matches.isEmpty ? null : _numbers(matches.single);
  final e = _episodeOnly.firstMatch(text) ?? _groupedEpisode(text);
  return (
    season: s?.season,
    episode: s?.episode ?? originalNumber(e?[1] ?? e?[2]) ?? int.tryParse(text),
  );
}

class OriginalWork {
  OriginalWork({
    required this.names,
    required this.years,
    this.doubanId = '',
    this.imdbId = '',
    this.episodeCount = 0,
    this.season,
    this.episode,
  }) : keys = names.map(originalNameKey).where((s) => s.isNotEmpty).toSet();
  final List<String> names;
  final String doubanId, imdbId;
  final Set<String> keys, years;
  final int? season, episode;
  final int episodeCount;
  bool get series => season != null;
  String get key =>
      '${(keys.toList()..sort()).join('|')}/${(years.toList()..sort()).join(',')}/$season/$episode';

  bool _matchesPrefix(String prefix) {
    var name = originalNameKey(prefix);
    if (keys.contains(name)) return true;
    final group = _releaseGroup.firstMatch(prefix);
    if (group != null) {
      name = originalNameKey(prefix.substring(group.end));
      if (keys.contains(name)) return true;
    }
    // Bilingual releases commonly put both complete names before the year.
    for (final alias in keys) {
      if (!name.startsWith(alias)) continue;
      final other = name.substring(alias.length);
      if (other != alias && keys.contains(other)) return true;
    }
    return false;
  }

  /// Match work identity before ranking. A season pack still needs a unique
  /// member from its real manifest before it can be played.
  bool? matchRelease(String name) {
    name = _episodeIdentity(cinemaIdentityTypography(name));
    final range = _seasonRange.firstMatch(name);
    if (range != null) {
      if (!series ||
          season! < int.parse(range[1]!) ||
          season! > int.parse(range[2]!) ||
          _episodeOnly.hasMatch(name)) {
        return null;
      }
      name = name.replaceRange(range.start, range.end, 'S$season');
    }
    if (!_quality.hasMatch(name) ||
        _lowerResolution.hasMatch(name) ||
        _unsuitable.hasMatch(name) ||
        _multiple.hasMatch(name) ||
        RegExp(
          r'\.(?:exe|app|dmg|zip|rar|lnk|scr)(?:$|\s)',
          caseSensitive: false,
        ).hasMatch(name)) {
      return null;
    }
    final scopes = _scope.allMatches(name).toList();
    if (!series) {
      if (scopes.isNotEmpty) return null;
      for (final y in _year.allMatches(name)) {
        if (years.contains(y[1]) &&
            _matchesPrefix(name.substring(0, y.start))) {
          return false;
        }
      }
      return null;
    }
    if (scopes.isEmpty && season == 1) {
      final tag = _groupedEpisode(name);
      if (tag != null &&
          originalNumber(tag[1] ?? tag[2]) == episode &&
          originalVideoFilename(name) &&
          _matchesPrefix(name.substring(0, tag.start))) {
        return false;
      }
    }
    if (scopes.length != 1) return null;
    final m = scopes.single, n = _numbers(m);
    if (n.season != season || n.episode != null && n.episode != episode) {
      return null;
    }
    var prefix = name.substring(0, m.start);
    // A release may use the show's premiere year or the season's air year.
    if (!_matchesPrefix(prefix)) {
      final y = _year.allMatches(prefix).lastOrNull;
      if (y == null ||
          !years.contains(y[1]) ||
          originalNameKey(prefix.substring(y.end)).isNotEmpty) {
        return null;
      }
      prefix = prefix.substring(0, y.start);
    }
    if (!_matchesPrefix(prefix)) return null;
    final e = _episodeOnly.firstMatch(name.substring(m.end));
    if (e != null && originalNumber(e[1] ?? e[2]) != episode) return null;
    return n.episode == null && e == null;
  }
}

final _chineseSubtitles = RegExp(
  r'中[英日韓韩]双[语語字]|中[英日韓韩]雙[語语字]|中英(?:文)?(?:字幕|双字|雙字)|简繁(?:英|中|字幕)|簡繁(?:英|中|字幕)|'
  r'(?:中文|简体|簡體|繁体|繁體)(?:[中双雙]文?)?字幕|(?:内封|內封|内嵌|內嵌|外挂|外掛|国配|國配)?中字|'
  r'(?<![a-z0-9])(?:chs|cht|zh[-_]han[st])(?:subs?)?(?![a-z0-9])|'
  r'(?<![a-z])(?:chinese|mandarin|zh)[ ._-]*(?:subtitles?|subs?|cc)(?![a-z])|'
  r'(?:subtitles?|subs?)\s*[:=]\s*(?:traditional |simplified )?(?:chinese|mandarin|zh)\b',
  caseSensitive: false,
);
bool originalChineseSubtitles(String value) {
  final text = value
      .replaceAll(
        RegExp(
          r'(?:audio|dub|音轨|音軌|配音)\s*[:：=][^\n|;；]*?(?=(?:subtitles?|subs|字幕)\s*[:：=]|[\n|;；]|$)',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(
        RegExp(
          r'(?:无|無|不含|不带|不帶)(?:简体|繁体|簡體|繁體)?(?:中文字幕|中字)|(?:no|without)[ ._-]+(?:chinese[ ._-]+sub(?:title)?s?|chs|cht)|(?:chs|cht|zh[-_]han[st])[ ._-]*(?:dub(?:bed)?|audio)',
          caseSensitive: false,
        ),
        ' ',
      );
  if (_chineseSubtitles.hasMatch(text)) return true;
  final list = RegExp(
    r'(?:字幕|subtitles?|subs)\s*[:：=]\s*([^\n;；|]+)',
    caseSensitive: false,
  ).firstMatch(text)?[1];
  return list != null &&
      RegExp(
        r'(?<![a-z])(?:chinese|zh(?:[-_](?:cn|tw|hk|han[st]))?|zho|chi)(?![a-z])|简体|繁体|簡體|繁體|中文',
        caseSensitive: false,
      ).hasMatch(
        list
            .split(
              RegExp(
                r'\b(?:audio|dub)\s*[:=]|音[轨軌]\s*[:：=]',
                caseSensitive: false,
              ),
            )
            .first,
      );
}

class OriginalEdition {
  const OriginalEdition({
    required this.hash,
    required this.name,
    required this.size,
    required this.seeds,
    required this.pack,
    required this.magnet,
    this.subtitleHint = false,
  });
  final String hash, name, magnet;
  final int size, seeds;
  final bool pack;
  final bool subtitleHint;
  bool get chineseSubtitles => subtitleHint || originalChineseSubtitles(name);
  int compareAvailability(OriginalEdition other) {
    if (chineseSubtitles != other.chineseSubtitles) {
      return chineseSubtitles ? -1 : 1;
    }
    return other.seeds.compareTo(seeds);
  }

  OriginalEdition mergeIndexEvidence(OriginalEdition other) {
    final labelled = !chineseSubtitles && other.chineseSubtitles ? other : this;
    final uri = Uri.parse(magnet);
    final existing = uri.queryParametersAll['tr'] ?? const <String>[];
    final trackers = {
      ...existing,
      ...?Uri.parse(other.magnet).queryParametersAll['tr'],
    };
    final count = seeds >= other.seeds ? seeds : other.seeds;
    if (identical(labelled, this) &&
        count == seeds &&
        trackers.length == existing.length) {
      return this;
    }
    return OriginalEdition(
      hash: hash,
      name: labelled.name,
      size: labelled.size,
      pack: labelled.pack,
      seeds: count,
      subtitleHint: labelled.chineseSubtitles,
      magnet: Uri.parse(labelled.magnet)
          .replace(
            queryParameters: {
              ...Uri.parse(labelled.magnet).queryParametersAll,
              'tr': trackers.toList(),
            },
          )
          .toString(),
    );
  }

  String get label {
    final s = name.toLowerCase();
    final format = s.contains('remux')
        ? 'Remux'
        : RegExp(r'blu[ .-]?ray|brrip').hasMatch(s)
        ? '蓝光'
        : s.contains('web')
        ? 'WEB'
        : '原片';
    return [
      if (chineseSubtitles) '中字',
      if (pack) '整季',
      format,
      '${(size / (1 << 30)).toStringAsFixed(1)} GB',
    ].join(' · ');
  }
}

typedef OriginalSelection = ({
  OriginalMatches matches,
  OriginalEdition edition,
});

class OriginalMatches {
  const OriginalMatches(this.work, this.editions);
  final OriginalWork work;
  final List<OriginalEdition> editions;
  bool acceptsEpisode(String label) {
    if (!work.series) return true;
    final part = originalEpisode(label);
    return (part.season == null || part.season == work.season) &&
        part.episode == work.episode;
  }
}

class OriginalFile {
  const OriginalFile(this.id, this.path, this.length);
  final int id, length;
  final String path;
}

OriginalFile? originalMainFile(
  OriginalWork work,
  OriginalEdition edition,
  List<OriginalFile> manifest,
) {
  final videos = manifest
      .where(
        (f) =>
            f.id >= 0 &&
            f.length > 0 &&
            _video.hasMatch(f.path) &&
            !_lowerResolution.hasMatch(f.path) &&
            !_unsuitable.hasMatch(f.path),
      )
      .toList();
  if (!work.series) {
    final main = videos.where((f) => f.length >= 128 * 1024 * 1024);
    return main.length == 1
        ? main.single
        : videos.length == 1
        ? videos.single
        : null;
  }
  final hits = <OriginalFile>[];
  for (final f in videos) {
    final parts = f.path.replaceAll('\\', '/').split('/');
    if (_multiple.hasMatch(parts.last)) continue;
    final scopes = parts
        .expand(
          (part) => _scope.allMatches(
            _episodeIdentity(part).replaceAll(_seasonRange, ' '),
          ),
        )
        .map(_numbers)
        .toList();
    if (_seasonRange.hasMatch(edition.name) &&
        !scopes.any((s) => s.season == work.season)) {
      continue;
    }
    if (scopes.any(
      (p) =>
          p.season != work.season ||
          p.episode != null && p.episode != work.episode,
    )) {
      continue;
    }
    final basename = parts.last.replaceFirst(_video, '');
    final leaf = originalEpisode(basename);
    if (leaf.episode != null && leaf.episode != work.episode) continue;
    // A pack directory gives season context, never the member's episode.
    if (leaf.episode == work.episode &&
        (leaf.season == null || leaf.season == work.season)) {
      hits.add(f);
    } else if (!edition.pack &&
        videos.length == 1 &&
        leaf.episode == null &&
        !RegExp(
          r'(?:^|[^a-z0-9])(?:e|ep)\d|第.+[集话話]',
          caseSensitive: false,
        ).hasMatch(parts.last)) {
      hits.add(f);
    }
  }
  return hits.length == 1 ? hits.single : null;
}
