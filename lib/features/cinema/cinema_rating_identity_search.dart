import 'dart:async';
import 'dart:convert';

import 'cinema_models.dart';
import 'cinema_search_discovery.dart';

/// Reuses public search's candidate cache, but applies stricter rules than a
/// search results list. Ambiguous titles, years, kinds and seasons stay unbound.
class CinemaRatingIdentitySearch {
  CinemaRatingIdentitySearch({required this.search, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Future<CinemaSearchDiscovery> Function(String) search;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, CinemaDiscoveryTitle?)>{};
  final _pending = <String, Future<CinemaDiscoveryTitle?>>{};
  final _waiters = <Completer<void>>[];
  int _running = 0;

  Future<void> _acquire() async {
    if (_running < 2) {
      _running++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _running--;
    }
  }

  Future<CinemaTitle> resolve(CinemaTitle title) async {
    if (title.doubanId.isNotEmpty ||
        !RegExp(r'^\d{4}$').hasMatch(title.year.trim()) ||
        _kind(title.category).isEmpty) {
      return title;
    }
    final key = jsonEncode([
      title.title,
      title.aliases,
      title.year,
      title.category,
    ]);
    final cached = _cache[key];
    CinemaDiscoveryTitle? candidate;
    if (cached != null &&
        _now().difference(cached.$1) < const Duration(minutes: 15)) {
      candidate = cached.$2;
    } else {
      // Drop excess speculative work without caching a failure; visible cards
      // can retry after navigation. Requests already queued still coalesce.
      if (!_pending.containsKey(key) && _pending.length >= 34) return title;
      candidate = await _pending.putIfAbsent(key, () async {
        await _acquire();
        try {
          final result = await search(title.title);
          final matched = _candidate(title, result.titles);
          _cache[key] = (_now(), matched);
          while (_cache.length > 128) {
            _cache.remove(_cache.keys.first);
          }
          return matched;
        } catch (_) {
          // A restricted search is a missing identifier, never a guessed score.
          _cache[key] = (_now(), null);
          return null;
        } finally {
          _pending.remove(key);
          _release();
        }
      });
    }
    if (candidate == null) return title;
    // Discovery ratings are from exact public metadata, but source fallback is
    // kept separate: the ratings repository still verifies this ID itself.
    return title.copyWith(doubanId: candidate.id);
  }

  /// Pure counterpart for candidates already available in the search page.
  /// A source with existing secondary IDs needs an exact crosswalk, so this
  /// name-based path deliberately does not add an unverified conflicting ID.
  static CinemaTitle? match(
    CinemaTitle title,
    List<CinemaDiscoveryTitle> candidates,
  ) {
    final candidate = _candidate(title, candidates);
    return candidate == null ? null : title.copyWith(doubanId: candidate.id);
  }

  static CinemaDiscoveryTitle? _candidate(
    CinemaTitle title,
    List<CinemaDiscoveryTitle> candidates,
  ) {
    if (title.doubanId.isEmpty &&
        (title.imdbId.isNotEmpty || title.rottenTomatoesId.isNotEmpty)) {
      return null;
    }
    final exact = <String, CinemaDiscoveryTitle>{};
    for (final item in candidates) {
      if ((title.doubanId.isEmpty || title.doubanId == item.id) &&
          matches(title, item)) {
        exact[item.id] = item;
      }
    }
    return exact.length == 1 ? exact.values.single : null;
  }

  static bool matches(CinemaTitle title, CinemaDiscoveryTitle candidate) {
    if (!candidate.identityVerified ||
        !RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(candidate.id) ||
        !RegExp(r'^\d{4}$').hasMatch(title.year.trim()) ||
        title.year.trim() != candidate.year.trim() ||
        _kind(title.category).isEmpty ||
        _kind(title.category) != candidate.kind) {
      return false;
    }
    final sourceNames = _names(title.title, title.aliases);
    final candidateNames = _names(
      candidate.title,
      '${candidate.originalTitle} / ${candidate.aliases}',
    );
    return sourceNames.intersection(candidateNames).isNotEmpty &&
        seasonForLabel(title.title) == seasonForLabel(candidate.title);
  }

  static String _kind(String value) {
    if (RegExp(r'解说|影评|综艺|綜藝|动漫|動漫').hasMatch(value)) return '';
    if (RegExp(r'连续剧|連續劇|电视剧|電視劇|剧集|劇集|剧$|劇$').hasMatch(value)) return 'tv';
    if (RegExp(r'电影|電影|片$').hasMatch(value)) return 'movie';
    return '';
  }

  static Set<String> _names(String title, String aliases) => {
    for (final value in [title, ...aliases.split(RegExp(r'[/／|,，;；\n]'))])
      if (value.trim().isNotEmpty)
        value
            .toLowerCase()
            .replaceFirst(RegExp(r'\s*[（(](原声版|普通话版|国语版|英语版)[）)]\s*$'), '')
            .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), ''),
  };

  // An explicit season must appear in both primary labels; aliases of the
  // complete series must not accidentally bind one season to the whole show.
  static String seasonForLabel(String name) {
    final english = RegExp(
      r'\bseason\s*(\d+)\b|\bs(\d{1,2})\b',
      caseSensitive: false,
    ).firstMatch(name);
    if (english != null) {
      return int.parse(english.group(1) ?? english.group(2)!).toString();
    }
    final chinese = RegExp(
      r'第([一二三四五六七八九十百零〇两\d]+)季',
    ).firstMatch(name)?.group(1);
    if (chinese == null) return '';
    final number = int.tryParse(chinese);
    if (number != null) return number.toString();
    const digits = {
      '一': 1,
      '二': 2,
      '两': 2,
      '三': 3,
      '四': 4,
      '五': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
    };
    if (digits.containsKey(chinese)) return digits[chinese].toString();
    if (chinese.contains('十')) {
      final parts = chinese.split('十');
      if (parts.length == 2 &&
          (parts.first.isEmpty || digits.containsKey(parts.first)) &&
          (parts.last.isEmpty || digits.containsKey(parts.last))) {
        return ((parts.first.isEmpty ? 1 : digits[parts.first]!) * 10 +
                (parts.last.isEmpty ? 0 : digits[parts.last]!))
            .toString();
      }
    }
    return chinese;
  }
}
