import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:scrollview_observer/scrollview_observer.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/dialog/material_bottom_sheet.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Kazumi's download grid, shared by anime, films, series and detail pages.
class DownloadEpisodeGroup {
  const DownloadEpisodeGroup({
    required this.name,
    required this.labels,
    required this.urls,
    this.queuedUrls = const {},
  });
  final String name;
  final List<String> labels;
  final List<String> urls;
  final Set<String> queuedUrls;
}

Set<String> queuedDownloadUrls(DownloadRecord? record) => {
  for (final episode in record?.episodes.values ?? <DownloadEpisode>[])
    if ({
      DownloadStatus.completed,
      DownloadStatus.downloading,
      DownloadStatus.pending,
      DownloadStatus.resolving,
    }.contains(episode.status))
      episode.episodePageUrl,
};

class DownloadEpisodeSheet extends StatelessWidget {
  const DownloadEpisodeSheet({
    super.key,
    required this.road,
    required this.videoPageController,
  });
  final int road;
  final VideoPageController videoPageController;

  @override
  Widget build(BuildContext context) => animeDownloadPicker(
    item: videoPageController.bangumiItem,
    plugin: videoPageController.currentPlugin,
    roads: videoPageController.roadList,
    initialRoad: road,
    initialEpisode: videoPageController.playbackEpisode.episode - 1,
  );
}

Widget animeDownloadPicker({
  required BangumiItem item,
  required Plugin plugin,
  required List<Road> roads,
  int initialRoad = 0,
  int? initialEpisode,
}) {
  final downloads = inject<DownloadController>();
  final queued = queuedDownloadUrls(downloads.getRecord(item.id, plugin.name));
  final name = item.nameCn.isNotEmpty ? item.nameCn : item.name;
  return EpisodeDownloadPicker(
    title: name,
    groups: [
      for (final road in roads)
        DownloadEpisodeGroup(
          name: road.name,
          labels: road.identifier,
          urls: road.data,
          queuedUrls: queued,
        ),
    ],
    initialGroup: initialRoad,
    initialEpisode: initialEpisode,
    onDownload: (road, indexes) => downloads.startEpisodeDownloads(
      media: DownloadRecord(
        item.id,
        name,
        item.images['large'] ?? '',
        plugin.name,
        {},
        DateTime.now(),
      ),
      selections: [
        for (final index in indexes)
          DownloadSelection(
            number: index + 1,
            name: roads[road].identifier[index],
            road: road,
            url: roads[road].data[index],
          ),
      ],
    ),
  );
}

class EpisodeDownloadPicker extends StatefulWidget {
  const EpisodeDownloadPicker({
    super.key,
    required this.title,
    required this.groups,
    required this.onDownload,
    this.initialGroup = 0,
    this.initialEpisode,
  });
  final String title;
  final List<DownloadEpisodeGroup> groups;
  final int initialGroup;
  final int? initialEpisode;
  final Future<int> Function(int group, List<int> episodeIndexes) onDownload;

  @override
  State<EpisodeDownloadPicker> createState() => _EpisodeDownloadPickerState();
}

class _EpisodeDownloadPickerState extends State<EpisodeDownloadPicker> {
  late int _group = widget.initialGroup.clamp(
    0,
    math.max(0, widget.groups.length - 1),
  );
  final Set<int> _selected = {};
  bool _submitting = false;
  bool _didJump = false;
  final _observer = GridObserverController();
  String? _error;
  DownloadEpisodeGroup get group => widget.groups[_group];

  @override
  void initState() {
    super.initState();
    if (widget.groups.isEmpty) return;
    if (group.urls.isEmpty) {
      final first = widget.groups.indexWhere((g) => g.urls.isNotEmpty);
      if (first >= 0) _group = first;
    }
    final initial =
        widget.initialEpisode ?? (group.urls.length == 1 ? 0 : null);
    if (initial != null &&
        initial >= 0 &&
        initial < group.urls.length &&
        !group.queuedUrls.contains(group.urls[initial])) {
      _selected.add(initial);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.groups.isEmpty) return const Center(child: Text('暂无可下载的集数'));
    final selectable = [
      for (var i = 0; i < group.urls.length; i++)
        if (!group.queuedUrls.contains(group.urls[i])) i,
    ];
    final queuedCount = group.urls.length - selectable.length;
    final allSelected =
        selectable.isNotEmpty && _selected.length == selectable.length;
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final minHeight = widget.groups.length > 1 ? 344 : 280;
        final minSize = (minHeight * math.max(1, scale) / constraints.maxHeight)
            .clamp(0.3, 1.0);
        return DraggableScrollableSheet(
          initialChildSize: math.max(0.65, minSize),
          minChildSize: minSize,
          maxChildSize: math.max(0.92, minSize),
          expand: false,
          builder: (context, scrollController) {
            _observer.controller = scrollController;
            if (!_didJump) {
              _didJump = true;
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                final index = widget.initialEpisode;
                if (!mounted ||
                    index == null ||
                    index < 0 ||
                    index >= group.urls.length ||
                    !scrollController.hasClients ||
                    _group != widget.initialGroup) {
                  return;
                }
                await _observer.jumpTo(index: index, isFixedHeight: true);
              });
            }
            return Column(
              children: [
                MaterialBottomSheetHeader(
                  title: '下载选集',
                  description:
                      '${widget.title} · 共 ${group.urls.length} 集'
                      '${queuedCount > 0 ? ' · 已添加 $queuedCount 集' : ''}',
                  onClose: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                ),
                if (widget.groups.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: DropdownButtonFormField<int>(
                      initialValue: _group,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '下载线路',
                        isDense: true,
                      ),
                      items: [
                        for (var i = 0; i < widget.groups.length; i++)
                          DropdownMenuItem(
                            value: i,
                            enabled: widget.groups[i].urls.isNotEmpty,
                            child: Text(
                              widget.groups[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: _submitting
                          ? null
                          : (value) {
                              if (value == null) return;
                              setState(() {
                                _group = value;
                                _selected.clear();
                                _error = null;
                              });
                              if (scrollController.hasClients) {
                                scrollController.jumpTo(0);
                              }
                            },
                    ),
                  ),
                Expanded(
                  child: GridViewObserver(
                    controller: _observer,
                    child: GridView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                            maxCrossAxisExtent: 160,
                            crossAxisSpacing: 8,
                            mainAxisSpacing: 8,
                            mainAxisExtent: 56,
                          ),
                      itemCount: group.urls.length,
                      itemBuilder: (context, index) {
                        final queued = group.queuedUrls.contains(
                          group.urls[index],
                        );
                        return _EpisodeTile(
                          identifier: group.labels[index],
                          isDownloaded: queued,
                          isSelected: _selected.contains(index),
                          onTap: queued || _submitting
                              ? null
                              : () => setState(() {
                                  if (!_selected.remove(index)) {
                                    _selected.add(index);
                                  }
                                }),
                        );
                      },
                    ),
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: SafeArea(
                    top: false,
                    child: Row(
                      children: [
                        TextButton(
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 48),
                          ),
                          onPressed: selectable.isEmpty || _submitting
                              ? null
                              : () => setState(() {
                                  _selected.clear();
                                  if (!allSelected) {
                                    _selected.addAll(selectable);
                                  }
                                }),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              const Opacity(opacity: 0, child: Text('取消全选')),
                              Text(allSelected ? '取消全选' : '全选'),
                            ],
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                            ),
                            onPressed: _selected.isEmpty || _submitting
                                ? null
                                : _submit,
                            icon: const Icon(Icons.download_rounded),
                            label: Text(
                              _submitting
                                  ? '正在添加'
                                  : _selected.isEmpty
                                  ? '选择集数'
                                  : '下载 ${_selected.length} 集',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final indexes = _selected.toList()..sort();
      final count = await widget.onDownload(_group, indexes);
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      KazumiDialog.showToast(
        messenger: messenger,
        message: count == 0 ? '所选集数已在下载队列中' : '已添加 $count 集到下载队列',
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = '未能添加下载，请检查已有任务后重试';
        });
      }
    }
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.identifier,
    required this.isDownloaded,
    required this.isSelected,
    this.onTap,
  });

  final String identifier;
  final bool isDownloaded;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final backgroundColor = isDownloaded
        ? colorScheme.surfaceContainerLow
        : isSelected
        ? colorScheme.secondaryContainer
        : colorScheme.surfaceContainerLow;
    final foregroundColor = isDownloaded
        ? colorScheme.outline
        : isSelected
        ? colorScheme.onSecondaryContainer
        : colorScheme.onSurface;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(isSelected ? 28 : 16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(isSelected ? 28 : 16),
          onTap: onTap,
          child: Stack(
            children: [
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    identifier,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: foregroundColor),
                  ),
                ),
              ),
              if (isDownloaded)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Icon(
                    Icons.download_done_rounded,
                    size: 14,
                    color: colorScheme.outline,
                  ),
                )
              else
                Positioned(
                  top: 4,
                  right: 4,
                  child: AnimatedScale(
                    scale: isSelected ? 1 : 0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeInOutCubic,
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 14,
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
