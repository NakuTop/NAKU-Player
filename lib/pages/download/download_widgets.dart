import 'package:flutter/material.dart';

import 'package:kazumi/bean/card/network_img_layer.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/bean/widget/kazumi_menu.dart';
import 'package:kazumi/bean/widget/loading_indicator.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/utils/format.dart';

const Duration _kExpandDuration = Duration(milliseconds: 250);
const Curve _kExpandCurve = Curves.easeInOutCubic;

class DownloadRecordCard extends StatelessWidget {
  const DownloadRecordCard({
    super.key,
    required this.record,
    required this.expanded,
    required this.onToggle,
    required this.onResumeAll,
    required this.onDeleteAll,
    required this.totalSpeed,
    required this.episodeTileBuilder,
  });

  final DownloadRecord record;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onResumeAll;
  final VoidCallback onDeleteAll;
  final double totalSpeed;

  final List<Widget> Function() episodeTileBuilder;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final episodes = record.episodes.values;
    final totalCount = episodes.length;
    final completedCount = episodes
        .where((e) => e.status == DownloadStatus.completed)
        .length;
    final reviewCount = episodes
        .where(
          (e) =>
              e.status == DownloadStatus.completed && e.errorMessage.isNotEmpty,
        )
        .length;
    final activeCount = episodes
        .where(
          (e) =>
              e.status == DownloadStatus.downloading ||
              e.status == DownloadStatus.resolving ||
              e.status == DownloadStatus.pending,
        )
        .length;
    final aggregateProgress = totalCount == 0
        ? 0.0
        : episodes.fold<double>(
                0,
                (sum, e) =>
                    sum +
                    (e.status == DownloadStatus.completed
                        ? 1.0
                        : e.progressPercent),
              ) /
              totalCount;
    final allCompleted = completedCount >= totalCount;

    var meta = reviewCount > 0
        ? '$completedCount/$totalCount 本地可播放 · $reviewCount 项待核对'
        : '$completedCount/$totalCount 已完成';
    if (activeCount > 0) {
      meta += ' · $activeCount 项进行中';
      if (totalSpeed > 0) {
        meta += ' · ${formatSpeed(totalSpeed)}';
      }
    }

    final episodeContent = expanded
        ? Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(children: episodeTileBuilder()),
          )
        : const SizedBox(width: double.infinity);

    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: CinemaGlass(
        radius: 20,
        blur: false,
        child: Material(
          color: Colors.transparent,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 520;
                  final coverWidth = compact ? 64.0 : 82.0;
                  return InkWell(
                    onTap: onToggle,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                        compact ? 14 : 20,
                        18,
                        8,
                        18,
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: record.bangumiCover.isEmpty
                                ? SizedBox(
                                    width: coverWidth,
                                    height: coverWidth * 1.4,
                                    child: const ColoredBox(
                                      color: Color(0x12FFFFFF),
                                      child: Icon(
                                        Icons.movie_outlined,
                                        color: CinemaTheme.muted,
                                      ),
                                    ),
                                  )
                                : NetworkImgLayer(
                                    src: record.bangumiCover,
                                    width: coverWidth,
                                    height: coverWidth * 1.4,
                                  ),
                          ),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  record.bangumiName,
                                  style: textTheme.titleMedium?.copyWith(
                                    fontSize: compact ? 16 : 18,
                                    fontWeight: FontWeight.w600,
                                    height: 1.3,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  record.displaySource,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  meta,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          KazumiMenuButton(
                            animated: false,
                            builder: (context, toggle) => IconButton(
                              icon: const Icon(Icons.more_horiz_rounded),
                              tooltip: '更多操作',
                              onPressed: toggle,
                            ),
                            menuChildren: [
                              KazumiMenuItem(
                                label: '全部开始',
                                onPressed: onResumeAll,
                              ),
                              KazumiMenuItem(
                                label: '全部删除',
                                destructive: true,
                                onPressed: onDeleteAll,
                              ),
                            ],
                          ),
                          IconButton(
                            tooltip: expanded ? '收起集数' : '展开集数',
                            onPressed: onToggle,
                            icon: AnimatedRotation(
                              turns: expanded ? .5 : 0,
                              duration: MediaQuery.disableAnimationsOf(context)
                                  ? Duration.zero
                                  : _kExpandDuration,
                              curve: _kExpandCurve,
                              child: const Icon(Icons.expand_more_rounded),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              if (!allCompleted)
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, expanded ? 8 : 18),
                  child: LinearProgressIndicator(
                    value: aggregateProgress.clamp(0.0, 1.0),
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(3),
                    color: const Color(0xCCFFFFFF),
                    backgroundColor: const Color(0x14FFFFFF),
                  ),
                ),
              if (MediaQuery.disableAnimationsOf(context))
                episodeContent
              else
                AnimatedSize(
                  duration: _kExpandDuration,
                  curve: _kExpandCurve,
                  alignment: Alignment.topCenter,
                  child: episodeContent,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class DownloadEpisodeTile extends StatelessWidget {
  const DownloadEpisodeTile({
    super.key,
    required this.episode,
    required this.statusText,
    this.actions = const [],
    this.onPlay,
  });

  final DownloadEpisode episode;
  final String statusText;
  final List<Widget> actions;

  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isError = episode.status == DownloadStatus.failed;
    final showProgress =
        episode.status == DownloadStatus.downloading ||
        (episode.status == DownloadStatus.paused &&
            episode.progressPercent > 0);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onPlay,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Row(
          children: [
            _EpisodeStatusBadge(episode: episode),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    episode.episodeName.isNotEmpty
                        ? episode.episodeName
                        : '第${episode.episodeNumber}集',
                    style: textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Tooltip(
                    message: statusText,
                    child: Text(
                      statusText,
                      style: textTheme.bodySmall?.copyWith(
                        color: isError
                            ? colorScheme.error
                            : colorScheme.onSurfaceVariant,
                      ),
                      maxLines: episode.errorMessage.isEmpty ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (showProgress) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: episode.progressPercent.clamp(0.0, 1.0),
                      minHeight: 2,
                      color: const Color(0xBBFFFFFF),
                      backgroundColor: const Color(0x14FFFFFF),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            ...actions,
          ],
        ),
      ),
    );
  }
}

class _EpisodeStatusBadge extends StatelessWidget {
  const _EpisodeStatusBadge({required this.episode});

  final DownloadEpisode episode;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    Color background;
    Widget child;
    switch (episode.status) {
      case DownloadStatus.completed:
        background = Colors.transparent;
        child = Icon(
          episode.errorMessage.isEmpty
              ? Icons.check_rounded
              : Icons.warning_amber_rounded,
          size: 18,
          color: colorScheme.onSecondaryContainer,
        );
        break;
      case DownloadStatus.downloading:
        background = Colors.transparent;
        child = SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            value: episode.progressPercent,
            strokeWidth: 2,
            color: colorScheme.onSurface,
            backgroundColor: const Color(0x18FFFFFF),
          ),
        );
        break;
      case DownloadStatus.resolving:
        background = Colors.transparent;
        child = const SizedBox(
          width: 22,
          height: 22,
          child: LoadingIndicator(),
        );
        break;
      case DownloadStatus.failed:
        background = Colors.transparent;
        child = Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: colorScheme.error,
        );
        break;
      case DownloadStatus.paused:
        background = Colors.transparent;
        child = Icon(
          Icons.pause_rounded,
          size: 18,
          color: colorScheme.onSurfaceVariant,
        );
        break;
      case DownloadStatus.pending:
      default:
        background = Colors.transparent;
        child = Icon(
          Icons.schedule_rounded,
          size: 18,
          color: colorScheme.onSurfaceVariant,
        );
        break;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Center(child: child),
    );
  }
}
