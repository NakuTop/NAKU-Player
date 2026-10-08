import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_sync_session.dart';

Future<void> showCinemaSyncSheet(
  BuildContext context,
  CinemaSyncSession session,
) => showDialog<void>(
  context: context,
  builder: (_) => _SyncDialog(session: session),
);

class _SyncDialog extends StatefulWidget {
  const _SyncDialog({required this.session});
  final CinemaSyncSession session;
  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  late final _server = TextEditingController(
    text: widget.session.endpoint.isEmpty
        ? defaultSyncPlayEndPoint
        : widget.session.endpoint,
  );
  late final _room = TextEditingController(
    text: widget.session.lastRoom.isEmpty
        ? 'NAKU-${100000 + Random.secure().nextInt(900000)}'
        : widget.session.lastRoom,
  );
  late final _name = TextEditingController(
    text: widget.session.username.isEmpty
        ? 'NAKU-${1000 + Random.secure().nextInt(9000)}'
        : widget.session.username,
  );
  @override
  void dispose() {
    _server.dispose();
    _room.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session,
    builder: (context, _) {
      final s = widget.session;
      return AlertDialog(
        title: const Text('一起看'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('双方选择同一作品和集数，填写相同服务器及房间名，即可同步播放、暂停和进度。'),
                const SizedBox(height: 20),
                if (!s.connected) ...[
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
                    decoration: const InputDecoration(labelText: '房间名'),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '昵称'),
                  ),
                ] else ...[
                  SelectableText('服务器：${s.endpoint}'),
                  SelectableText('房间：${s.room}'),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(
                        text: 'NAKU播放器一起看\n服务器：${s.endpoint}\n房间：${s.room}',
                      ),
                    ),
                    icon: const Icon(Icons.copy, size: 17),
                    label: const Text('复制房间信息'),
                  ),
                ],
                if (s.status.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(s.status),
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
          if (s.connected || s.connecting)
            TextButton(
              onPressed: () => s.disconnect(),
              child: const Text('断开'),
            ),
          if (!s.connected)
            FilledButton(
              onPressed: s.connecting
                  ? null
                  : () async {
                      try {
                        await s.connect(
                          endpoint: _server.text,
                          roomName: _room.text,
                          username: _name.text,
                        );
                      } catch (_) {}
                    },
              child: Text(s.connecting ? '连接中…' : '创建 / 加入房间'),
            ),
        ],
      );
    },
  );
}
