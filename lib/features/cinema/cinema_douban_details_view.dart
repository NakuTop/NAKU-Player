import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'cinema_douban_details.dart';
import 'cinema_theme.dart';
import 'douban/douban_image_headers.dart';

class DoubanDetailsView extends StatelessWidget {
  const DoubanDetailsView({
    super.key,
    this.details,
    this.loading = false,
    this.onRecommendationSelected,
  });
  final DoubanSubjectDetails? details;
  final bool loading;
  final ValueChanged<DoubanRecommendation>? onRecommendationSelected;

  @override
  Widget build(BuildContext context) {
    final data = details;
    if (loading && data == null) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          '正在读取豆瓣影片资料与推荐…',
          style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
        ),
      );
    }
    if (data == null) return const SizedBox.shrink();
    if (!data.hasContent) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          data.note.isEmpty ? '豆瓣详细资料暂不可用' : data.note,
          style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 28, color: CinemaTheme.border),
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              '影片资料',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            TextButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(data.url),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new_rounded, size: 14),
              label: const Text('豆瓣官网'),
            ),
            if (loading)
              const Text(
                '更新中…',
                style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
              ),
          ],
        ),
        Text(
          '${data.title}${data.year.isEmpty ? '' : ' · ${data.year}'}',
          style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
        ),
        const SizedBox(height: 10),
        _MetadataRow('上映日期', data.releaseDates.join(' / ')),
        _MetadataRow('片长', data.durations.join(' / ')),
        _MetadataRow('原名', data.originalTitle),
        _MetadataRow('又名', data.aliases.join(' / ')),
        const SizedBox(height: 16),
        const Text(
          '豆瓣星级分布',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        if (data.stars.isEmpty)
          const Text(
            '官网暂未提供星级分布',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
          )
        else ...[
          for (final star in data.stars)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(
                    width: 34,
                    child: Text(
                      '${star.stars} 星',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Semantics(
                      label:
                          '${star.stars} 星 ${(star.share * 100).toStringAsFixed(1)}%',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          key: ValueKey('douban-star-${star.stars}'),
                          value: star.share,
                          minHeight: 7,
                          color: CinemaTheme.copper,
                          backgroundColor: CinemaTheme.border,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 55,
                    child: Text(
                      '${(star.share * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        color: CinemaTheme.muted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 5),
          Text(
            '${data.ratingCount == null ? '评价人数未返回' : '${data.ratingCount} 人评价'} · 比例来自豆瓣；未推算每星人数',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
          ),
        ],
        if (data.recommendations.isNotEmpty) ...[
          const SizedBox(height: 20),
          const Text(
            '喜欢这部作品的人也喜欢',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          const Text(
            '豆瓣推荐 · 点击搜索可用片源',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 11),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 190,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: data.recommendations.length,
              separatorBuilder: (_, _) => const SizedBox(width: 12),
              itemBuilder: (context, index) {
                final item = data.recommendations[index];
                return SizedBox(
                  width: 102,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      key: ValueKey('douban-rec-${item.doubanId}'),
                      onTap: onRecommendationSelected == null
                          ? null
                          : () => onRecommendationSelected!(item),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 102,
                              height: 142,
                              child: item.poster.isEmpty
                                  ? const _PosterFallback()
                                  : CachedNetworkImage(
                                      imageUrl: item.poster,
                                      memCacheWidth: 240,
                                      httpHeaders: doubanImageHeaders,
                                      fit: BoxFit.cover,
                                      errorWidget: (_, _, _) =>
                                          const _PosterFallback(),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 7),
                          Text(
                            item.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ] else ...[
          const SizedBox(height: 14),
          const Text(
            '官网暂未返回相似推荐',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
        ],
        if (data.note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              data.note,
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
            ),
          ),
        if (data.fetchedAt != null)
          Text(
            '${data.stale ? '上次成功获取' : '官网资料获取于'} ${data.fetchedAt!.toLocal().toString().substring(0, 16)}',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 11),
          ),
      ],
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 68,
          child: Text(
            label,
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      ],
    ),
  );
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: CinemaTheme.raised,
    child: const Center(
      child: Icon(Icons.movie_outlined, color: CinemaTheme.muted),
    ),
  );
}
