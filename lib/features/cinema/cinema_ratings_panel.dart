import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cinema_models.dart';
import 'cinema_ratings.dart';
import 'cinema_douban_details_view.dart';
import 'cinema_theme.dart';

/// Loads ratings independently of playback and keeps each provider's scale.
class CinemaRatingsPanel extends StatefulWidget {
  const CinemaRatingsPanel({
    super.key,
    required this.title,
    required this.sourceName,
    this.repository,
    this.onRecommendationSelected,
  });

  final CinemaTitle title;
  final String sourceName;
  final CinemaRatingsRepository? repository;
  final ValueChanged<DoubanRecommendation>? onRecommendationSelected;

  @override
  State<CinemaRatingsPanel> createState() => _CinemaRatingsPanelState();
}

class _CinemaRatingsPanelState extends State<CinemaRatingsPanel> {
  CinemaRatings? _result;
  DoubanSubjectDetails? _details;
  bool _detailsLoading = true;
  bool _loading = true;
  bool _editing = false;
  String? _error;
  int _request = 0;

  CinemaRatingsRepository get _repository =>
      widget.repository ?? CinemaRatingsRepository.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CinemaRatingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.title != widget.title ||
        oldWidget.repository != widget.repository) {
      _result = null;
      _details = null;
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    _loadDetails(request, force);
    _loadQuick(request);
    try {
      final result = await _repository.load(widget.title, force: force);
      if (!mounted || request != _request) return;
      setState(() => _result = result);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() => _error = '评分暂未加载：${_readableError(error)}');
    } finally {
      if (mounted && request == _request) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadQuick(int request) async {
    try {
      final result = await _repository.loadQuickRatings(widget.title);
      if (mounted && request == _request && _loading) {
        setState(() => _result = result);
      }
    } catch (_) {
      /* The full lookup provides the visible error if needed. */
    }
  }

  Future<void> _loadDetails(int request, bool force) async {
    setState(() => _detailsLoading = true);
    try {
      final details = await _repository.loadDoubanDetails(
        widget.title,
        force: force,
      );
      if (mounted && request == _request) setState(() => _details = details);
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _details = DoubanSubjectDetails(
            doubanId: '',
            note: '官网资料暂未加载：${_readableError(error)}',
          ),
        );
      }
    } finally {
      if (mounted && request == _request) {
        setState(() => _detailsLoading = false);
      }
    }
  }

  Future<void> _editIdentity() async {
    final title = widget.title;
    final repository = _repository;
    setState(() => _editing = true);
    try {
      final identity = await showDialog<RatingIdentity>(
        context: context,
        builder: (_) => Theme(
          data: CinemaTheme.of(context),
          child: _RatingIdentityDialog(
            title: title,
            sourceName: widget.sourceName,
            initial:
                _result?.identity ??
                RatingIdentity(
                  doubanId: title.doubanId,
                  imdbId: title.imdbId,
                  rottenTomatoesId: title.rottenTomatoesId,
                ),
          ),
        ),
      );
      if (identity == null || !mounted) return;
      await repository.setIdentity(title, identity);
      if (!mounted || widget.title != title) return;
      // A changed binding must not display the previous work's scores.
      setState(() {
        _result = null;
        _details = null;
      });
      await _load(force: true);
    } catch (error) {
      if (mounted && widget.title == title) {
        setState(() => _error = '评分关联未保存：${_readableError(error)}');
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  CinemaRating _rating(String provider) {
    final details = _details;
    final available = _result?.ratings
        .where((r) => _providerName(r.provider) == provider)
        .firstOrNull;
    if (provider == '豆瓣' &&
        details?.score != null &&
        details!.doubanId == (_result?.identity.doubanId ?? details.doubanId)) {
      if (available != null &&
          available.verified &&
          available.value != null &&
          (details.stale ||
              (available.fetchedAt != null &&
                  details.fetchedAt != null &&
                  !available.fetchedAt!.isBefore(details.fetchedAt!)))) {
        return available;
      }
      return CinemaRating(
        provider: '豆瓣',
        value: details.score,
        count: details.ratingCount,
        url: details.url,
        verified: true,
        note: details.stale ? '更新失败，保留上次官网评分' : '豆瓣官网公开条目',
        fetchedAt: details.fetchedAt,
      );
    }
    for (final rating in _result?.ratings ?? <CinemaRating>[]) {
      if (_providerName(rating.provider) == provider) return rating;
    }
    return CinemaRating(
      provider: provider,
      scale: provider == '烂番茄' ? 100 : 10,
      note: _loading ? '正在查询' : '暂无评分或尚未关联条目',
    );
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: Material(
      color: CinemaTheme.surface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: CinemaTheme.border),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 4,
              children: [
                const Text(
                  '作品评分',
                  style: TextStyle(
                    color: CinemaTheme.text,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _loading || _editing
                          ? null
                          : () => _load(force: true),
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('刷新评分'),
                    ),
                    TextButton.icon(
                      onPressed: _editing ? null : _editIdentity,
                      icon: const Icon(Icons.link_rounded, size: 17),
                      label: Text(_editing ? '正在关联' : '关联条目'),
                    ),
                  ],
                ),
              ],
            ),
            if (_loading) ...[
              const SizedBox(height: 8),
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 8),
              const Text(
                '正在读取评分；首次使用 IMDb 需下载约 9 MB，每日更新缓存。',
                style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                key: const ValueKey('ratings-error'),
                style: const TextStyle(color: Color(0xFFF5A69F), fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, constraints) {
                final columns = constraints.maxWidth >= 600
                    ? 3
                    : constraints.maxWidth >= 400
                    ? 2
                    : 1;
                final width =
                    (constraints.maxWidth - (columns - 1) * 10) / columns;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final provider in ['豆瓣', 'IMDb', '烂番茄'])
                      SizedBox(
                        width: width,
                        child: _RatingCard(
                          provider: provider,
                          rating: _rating(provider),
                          sourceName: widget.sourceName,
                        ),
                      ),
                  ],
                );
              },
            ),
            if (_result != null)
              ExpansionTile(
                key: const ValueKey('ratings-identity-details'),
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 4),
                dense: true,
                title: const Text('关联与说明', style: TextStyle(fontSize: 13)),
                subtitle: _result!.identity.label.isEmpty
                    ? null
                    : Text(
                        _result!.identity.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: CinemaTheme.muted,
                          fontSize: 12,
                        ),
                      ),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(
                      [
                        if (_result!.message.isNotEmpty) _result!.message,
                        if (_result!.identity.doubanId.isNotEmpty)
                          '豆瓣 ID：${_result!.identity.doubanId}',
                        if (_result!.identity.imdbId.isNotEmpty)
                          'IMDb ID：${_result!.identity.imdbId}',
                        if (_result!.identity.rottenTomatoesId.isNotEmpty)
                          '烂番茄 ID：${_result!.identity.rottenTomatoesId}',
                        if (_result!.identity.wikidataId.isNotEmpty)
                          'Wikidata：${_result!.identity.wikidataId}',
                      ].join('\n'),
                      style: const TextStyle(
                        color: CinemaTheme.muted,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ),
                ],
              ),
            DoubanDetailsView(
              details: _details,
              loading: _detailsLoading,
              onRecommendationSelected: widget.onRecommendationSelected,
            ),
          ],
        ),
      ),
    ),
  );
}

class _RatingCard extends StatelessWidget {
  const _RatingCard({
    required this.provider,
    required this.rating,
    required this.sourceName,
  });

  final String provider;
  final CinemaRating rating;
  final String sourceName;

  Future<void> _openSource(BuildContext context) async {
    final uri = Uri.tryParse(rating.url);
    try {
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException('无法打开评分来源链接');
      }
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(_readableError(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isTomatometer = provider == '烂番茄';
    final expectedScale = isTomatometer ? 100 : 10;
    final raw = rating.value;
    final valid =
        raw != null &&
        raw.isFinite &&
        raw >= 0 &&
        raw <= expectedScale &&
        rating.scale == expectedScale;
    final score = valid
        ? raw.toStringAsFixed(
            isTomatometer && raw == raw.roundToDouble() ? 0 : 1,
          )
        : '—';
    final sourceReported = provider == '豆瓣' && valid && !rating.verified;
    final originalNote = raw != null && !valid
        ? '评分数值或刻度无效'
        : rating.note.isEmpty
        ? valid
              ? '来源未提供更多说明'
              : '暂无评分'
        : rating.note;
    final note = sourceReported
        ? originalNote.replaceFirst(RegExp(r'^片源转述\s*·\s*未核验[；;]?\s*'), '')
        : originalNote;
    return Container(
      key: ValueKey('rating-card-$provider'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CinemaTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: CinemaTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider,
            style: const TextStyle(
              color: CinemaTheme.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Semantics(
            label: valid
                ? '$provider $score${isTomatometer ? '%' : ' / 10'}'
                : '$provider 暂无评分',
            excludeSemantics: true,
            child: Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  score,
                  key: ValueKey('rating-value-$provider'),
                  style: TextStyle(
                    color: valid ? CinemaTheme.copper : CinemaTheme.muted,
                    fontSize: 30,
                    fontWeight: FontWeight.w600,
                    height: 1.1,
                  ),
                ),
                Text(
                  isTomatometer ? '%' : '/10',
                  style: const TextStyle(
                    color: CinemaTheme.muted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          if (isTomatometer)
            const Text(
              '影评人 · Tomatometer',
              style: TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          if (sourceReported) ...[
            const Text(
              '片源转述 · 未核验',
              style: TextStyle(color: CinemaTheme.copper, fontSize: 11),
            ),
            Text(
              '来自 $sourceName',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          ] else if (valid && !rating.verified)
            const Text(
              '未核验',
              style: TextStyle(color: CinemaTheme.copper, fontSize: 11),
            ),
          if (note.isNotEmpty)
            Text(
              note,
              style: const TextStyle(
                color: CinemaTheme.muted,
                fontSize: 11,
                height: 1.5,
              ),
            ),
          if (valid && rating.count != null && rating.count! >= 0)
            Text(
              isTomatometer
                  ? '${_groupCount(rating.count!)} 条影评'
                  : '${_groupCount(rating.count!)} 人评价',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          if (rating.fetchedAt != null)
            Text(
              '更新 ${_dateText(rating.fetchedAt!)}',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          if (rating.url.isNotEmpty)
            TextButton.icon(
              onPressed: () => _openSource(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 12),
              label: const Text('查看来源', style: TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }
}

class _RatingIdentityDialog extends StatefulWidget {
  const _RatingIdentityDialog({
    required this.title,
    required this.sourceName,
    required this.initial,
  });

  final CinemaTitle title;
  final String sourceName;
  final RatingIdentity initial;

  @override
  State<_RatingIdentityDialog> createState() => _RatingIdentityDialogState();
}

class _RatingIdentityDialogState extends State<_RatingIdentityDialog> {
  late final _douban = TextEditingController(text: widget.initial.doubanId);
  late final _imdb = TextEditingController(text: widget.initial.imdbId);
  late final _tomatoes = TextEditingController(
    text: widget.initial.rottenTomatoesId,
  );
  String? _error;

  @override
  void dispose() {
    _douban.dispose();
    _imdb.dispose();
    _tomatoes.dispose();
    super.dispose();
  }

  void _save() {
    final identity = RatingIdentity(
      doubanId: _douban.text.trim(),
      imdbId: _imdb.text.trim(),
      rottenTomatoesId: _tomatoes.text.trim(),
      label: [
        widget.title.title,
        if (widget.title.year.isNotEmpty) widget.title.year,
      ].join(' · '),
      confirmed: true,
    );
    try {
      identity.validate();
      Navigator.of(context).pop(identity);
    } catch (error) {
      setState(() => _error = _readableError(error));
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('关联评分条目'),
    scrollable: true,
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              widget.title.title,
              if (widget.title.year.isNotEmpty) widget.title.year,
            ].join(' · '),
            style: const TextStyle(
              color: CinemaTheme.copper,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '当前片源：${widget.sourceName}',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          const Text(
            '请核对片名、年份及剧集季数后保存；留空可清除对应关联。',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('rating-douban-id'),
            controller: _douban,
            decoration: const InputDecoration(
              labelText: '豆瓣 ID',
              hintText: '例如 1889243',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rating-imdb-id'),
            controller: _imdb,
            decoration: const InputDecoration(
              labelText: 'IMDb ID',
              hintText: '例如 tt0816692',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('rating-rotten-tomatoes-id'),
            controller: _tomatoes,
            decoration: const InputDecoration(
              labelText: '烂番茄 ID',
              hintText: 'm/作品 或 tv/剧集/s01',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('rating-identity-error'),
              style: const TextStyle(color: Color(0xFFF5A69F), fontSize: 12),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () {
          _douban.clear();
          _imdb.clear();
          _tomatoes.clear();
          setState(() => _error = null);
        },
        child: const Text('清空字段'),
      ),
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(onPressed: _save, child: const Text('确认并保存')),
    ],
  );
}

String _providerName(String value) => switch (value.trim().toLowerCase()) {
  'douban' || '豆瓣' => '豆瓣',
  'imdb' => 'IMDb',
  'rotten tomatoes' || 'rottentomatoes' || '烂番茄' => '烂番茄',
  _ => value,
};

String _readableError(Object error) => error is FormatException
    ? error.message
    : error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');

String _groupCount(int count) => count.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

String _dateText(DateTime value) {
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
