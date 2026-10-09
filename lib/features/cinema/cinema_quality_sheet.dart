import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/pages/settings/playback_quality_settings.dart';
import 'package:kazumi/services/player/playback_quality.dart';

Future<void> showCinemaQualitySheet(BuildContext context, Player player) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 760),
      builder: (_) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .82,
        child: CinemaQualitySheet(player: player),
      ),
    );

class CinemaQualitySheet extends StatefulWidget {
  const CinemaQualitySheet({super.key, required this.player});
  final Player player;
  @override
  State<CinemaQualitySheet> createState() => _CinemaQualitySheetState();
}

class _CinemaQualitySheetState extends State<CinemaQualitySheet> {
  PlaybackQualitySnapshot? _snapshot;
  Timer? _timer;
  bool _reading = false, _switching = false;
  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_refresh()),
    );
  }

  Future<void> _refresh() async {
    if (_reading) return;
    final native = widget.player.platform;
    if (native is! NativePlayer) return;
    _reading = true;
    try {
      final value = await PlaybackQualitySnapshot.read(native);
      if (mounted) setState(() => _snapshot = value);
    } finally {
      _reading = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _choose(VideoTrack track) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      await widget.player.setVideoTrack(track);
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '此清晰度暂时无法切换，请尝试其他线路');
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: '实际画质'),
            Tab(text: '本地处理'),
          ],
        ),
        Expanded(
          child: TabBarView(
            children: [
              ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    _snapshot?.resolution ?? '正在读取视频信息',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  const Text('这里显示解码得到的原视频信息。超分辨率和窗口大小不改变片源的真实分辨率。'),
                  const SizedBox(height: 16),
                  for (final row in [
                    (
                      '原视频帧率',
                      _snapshot?.number(
                            'container-fps',
                            suffix: ' fps',
                            digits: 3,
                          ) ??
                          '暂无数据',
                    ),
                    (
                      '解码 / 滤镜帧率',
                      _snapshot?.number(
                            'estimated-vf-fps',
                            suffix: ' fps',
                            digits: 3,
                          ) ??
                          '暂无数据',
                    ),
                    ('编码', _snapshot?.properties['video-codec'] ?? '暂无数据'),
                    ('硬件解码', _snapshot?.properties['hwdec-current'] ?? '暂无数据'),
                    (
                      '传递函数',
                      _snapshot?.properties['video-params/gamma'] ?? '暂无数据',
                    ),
                    (
                      '已缓冲',
                      _snapshot?.number(
                            'demuxer-cache-duration',
                            suffix: ' 秒',
                          ) ??
                          '暂无数据',
                    ),
                    (
                      '渲染丢帧',
                      _snapshot?.number('frame-drop-count', digits: 0) ??
                          '暂无数据',
                    ),
                    (
                      '显示同步',
                      _snapshot?.properties['display-sync-active'] == 'yes'
                          ? '已启用'
                          : '未启用 / 输出不支持',
                    ),
                  ])
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(row.$1),
                      trailing: Text(row.$2),
                    ),
                  const Divider(),
                  const Text('视频轨道 / 清晰度'),
                  StreamBuilder<Tracks>(
                    stream: widget.player.stream.tracks,
                    initialData: widget.player.state.tracks,
                    builder: (context, snapshot) {
                      final tracks =
                          snapshot.data?.video
                              .where((t) => t.id != 'no')
                              .toList() ??
                          [];
                      return Column(
                        children: [
                          for (final track in tracks)
                            ListTile(
                              title: Text(
                                track.id == 'auto'
                                    ? '自动选择（按码率偏好）'
                                    : '${track.w ?? '?'} × ${track.h ?? '?'} · ${track.fps?.toStringAsFixed(2) ?? '?'} fps · ${track.codec ?? '视频'}',
                              ),
                              subtitle: track.id == 'auto'
                                  ? null
                                  : Text(track.title ?? '视频轨道 ${track.id}'),
                              trailing:
                                  widget.player.state.track.video.id == track.id
                                  ? const Icon(Icons.check)
                                  : null,
                              enabled: !_switching,
                              onTap: () => _choose(track),
                            ),
                          if (tracks.where((t) => t.id != 'auto').length <= 1)
                            const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text(
                                '当前链接只提供一个视频轨道。需要更高清画质时，请切换作品线路或打开4K直链。',
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
              SettingsPaneScope(
                embedded: true,
                showBackButton: false,
                onBack: () {},
                child: PlaybackQualitySettings(
                  onApply: (settings) async {
                    final native = widget.player.platform;
                    if (native is! NativePlayer) {
                      throw StateError('Native output required');
                    }
                    await settings.apply(native);
                    await _refresh();
                    if (mounted &&
                        settings.smoothMotion &&
                        _snapshot?.properties['display-sync-active'] != 'yes') {
                      KazumiDialog.showToast(
                        context: this.context,
                        message: '当前输出尚未启用显示同步，平滑设置不能保证生效',
                      );
                    }
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
