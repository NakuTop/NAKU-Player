import 'package:flutter/material.dart';

import 'cinema_models.dart';
import 'cinema_ratings.dart';
import 'cinema_theme.dart';

/// A compact, non-interactive summary that shares the detail rating cache.
class CinemaCardRatings extends StatefulWidget {
  const CinemaCardRatings({
    super.key,
    required this.title,
    this.repository,
    this.resolveTitle,
  });

  final CinemaTitle title;
  final CinemaRatingsRepository? repository;
  final Future<CinemaTitle> Function(CinemaTitle)? resolveTitle;

  @override
  State<CinemaCardRatings> createState() => _CinemaCardRatingsState();
}

class _CinemaCardRatingsState extends State<CinemaCardRatings> {
  CinemaRatings? _ratings;
  String? _error;
  bool _loading = false;
  int _request = 0;
  int _bindingRevision = 0;

  CinemaRatingsRepository get _repository =>
      widget.repository ?? CinemaRatingsRepository.instance;

  @override
  void initState() {
    super.initState();
    _repository.changes.addListener(_cacheChanged);
    _begin();
  }

  @override
  void didUpdateWidget(CinemaCardRatings oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) {
      (oldWidget.repository ?? CinemaRatingsRepository.instance).changes
          .removeListener(_cacheChanged);
      _repository.changes.addListener(_cacheChanged);
    }
    if (_identityKey(oldWidget.title) != _identityKey(widget.title) ||
        oldWidget.repository != widget.repository) {
      _begin();
    } else {
      // Detail-page refreshes can update this shared cache between rebuilds.
      _ratings = _repository.peek(widget.title) ?? _ratings;
    }
  }

  void _cacheChanged() {
    if (!mounted) return;
    if (_bindingRevision != _repository.bindingRevision) {
      setState(_begin);
      return;
    }
    final latest = _repository.peek(widget.title);
    if (latest != null && !_sameDisplayedRatings(latest, _ratings)) {
      setState(() => _ratings = latest);
    }
  }

  @override
  void dispose() {
    _repository.changes.removeListener(_cacheChanged);
    super.dispose();
  }

  // Both callers are lifecycle methods followed by a build, so the immediate
  // cache/fallback assignment needs no extra setState or waiting frame.
  void _begin() {
    final request = ++_request;
    final title = widget.title;
    final repository = _repository;
    _bindingRevision = repository.bindingRevision;
    _error = null;
    _ratings = repository.peek(title);
    _loading = true;
    // Even titles without source IDs can have a saved manual binding. The
    // repository reads that local state before deciding whether network is needed.
    _load(title, repository, request);
  }

  Future<void> _load(
    CinemaTitle title,
    CinemaRatingsRepository repository,
    int request,
  ) async {
    try {
      final ratings = await repository.loadForCard(
        title,
        resolveTitle: widget.resolveTitle,
        isCurrent: () => mounted && request == _request,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _ratings = ratings;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error is FormatException ? error.message : '评分服务暂不可用';
        _loading = false;
      });
    }
  }

  CinemaRating _rating(String provider) {
    for (final rating in _ratings?.ratings ?? <CinemaRating>[]) {
      if (rating.provider == provider) return rating;
    }
    final sourceScore = widget.title.sourceDoubanScore;
    if (provider == '豆瓣' &&
        sourceScore != null &&
        sourceScore.isFinite &&
        sourceScore > 0 &&
        sourceScore <= 10) {
      return CinemaRating(
        provider: provider,
        value: sourceScore,
        note: '片源 vod_douban_score 转述，未向豆瓣官网核验',
      );
    }
    return CinemaRating(
      provider: provider,
      scale: provider == '烂番茄' ? 100 : 10,
      note: _error != null
          ? '暂未获取评分：$_error'
          : _loading
          ? '正在后台查询评分'
          : '暂无评分或缺少确切条目 ID',
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final labelWidth =
          constraints.hasBoundedWidth && constraints.maxWidth < 180
          ? ((constraints.maxWidth - 8) / 2).clamp(1.0, double.infinity)
          : double.infinity;
      return Wrap(
        key: const ValueKey('cinema-card-ratings'),
        spacing: 8,
        runSpacing: 3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final provider in ['豆瓣', 'IMDb', '烂番茄'])
            _ScoreLabel(
              provider: provider,
              rating: _rating(provider),
              maxWidth: labelWidth,
            ),
        ],
      );
    },
  );
}

class _ScoreLabel extends StatelessWidget {
  const _ScoreLabel({
    required this.provider,
    required this.rating,
    required this.maxWidth,
  });

  final String provider;
  final CinemaRating rating;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final isTomatometer = provider == '烂番茄';
    final scale = isTomatometer ? 100 : 10;
    final value = rating.value;
    final valid =
        value != null &&
        value.isFinite &&
        value >= 0 &&
        value <= scale &&
        rating.scale == scale;
    final reported = provider == '豆瓣' && valid && !rating.verified;
    final number = valid
        ? value.toStringAsFixed(
            isTomatometer && value == value.roundToDouble() ? 0 : 1,
          )
        : '—';
    final score =
        '$number${valid && isTomatometer ? '%' : ''}'
        '${reported ? '*' : ''}';
    final provenance = reported
        ? '片源 vod_douban_score 转述，未向豆瓣官网核验'
        : rating.verified
        ? switch (provider) {
            'IMDb' => 'IMDb 官方每日评分数据',
            '烂番茄' => '烂番茄官网 Tomatometer，影评人正面评价百分比',
            _ => '豆瓣官网公开条目评分',
          }
        : valid
        ? '来源未核验'
        : '暂无评分';
    final tooltip = [
      valid
          ? '$provider $number${isTomatometer ? '%' : ' / 10'}'
          : '$provider —',
      provenance,
      if (rating.note.isNotEmpty && rating.note != provenance) rating.note,
      if (rating.fetchedAt != null) '更新：${_dateText(rating.fetchedAt!)}',
    ].join('\n');
    return Tooltip(
      key: ValueKey('card-rating-$provider'),
      message: tooltip,
      // Hover tooltips still work on desktop; no tap/long-press action competes
      // with the surrounding poster card's navigation gesture.
      triggerMode: TooltipTriggerMode.manual,
      waitDuration: const Duration(milliseconds: 350),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            '$provider $score',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.25,
              color: valid ? CinemaTheme.copper : CinemaTheme.muted,
            ),
          ),
        ),
      ),
    );
  }
}

Object _identityKey(CinemaTitle title) => (
  title.key,
  title.title,
  title.year,
  title.doubanId,
  title.imdbId,
  title.rottenTomatoesId,
  title.sourceDoubanScore,
);

String _dateText(DateTime date) {
  final local = date.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}

bool _sameDisplayedRatings(CinemaRatings a, CinemaRatings? b) {
  if (b == null || a.ratings.length != b.ratings.length) return false;
  for (var i = 0; i < a.ratings.length; i++) {
    final x = a.ratings[i], y = b.ratings[i];
    if ((x.provider, x.value, x.scale, x.verified, x.note, x.fetchedAt) !=
        (y.provider, y.value, y.scale, y.verified, y.note, y.fetchedAt)) {
      return false;
    }
  }
  return true;
}
