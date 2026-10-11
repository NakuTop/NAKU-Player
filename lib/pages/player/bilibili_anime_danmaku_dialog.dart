import 'package:flutter/material.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/bilibili_anime_matcher.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'bilibili_danmaku_dialog.dart';

class BilibiliAnimeDanmakuDialog extends StatefulWidget {
  const BilibiliAnimeDanmakuDialog({
    super.key,
    required this.subject,
    required this.episode,
    required this.matcher,
  });
  final BangumiItem subject;
  final int episode;
  final BilibiliAnimeMatcher matcher;
  @override
  State<BilibiliAnimeDanmakuDialog> createState() =>
      _BilibiliAnimeDanmakuDialogState();
}

class _BilibiliAnimeDanmakuDialogState
    extends State<BilibiliAnimeDanmakuDialog> {
  late final _query = TextEditingController(
    text: widget.subject.nameCn.isEmpty
        ? widget.subject.name
        : widget.subject.nameCn,
  );
  List<BilibiliAnimeCandidate> _candidates = const [];
  BilibiliAnimeCandidate? _candidate;
  BilibiliDanmakuVideo? _video;
  int _page = -1, _generation = 0;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int generation) action) async {
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action(generation);
    } on FormatException catch (e) {
      if (mounted && generation == _generation) {
        setState(() => _error = e.message);
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() => _error = 'B 站弹幕暂时无法加载，请稍后重试');
      }
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  Future<void> _discover({bool search = false}) => _run((generation) async {
    setState(() {
      _video = null;
      _candidate = null;
      _candidates = const [];
      _page = -1;
    });
    if (search && _query.text.trim().isEmpty) {
      throw const FormatException('请输入动漫名称');
    }
    final result = await widget.matcher.discover(
      widget.subject,
      keyword: search ? _query.text.trim() : null,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _candidates = result.candidates;
      _candidate = result.automatic ?? result.candidates.firstOrNull;
    });
    if (_candidate == null) {
      throw const FormatException('没有找到对应番剧，可改用别名搜索；该作品也可能未在 B 站上线');
    }
    await _readVideo(_candidate!, generation, offset: result.offset);
  });

  Future<void> _readVideo(
    BilibiliAnimeCandidate candidate,
    int generation, {
    int offset = 0,
  }) async {
    setState(() {
      _candidate = candidate;
      _video = null;
      _page = -1;
    });
    final video = await widget.matcher.video(candidate.reference);
    if (!mounted || generation != _generation) return;
    final page = BilibiliAnimeMatcher.episode(video, widget.episode + offset);
    setState(() {
      _video = video;
      _page = page == null ? -1 : video.pages.indexOf(page);
    });
  }

  Future<void> _apply() => _run((generation) async {
    final page = _video!.pages[_page];
    final entries = await widget.matcher.client.comments(page.cid);
    if (!mounted || generation != _generation) return;
    if (page.episodeNumber != null &&
        !GStorage.getSetting(SettingsKeys.privateMode)) {
      await widget.matcher.remember(
        widget.subject.id,
        BilibiliAnimeCandidate(_candidate!.reference, _video!.title),
        page.episodeNumber! - widget.episode,
      );
    }
    if (mounted && generation == _generation) {
      Navigator.pop<List<DanmakuEntry>>(context, entries);
    }
  });

  Future<void> _manual() async {
    final result = await showDialog<List<DanmakuEntry>>(
      context: context,
      builder: (_) => BilibiliDanmakuDialog(client: widget.matcher.client),
    );
    if (mounted && result != null) {
      Navigator.pop<List<DanmakuEntry>>(context, result);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('匹配当前动漫弹幕'),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.subject.nameCn.isEmpty ? widget.subject.name : widget.subject.nameCn} · 第 ${widget.episode} 集',
            ),
            const SizedBox(height: 8),
            const Text('播放和换集时会自动匹配。若版本不一致，在这里选择一次，后续沿用对应版本与集号。'),
            const SizedBox(height: 16),
            TextField(
              controller: _query,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: '动漫名称或别名',
                suffixIcon: IconButton(
                  tooltip: '搜索番剧',
                  onPressed: _busy ? null : () => _discover(search: true),
                  icon: const Icon(Icons.search),
                ),
              ),
              onSubmitted: (_) {
                if (!_busy) _discover(search: true);
              },
            ),
            if (_candidates.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButton<BilibiliAnimeCandidate>(
                value: _candidate,
                isExpanded: true,
                hint: const Text('选择番剧版本'),
                items: [
                  for (var i = 0; i < _candidates.length; i++)
                    DropdownMenuItem(
                      value: _candidates[i],
                      child: Text(
                        '${_candidates[i].title}${_candidates.length > 1 ? ' · ${i + 1}' : ''}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (c) {
                        if (c != null) _run((g) => _readVideo(c, g));
                      },
              ),
            ],
            if (_video != null) ...[
              Text(
                _video!.title,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              DropdownButton<int>(
                value: _page < 0 ? null : _page,
                isExpanded: true,
                hint: const Text('请选择对应分集'),
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
                onChanged: _busy
                    ? null
                    : (p) {
                        if (p != null) setState(() => _page = p);
                      },
              ),
            ],
            if (_busy) const LinearProgressIndicator(),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _manual,
                child: const Text('手动链接（可选）'),
              ),
            ),
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
        onPressed: _busy || _video == null || _page < 0 ? null : _apply,
        child: const Text('应用到本集'),
      ),
    ],
  );
}
