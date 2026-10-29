import 'dart:async';

import 'package:flutter/material.dart';

import 'cinema_models.dart';
import 'cinema_ratings.dart';
import 'cinema_theme.dart';

/// The existing three-provider lookup, displayed without TV focus targets,
/// provider dialogs, review requests, or decorative loading animation.
class CinemaTVRatings extends StatefulWidget {
  const CinemaTVRatings({
    super.key,
    required this.title,
    this.repository,
    this.resolveTitle,
  });

  final CinemaTitle title;
  final CinemaRatingsRepository? repository;
  final Future<CinemaTitle> Function(CinemaTitle)? resolveTitle;

  @override
  State<CinemaTVRatings> createState() => _CinemaTVRatingsState();
}

class _CinemaTVRatingsState extends State<CinemaTVRatings> {
  CinemaRatingsRepository get _repository =>
      widget.repository ?? CinemaRatingsRepository.instance;
  CinemaRatings? _ratings;
  bool _loading = true, _failed = false;
  int _request = 0, _bindingRevision = 0;

  @override
  void initState() {
    super.initState();
    _repository.changes.addListener(_changed);
    _begin();
  }

  @override
  void didUpdateWidget(CinemaTVRatings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      (oldWidget.repository ?? CinemaRatingsRepository.instance).changes
          .removeListener(_changed);
      _repository.changes.addListener(_changed);
    }
    if (_identity(oldWidget.title) != _identity(widget.title) ||
        oldWidget.repository != widget.repository) {
      _begin();
    }
  }

  void _begin() {
    final request = ++_request;
    _bindingRevision = _repository.bindingRevision;
    _ratings = _repository.peek(widget.title);
    _loading = true;
    _failed = false;
    unawaited(_load(widget.title, request));
  }

  Future<void> _load(CinemaTitle title, int request) async {
    try {
      // This shared pipeline hydrates missing exact IDs, publishes each
      // provider as it completes, and coalesces with the visible poster cache.
      final result = await _repository.loadForCard(
        title,
        resolveTitle: widget.resolveTitle,
        isCurrent: () => mounted && request == _request,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _ratings = _repository.peek(title) ?? result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_bindingRevision != _repository.bindingRevision) {
      setState(_begin);
      return;
    }
    final latest = _repository.peek(widget.title);
    if (latest != null && !identical(latest, _ratings)) {
      setState(() => _ratings = latest);
    }
  }

  CinemaRating? _rating(String provider) {
    for (final rating in _ratings?.ratings ?? const <CinemaRating>[]) {
      if (rating.provider == provider) return rating;
    }
    final score = widget.title.sourceDoubanScore;
    if (provider == '豆瓣' &&
        score != null &&
        score.isFinite &&
        score > 0 &&
        score <= 10) {
      return CinemaRating(provider: provider, value: score, note: '片源评分');
    }
    return null;
  }

  @override
  void dispose() {
    _request++;
    _repository.changes.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
    key: const ValueKey('tv-three-provider-ratings'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final provider in const ['豆瓣', 'IMDb', '烂番茄'])
        Expanded(child: _score(provider, _rating(provider))),
    ],
  );

  Widget _score(String provider, CinemaRating? rating) {
    final tomato = provider == '烂番茄';
    final scale = tomato ? 100 : 10;
    final value = rating?.value;
    final valid =
        value != null &&
        value.isFinite &&
        value >= 0 &&
        value <= scale &&
        rating?.scale == scale;
    final reported = provider == '豆瓣' && valid && rating?.verified != true;
    final number = valid
        ? value.toStringAsFixed(
            tomato && value == value.roundToDouble() ? 0 : 1,
          )
        : '—';
    final status = _loading
        ? '查询中'
        : _failed
        ? '暂不可用'
        : '暂无评分';
    final scope = rating?.scope ?? '';
    return Semantics(
      key: ValueKey('tv-rating-$provider'),
      label: valid
          ? '$provider $number${tomato ? '%' : ' / 10'}${reported ? '，片源评分' : ''}${scope.isEmpty ? '' : '，$scope'}'
          : '$provider $status',
      readOnly: true,
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${tomato ? '🍅 ' : ''}$provider${scope.isEmpty ? '' : ' · $scope'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                color: CinemaTheme.muted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$number${reported ? '*' : ''}',
                  key: ValueKey('tv-rating-value-$provider'),
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    color: valid ? CinemaTheme.text : CinemaTheme.muted,
                  ),
                ),
                const SizedBox(width: 4),
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    valid
                        ? tomato
                              ? '%'
                              : '/10'
                        : status,
                    style: const TextStyle(
                      fontSize: 13,
                      color: CinemaTheme.muted,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Object _identity(CinemaTitle title) => (
  title.key,
  title.title,
  title.year,
  title.category,
  title.aliases,
  title.doubanId,
  title.imdbId,
  title.rottenTomatoesId,
  title.sourceDoubanScore,
);
