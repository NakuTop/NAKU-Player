import 'dart:convert';

import 'package:html/parser.dart' as html;

import 'cinema_media_identity.dart';

String cinemaRatingName(String value) => cinemaMediaBaseTitle(
  value,
).toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{Cf}]', unicode: true), '');

String cinemaRatingSeriesName(String value) => value
    .replaceAll(RegExp(r'第[一二三四五六七八九十百零〇两\d]+季'), '')
    .replaceAll(
      RegExp(r'\bseason\s*\d+\b|\bs\d{1,2}\b', caseSensitive: false),
      '',
    )
    .trim();

/// An unnumbered catalogue series may match its first season only when the
/// caller separately verifies the same premiere year and TV kind. A subtitle
/// is accepted only with an already exact official subject ID and season.
bool cinemaOfficialTitleMatches(
  String source,
  Iterable<String> officialNames, {
  required String kind,
  required String sourceSeason,
  required String officialSeason,
  bool exactId = false,
}) {
  final names = officialNames.where((n) => n.trim().isNotEmpty).toList();
  if (sourceSeason != officialSeason &&
      !(kind == 'tv' && sourceSeason.isEmpty && officialSeason == '1')) {
    return false;
  }
  if (names.map(cinemaRatingName).contains(cinemaRatingName(source))) {
    return true;
  }
  if (kind != 'tv') return false;
  if (sourceSeason.isEmpty && officialSeason == '1') {
    return names
        .map(cinemaRatingSeriesName)
        .map(cinemaRatingName)
        .contains(cinemaRatingName(source));
  }
  if (exactId &&
      sourceSeason.isNotEmpty &&
      sourceSeason == officialSeason &&
      RegExp(r'[:：]').hasMatch(source)) {
    final prefix = cinemaRatingName(
      cinemaRatingSeriesName(source.split(RegExp(r'[:：]')).first),
    );
    return names
        .map(cinemaRatingSeriesName)
        .map(cinemaRatingName)
        .contains(prefix);
  }
  return false;
}

/// Official suggestions supply candidate identities, never rating values.
/// Require one exact name, release year and film/series type. People, episodes,
/// another remake and an ambiguous result cannot become an automatic binding.
String cinemaImdbSuggestionId(
  Map<String, dynamic> data, {
  required Set<String> names,
  required String year,
  required String kind,
}) {
  final expected = names
      .map(cinemaRatingName)
      .where((n) => n.isNotEmpty)
      .toSet();
  final ids = <String>{};
  for (final row in (data['d'] as List? ?? []).whereType<Map>()) {
    final id = row['id']?.toString() ?? '';
    final type = row['qid']?.toString() ?? '';
    final compatible = kind == 'tv'
        ? ['tvSeries', 'tvMiniSeries'].contains(type)
        : ['movie', 'tvMovie', 'short', 'tvShort'].contains(type);
    if (RegExp(r'^tt[0-9]{7,10}$').hasMatch(id) &&
        compatible &&
        RegExp(r'^\d{4}$').hasMatch(year) &&
        row['y']?.toString() == year &&
        expected.contains(cinemaRatingName(row['l']?.toString() ?? ''))) {
      ids.add(id);
    }
  }
  return ids.length == 1 ? ids.single : '';
}

/// The public search page exposes names and years. Ignore all scores in it;
/// a selected candidate must still pass its canonical detail-page checks.
String cinemaRtSearchId(
  String body, {
  required Set<String> names,
  required String year,
  required String kind,
  String season = '',
}) {
  final candidates = cinemaRtSearchCandidates(
    body,
    names: names,
    year: year,
    kind: kind,
    season: season,
  );
  return candidates.length == 1 ? candidates.keys.single : '';
}

Map<String, String> cinemaRtSearchCandidates(
  String body, {
  required Set<String> names,
  required String year,
  required String kind,
  String season = '',
}) {
  final expected = names
      .map(cinemaRatingName)
      .where((n) => n.isNotEmpty)
      .toSet();
  final document = html.parse(body);
  final ids = <String, String>{};
  for (final row in document.querySelectorAll('search-page-media-row')) {
    final anchor = row.querySelector('a[slot="title"]');
    if (anchor == null || !expected.contains(cinemaRatingName(anchor.text))) {
      continue;
    }
    final uri = Uri.tryParse(anchor.attributes['href'] ?? '');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'www.rottentomatoes.com') {
      continue;
    }
    final id = uri.path
        .replaceFirst(RegExp(r'^/'), '')
        .replaceFirst(RegExp(r'/$'), '');
    if (!(kind == 'tv'
            ? RegExp(r'^tv/[a-zA-Z0-9_-]+$')
            : RegExp(r'^m/[a-zA-Z0-9_-]+$'))
        .hasMatch(id)) {
      continue;
    }
    final candidateYear = kind == 'tv'
        ? row.attributes['start-year'] ?? row.attributes['startyear']
        : row.attributes['release-year'] ?? row.attributes['releaseyear'];
    if (RegExp(r'^\d{4}$').hasMatch(year) &&
        (candidateYear == year ||
            kind == 'tv' &&
                season.isNotEmpty &&
                int.tryParse(candidateYear ?? '') != null &&
                int.parse(candidateYear!) <= int.parse(year))) {
      ids[id] = candidateYear!;
    }
  }
  return ids;
}

Iterable<Map> cinemaRatingJsonNodes(Object? value) sync* {
  if (value is List) {
    for (final item in value) {
      yield* cinemaRatingJsonNodes(item);
    }
  } else if (value is Map) {
    yield value;
    yield* cinemaRatingJsonNodes(value['@graph']);
  }
}

/// A derived season URL or search result must resolve to that exact canonical
/// work and its release year. A redirect to the series or a different season
/// cannot pass. A missing rating does not invalidate the work's identity.
bool cinemaRtPageMatches(
  String id,
  String body, {
  required String year,
  required String kind,
}) {
  if (!RegExp(r'^\d{4}$').hasMatch(year)) return false;
  final document = html.parse(body);
  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    Object? data;
    try {
      data = jsonDecode(script.text);
    } catch (_) {
      continue;
    }
    for (final node in cinemaRatingJsonNodes(data)) {
      final uri = Uri.tryParse((node['url'] ?? node['@id'])?.toString() ?? '');
      if (uri?.host != 'www.rottentomatoes.com' ||
          uri?.path.replaceFirst(RegExp(r'/$'), '') != '/$id') {
        continue;
      }
      final expectedType = kind == 'movie'
          ? 'Movie'
          : RegExp(r'/s[0-9]+$').hasMatch(id)
          ? 'TVSeason'
          : 'TVSeries';
      if (node['@type'] != expectedType) continue;
      final dates = [
        'datePublished',
        'dateCreated',
        'startDate',
      ].map((k) => node[k]?.toString() ?? '').toList();
      // RT sometimes places the release year in the canonical watch metadata.
      final watch = document.querySelector('script[data-json="whereToWatch"]');
      if (watch != null) {
        try {
          dates.add(
            (jsonDecode(watch.text) as Map)['releaseYear']?.toString() ?? '',
          );
        } catch (_) {
          /* Optional metadata. */
        }
      }
      if (dates.any(
        (d) =>
            RegExp(r'^\d{4}(?:-|$)').hasMatch(d) && d.substring(0, 4) == year,
      )) {
        return true;
      }
    }
  }
  return false;
}
