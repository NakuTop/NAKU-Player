import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// A recommendation identifies a catalogue work, never a playable source.
class DoubanRecommendation {
  const DoubanRecommendation({
    required this.doubanId,
    required this.title,
    this.year = '',
    this.poster = '',
  });
  final String doubanId, title, year, poster;
  String get url => 'https://movie.douban.com/subject/$doubanId/';
  Map<String, dynamic> toJson() => {
    'doubanId': doubanId,
    'title': title,
    'year': year,
    'poster': poster,
  };
  factory DoubanRecommendation.fromJson(Map<String, dynamic> json) =>
      DoubanRecommendation(
        doubanId: json['doubanId'] as String,
        title: json['title'] as String,
        year: json['year'] as String? ?? '',
        poster: json['poster'] as String? ?? '',
      );
}

class DoubanStarShare {
  const DoubanStarShare({required this.stars, required this.share});
  final int stars;

  /// Original proportion in [0, 1]; not a count or a five-point score.
  final double share;
  Map<String, dynamic> toJson() => {'stars': stars, 'share': share};
}

class DoubanSubjectDetails {
  const DoubanSubjectDetails({
    required this.doubanId,
    this.title = '',
    this.year = '',
    this.originalTitle = '',
    this.releaseDates = const [],
    this.durations = const [],
    this.aliases = const [],
    this.stars = const [],
    this.recommendations = const [],
    this.score,
    this.ratingCount,
    this.fetchedAt,
    this.starsFetchedAt,
    this.recommendationsFetchedAt,
    this.note = '',
    this.stale = false,
  });
  final String doubanId, title, year, originalTitle, note;
  final List<String> releaseDates, durations, aliases;

  /// Descending 5 → 1 stars. Empty means unavailable, never five zero bars.
  final List<DoubanStarShare> stars;
  final List<DoubanRecommendation> recommendations;
  final double? score;
  final int? ratingCount;
  final DateTime? fetchedAt;
  final DateTime? starsFetchedAt, recommendationsFetchedAt;
  final bool stale;
  String get url => 'https://movie.douban.com/subject/$doubanId/';
  bool get hasContent => title.isNotEmpty;

  DoubanSubjectDetails copyWith({
    List<DoubanStarShare>? stars,
    List<DoubanRecommendation>? recommendations,
    String? note,
    bool? stale,
    DateTime? starsFetchedAt,
    DateTime? recommendationsFetchedAt,
  }) => DoubanSubjectDetails(
    doubanId: doubanId,
    title: title,
    year: year,
    originalTitle: originalTitle,
    releaseDates: releaseDates,
    durations: durations,
    aliases: aliases,
    stars: stars ?? this.stars,
    recommendations: recommendations ?? this.recommendations,
    score: score,
    ratingCount: ratingCount,
    fetchedAt: fetchedAt,
    starsFetchedAt: starsFetchedAt ?? this.starsFetchedAt,
    recommendationsFetchedAt:
        recommendationsFetchedAt ?? this.recommendationsFetchedAt,
    note: note ?? this.note,
    stale: stale ?? this.stale,
  );

  Map<String, dynamic> toJson() => {
    'doubanId': doubanId,
    'title': title,
    'year': year,
    'originalTitle': originalTitle,
    'releaseDates': releaseDates,
    'durations': durations,
    'aliases': aliases,
    'stars': stars.map((e) => e.toJson()).toList(),
    'recommendations': recommendations.map((e) => e.toJson()).toList(),
    'score': score,
    'ratingCount': ratingCount,
    'fetchedAt': fetchedAt?.toIso8601String(),
    'starsFetchedAt': starsFetchedAt?.toIso8601String(),
    'recommendationsFetchedAt': recommendationsFetchedAt?.toIso8601String(),
    'note': note,
  };

  factory DoubanSubjectDetails.fromJson(Map<String, dynamic> json) {
    final stars = (json['stars'] as List? ?? [])
        .map(
          (e) => DoubanStarShare(
            stars: e['stars'] as int,
            share: (e['share'] as num).toDouble(),
          ),
        )
        .toList();
    if (stars.isNotEmpty && !_validShares(stars)) {
      throw const FormatException('缓存中的星级比例无效');
    }
    return DoubanSubjectDetails(
      doubanId: json['doubanId'] as String,
      title: json['title'] as String? ?? '',
      year: json['year'] as String? ?? '',
      originalTitle: json['originalTitle'] as String? ?? '',
      releaseDates: _strings(json['releaseDates']),
      durations: _strings(json['durations']),
      aliases: _strings(json['aliases']),
      stars: stars,
      recommendations: (json['recommendations'] as List? ?? [])
          .take(12)
          .map(
            (e) => DoubanRecommendation.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(),
      score: _score(json['score']),
      ratingCount: _count(json['ratingCount']),
      fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? ''),
      starsFetchedAt: DateTime.tryParse(
        json['starsFetchedAt']?.toString() ?? '',
      ),
      recommendationsFetchedAt: DateTime.tryParse(
        json['recommendationsFetchedAt']?.toString() ?? '',
      ),
      note: json['note'] as String? ?? '',
    );
  }
}

String? doubanIdFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      !['movie.douban.com', 'm.douban.com'].contains(uri.host) ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return RegExp(
    r'^/(?:movie/)?subject/([1-9][0-9]{1,11})/?$',
  ).firstMatch(uri.path)?.group(1);
}

/// Public JSON used by Douban's own mobile subject_header.js. Exact ID required.
DoubanSubjectDetails parseDoubanSubjectJson(
  String expectedId,
  Map<String, dynamic> data,
) {
  if (data['id']?.toString() != expectedId ||
      !['movie', 'tv'].contains(data['type']) ||
      (data['url'] != null &&
          doubanIdFromUrl(data['url'].toString()) != expectedId)) {
    throw const FormatException('豆瓣返回的条目身份不一致');
  }
  final title = _text(data['title']);
  if (title.isEmpty) throw const FormatException('豆瓣条目缺少片名');
  final rating = data['rating'];
  final scale = rating is Map ? num.tryParse('${rating['max']}') : null;
  return DoubanSubjectDetails(
    doubanId: expectedId,
    title: title,
    year: _text(data['year']),
    originalTitle: _text(data['original_title']),
    releaseDates: _strings(data['pubdate']),
    durations: _strings(data['durations']),
    aliases: _strings(data['aka']),
    score: scale == 10 ? _score(rating['value']) : null,
    ratingCount: scale == 10 ? _count(rating['count']) : null,
    fetchedAt: DateTime.now(),
    note: '豆瓣官网公开条目',
  );
}

/// Douban's public /rating endpoint returns proportions ordered 1 → 5.
/// done_count counts watched entries, not voters; never use it as ratingCount.
List<DoubanStarShare> parseDoubanStarShares(Map<String, dynamic> data) {
  final values = data['stats'];
  if (values is! List || values.length != 5) {
    throw const FormatException('豆瓣暂未提供星级分布');
  }
  final shares = <DoubanStarShare>[];
  for (var i = 4; i >= 0; i--) {
    final value = values[i];
    if (value is! num) throw const FormatException('豆瓣星级分布格式无效');
    shares.add(DoubanStarShare(stars: i + 1, share: value.toDouble()));
  }
  if (!_validShares(shares)) throw const FormatException('豆瓣星级分布格式无效');
  return shares;
}

bool _validShares(List<DoubanStarShare> shares) =>
    shares.length == 5 &&
    shares.map((s) => s.stars).toSet().containsAll([1, 2, 3, 4, 5]) &&
    shares.every((s) => s.share.isFinite && s.share >= 0 && s.share <= 1) &&
    (shares.fold<double>(0, (sum, s) => sum + s.share) - 1).abs() <= .02;

DoubanSubjectDetails parseDoubanSubjectHtml(String expectedId, String body) {
  final document = html.parse(body);
  final ownUrls = [
    ...document
        .querySelectorAll('meta[property="og:url"]')
        .map((e) => e.attributes['content']),
    ...document
        .querySelectorAll('link[rel="canonical"]')
        .map((e) => e.attributes['href']),
  ].whereType<String>().toList();
  Map? ld;
  for (final script in document.querySelectorAll(
    'script[type="application/ld+json"]',
  )) {
    Object? value;
    try {
      value = jsonDecode(script.text);
    } catch (_) {
      continue;
    }
    for (final node in _jsonNodes(value)) {
      if ([
            'Movie',
            'TVSeries',
            'TVSeason',
            'TVEpisode',
            'CreativeWork',
          ].contains(node['@type']) &&
          doubanIdFromUrl('${node['url'] ?? node['@id']}') == expectedId) {
        ld = node;
      }
    }
  }
  if ((ownUrls.isEmpty && ld == null) ||
      ownUrls.any((url) => doubanIdFromUrl(url) != expectedId)) {
    throw const FormatException('豆瓣页面要求验证或条目身份不一致');
  }
  String text(String selector) => _text(document.querySelector(selector)?.text);
  final original = text('.sub-original-title');
  final ldRating = ld?['aggregateRating'];
  double? score;
  int? count;
  if (ldRating is Map && num.tryParse('${ldRating['bestRating']}') == 10) {
    score = _score(ldRating['ratingValue']);
    count = _count(ldRating['ratingCount'] ?? ldRating['reviewCount']);
  }
  score ??= _score(
    document
            .querySelector('meta[itemprop="ratingValue"]')
            ?.attributes['content'] ??
        text('[property="v:average"]'),
  );
  count ??= _count(
    document
            .querySelector('meta[itemprop="reviewCount"]')
            ?.attributes['content'] ??
        text('[property="v:votes"]'),
  );
  final meta = text('.sub-meta');
  final releases = document
      .querySelectorAll('[property="v:initialReleaseDate"]')
      .map((e) => _text(e.text))
      .where((e) => e.isNotEmpty)
      .toList();
  releases.addAll(
    RegExp(
      r'\d{4}-\d{2}-\d{2}(?:[（(][^）)]+[）)])?(?=上映)',
    ).allMatches(meta).map((m) => m.group(0)!),
  );
  final durations = document
      .querySelectorAll('[property="v:runtime"]')
      .map((e) => _text(e.text))
      .where((e) => e.isNotEmpty)
      .toList();
  durations.addAll(
    RegExp(r'(?<=片长)[^/]+').allMatches(meta).map((m) => m.group(0)!.trim()),
  );
  final aliases = <String>[];
  for (final label in document.querySelectorAll('#info .pl')) {
    if (label.text.trim().startsWith('又名')) {
      final buffer = StringBuffer();
      final siblings = label.parentNode?.nodes ?? <Node>[];
      for (final n in siblings.skip(siblings.indexOf(label) + 1)) {
        if (n is Element && n.localName == 'br') break;
        buffer.write(n.text);
      }
      aliases.addAll(
        buffer.toString().split('/').map(_text).where((s) => s.isNotEmpty),
      );
    }
  }
  final shares = <DoubanStarShare>[];
  for (final row in document.querySelectorAll('.ratings-on-weight .item')) {
    final stars = int.tryParse(
      RegExp(
            r'[1-5]',
          ).firstMatch(row.querySelector('.starstop')?.text ?? '')?.group(0) ??
          '',
    );
    final percent = double.tryParse(
      (row.querySelector('.rating_per')?.text ?? '').replaceAll('%', '').trim(),
    );
    if (stars != null && percent != null) {
      shares.add(DoubanStarShare(stars: stars, share: percent / 100));
    }
  }
  shares.sort((a, b) => b.stars.compareTo(a.stars));
  final recommendations = <String, DoubanRecommendation>{};
  for (final item in document.querySelectorAll(
    '.subject-rec li, #recommendations dl',
  )) {
    for (final anchor in item.querySelectorAll('a[href]')) {
      final url = Uri.parse(
        'https://m.douban.com/',
      ).resolve(anchor.attributes['href']!);
      final id = doubanIdFromUrl(url.toString());
      final img = item.querySelector('img');
      final name = _text(
        item.querySelector('h3')?.text ?? img?.attributes['alt'] ?? anchor.text,
      );
      if (id == null ||
          id == expectedId ||
          name.isEmpty ||
          recommendations.length >= 12) {
        continue;
      }
      final image = img?.attributes['data-src'] ?? img?.attributes['src'] ?? '';
      final parsedImage = Uri.tryParse(image);
      recommendations[id] = DoubanRecommendation(
        doubanId: id,
        title: name,
        poster:
            parsedImage != null &&
                parsedImage.scheme == 'https' &&
                parsedImage.host.endsWith('.doubanio.com')
            ? image
            : '',
      );
    }
  }
  final title = text('.sub-title').isNotEmpty
      ? text('.sub-title')
      : (text('[property="v:itemreviewed"]').isNotEmpty
            ? text('[property="v:itemreviewed"]')
            : _text(ld?['name']));
  return DoubanSubjectDetails(
    doubanId: expectedId,
    title: title,
    year:
        RegExp(r'[（(](\d{4})[）)]').firstMatch(original)?.group(1) ??
        RegExp(r'\d{4}').firstMatch(text('.year'))?.group(0) ??
        '',
    originalTitle: original.replaceFirst(RegExp(r'\s*[（(]\d{4}[）)]\s*$'), ''),
    releaseDates: releases.toSet().toList(),
    durations: durations.toSet().toList(),
    aliases: aliases,
    stars: _validShares(shares) ? shares : const [],
    recommendations: recommendations.values.toList(),
    score: score,
    ratingCount: count,
    fetchedAt: DateTime.now(),
    note: '豆瓣官网公开页面',
  );
}

Iterable<Map> _jsonNodes(Object? value) sync* {
  if (value is List) {
    for (final e in value) {
      yield* _jsonNodes(e);
    }
  }
  if (value is Map) {
    yield value;
    if (value['@graph'] != null) yield* _jsonNodes(value['@graph']);
  }
}

String _text(Object? value) =>
    value is String ? value.replaceAll(RegExp(r'\s+'), ' ').trim() : '';
List<String> _strings(Object? value) => value is List
    ? value
          .whereType<String>()
          .map(_text)
          .where((s) => s.isNotEmpty)
          .take(32)
          .toSet()
          .toList()
    : const [];
double? _score(Object? value) {
  final number = double.tryParse(value?.toString() ?? '');
  return number != null && number.isFinite && number > 0 && number <= 10
      ? number
      : null;
}

int? _count(Object? value) {
  final number = int.tryParse(value?.toString().replaceAll(',', '') ?? '');
  return number != null && number >= 0 ? number : null;
}
