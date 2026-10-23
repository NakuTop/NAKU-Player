import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_subtitle_timing.dart';
import 'cinema_subtitle_replay.dart';
import 'cinema_subtitle_auto_sync.dart';

/// The primary subtitle workflow stays visible; detailed drift/replay controls
/// remain in the advanced panel below it.
class CinemaSubtitleQuickSyncPanel extends StatefulWidget {
  const CinemaSubtitleQuickSyncPanel({
    super.key,
    required this.player,
    this.autoSync,
  });
  final Player player;
  final CinemaSubtitleAutoSync? autoSync;
  @override
  State<CinemaSubtitleQuickSyncPanel> createState() =>
      _CinemaSubtitleQuickSyncPanelState();
}

class _CinemaSubtitleQuickSyncPanelState
    extends State<CinemaSubtitleQuickSyncPanel> {
  late final session = cinemaExternalSubtitleState(widget.player);
  late final cues = session.cues;
  final _search = TextEditingController();
  late final _scroll = ScrollController(
    initialScrollOffset: (_nearest() - 1).clamp(0, cues.length) * 68.0,
  );
  int? _selected;
  int _followed = -1;
  String _query = '', _notice = '';

  int _nearest() {
    if (cues.isEmpty) return 0;
    final at = session.timing.value
        .subtitleTime(widget.player.state.position)
        .inMilliseconds;
    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) ~/ 2;
      if (cues[mid].start <= at) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return (lo - 1).clamp(0, cues.length - 1);
  }

  void _shift(double seconds) {
    widget.autoSync?.cancel();
    try {
      session.setDelay(session.delay + seconds);
      setState(() => _notice = seconds < 0 ? '字幕已提前 0.5 秒' : '字幕已延后 0.5 秒');
    } on FormatException catch (error) {
      setState(() => _notice = error.message.toString());
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      session.timing,
      session.text,
      session.saveError,
      if (widget.autoSync != null) widget.autoSync!,
    ]),
    builder: (context, _) {
      final timing = session.timing.value;
      final selected = _selected ?? _nearest();
      final indices = [
        for (var i = 0; i < cues.length; i++)
          if (_query.isEmpty || cues[i].text.toLowerCase().contains(_query)) i,
      ];
      if (_selected == null && _query.isEmpty && _followed != selected) {
        _followed = selected;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _scroll.hasClients) {
            _scroll.jumpTo(
              ((selected - 1).clamp(0, cues.length) * 68.0).clamp(
                0,
                _scroll.position.maxScrollExtent,
              ),
            );
          }
        });
      }
      final scheme = Theme.of(context).colorScheme;
      final sync = widget.autoSync;
      final automatic = FilledButton.icon(
        key: const ValueKey('subtitle-quick-auto'),
        onPressed: sync == null || sync.busy
            ? null
            : () async {
                final anchor = _selected == null ? null : cues[_selected!];
                setState(() {
                  _notice = '';
                });
                await sync.run(anchorCue: anchor);
              },
        icon: sync?.busy == true
            ? const SizedBox.square(
                dimension: 15,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.auto_fix_high, size: 18),
        label: Text(
          sync?.busy == true
              ? '正在对齐…'
              : _selected != null
              ? '按这句自动对齐'
              : sync?.outcome == CinemaSubtitleSyncOutcome.succeeded
              ? '重新对齐'
              : sync != null &&
                    const {
                      CinemaSubtitleSyncOutcome.failed,
                      CinemaSubtitleSyncOutcome.timedOut,
                      CinemaSubtitleSyncOutcome.noMatch,
                      CinemaSubtitleSyncOutcome.saveFailed,
                    }.contains(sync.outcome)
              ? '重试自动对齐'
              : '自动对齐',
        ),
      );
      final earlier = OutlinedButton.icon(
        key: const ValueKey('subtitle-quick-earlier'),
        onPressed: () => _shift(-.5),
        icon: const Icon(Icons.keyboard_double_arrow_left, size: 18),
        label: const Text('提前 0.5 秒'),
      );
      final later = OutlinedButton.icon(
        key: const ValueKey('subtitle-quick-later'),
        onPressed: () => _shift(.5),
        icon: const Icon(Icons.keyboard_double_arrow_right, size: 18),
        label: const Text('延后 0.5 秒'),
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (_, constraints) => constraints.maxWidth < 480
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      automatic,
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(child: earlier),
                          const SizedBox(width: 8),
                          Expanded(child: later),
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: automatic),
                      const SizedBox(width: 8),
                      Expanded(child: earlier),
                      const SizedBox(width: 8),
                      Expanded(child: later),
                    ],
                  ),
          ),
          const SizedBox(height: 8),
          Text(
            '选择附近对白密集的 ${sync?.sampleSeconds ?? 5} 秒，在 Mac 本地识别并匹配字幕文字；也可选中听到的一句校准',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (sync != null)
            Row(
              children: [
                const Text('采样时长'),
                Expanded(
                  child: Slider(
                    key: const ValueKey('subtitle-sample-seconds'),
                    min: 5,
                    max: 20,
                    divisions: 15,
                    value: sync.sampleSeconds.toDouble(),
                    label: '${sync.sampleSeconds} 秒',
                    onChanged: sync.busy
                        ? null
                        : (value) => sync.setSampleSeconds(value.round()),
                    onChangeEnd: (_) =>
                        unawaited(sync.saveSamplingPreference()),
                  ),
                ),
                SizedBox(width: 42, child: Text('${sync.sampleSeconds} 秒')),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            '字幕偏移 ${timing.offsetSeconds >= 0 ? '+' : ''}${timing.offsetSeconds.toStringAsFixed(2)} 秒 · 调整自动保存',
            key: const ValueKey('subtitle-quick-offset'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (session.saveError.value case final error?)
            Text(error, style: TextStyle(color: scheme.error)),
          if (sync != null) CinemaSubtitleAutoSyncStatus(controller: sync),
          if (_notice.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _notice,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '字幕文件内容',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${cues.length} 句',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_selected != null)
                TextButton(
                  onPressed: () => setState(() => _selected = null),
                  child: const Text('跟随播放'),
                ),
            ],
          ),
          TextField(
            key: const ValueKey('subtitle-quick-search'),
            controller: _search,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '搜索听到的对白',
              prefixIcon: Icon(Icons.search, size: 18),
            ),
            onChanged: (value) => setState(() {
              _query = value.trim().toLowerCase();
            }),
          ),
          const SizedBox(height: 8),
          Container(
            height: (indices.length * 68.0).clamp(68.0, 204.0),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: indices.isEmpty
                  ? const Center(child: Text('没有匹配对白，请尝试其他字幕版本'))
                  : ListView.builder(
                      controller: _scroll,
                      itemExtent: 68,
                      itemCount: indices.length,
                      itemBuilder: (context, index) {
                        final i = indices[index], cue = cues[i];
                        return ListTile(
                          key: ValueKey('subtitle-quick-cue-$i'),
                          dense: true,
                          selected: i == selected,
                          selectedTileColor: scheme.primary.withValues(
                            alpha: .09,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                          ),
                          title: Text(
                            cue.text,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            _preciseStamp(
                              timing.mediaTime(
                                Duration(milliseconds: cue.start),
                              ),
                            ),
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          onTap: () => setState(() => _selected = i),
                        );
                      },
                    ),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const ValueKey('subtitle-quick-align-cue'),
              onPressed: cues.isEmpty
                  ? null
                  : () {
                      widget.autoSync?.cancel();
                      session.setTiming(
                        timing.align(
                          subtitle: Duration(
                            milliseconds: cues[selected].start,
                          ),
                          media: widget.player.state.position,
                        ),
                      );
                      session.firstSyncAnchor = (
                        subtitle: Duration(milliseconds: cues[selected].start),
                        media: widget.player.state.position,
                      );
                      setState(() => _notice = '已将选中对白对齐当前画面');
                    },
              icon: const Icon(Icons.vertical_align_center, size: 16),
              label: const Text('选中这句 → 对齐当前画面'),
            ),
          ),
        ],
      );
    },
  );
}

class CinemaSubtitleAutoSyncStatus extends StatelessWidget {
  const CinemaSubtitleAutoSyncStatus({super.key, required this.controller});
  final CinemaSubtitleAutoSync controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final sync = controller;
      if (sync.message.isEmpty && !sync.busy) return const SizedBox.shrink();
      final succeeded = sync.outcome == CinemaSubtitleSyncOutcome.succeeded;
      final title = sync.busy
          ? sync.phase
          : switch (sync.outcome) {
              CinemaSubtitleSyncOutcome.succeeded => '已完成',
              CinemaSubtitleSyncOutcome.noMatch => '未找到可靠对齐',
              CinemaSubtitleSyncOutcome.cancelled => '已取消',
              CinemaSubtitleSyncOutcome.timedOut => '已超时',
              CinemaSubtitleSyncOutcome.saveFailed => '已应用，保存未完成',
              _ => '未完成',
            };
      return Semantics(
        liveRegion: true,
        child: Container(
          key: const ValueKey('subtitle-auto-sync-status'),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    sync.busy
                        ? Icons.hourglass_top
                        : succeeded
                        ? Icons.check_circle_outline
                        : sync.outcome == CinemaSubtitleSyncOutcome.cancelled
                        ? Icons.stop_circle_outlined
                        : Icons.info_outline,
                    size: 18,
                    color: succeeded ? const Color(0xFF57B982) : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      key: const ValueKey('subtitle-auto-sync-outcome'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              if (sync.busy) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: sync.progress),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已用 ${sync.elapsed.inSeconds} 秒 · 最多 ${sync.timeout.inSeconds} 秒',
                        key: const ValueKey('subtitle-auto-sync-elapsed'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      key: const ValueKey('subtitle-auto-sync-cancel'),
                      onPressed: sync.cancel,
                      child: const Text('取消'),
                    ),
                  ],
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    sync.message,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

String _stamp(Duration value) {
  final seconds = value.inSeconds.abs();
  return '${value.isNegative ? '-' : ''}${(seconds ~/ 3600).toString().padLeft(2, '0')}:'
      '${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

String _preciseStamp(Duration value) =>
    '${_stamp(value)}.${(value.inMilliseconds.abs() % 1000).toString().padLeft(3, '0')}';

/// One media/subtitle session owns its timing and first anchor. Closing the
/// sheet does not lose the first point while seeking to a later dialogue.
class CinemaSubtitleSyncPanel extends StatefulWidget {
  const CinemaSubtitleSyncPanel({super.key, required this.player});
  final Player player;
  @override
  State<CinemaSubtitleSyncPanel> createState() =>
      _CinemaSubtitleSyncPanelState();
}

class _CinemaSubtitleSyncPanelState extends State<CinemaSubtitleSyncPanel> {
  late final session = cinemaExternalSubtitleState(widget.player);
  late final cues = session.cues;
  late final replay = CinemaSubtitleReplay(widget.player);
  final query = TextEditingController();
  late final offset = TextEditingController(
    text: session.delay.toStringAsFixed(2),
  );
  int selected = 0;
  String? message;

  @override
  void initState() {
    super.initState();
    final at = session.timing.value
        .subtitleTime(widget.player.state.position)
        .inMilliseconds;
    for (var i = 0; i < cues.length; i++) {
      if ((cues[i].start - at).abs() < (cues[selected].start - at).abs()) {
        selected = i;
      }
    }
  }

  void apply(CinemaSubtitleTiming value, String notice) {
    session.setTiming(value);
    offset.text = value.offsetSeconds.toStringAsFixed(2);
    setState(() => message = notice);
  }

  void shift(double seconds) {
    try {
      apply(
        session.timing.value.withOffset(session.delay + seconds),
        seconds < 0 ? '字幕提前 0.5 秒' : '字幕延后 0.5 秒',
      );
    } on FormatException catch (error) {
      setState(() => message = error.message.toString());
    }
  }

  void alignNow({bool second = false}) =>
      alignAt(widget.player.state.position, second: second);

  void alignAt(Duration media, {bool second = false}) {
    if (cues.isEmpty) return;
    final source = Duration(milliseconds: cues[selected].start);
    try {
      if (second) {
        final first = session.firstSyncAnchor;
        if (first == null) throw const FormatException('请先对齐第一处对白');
        apply(
          CinemaSubtitleTiming.fromAnchors(
            firstSubtitle: first.subtitle,
            firstMedia: first.media,
            secondSubtitle: source,
            secondMedia: media,
          ),
          '已按两处对白校准。请复查中段；剪辑删减不同仍需更换字幕版本。',
        );
      } else {
        final timing = session.timing.value.align(
          subtitle: source,
          media: media,
        );
        session.firstSyncAnchor = (subtitle: source, media: media);
        apply(timing, '已对齐这句。若后面逐渐错位，可到后一处对白校正漂移。');
      }
    } on FormatException catch (error) {
      setState(() => message = error.message.toString());
    }
  }

  Future<void> alignReplay() async {
    final start = replay.start;
    if (start == null) return;
    await replay.stop();
    if (mounted) alignAt(start);
  }

  Widget replayControls() => ListenableBuilder(
    listenable: replay,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Text('听清后再回听定位', style: Theme.of(context).textTheme.titleSmall),
        const Text(
          '先听到几个词再暂停。慢速回听前 3 秒，前后移动回听起点，让片段从这句开头开始；然后按起点对齐，不用抢在第一词暂停。',
        ),
        if (replay.start case final start?)
          Text(
            '回听起点 ${_preciseStamp(start)} → ${_preciseStamp(replay.end!)}（0.75 倍速，结束自动暂停）',
          ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('subtitle-replay-play'),
              onPressed: replay.busy ? null : replay.play,
              icon: const Icon(Icons.replay),
              label: Text(replay.start == null ? '慢速回听前 3 秒' : '重听这段'),
            ),
            if (replay.listening)
              TextButton(onPressed: replay.stop, child: const Text('停止回听')),
            if (replay.start != null) ...[
              TextButton(
                onPressed: replay.busy
                    ? null
                    : () => replay.shift(const Duration(milliseconds: -250)),
                child: const Text('起点提前 0.25 秒'),
              ),
              TextButton(
                onPressed: replay.busy
                    ? null
                    : () => replay.shift(const Duration(milliseconds: 250)),
                child: const Text('起点延后 0.25 秒'),
              ),
              TextButton(
                onPressed: replay.busy ? null : replay.capture,
                child: const Text('重取当前附近'),
              ),
            ],
          ],
        ),
        FilledButton(
          key: const ValueKey('subtitle-replay-align'),
          onPressed: replay.start == null || replay.busy ? null : alignReplay,
          child: const Text('以回听起点对齐这句'),
        ),
        if (replay.error != null) Text(replay.error!),
        const SizedBox(height: 12),
      ],
    ),
  );

  @override
  void dispose() {
    query.dispose();
    offset.dispose();
    replay.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<CinemaSubtitleTiming>(
    valueListenable: session.timing,
    builder: (context, timing, _) {
      if (cues.isEmpty) return const SizedBox.shrink();
      final cue = cues[selected];
      final filtered = query.text.trim().isEmpty
          ? <int>[]
          : [
              for (var i = 0; i < cues.length; i++)
                if (cues[i].text.toLowerCase().contains(
                  query.text.trim().toLowerCase(),
                ))
                  i,
            ];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Text('外挂字幕对齐', style: Theme.of(context).textTheme.titleMedium),
          const Text('先听清对白再暂停，选中同一句。可用下面的慢速回听定位开头；对白内容不同请换同集的其他版本。'),
          Text(
            '偏移 ${timing.offsetSeconds >= 0 ? '+' : ''}${timing.offsetSeconds.toStringAsFixed(2)} 秒 · 时间轴倍率 ${timing.scale.toStringAsFixed(6)}',
          ),
          ValueListenableBuilder<String?>(
            valueListenable: session.saveError,
            builder: (context, error, _) => error == null
                ? const SizedBox.shrink()
                : Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => shift(-.5),
                child: const Text('提前 0.5 秒'),
              ),
              TextButton(
                onPressed: () => shift(.5),
                child: const Text('延后 0.5 秒'),
              ),
              TextButton(
                onPressed: () {
                  session.firstSyncAnchor = null;
                  apply(const CinemaSubtitleTiming(), '已恢复字幕原始时间轴');
                },
                child: const Text('重置对齐'),
              ),
            ],
          ),
          TextField(
            controller: offset,
            keyboardType: const TextInputType.numberWithOptions(
              signed: true,
              decimal: true,
            ),
            decoration: InputDecoration(
              labelText: '整体偏移秒数（正数晚显示，负数早显示）',
              suffixIcon: IconButton(
                tooltip: '应用偏移',
                icon: const Icon(Icons.check),
                onPressed: () {
                  final value = double.tryParse(offset.text.trim());
                  try {
                    if (value == null) throw const FormatException('请输入秒数');
                    apply(timing.withOffset(value), '已应用整体偏移');
                  } on FormatException catch (error) {
                    setState(() => message = error.message.toString());
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('subtitle-cue-search'),
            controller: query,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: '查找听到的对白（中文或英文片段）',
              prefixIcon: Icon(Icons.search),
            ),
          ),
          if (query.text.trim().isNotEmpty) ...[
            if (filtered.isEmpty) const Text('没有相同对白，可能是其他集数、语言或剪辑版本。'),
            for (final index in filtered.take(8))
              ListTile(
                dense: true,
                selected: selected == index,
                title: Text(
                  cues[index].text,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '字幕 ${_stamp(Duration(milliseconds: cues[index].start))}',
                ),
                onTap: () => setState(() => selected = index),
              ),
            if (filtered.length > 8) const Text('仅显示前 8 条，请输入更长的对白缩小范围。'),
          ],
          Row(
            children: [
              IconButton(
                tooltip: '上一句字幕',
                onPressed: selected > 0
                    ? () => setState(() => selected--)
                    : null,
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      cue.text,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '字幕 ${_stamp(Duration(milliseconds: cue.start))} → 视频 ${_stamp(timing.mediaTime(Duration(milliseconds: cue.start)))}',
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '下一句字幕',
                onPressed: selected + 1 < cues.length
                    ? () => setState(() => selected++)
                    : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          replayControls(),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: () => alignNow(),
                child: const Text('对齐到当前画面'),
              ),
              OutlinedButton(
                onPressed: session.firstSyncAnchor == null
                    ? null
                    : () => alignNow(second: true),
                child: const Text('第二处校正漂移'),
              ),
            ],
          ),
          if (session.firstSyncAnchor case final first?)
            Text(
              '第一处：字幕 ${_stamp(first.subtitle)} ↔ 视频 ${_stamp(first.media)}。可关闭面板，播放到至少 30 秒后的另一处对白再校准。',
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(message!),
            ),
          const Divider(),
        ],
      );
    },
  );
}
