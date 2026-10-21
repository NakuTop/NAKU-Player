import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_subtitle_timing.dart';
import 'cinema_subtitle_replay.dart';

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
