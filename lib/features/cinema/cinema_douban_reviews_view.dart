import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cinema_douban_reviews.dart';
import 'cinema_theme.dart';

/// Independently loads public reviews after the work's metadata/recommendations.
/// A late response may never replace reviews for a newly selected subject.
class CinemaDoubanReviewsView extends StatefulWidget {
  const CinemaDoubanReviewsView({
    super.key,
    required this.subjectId,
    this.repository,
    this.onOpenUrl,
  });

  final String subjectId;
  final CinemaDoubanReviewsRepository? repository;
  final Future<void> Function(Uri)? onOpenUrl;

  @override
  State<CinemaDoubanReviewsView> createState() =>
      _CinemaDoubanReviewsViewState();
}

class _CinemaDoubanReviewsViewState extends State<CinemaDoubanReviewsView> {
  CinemaDoubanReviews? _result;
  String? _error;
  bool _loading = false;
  int _request = 0;
  final _revealed = <String>{};

  CinemaDoubanReviewsRepository get _repository =>
      widget.repository ?? CinemaDoubanReviewsRepository.instance;
  bool get _hasSubject =>
      RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(widget.subjectId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CinemaDoubanReviewsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subjectId != widget.subjectId ||
        oldWidget.repository != widget.repository) {
      _result = null;
      _error = null;
      _revealed.clear();
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    final request = ++_request;
    if (!_hasSubject) {
      _loading = false;
      return;
    }
    final id = widget.subjectId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _repository.load(id, force: force);
      if (!mounted || request != _request) return;
      if (result.subjectId != id) {
        throw const FormatException('影评条目不一致，请稍后重试。');
      }
      setState(() => _result = result);
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = error is FormatException
            ? error.message
            : '影评暂时无法读取，可重试或前往豆瓣查看。',
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _open(String value) async {
    try {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host != 'movie.douban.com' ||
          uri.hasPort ||
          uri.userInfo.isNotEmpty ||
          !(RegExp(r'^/review/[1-9][0-9]*/?$').hasMatch(uri.path) ||
              uri.path == '/subject/${widget.subjectId}/reviews' ||
              uri.path == '/subject/${widget.subjectId}/reviews/')) {
        throw const FormatException('影评来源链接无效。');
      }
      if (widget.onOpenUrl case final opener?) {
        await opener(uri);
      } else if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException('暂时无法打开豆瓣链接。');
      }
    } catch (error) {
      if (!mounted) return;
      KazumiDialog.showToast(
        context: context,
        message: error is FormatException ? error.message : '暂时无法打开豆瓣链接。',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasSubject) return const SizedBox.shrink();
    final data = _result;
    final items = data?.items.take(6).toList() ?? <CinemaDoubanReview>[];
    final failed =
        _error != null ||
        (data != null &&
            ![
              CinemaDoubanReviewsStatus.available,
              CinemaDoubanReviewsStatus.empty,
            ].contains(data.status));
    final notice =
        _error ??
        (data?.message.isNotEmpty == true
            ? data!.message
            : data?.stale == true
            ? '更新未完成，保留上次影评。'
            : data != null && items.isEmpty
            ? '豆瓣暂未返回公开影评。'
            : null);
    return Column(
      key: const ValueKey('cinema-douban-reviews'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28, color: CinemaTheme.border),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 4,
          children: [
            const Text(
              '豆瓣影评',
              style: TextStyle(
                color: CinemaTheme.text,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('douban-reviews-more'),
              onPressed: () => _open(
                data?.url ??
                    'https://movie.douban.com/subject/${widget.subjectId}/reviews',
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('更多影评'),
            ),
          ],
        ),
        if (_loading) ...[
          const LinearProgressIndicator(
            key: ValueKey('douban-reviews-progress'),
            minHeight: 2,
          ),
          const SizedBox(height: 8),
          Text(
            items.isEmpty ? '正在读取影评…' : '正在更新影评…',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 8),
        ],
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              notice,
              key: const ValueKey('douban-reviews-notice'),
              style: const TextStyle(
                color: CinemaTheme.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ),
        for (final review in items)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _ReviewCard(
              key: ValueKey('douban-review-${review.id}'),
              review: review,
              revealed: _revealed.contains(review.id),
              onToggleSpoiler: () => setState(() {
                if (!_revealed.add(review.id)) _revealed.remove(review.id);
              }),
              onOpen: () => _open(review.url),
            ),
          ),
        if ((failed || data?.stale == true) && !_loading)
          TextButton.icon(
            key: const ValueKey('douban-reviews-retry'),
            onPressed: () => _load(force: true),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('重试影评'),
          ),
        if (data?.fetchedAt != null && data?.stale == true)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '影评缓存：${_dateText(data!.fetchedAt!)}',
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          ),
      ],
    );
  }
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    super.key,
    required this.review,
    required this.revealed,
    required this.onToggleSpoiler,
    required this.onOpen,
  });
  final CinemaDoubanReview review;
  final bool revealed;
  final VoidCallback onToggleSpoiler, onOpen;

  @override
  Widget build(BuildContext context) {
    final hidden = review.spoiler && !revealed;
    final score = review.rating;
    final valid = score != null && score.isFinite && score >= 0 && score <= 5;
    final excerpt = review.excerpt.replaceAll(RegExp(r'\s+'), ' ').trim();
    final preview = excerpt.characters.length <= 120
        ? excerpt
        : '${excerpt.characters.take(119)}…';
    return Container(
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
            hidden
                ? '含剧透影评'
                : review.title.isEmpty
                ? '豆瓣影评'
                : review.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: CinemaTheme.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            review.author.isEmpty ? '豆瓣用户' : review.author,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 6),
          if (valid)
            Semantics(
              label: '作者评分 ${_scoreText(score)} / 5',
              excludeSemantics: true,
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var star = 0; star < 5; star++)
                        Icon(
                          score >= star + 1
                              ? Icons.star_rounded
                              : score > star
                              ? Icons.star_half_rounded
                              : Icons.star_outline_rounded,
                          size: 16,
                          color: CinemaTheme.copper,
                        ),
                    ],
                  ),
                  Text(
                    '作者评分 ${_scoreText(score)} / 5',
                    style: const TextStyle(
                      color: CinemaTheme.muted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          else
            const Text(
              '作者未评分',
              style: TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          if (!hidden && preview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              preview,
              key: ValueKey('douban-review-excerpt-${review.id}'),
              style: const TextStyle(
                color: CinemaTheme.text,
                fontSize: 12,
                height: 1.65,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 2,
            children: [
              if (review.spoiler)
                TextButton.icon(
                  key: ValueKey('douban-review-spoiler-${review.id}'),
                  onPressed: onToggleSpoiler,
                  icon: Icon(
                    hidden
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 14,
                  ),
                  label: Text(hidden ? '展开剧透内容' : '收起剧透内容'),
                ),
              TextButton.icon(
                key: ValueKey('douban-review-open-${review.id}'),
                onPressed: onOpen,
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                label: const Text('阅读全文'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _scoreText(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toString();
String _dateText(DateTime value) {
  final date = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
}
