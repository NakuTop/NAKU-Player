import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _perform(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      await action();
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(() => _error = error.message ?? '请先登录 NAS，再检查配对码。');
      }
    } catch (_) {
      if (mounted) setState(() => _error = '配对未完成，请先登录 NAS 并检查配对码和网络连接。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.together,
    builder: (context, _) {
      final together = widget.together, s = together.session;
      return AlertDialog(
        title: const Text('NAS 用户配对'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('登录 NAS 后即可使用一起看。生成配对码发给对方，或输入对方的配对码，即可连接。'),
                const SizedBox(height: 16),
                if (!together.isNASPaired) ...[
                  TextField(
                    controller: _code,
                    enabled: !_busy,
                    maxLength: 16,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: '配对码（留空自动生成）',
                      helperText: '另一端也需先登录 NAS，其余设置自动完成',
                    ),
                  ),
                ] else ...[
                  Text('我的 NAS 账号：${together.nasAccount}'),
                  SelectableText(
                    '配对码：${together.pairingCode.substring(0, 5)}-${together.pairingCode.substring(5)}',
                  ),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: together.pairingCode),
                    ),
                    icon: const Icon(Icons.copy, size: 17),
                    label: const Text('复制配对码'),
                  ),
                  const SizedBox(height: 10),
                  if (together.peers.isEmpty)
                    Text(s.connected ? '等待另一端输入配对码' : '正在等待连接恢复'),
                  for (final peer in together.peers)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.person_outline),
                      title: Text(together.peerDisplayName(peer)),
                      subtitle: Text(
                        peer.media == null
                            ? '未在播放，或对方版本暂不支持作品信息'
                            : '${peer.media!.title} · ${peer.media!.episodeName}${s.peerBufferReady(peer.username) == null
                                  ? ''
                                  : s.peerBufferReady(peer.username) == true
                                  ? ' · 缓冲就绪'
                                  : ' · 正在缓冲'}',
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
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: s.coordinateBuffering,
                  title: const Text('等待双方缓冲就绪'),
                  subtitle: const Text('对方需使用 NAKU 2.0；旧客户端继续使用进度同步'),
                  onChanged: (value) => _perform(() async {
                    await together.configureBufferCoordination(value);
                    setState(() {});
                  }),
                ),
                if (s.waitingForBuffer)
                  TextButton(
                    onPressed: () => _perform(s.continueIndependently),
                    child: const Text('继续单独播放'),
                  ),
                Text(
                  '本机版本时间偏移：${s.localOffsetSeconds >= 0 ? '+' : ''}${s.localOffsetSeconds.toStringAsFixed(1)} 秒',
                ),
                Row(
                  children: [
                    IconButton(
                      tooltip: '本机进度提前 1 秒',
                      onPressed: () => _perform(
                        () => together.setLocalOffset(s.localOffsetSeconds - 1),
                      ),
                      icon: const Icon(Icons.remove),
                    ),
                    TextButton(
                      onPressed: () =>
                          _perform(() => together.setLocalOffset(0)),
                      child: const Text('归零'),
                    ),
                    IconButton(
                      tooltip: '本机进度推后 1 秒',
                      onPressed: () => _perform(
                        () => together.setLocalOffset(s.localOffsetSeconds + 1),
                      ),
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
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
                  '双方各自播放片源，同步播放、暂停、进度与缓冲状态；不传输视频画面。配对关系会保存，重启后自动重连。版本或片头不同可在此校准进度。',
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
          if (together.isNASPaired && !s.connected)
            FilledButton(
              onPressed: s.connecting
                  ? null
                  : () => _perform(together.reconnect),
              child: Text(s.connecting ? '连接中…' : '重新连接'),
            ),
          if (!together.isNASPaired)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _perform(() => together.pairNAS(_code.text)),
              child: Text(_busy ? '正在配对…' : '开始配对'),
            ),
        ],
      );
    },
  );
}
