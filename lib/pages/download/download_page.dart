import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'package:kazumi/bean/appbar/sys_app_bar.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/widget/empty_state_widget.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/download/download_widgets.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/services/download/download_library.dart';
import 'package:kazumi/utils/format.dart';

enum _DownloadFilter { all, active, paused, failed, completed }

class DownloadPage extends StatefulWidget {
  const DownloadPage({super.key, required this.controller});
  static const routePath = '/settings/download/';
  final DownloadController controller;
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  DownloadController get downloadController => widget.controller;
  final _query = TextEditingController();
  final Map<String, bool> _expanded = {};
  final Map<String, int> _visibleCounts = {};
  final _selected = <(String, int)>{};
  _DownloadFilter _filter = _DownloadFilter.all;
  bool _managing = false, _busy = false, _confirmationOpen = false;
  List<DownloadWork> _works = [];

  @override
  void initState() {
    super.initState();
    downloadController.refreshRecords();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool _matches(DownloadEntry entry) {
    final status = entry.episode.status;
    final matchesStatus = switch (_filter) {
      _DownloadFilter.all => true,
      _DownloadFilter.active => downloadIsActive(status),
      _DownloadFilter.paused => status == DownloadStatus.paused,
      _DownloadFilter.failed => status == DownloadStatus.failed,
      _DownloadFilter.completed => status == DownloadStatus.completed,
    };
    final query = _query.text.trim().toLowerCase();
    return matchesStatus &&
        (query.isEmpty ||
            '${entry.record.bangumiName} ${entry.record.displaySource} ${entry.episode.episodeName}'
                .toLowerCase()
                .contains(query));
  }

  List<DownloadEntry> get _selection => [
    for (final work in _works)
      for (final e in work.entries)
        if (_selected.contains(e.key)) e,
  ];

  void _toggle(Iterable<DownloadEntry> entries) {
    final keys = entries.map((e) => e.key).toSet();
    setState(() {
      if (keys.every(_selected.contains)) {
        _selected.removeAll(keys);
      } else {
        _selected.addAll(keys);
      }
    });
  }

  Future<void> _perform(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '操作未完成，请检查下载状态后重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: Builder(builder: _buildLibrary),
  );

  Widget _buildLibrary(BuildContext context) => Scaffold(
    appBar: SysAppBar(
      title: const Text(
        '下载管理',
        style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
      ),
      toolbarHeight: 72,
      leading: IconButton(
        tooltip: '返回',
        icon: const Icon(Icons.arrow_back),
        onPressed: () {
          if (!context.maybePop()) context.navigate('/cinema');
        },
      ),
    ),
    body: Observer(
      builder: (context) {
        // Observe snapshots, not just record keys: progress and status can change
        // while the same sources remain in the library.
        final records = [
          for (final key in downloadController.recordKeys)
            ?downloadController.getRecordSnapshot(key),
        ];
        _works = groupDownloadWorks(records);
        final keys = {
          for (final work in _works)
            for (final e in work.entries) e.key,
        };
        _selected.removeWhere((key) => !keys.contains(key));
        final visible = [
          for (final w in _works)
            if (w.entries.any(_matches)) w,
        ];
        final visibleEntries = [
          for (final w in visible) ...w.entries.where(_matches),
        ];
        final selected = _selection;
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1160),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _query,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: '搜索作品、集数或来源',
                            prefixIcon: const Icon(Icons.search_rounded),
                            suffixIcon: _query.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空筛选',
                                    onPressed: () => setState(_query.clear),
                                    icon: const Icon(Icons.close_rounded),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _managing = !_managing;
                                _selected.clear();
                              }),
                        child: Text(_managing ? '完成管理' : '批量管理'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final filter in _DownloadFilter.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(
                                switch (filter) {
                                  _DownloadFilter.all => '全部',
                                  _DownloadFilter.active => '下载中',
                                  _DownloadFilter.paused => '已暂停',
                                  _DownloadFilter.failed => '失败',
                                  _DownloadFilter.completed => '已完成',
                                },
                                style: TextStyle(
                                  fontFamily: Theme.of(
                                    context,
                                  ).textTheme.bodyMedium?.fontFamily,
                                ),
                              ),
                              selected: _filter == filter,
                              showCheckmark: false,
                              onSelected: (_) =>
                                  setState(() => _filter = filter),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (_managing)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                    child: Wrap(
                      spacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text('已选 ${selected.length} 项'),
                        TextButton(
                          onPressed: _busy || visibleEntries.isEmpty
                              ? null
                              : () => _toggle(visibleEntries),
                          child: Text(
                            visibleEntries.isNotEmpty &&
                                    visibleEntries.every(
                                      (e) => _selected.contains(e.key),
                                    )
                                ? '取消全选'
                                : '全选当前结果',
                          ),
                        ),
                        TextButton.icon(
                          onPressed:
                              _busy ||
                                  !selected.any(
                                    (e) => downloadCanResume(e.episode.status),
                                  )
                              ? null
                              : () => _perform(
                                  () => downloadController.resumeEntries(
                                    selected,
                                  ),
                                ),
                          icon: const Icon(Icons.play_arrow_rounded, size: 18),
                          label: const Text('继续所选'),
                        ),
                        TextButton.icon(
                          onPressed:
                              _busy ||
                                  !selected.any(
                                    (e) => downloadIsActive(e.episode.status),
                                  )
                              ? null
                              : () => _perform(
                                  () =>
                                      downloadController.pauseEntries(selected),
                                ),
                          icon: const Icon(Icons.pause_rounded, size: 18),
                          label: const Text('暂停所选'),
                        ),
                        TextButton.icon(
                          onPressed: _busy || selected.isEmpty
                              ? null
                              : () => _confirmDeleteEntries(selected),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('删除所选'),
                        ),
                      ],
                    ),
                  ),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
                Expanded(
                  child: _works.isEmpty
                      ? const GeneralEmptyState(
                          icon: Icons.download_rounded,
                          title: '还没有下载记录',
                        )
                      : visible.isEmpty
                      ? const GeneralEmptyState(
                          icon: Icons.search_off_rounded,
                          title: '没有符合条件的下载',
                        )
                      : ListView.builder(
                          key: const PageStorageKey('download-records-scroll'),
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                          itemCount: visible.length,
                          itemBuilder: (_, i) => _buildWorkCard(visible[i]),
                        ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _buildWorkCard(DownloadWork work) {
    final all = work.entries;
    final entries = all.where(_matches).toList();
    final expanded = _expanded.putIfAbsent(
      work.key,
      () => all.any((e) => e.episode.status != DownloadStatus.completed),
    );
    final limit = _visibleCounts[work.key] ?? 30;
    final speed = all.fold<double>(
      0,
      (sum, e) =>
          sum +
          downloadController.getSpeed(
            e.record.bangumiId,
            e.record.pluginName,
            e.episode.episodeNumber,
          ),
    );
    return DownloadRecordCard(
      key: ValueKey('download-work:${work.key}'),
      record: work.records.first,
      work: work,
      expanded: expanded,
      totalSpeed: speed,
      leading: _managing
          ? Checkbox(
              tristate: true,
              value: entries.every((e) => _selected.contains(e.key))
                  ? true
                  : entries.any((e) => _selected.contains(e.key))
                  ? null
                  : false,
              onChanged: _busy ? null : (_) => _toggle(entries),
            )
          : null,
      onToggle: () => setState(() => _expanded[work.key] = !expanded),
      onResumeAll: () => _perform(() async {
        for (final r in work.records) {
          await downloadController.resumeAllDownloads(
            r.bangumiId,
            r.pluginName,
          );
        }
      }),
      onPauseAll: () => _perform(() => downloadController.pauseEntries(all)),
      onSelectEpisodes: () => setState(() {
        _managing = true;
        _expanded[work.key] = true;
      }),
      onDeleteAll: () => _confirmDeleteWork(work),
      episodeTileBuilder: () => [
        for (final entry in entries.take(limit)) _buildEpisodeTile(work, entry),
        if (entries.length > limit)
          TextButton(
            onPressed: () =>
                setState(() => _visibleCounts[work.key] = limit + 60),
            child: Text('显示更多（还有 ${entries.length - limit} 项）'),
          ),
      ],
    );
  }

  Widget _buildEpisodeTile(DownloadWork work, DownloadEntry entry) {
    final record = entry.record, episode = entry.episode;
    return DownloadEpisodeTile(
      key: ValueKey(entry.key),
      episode: episode,
      sourceLabel: record.displaySource,
      statusText: _getStatusText(record, episode),
      selection: _managing
          ? Checkbox(
              value: _selected.contains(entry.key),
              onChanged: _busy ? null : (_) => _toggle([entry]),
            )
          : null,
      actions: _managing || _busy
          ? const []
          : _getActionButtons(record, episode),
      onPlay: _managing
          ? () => _toggle([entry])
          : episode.status == DownloadStatus.completed
          ? () => _playEpisode(record, episode)
          : null,
    );
  }

  String _getStatusText(DownloadRecord record, DownloadEpisode episode) {
    switch (episode.status) {
      case DownloadStatus.completed:
        return episode.errorMessage.isEmpty
            ? '已完成 · ${formatBytes(episode.totalBytes)}'
            : '本地可播放 · ${formatBytes(episode.totalBytes)} · ${episode.errorMessage}';
      case DownloadStatus.downloading:
        final speed = downloadController.getSpeed(
          record.bangumiId,
          record.pluginName,
          episode.episodeNumber,
        );
        final progress =
            '${(episode.progressPercent * 100).toStringAsFixed(0)}%';
        final detail = episode.totalSegments > 1
            ? '${episode.downloadedSegments}/${episode.totalSegments} 分片'
            : formatBytes(episode.totalBytes);
        return '$progress · $detail${speed > 0 ? ' · ${formatSpeed(speed)}' : ''}';
      case DownloadStatus.failed:
        return episode.errorMessage.isEmpty
            ? '下载失败，请重试或更换来源'
            : episode.errorMessage;
      case DownloadStatus.paused:
        return '已暂停 · ${(episode.progressPercent * 100).toStringAsFixed(0)}%'
            '${episode.errorMessage.isEmpty ? '' : ' · ${episode.errorMessage}'}';
      case DownloadStatus.pending:
        return '排队中';
      case DownloadStatus.resolving:
        return '正在解析视频源';
      default:
        return '';
    }
  }

  List<Widget> _getActionButtons(
    DownloadRecord record,
    DownloadEpisode episode,
  ) {
    final colorScheme = CinemaTheme.of(context).colorScheme;
    final buttons = <Widget>[];

    switch (episode.status) {
      case DownloadStatus.completed:
        buttons.add(
          IconButton(
            icon: Icon(
              Icons.play_circle_outline,
              size: 20,
              color: colorScheme.primary,
            ),
            onPressed: () => _playEpisode(record, episode),
            tooltip: '播放',
            visualDensity: VisualDensity.compact,
          ),
        );
        break;
      case DownloadStatus.resolving:
      case DownloadStatus.downloading:
        buttons.add(
          IconButton(
            icon: const Icon(Icons.pause_rounded, size: 20),
            onPressed: () => downloadController.pauseDownload(
              record.bangumiId,
              record.pluginName,
              episode.episodeNumber,
            ),
            tooltip: '暂停',
            visualDensity: VisualDensity.compact,
          ),
        );
        break;
      case DownloadStatus.paused:
        buttons.add(
          IconButton(
            icon: const Icon(Icons.play_arrow_rounded, size: 20),
            onPressed: () => downloadController.retryDownload(
              bangumiId: record.bangumiId,
              pluginName: record.pluginName,
              episodeNumber: episode.episodeNumber,
            ),
            tooltip: '继续',
            visualDensity: VisualDensity.compact,
          ),
        );
        break;
      case DownloadStatus.failed:
        buttons.add(
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: () => downloadController.retryDownload(
              bangumiId: record.bangumiId,
              pluginName: record.pluginName,
              episodeNumber: episode.episodeNumber,
            ),
            tooltip: '重试',
            visualDensity: VisualDensity.compact,
          ),
        );
        break;
      case DownloadStatus.pending:
        buttons.add(
          IconButton(
            icon: Icon(
              Icons.priority_high,
              size: 20,
              color: colorScheme.primary,
            ),
            onPressed: () {
              downloadController.priorityDownload(
                bangumiId: record.bangumiId,
                pluginName: record.pluginName,
                episodeNumber: episode.episodeNumber,
              );
              KazumiDialog.showToast(message: '已插队优先下载');
            },
            tooltip: '优先下载',
            visualDensity: VisualDensity.compact,
          ),
        );
        break;
      default:
        break;
    }

    if (episode.status == DownloadStatus.pending) {
      buttons.add(
        IconButton(
          icon: const Icon(Icons.pause_rounded, size: 20),
          onPressed: () => downloadController.pauseDownload(
            record.bangumiId,
            record.pluginName,
            episode.episodeNumber,
          ),
          tooltip: '暂停',
          visualDensity: VisualDensity.compact,
        ),
      );
    }
    buttons.add(
      IconButton(
        icon: Icon(
          Icons.delete_outline,
          size: 20,
          color: colorScheme.onSurfaceVariant,
        ),
        onPressed: () => _confirmDeleteEpisode(record, episode),
        tooltip: '删除',
        visualDensity: VisualDensity.compact,
      ),
    );

    return buttons;
  }

  void _playEpisode(DownloadRecord record, DownloadEpisode episode) {
    if (record.isCinema) {
      if (!CinemaSettingsHostBinding.instance.playOffline(record, episode)) {
        KazumiDialog.showToast(message: '请从主界面的下载管理打开视频');
      }
      return;
    }
    final localPath = downloadController.getLocalVideoPath(
      record.bangumiId,
      record.pluginName,
      episode.episodeNumber,
    );
    if (localPath == null) {
      KazumiDialog.showToast(message: '本地文件不存在');
      return;
    }

    final bangumiItem = BangumiItem(
      id: record.bangumiId,
      type: 2,
      name: record.bangumiName,
      nameCn: record.bangumiName,
      summary: '',
      airDate: '',
      airWeekday: 0,
      rank: 0,
      images: {'large': record.bangumiCover},
      tags: [],
      alias: [],
      ratingScore: 0.0,
      votes: 0,
      votesCount: [],
      info: '',
    );

    final downloadedEpisodes = downloadController.getCompletedEpisodes(
      record.bangumiId,
      record.pluginName,
    );

    final work = _works
        .where((w) => w.records.any((r) => r.key == record.key))
        .firstOrNull;
    final playlist = work == null
        ? <DownloadEntry>[]
        : downloadOfflinePlaylist(
            work,
            DownloadEntry(record, episode),
            (e) =>
                downloadController.getLocalVideoPath(
                  e.record.bangumiId,
                  e.record.pluginName,
                  e.episode.episodeNumber,
                ) !=
                null,
          );

    context.pushNamed(
      '/video/',
      arguments: OfflineVideoPlaybackArgs(
        bangumiItem: bangumiItem,
        pluginName: record.pluginName,
        episodeNumber: episode.episodeNumber,
        road: episode.road,
        downloadedEpisodes: downloadedEpisodes,
        downloadEntries: playlist,
      ),
    );
  }

  Future<bool> _confirm(String title, String message) async {
    if (_busy || _confirmationOpen) return false;
    _confirmationOpen = true;
    try {
      return await showDialog<bool>(
            context: context,
            builder: (dialogContext) {
              void accept() => Navigator.of(dialogContext).pop(true);
              void cancel() => Navigator.of(dialogContext).pop(false);
              return Theme(
                data: CinemaTheme.of(context),
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.enter): accept,
                    const SingleActivator(LogicalKeyboardKey.numpadEnter):
                        accept,
                    const SingleActivator(LogicalKeyboardKey.escape): cancel,
                  },
                  child: Focus(
                    autofocus: true,
                    child: AlertDialog(
                      title: Text(title),
                      content: Text(message),
                      actions: [
                        TextButton(onPressed: cancel, child: const Text('取消')),
                        TextButton(
                          onPressed: accept,
                          child: Text(
                            '删除',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ) ??
          false;
    } finally {
      _confirmationOpen = false;
    }
  }

  Future<void> _confirmDeleteEpisode(
    DownloadRecord record,
    DownloadEpisode episode,
  ) async {
    if (!await _confirm(
      '删除下载',
      '确定要删除「${episode.episodeName.isEmpty ? '第${episode.episodeNumber}集' : episode.episodeName}」的下载文件吗？',
    )) {
      return;
    }
    if (!mounted) return;
    await _perform(
      () => downloadController.deleteEpisode(
        record.bangumiId,
        record.pluginName,
        episode.episodeNumber,
      ),
    );
  }

  Future<void> _confirmDeleteWork(DownloadWork work) async {
    if (!await _confirm(
      '删除全部下载',
      '确定要删除「${work.name}」的全部 ${work.entries.length} 项下载吗？包含 ${work.sources.length} 个来源。',
    )) {
      return;
    }
    if (!mounted) return;
    await _perform(() => downloadController.deleteEntries(work.entries));
  }

  Future<void> _confirmDeleteEntries(List<DownloadEntry> entries) async {
    final selection = entries.toList();
    if (!await _confirm(
      '删除所选下载',
      '确定要删除所选 ${selection.length} 项下载文件吗？包含 ${selection.map((e) => e.record.displaySource).toSet().length} 个来源。',
    )) {
      return;
    }
    if (!mounted) return;
    await _perform(() => downloadController.deleteEntries(selection));
  }
}
