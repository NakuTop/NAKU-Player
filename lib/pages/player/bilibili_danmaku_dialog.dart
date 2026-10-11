import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';

class BilibiliDanmakuDialog extends StatefulWidget {
  const BilibiliDanmakuDialog({super.key, this.client});
  final BilibiliDanmakuClient? client;
  @override
  State<BilibiliDanmakuDialog> createState() => _BilibiliDanmakuDialogState();
}

class _BilibiliDanmakuDialogState extends State<BilibiliDanmakuDialog> {
  final _link = TextEditingController();
  final _cancel = CancelToken();
  late final _client = widget.client ?? BilibiliDanmakuClient();
  BilibiliDanmakuVideo? _video;
  var _page = 0, _generation = 0;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _cancel.cancel();
    _link.dispose();
    super.dispose();
  }

  Future<void> _run({required bool load}) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (load) {
        final video = await _client.video(_link.text, cancelToken: _cancel);
        if (!mounted || generation != _generation) return;
        setState(() {
          _video = video;
          _page = video.selectedIndex;
        });
      } else {
        final comments = await _client.comments(
          _video!.pages[_page].cid,
          cancelToken: _cancel,
        );
        if (!mounted || generation != _generation) return;
        Navigator.pop<List<DanmakuEntry>>(context, comments);
      }
    } on FormatException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'B 站弹幕暂时无法加载，请稍后重试或导入本地文件');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('从 Bilibili 加载本集弹幕'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('粘贴对应视频或番剧链接，确认分集后应用到当前一集。无需弹弹play凭据；加载后保存在本机，离线也可使用。'),
            const SizedBox(height: 16),
            TextField(
              controller: _link,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '视频链接 / BV、av、ep、ss 编号',
              ),
              onChanged: (_) => setState(() {
                _video = null;
                _error = null;
              }),
              onSubmitted: (_) => _run(load: true),
            ),
            const SizedBox(height: 12),
            if (_video != null) ...[
              Text(
                _video!.title,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              DropdownButton<int>(
                value: _page,
                isExpanded: true,
                items: [
                  for (var i = 0; i < _video!.pages.length; i++)
                    DropdownMenuItem(
                      value: i,
                      child: Text(
                        _video!.pages[i].name,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy ? null : (i) => setState(() => _page = i!),
              ),
              const Text('仅加载接口当前提供的公开弹幕。不同剪辑可在弹幕设置中调整时间偏移。'),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : () => _run(load: _video == null),
        child: Text(_video == null ? '读取视频' : '应用到本集'),
      ),
    ],
  );
}
