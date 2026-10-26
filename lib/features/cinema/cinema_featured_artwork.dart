import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'cinema_detail_artwork.dart';
import 'cinema_models.dart';
import 'cinema_ratings.dart';

typedef CinemaArtworkIdentity = RatingIdentity Function(CinemaTitle title);

/// The hero upgrades only its visible work and one neighbour. Cancelled work
/// retains its slot until settled, so fast swipes cannot start a request fanout.
class CinemaFeaturedArtworkWindow extends ChangeNotifier {
  CinemaFeaturedArtworkWindow({
    CinemaDetailArtworkRepository? repository,
    DateTime Function()? now,
  }) : _repository = repository ?? CinemaDetailArtworkRepository.instance,
       _now = now ?? DateTime.now;

  final CinemaDetailArtworkRepository _repository;
  final DateTime Function() _now;
  final _cache = <String, (DateTime, CinemaDetailArtwork)>{};
  final _pending = <String, CancelToken>{};
  Map<String, (CinemaTitle, RatingIdentity)> _desired = {};
  bool _disposed = false;

  CinemaDetailArtwork artworkFor(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
  }) =>
      _cache[CinemaDetailArtworkRepository.identityKey(title, identity)]?.$2 ??
      const CinemaDetailArtwork(url: '');

  void update(
    List<CinemaTitle> titles,
    int index, {
    CinemaArtworkIdentity? identityFor,
    bool active = true,
  }) {
    if (_disposed) return;
    final indices = <int>[];
    if (active && titles.isNotEmpty) {
      final current = index.clamp(0, titles.length - 1);
      indices.add(current);
      if (titles.length > 1) {
        indices.add(current + 1 < titles.length ? current + 1 : current - 1);
      }
    }
    _desired = {};
    for (final i in indices) {
      final title = titles[i];
      final identity = identityFor?.call(title) ?? const RatingIdentity();
      _desired[CinemaDetailArtworkRepository.identityKey(title, identity)] = (
        title,
        identity,
      );
    }
    _cache.removeWhere((_, value) => !_now().isBefore(value.$1));
    for (final entry in _pending.entries) {
      if (!_desired.containsKey(entry.key)) {
        entry.value.cancel('Artwork moved outside the hero window');
      }
    }
    _drain();
  }

  void _drain() {
    if (_disposed) return;
    for (final entry in _desired.entries) {
      if (_pending.length >= 2) break;
      if (_cache.containsKey(entry.key) || _pending.containsKey(entry.key)) {
        continue;
      }
      final cancel = CancelToken();
      _pending[entry.key] = cancel;
      unawaited(_resolve(entry.key, entry.value.$1, entry.value.$2, cancel));
    }
  }

  Future<void> _resolve(
    String key,
    CinemaTitle title,
    RatingIdentity identity,
    CancelToken cancel,
  ) async {
    bool current() =>
        !_disposed && !cancel.isCancelled && _desired.containsKey(key);
    try {
      CinemaDetailArtwork artwork;
      try {
        artwork = await _repository.resolveLandscape(
          title,
          identity: identity,
          cancelToken: cancel,
          isCurrent: current,
        );
      } catch (_) {
        artwork = const CinemaDetailArtwork(url: '');
      }
      if (!current()) return;
      // Keep a portrait or an uninspected fallback out even when an injected
      // repository supplies one. Edge extension must not masquerade as a still.
      if (!artwork.usableLandscape) {
        artwork = const CinemaDetailArtwork(url: '');
      }
      _cache.remove(key);
      _cache[key] = (
        _now().add(
          artwork.highResolution
              ? const Duration(hours: 24)
              : const Duration(seconds: 30),
        ),
        artwork,
      );
      while (_cache.length > 8) {
        _cache.remove(_cache.keys.first);
      }
      notifyListeners();
    } finally {
      _pending.remove(key);
      _drain();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _desired = {};
    for (final cancel in _pending.values) {
      cancel.cancel('Hero disposed');
    }
    _cache.clear();
    super.dispose();
  }
}

/// Decode real source pixels for Retina screens, bounded to 8 MP. A smaller
/// original is never enlarged to satisfy a requested display width.
int cinemaHeroDecodeWidth(
  CinemaDetailArtwork artwork,
  double logicalWidth,
  double devicePixelRatio,
) {
  var width = (logicalWidth * devicePixelRatio).ceil().clamp(1, 3200);
  if (artwork.width > 0 && artwork.height > 0) {
    width = math.min(width, artwork.width);
    final areaBound = math
        .sqrt(8000000 * artwork.width / artwork.height)
        .floor();
    width = math.min(width, areaBound);
  } else {
    width = math.min(width, 1600);
  }
  return math.max(1, width);
}
