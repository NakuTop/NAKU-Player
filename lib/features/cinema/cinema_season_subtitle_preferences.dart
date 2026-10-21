import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'cinema_online_subtitles.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_timing.dart';

const _field = 'seasonSubtitleProfilesV1';
final _writes = Expando<Future<void>>();

/// A preference for this library work and season, not a subtitle for every
/// episode. Each episode still has to obtain its own verified matching file.
class CinemaSeasonSubtitleProfile {
  const CinemaSeasonSubtitleProfile({
    required this.season,
    required this.fromEpisode,
    required this.queryTitle,
    required this.language,
    required this.name,
    this.imdbId = '',
    this.provider = '',
    this.releaseFormat = '',
    this.bilingual = false,
    this.timing = const CinemaSubtitleTiming(),
  });

  final int season, fromEpisode;
  final String queryTitle, imdbId, language, name, provider, releaseFormat;
  final bool bilingual;
  final CinemaSubtitleTiming timing;

  bool appliesTo(int episode) => episode >= fromEpisode && episode <= 9999;

  CinemaSeasonSubtitleProfile withTiming(CinemaSubtitleTiming value) =>
      CinemaSeasonSubtitleProfile(
        season: season,
        fromEpisode: fromEpisode,
        queryTitle: queryTitle,
        imdbId: imdbId,
        language: language,
        name: name,
        provider: provider,
        releaseFormat: releaseFormat,
        bilingual: bilingual,
        timing: value,
      );

  Map<String, dynamic> _json() => {
    'season': season,
    'fromEpisode': fromEpisode,
    'queryTitle': queryTitle,
    'imdbId': imdbId,
    'language': language,
    'name': name,
    'provider': provider,
    'releaseFormat': releaseFormat,
    'bilingual': bilingual,
    'scale': timing.scale,
    'offset': timing.offsetSeconds,
  };

  static CinemaSeasonSubtitleProfile? _parse(Object? value) {
    if (value is! Map) return null;
    final season = value['season'], fromEpisode = value['fromEpisode'];
    final scale = value['scale'], offset = value['offset'];
    final title = value['queryTitle'], lang = value['language'];
    final name = value['name'], provider = value['provider'];
    final release = value['releaseFormat'], imdb = value['imdbId'];
    if (season is! int ||
        season < 0 ||
        season > 999 ||
        fromEpisode is! int ||
        fromEpisode < 1 ||
        fromEpisode > 9999 ||
        scale is! num ||
        offset is! num ||
        !_validTiming(scale.toDouble(), offset.toDouble()) ||
        title is! String ||
        title.isEmpty ||
        title != _publicText(title) ||
        lang is! String ||
        lang != _language(lang) ||
        lang.isEmpty ||
        name is! String ||
        name != _publicText(name, basename: true) ||
        provider is! String ||
        provider != _publicText(provider) ||
        release is! String ||
        release != _publicText(release) ||
        imdb is! String ||
        (imdb.isNotEmpty && !RegExp(r'^tt\d+$').hasMatch(imdb)) ||
        value['bilingual'] is! bool) {
      return null;
    }
    return CinemaSeasonSubtitleProfile(
      season: season,
      fromEpisode: fromEpisode,
      queryTitle: title,
      language: lang,
      name: name,
      provider: provider,
      releaseFormat: release,
      imdbId: imdb,
      bilingual: value['bilingual'] as bool,
      timing: CinemaSubtitleTiming(
        scale: scale.toDouble(),
        offsetSeconds: offset.toDouble(),
      ),
    );
  }
}

/// Only the hashed work identity and public catalog metadata are persisted.
/// Neither a playback URL/path nor subtitle dialogue enters these records.
/// Writes are serialized per store, including across preference instances.
class CinemaSeasonSubtitlePreferences {
  CinemaSeasonSubtitlePreferences(this.store);
  final CinemaStore store;

  /// Wait for pending selections and timing updates before the next episode
  /// snapshots its inherited preference.
  Future<void> flush() => _writes[store] ?? Future<void>.value();

  static String _key(String identity, int season) =>
      '${sha256.convert(utf8.encode(identity))}:$season';

  CinemaSeasonSubtitleProfile? read(String seriesIdentity, int season) {
    if (seriesIdentity.trim().isEmpty || season < 0 || season > 999) {
      return null;
    }
    final records = store.extras[_field];
    final profile = CinemaSeasonSubtitleProfile._parse(
      records is Map ? records[_key(seriesIdentity, season)] : null,
    );
    return profile?.season == season ? profile : null;
  }

  Future<void> remember({
    required String seriesIdentity,
    required int season,
    required int fromEpisode,
    required String queryTitle,
    String imdbId = '',
    required Map<String, dynamic> row,
    CinemaSubtitleTiming timing = const CinemaSubtitleTiming(),
  }) {
    final title = _publicText(queryTitle);
    final language = _language('${row['lang'] ?? ''}');
    if (seriesIdentity.trim().isEmpty ||
        season < 0 ||
        season > 999 ||
        fromEpisode < 1 ||
        fromEpisode > 9999 ||
        title.isEmpty ||
        language.isEmpty ||
        row['verified'] != true ||
        !_episodeMatches(_rowName(row), season, fromEpisode) ||
        !_validTiming(timing.scale, timing.offsetSeconds)) {
      return Future<void>.error(const FormatException('仅可记忆已验证的同季字幕和有效校准'));
    }
    final profile = CinemaSeasonSubtitleProfile(
      season: season,
      fromEpisode: fromEpisode,
      queryTitle: title,
      imdbId: RegExp(r'^tt\d+$').hasMatch(imdbId) ? imdbId : '',
      language: language,
      name: _publicText(_rowName(row), basename: true),
      provider: _publicText('${row['provider'] ?? ''}'),
      releaseFormat: _publicText('${row['releaseFormat'] ?? ''}'),
      bilingual: row['bilingual'] == true,
      timing: timing,
    );
    return _mutate((records) {
      final key = _key(seriesIdentity, season);
      records.remove(key);
      records[key] = profile._json();
    });
  }

  Future<void> updateTiming(
    String seriesIdentity,
    int season,
    CinemaSubtitleTiming timing,
  ) {
    if (!_validTiming(timing.scale, timing.offsetSeconds)) {
      return Future<void>.error(const FormatException('字幕校准超出有效范围'));
    }
    return _mutate((records) {
      final key = _key(seriesIdentity, season);
      final profile = CinemaSeasonSubtitleProfile._parse(records[key]);
      if (profile == null || profile.season != season) return;
      records.remove(key);
      records[key] = profile.withTiming(timing)._json();
    });
  }

  Future<void> clear(String seriesIdentity, int season) =>
      _mutate((records) => records.remove(_key(seriesIdentity, season)));

  Future<void> _mutate(void Function(Map<String, dynamic>) mutate) {
    final previous = _writes[store] ?? Future<void>.value();
    late Future<void> pending;
    pending = previous
        .catchError((Object _) {})
        .then((_) async {
          final old = store.extras[_field];
          final records = <String, dynamic>{
            if (old is Map)
              for (final item in old.entries)
                if (item.key is String &&
                    CinemaSeasonSubtitleProfile._parse(item.value) != null)
                  item.key as String: item.value,
          };
          mutate(records);
          while (records.length > 64) {
            records.remove(records.keys.first);
          }
          await store.setExtra(_field, records);
        })
        .whenComplete(() {
          if (identical(_writes[store], pending)) _writes[store] = null;
        });
    _writes[store] = pending;
    return pending;
  }
}

/// An early streaming result may be used only when its release family matches
/// exactly after removing episode markers and filename separators. Fuzzy title
/// overlap or a shared provider is not enough to inherit another cut's timing.
bool cinemaSeasonSubtitleFamilyMatches(
  CinemaSeasonSubtitleProfile profile,
  Map<String, dynamic> row,
) {
  if (row['verified'] != true ||
      _language('${row['lang'] ?? ''}') != profile.language) {
    return false;
  }
  final wanted = '${profile.name} ${profile.releaseFormat}';
  final candidate =
      '${_publicText(_rowName(row), basename: true)} ${row['releaseFormat'] ?? ''}';
  final script = _script(profile.name);
  if (script.isNotEmpty && _script(candidate) != script) return false;
  final family = _family(wanted).replaceAll(' ', '');
  return family.isNotEmpty && family == _family(candidate).replaceAll(' ', '');
}

/// Select a verified file for this episode. A missing language never silently
/// changes Chinese to English, and an explicit other episode is never reused.
Map<String, dynamic>? chooseCinemaSeasonSubtitle(
  CinemaSeasonSubtitleProfile profile,
  List<Map<String, dynamic>> verifiedRows, {
  required int season,
  required int episode,
  String playbackName = '',
}) {
  if (season != profile.season || !profile.appliesTo(episode)) return null;
  final eligible = verifiedRows.where(
    (row) =>
        row['verified'] == true &&
        _language('${row['lang'] ?? ''}') == profile.language &&
        _episodeMatches(
          _publicText(_rowName(row), basename: true),
          season,
          episode,
        ),
  );
  Map<String, dynamic>? best;
  var bestScore = -100000;
  final wanted = '${profile.name} ${profile.releaseFormat}';
  final family = _family(wanted);
  final tokens = _tokens(family);
  for (final row in eligible) {
    final candidate =
        '${_publicText(_rowName(row), basename: true)} ${row['releaseFormat'] ?? ''}';
    final otherFamily = _family(candidate);
    final otherTokens = _tokens(otherFamily);
    var score = cinemaSubtitleReleaseScore(candidate, wanted) * 24;
    score += cinemaSubtitleReleaseScore(candidate, playbackName) * 4;
    if (family.isNotEmpty && family == otherFamily) score += 1000;
    final union = tokens.union(otherTokens).length;
    if (union > 0) {
      score += (160 * tokens.intersection(otherTokens).length / union).round();
    }
    if ('${row['provider'] ?? ''}' == profile.provider) score += 12;
    if ((row['bilingual'] == true) == profile.bilingual) score += 20;
    final script = _script(profile.name), candidateScript = _script(candidate);
    if (script.isNotEmpty && script == candidateScript) score += 30;
    if (best == null || score > bestScore) {
      best = row;
      bestScore = score;
    }
  }
  return best;
}

bool _validTiming(double scale, double offset) =>
    scale.isFinite &&
    offset.isFinite &&
    scale >= .5 &&
    scale <= 2 &&
    offset.abs() <= 21600;

String _language(String value) {
  final lang = value.toLowerCase().replaceAll('_', '-').trim();
  if (lang.isEmpty || const {'all', 'und', 'null', 'zh-eng'}.contains(lang)) {
    return '';
  }
  if (cinemaSubtitleLanguageMatches(lang, 'zh')) return 'zh';
  if (cinemaSubtitleLanguageMatches(lang, 'eng')) return 'eng';
  if (cinemaSubtitleLanguageMatches(lang, 'jpn')) return 'jpn';
  return RegExp(r'^[a-z]{2,3}(?:-[a-z]{2,4})?$').hasMatch(lang) ? lang : '';
}

String _publicText(String value, {bool basename = false}) {
  var text = value.trim();
  if (text.contains('://')) return '';
  if (basename) {
    text = text.split(RegExp(r'[/\\]')).last;
  } else if (RegExp(r'^[a-zA-Z]:[\\/]|^[/\\]').hasMatch(text)) {
    return '';
  }
  text = text.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return text.length > 1024 ? text.substring(0, 1024) : text;
}

String _rowName(Map<String, dynamic> row) {
  for (final field in [
    'archiveEntry',
    'subtitleFileName',
    'movieReleaseName',
  ]) {
    final name = row[field]?.toString().trim() ?? '';
    if (name.isNotEmpty) return name;
  }
  return '';
}

String _script(String name) =>
    RegExp(
      r'繁|(?<![a-z])(?:cht|zht)(?![a-z])',
      caseSensitive: false,
    ).hasMatch(name)
    ? 'traditional'
    : RegExp(
        r'简|(?<![a-z])(?:chs|zhs)(?![a-z])',
        caseSensitive: false,
      ).hasMatch(name)
    ? 'simplified'
    : '';

String _family(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'(?<![a-z0-9])s\d{1,3}[ ._-]*e\d{1,4}(?!\d)'), ' ')
    .replaceAll(RegExp(r'(?<![a-z0-9])\d{1,3}x\d{1,4}(?!\d)'), ' ')
    .replaceAll(
      RegExp(r'(?<![a-z0-9])(?:season|episode|s|e)\s*\d{1,4}(?!\d)'),
      ' ',
    )
    .replaceAll(RegExp(r'第\s*[零一二两三四五六七八九十百\d]+\s*[季集话話]'), ' ')
    .replaceAll(RegExp(r'\.(?:srt|ass|ssa|vtt|sub)\b'), ' ')
    .replaceAll(RegExp(r'[\s._\-\[\](){}]+'), ' ')
    .trim();

Set<String> _tokens(String value) =>
    value.split(' ').where((token) => token.length > 1).toSet();

bool _episodeMatches(String name, int season, int episode) {
  final seasons = RegExp(
    r'(?<![a-z0-9])(?:season\s*|s)(\d{1,3})(?!\d)',
    caseSensitive: false,
  ).allMatches(name);
  if (seasons.any((match) => int.parse(match[1]!) != season)) return false;
  final chineseSeasons = RegExp(
    r'第\s*([零一二两三四五六七八九十百千\d]+)\s*季',
  ).allMatches(name);
  if (chineseSeasons.any((match) => _number(match[1]!) != season)) return false;
  final sCodes = RegExp(
    r'(?<![a-z0-9])s(\d{1,3})[ ._-]*e(\d{1,4})(?!\d)',
    caseSensitive: false,
  ).allMatches(name);
  if (sCodes.isNotEmpty &&
      !sCodes.any(
        (code) =>
            int.parse(code[1]!) == season && int.parse(code[2]!) == episode,
      )) {
    return false;
  }
  final codes = RegExp(
    r'(?<![a-z0-9])(\d{1,3})x(\d{1,4})(?!\d)',
    caseSensitive: false,
  ).allMatches(name);
  if (codes.isNotEmpty &&
      !codes.any(
        (code) =>
            int.parse(code[1]!) == season && int.parse(code[2]!) == episode,
      )) {
    return false;
  }
  final episodes = RegExp(
    r'(?:(?<![a-z0-9])(?:episode\s*|e)(\d{1,4})(?!\d))|(?:第\s*([零一二两三四五六七八九十百千\d]+)\s*[集话話])',
    caseSensitive: false,
  ).allMatches(name);
  return episodes.isEmpty ||
      episodes.any((match) {
        final number = match[1] != null
            ? int.parse(match[1]!)
            : _number(match[2]!);
        return number == episode;
      });
}

int _number(String value) {
  final integer = int.tryParse(value);
  if (integer != null) return integer;
  const digits = '零一二三四五六七八九';
  const units = {'十': 10, '百': 100, '千': 1000};
  var total = 0, pending = 0;
  for (final char in value.split('')) {
    final unit = units[char];
    if (unit != null) {
      total += (pending == 0 ? 1 : pending) * unit;
      pending = 0;
    } else {
      pending = char == '两' ? 2 : digits.indexOf(char);
      if (pending < 0) return -1;
    }
  }
  return total + pending;
}
