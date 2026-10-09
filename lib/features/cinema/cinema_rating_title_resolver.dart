import 'dart:async';
import 'dart:convert';

import 'cinema_models.dart';
import 'cinema_repository.dart';
import 'cinema_rating_identity_search.dart';

/// Some catalogue responses omit the identifiers returned by the detail API.
/// Resolve those without opening a detail sheet or blocking the poster grid.
class CinemaRatingTitleResolver {
  CinemaRatingTitleResolver({
    required this.repository,
    required this.sourceFor,
    this.discoverTitle,
    DateTime Function()? now,
    this.maxQueueWait = const Duration(seconds: 12),
  }) : _now = now ?? DateTime.now;

  final CinemaRepository repository;
  final CinemaSource? Function(String) sourceFor;
  final Future<CinemaTitle> Function(CinemaTitle)? discoverTitle;
  final DateTime Function() _now;
  final Duration maxQueueWait;
  final _cache = <String, (DateTime, CinemaTitle?)>{};
  final _pending = <String, Future<CinemaTitle?>>{};
  final _waiters = <Completer<bool>>[];
  int _running = 0;
  bool _disposed = false;

  Future<CinemaTitle> resolve(CinemaTitle title) {
    final source = sourceFor(title.sourceId);
    if (_disposed ||
        title.doubanId.isNotEmpty ||
        source == null ||
        !source.enabled ||
        source.kind != CinemaSourceKind.maccms) {
      return Future.value(title);
    }
    final config = _configuration(source);
    final key = jsonEncode([
      config,
      title.key,
      title.title,
      title.year,
      title.category,
      title.aliases,
      title.imdbId,
      title.rottenTomatoesId,
    ]);
    final cached = _cache.remove(key);
    if (cached != null &&
        !_now().isBefore(cached.$1) &&
        _now().difference(cached.$1) < const Duration(minutes: 30)) {
      _cache[key] = cached;
      return Future.value(_merge(title, cached.$2));
    }
    var pending = _pending[key];
    if (pending == null) {
      // Fast scrolling must not enqueue every previously mounted card. A
      // rejected/expired queue entry is retryable and is never negative-cached.
      if (_pending.length >= 34) return Future.value(title);
      late final Future<CinemaTitle?> request;
      request = _load(source, config, key, title).whenComplete(() {
        if (identical(_pending[key], request)) _pending.remove(key);
      });
      _pending[key] = request;
      pending = request;
    }
    return pending.then(
      (detail) => _isCurrent(source.id, config) ? _merge(title, detail) : title,
    );
  }

  Future<CinemaTitle?> _load(
    CinemaSource source,
    String config,
    String key,
    CinemaTitle title,
  ) async {
    if (!await _acquire()) return null;
    var ownsSourceSlot = true;
    try {
      if (!_isCurrent(source.id, config)) return null;
      CinemaTitle? result;
      try {
        final detail = await repository.detail(source, title);
        if (detail.key == title.key && _compatible(title, detail)) {
          result = detail;
        }
      } catch (_) {
        // Failed requests get the same cooldown as missing identifiers.
      }
      if (!_isCurrent(source.id, config)) return null;
      if ((result?.doubanId ?? '').isEmpty && discoverTitle != null) {
        // Discovery is independently bounded; release the source-detail slot so
        // slow public metadata cannot expire other source requests in this queue.
        _release();
        ownsSourceSlot = false;
        try {
          final discovered = await discoverTitle!(_merge(title, result));
          if (discovered.key == title.key && _compatible(title, discovered)) {
            // The lookup's input contains this caller's source fallback score.
            // Cache only an actual source-detail score, never that caller field.
            result = CinemaTitle.fromJson({
              ...discovered.toJson(),
              'sourceDoubanScore': result?.sourceDoubanScore,
            });
          }
        } catch (_) {
          // Discovery failure leaves source metadata and playback untouched.
        }
      }
      if (!_isCurrent(source.id, config)) return null;
      // Cache source data only, never one caller's explicit IDs or card fields.
      _cache[key] = (_now(), result);
      while (_cache.length > 256) {
        _cache.remove(_cache.keys.first);
      }
      return result;
    } finally {
      if (ownsSourceSlot) _release();
    }
  }

  bool _isCurrent(String sourceId, String config) {
    final source = sourceFor(sourceId);
    return !_disposed &&
        source?.enabled == true &&
        _configuration(source!) == config;
  }

  static bool _compatible(CinemaTitle title, CinemaTitle detail) {
    final a = RegExp(r'\d{4}').firstMatch(title.year)?.group(0);
    final b = RegExp(r'\d{4}').firstMatch(detail.year)?.group(0);
    if (a != null && b != null && a != b) return false;
    final kind = _kind(title.category), detailKind = _kind(detail.category);
    if (kind.isNotEmpty && detailKind.isNotEmpty && kind != detailKind) {
      return false;
    }
    if (CinemaRatingIdentitySearch.seasonForLabel(title.title) !=
        CinemaRatingIdentitySearch.seasonForLabel(detail.title)) {
      return false;
    }
    var sameIdentity = false;
    for (final ids in [
      (title.doubanId, detail.doubanId),
      (title.imdbId, detail.imdbId),
      (title.rottenTomatoesId, detail.rottenTomatoesId),
    ]) {
      if (ids.$1.isEmpty || ids.$2.isEmpty) continue;
      if (ids.$1 != ids.$2) return false;
      sameIdentity = true;
    }
    // A matching external ID permits translated titles. Otherwise accept only
    // explicit aliases or formatting/language-edition variants, never fuzzy
    // same-name/year guesses across seasons or different works.
    return sameIdentity ||
        _names(title).intersection(_names(detail)).isNotEmpty;
  }

  static Set<String> _names(CinemaTitle title) => {
    for (final name in [
      title.title,
      ...title.aliases.split(RegExp(r'[/／|,，;；\n]')),
    ])
      if (name.trim().isNotEmpty)
        cleanCinemaText(name)
            .toLowerCase()
            .replaceFirst(
              RegExp(
                r'\s*(?:[（(\[【]\s*)?(?:原声版|原聲版|普通话版|普通話版|国语版|國語版|英语版|英語版)\s*[）)\]】]?\s*$',
              ),
              '',
            )
            .replaceAll(RegExp(r'[\s·・:：\-—–]+'), ''),
  }..remove('');

  static String _kind(String value) {
    if (RegExp('解说|影评').hasMatch(value)) return 'commentary';
    if (RegExp('纪录|记录片|紀錄').hasMatch(value)) return 'documentary';
    if (RegExp('动漫|动画|動漫|動畫').hasMatch(value)) return 'anime';
    if (RegExp('综艺|綜藝').hasMatch(value)) return 'variety';
    if (RegExp(r'连续剧|連續劇|电视剧|電視劇|剧集|劇集|剧$|劇$').hasMatch(value)) return 'series';
    if (RegExp(r'电影|電影|片$').hasMatch(value)) return 'movie';
    return '';
  }

  static CinemaTitle _merge(CinemaTitle title, CinemaTitle? detail) =>
      detail == null
      ? title
      : title.copyWith(
          doubanId: title.doubanId.isEmpty ? detail.doubanId : title.doubanId,
          imdbId: title.imdbId.isEmpty ? detail.imdbId : title.imdbId,
          rottenTomatoesId: title.rottenTomatoesId.isEmpty
              ? detail.rottenTomatoesId
              : title.rottenTomatoesId,
          sourceDoubanScore:
              title.sourceDoubanScore ?? detail.sourceDoubanScore,
        );

  Future<bool> _acquire() async {
    if (_disposed) return false;
    if (_running < 2) {
      _running++;
      return true;
    }
    final waiter = Completer<bool>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      maxQueueWait,
      onTimeout: () {
        _waiters.remove(waiter);
        return false;
      },
    );
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(true);
    } else {
      _running--;
    }
  }

  void dispose() {
    _disposed = true;
    _cache.clear();
    for (final waiter in _waiters) {
      waiter.complete(false);
    }
    _waiters.clear();
  }

  static String _configuration(CinemaSource source) =>
      jsonEncode(_canonical(source.toJson()));

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
