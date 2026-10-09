import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_watch_together.dart';

Future<void> showCinemaSyncSheet(
  BuildContext context, {
  CinemaWatchTogether? coordinator,
}) async {
  final together = coordinator ?? CinemaWatchTogether.instance;
  await together.initialize();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _SyncDialog(together: together),
  );
}

class _SyncDialog extends StatefulWidget {
  const _SyncDialog({required this.together});
  final CinemaWatchTogether together;
  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  late final _server = TextEditingController(
    text: widget.together.endpoint.isEmpty
        ? defaultSyncPlayEndPoint
        : widget.together.endpoint,
  );
  late final _room = TextEditingController(
    text: widget.together.roomName.isEmpty
        ? 'NAKU-${List.generate(12, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}'
        : widget.together.roomName,
  );
  late final _name = TextEditingController(
    text: widget.together.username.isEmpty
        ? 'NAKU-${1000 + Random.secure().nextInt(9000)}'
        : widget.together.username,
  );
  String? _error;
  @override
  void dispose() {
    _server.dispose();
    _room.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    setState(() => _error = null);
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '配对设置未保存，请检查填写内容及磁盘空间后重试。');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.together,
    builder: (context, _) {
      final together = widget.together, s = together.session;
      return AlertDialog(
        title: const Text('一起看'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '配对后，离开播放器或重启软件仍会保留房间。点击对方的「跟随观看」，使用自己的片源打开同一作品和集数。',
                ),
                const SizedBox(height: 16),
                if (!together.isPaired) ...[
                  TextField(
                    controller: _server,
                    decoration: const InputDecoration(
                      labelText: 'Syncplay 服务器',
                      helperText: '使用 TLS 加密连接',
                    ),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _room,
                    maxLength: 35,
                    decoration: const InputDecoration(labelText: '房间名'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _name,
                    maxLength: 16,
                    decoration: const InputDecoration(labelText: '昵称'),
                  ),
                ] else ...[
                  SelectableText('服务器：${together.endpoint}'),
                  SelectableText('房间：${together.roomName}'),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(
                        text:
                            'NAKU播放器一起看\n服务器：${together.endpoint}\n房间：${together.roomName}',
                      ),
                    ),
                    icon: const Icon(Icons.copy, size: 17),
                    label: const Text('复制房间信息'),
                  ),
                  const SizedBox(height: 10),
                  if (together.peers.isEmpty)
                    Text(s.connected ? '等待对方加入此房间' : '正在等待连接恢复'),
                  for (final peer in together.peers)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(peer.username),
                      subtitle: Text(
                        peer.media == null
                            ? '未在播放，或对方版本暂不支持作品信息'
                            : '${peer.media!.title} · ${peer.media!.episodeName}',
                      ),
                      trailing: TextButton(
                        onPressed:
                            peer.media == null ||
                                !s.connected ||
                                together.following
                            ? null
                            : () async {
                                Navigator.pop(context);
                                await together.requestFollow(peer);
                              },
                        child: const Text('跟随观看'),
                      ),
                    ),
                ],
                if (s.status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: Text(s.status),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                const Text(
                  '双方各自联网播放；这里同步播放和进度，不传输画面。影片剪辑或片头不同，可手动校准进度。请只把房间信息分享给一起观看的人。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          if (together.isPaired)
            TextButton(
              onPressed: () => _perform(together.unpair),
              child: const Text('解除配对'),
            ),
          if (together.isPaired && !s.connected)
            FilledButton(
              onPressed: s.connecting
                  ? null
                  : () => _perform(together.reconnect),
              child: Text(s.connecting ? '连接中…' : '重新连接'),
            ),
          if (!together.isPaired)
            FilledButton(
              onPressed: () => _perform(
                () => together.pair(
                  endpoint: _server.text,
                  roomName: _room.text,
                  username: _name.text,
                ),
              ),
              child: const Text('创建 / 加入房间'),
            ),
        ],
      );
    },
  );
}
