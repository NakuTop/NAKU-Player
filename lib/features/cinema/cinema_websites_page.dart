import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_theme.dart';
import 'cinema_website_store.dart';
import 'cinema_webview_page.dart';

/// A visible WebKit website library inspired by Joyflix's site configuration.
/// Website responses are deliberately never described as playback validation.
class CinemaWebsitesPage extends StatefulWidget {
  const CinemaWebsitesPage({super.key, this.store});
  final CinemaWebsiteStore? store;

  @override
  State<CinemaWebsitesPage> createState() => _CinemaWebsitesPageState();
}

class _CinemaWebsitesPageState extends State<CinemaWebsitesPage> {
  late final _store = widget.store ?? CinemaWebsiteStore();
  final _checks = <String, ({int? code, int milliseconds, String label})>{};
  final _pending = <String>{};
  Dio? _dio;
  bool _checking = false;
  bool _opening = false;
  String? _error;
  String _category = '全部';

  @override
  void initState() {
    super.initState();
    _store.addListener(_changed);
    unawaited(_load());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      await _store.load();
      if (!mounted) return;
      setState(() {});
      if (_store.restoreLastSite) {
        final site = _store.sites
            .where((s) => s.id == _store.lastSiteId)
            .firstOrNull;
        if (site != null) await _open(site);
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _dio?.close(force: true);
    _store.removeListener(_changed);
    if (widget.store == null) _store.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (mounted) {
      KazumiDialog.showToast(context: context, message: text);
    }
  }

  Future<void> _open(CinemaWebsite site) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      site.validate();
      await _store.recordLastSite(site.id);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CinemaWebviewPage(title: site.name, url: site.url),
        ),
      );
    } catch (e) {
      _toast('无法打开站点：$e');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _checkSites() async {
    if (_checking || !_store.loaded) return;
    final sites = _store.sites.toList();
    setState(() {
      _checking = true;
      _checks.clear();
      _pending.addAll(sites.map((s) => s.id));
    });
    await MacOSSystemProxy.initialize();
    if (!mounted) return;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (_) => true,
        responseType: ResponseType.plain,
      ),
    );
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        return HttpClient()..findProxy = MacOSSystemProxy.findProxy;
      },
    );
    _dio = dio;
    var cursor = 0;
    Future<void> worker() async {
      while (mounted && cursor < sites.length) {
        final site = sites[cursor++];
        final stopwatch = Stopwatch()..start();
        int? code;
        var label = '连接未完成，请在网页中验证';
        final cancellation = CancelToken();
        try {
          final response = await dio
              .head<String>(site.url, cancelToken: cancellation)
              .timeout(
                const Duration(seconds: 10),
                onTimeout: () {
                  cancellation.cancel('Homepage check timed out');
                  throw TimeoutException('Homepage check timed out');
                },
              );
          code = response.statusCode;
          label = switch (code) {
            final int value when value >= 200 && value < 400 =>
              '首页响应正常 · 未验证播放',
            403 || 429 => '可能需要验证或稍后重试',
            405 => '不支持快速检查 · 请打开查看',
            _ => '首页返回 HTTP ${code ?? "未知"}',
          };
        } catch (_) {
          label = '连接超时或失败 · 可打开重试';
        }
        stopwatch.stop();
        if (!mounted) return;
        setState(() {
          _pending.remove(site.id);
          _checks[site.id] = (
            code: code,
            milliseconds: stopwatch.elapsedMilliseconds,
            label: label,
          );
        });
      }
    }

    try {
      await Future.wait(List.generate(3, (_) => worker()));
    } finally {
      dio.close(force: true);
      if (identical(_dio, dio)) _dio = null;
      if (mounted) setState(() => _checking = false);
    }
  }

  CinemaWebsite? get _fastest {
    final candidates = _store.sites.where((s) {
      final code = _checks[s.id]?.code;
      return code != null && code >= 200 && code < 400;
    }).toList();
    candidates.sort(
      (a, b) =>
          _checks[a.id]!.milliseconds.compareTo(_checks[b.id]!.milliseconds),
    );
    return candidates.firstOrNull;
  }

  Future<void> _edit([CinemaWebsite? site]) async {
    final name = TextEditingController(text: site?.name ?? '');
    final url = TextEditingController(text: site?.url ?? 'https://');
    var category = ['影视', '动漫', '直播'].contains(site?.category)
        ? site!.category
        : '影视';
    String? error;
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, update) => AlertDialog(
            title: Text(site == null ? '添加网页站点' : '编辑网页站点'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称'),
                    autofocus: true,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: url,
                    decoration: const InputDecoration(
                      labelText: '网站地址',
                      hintText: 'https://example.com/',
                    ),
                  ),
                  const SizedBox(height: 14),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration: const InputDecoration(labelText: '分类'),
                    items: ['影视', '动漫', '直播']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) category = value;
                    },
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: const TextStyle(color: Color(0xFFF5A69F)),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  try {
                    final changed = CinemaWebsite(
                      id:
                          site?.id ??
                          'custom-${DateTime.now().microsecondsSinceEpoch}',
                      name: name.text.trim(),
                      url: url.text.trim(),
                      category: category,
                    );
                    changed.validate();
                    await _store.saveSite(changed);
                    if (mounted) setState(() => _checks.remove(changed.id));
                    if (dialogContext.mounted) Navigator.pop(dialogContext);
                  } catch (e) {
                    if (dialogContext.mounted) update(() => error = '$e');
                  }
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ),
      );
    } finally {
      name.dispose();
      url.dispose();
    }
  }

  Future<void> _remove(CinemaWebsite site) async {
    try {
      await _store.removeSite(site.id);
      if (!mounted) return;
      setState(() => _checks.remove(site.id));
      KazumiDialog.showToast(
        context: context,
        message: '已移除 ${site.name}',
        showActionButton: true,
        actionLabel: '撤销',
        onActionPressed: () async {
          try {
            await _store.saveSite(site);
          } catch (e) {
            _toast('$e');
          }
        },
      );
    } catch (e) {
      _toast('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: CinemaTheme.of(context),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('网页影院'),
          backgroundColor: CinemaTheme.background,
          actions: [
            TextButton.icon(
              onPressed: _store.loaded && !_checking ? () => _edit() : null,
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加站点'),
            ),
            const SizedBox(width: 18),
          ],
        ),
        body: !_store.loaded
            ? Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text(_error!),
              )
            : LayoutBuilder(
                builder: (context, constraints) {
                  final sites = _store.sites
                      .where(
                        (s) => _category == '全部' || s.category == _category,
                      )
                      .toList();
                  final columns = constraints.maxWidth >= 1200
                      ? 3
                      : constraints.maxWidth >= 750
                      ? 2
                      : 1;
                  return CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(32, 24, 32, 28),
                        sliver: SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '让网站，在影院里播放。',
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: .5,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                '参考 Joyflix 的内置站点与 WebKit 播放方式。打开后，在网站内搜索、选集和播放。',
                                style: TextStyle(
                                  color: CinemaTheme.muted,
                                  height: 1.8,
                                ),
                              ),
                              const SizedBox(height: 22),
                              Wrap(
                                spacing: 12,
                                runSpacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  FilledButton.tonalIcon(
                                    onPressed: _checking ? null : _checkSites,
                                    icon: _checking
                                        ? const SizedBox(
                                            width: 16,
                                            height: 16,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          )
                                        : const Icon(
                                            Icons.network_check_rounded,
                                            size: 19,
                                          ),
                                    label: Text(
                                      _checking
                                          ? '正在检查 ${_pending.length} 个站点'
                                          : '检查首页连通性',
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _checking || _fastest == null
                                        ? null
                                        : () => _open(_fastest!),
                                    icon: const Icon(
                                      Icons.bolt_outlined,
                                      size: 18,
                                    ),
                                    label: const Text('打开响应最快的站点'),
                                  ),
                                  TextButton(
                                    onPressed: () => launchUrl(
                                      Uri.parse(
                                        'https://github.com/jeffernn/Joyflix-Mac-Objective-C',
                                      ),
                                    ),
                                    child: const Text('Joyflix 来源 ↗'),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                '检查仅测首页响应；不代表视频可播、画质或口碑。需要验证码时请在网站内手动完成。',
                                style: TextStyle(
                                  color: CinemaTheme.muted,
                                  fontSize: 12,
                                  height: 1.7,
                                ),
                              ),
                              SwitchListTile.adaptive(
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  '进入网页影院时恢复上次站点',
                                  style: TextStyle(fontSize: 13),
                                ),
                                value: _store.restoreLastSite,
                                onChanged: (value) async {
                                  try {
                                    await _store.setRestoreLastSite(value);
                                  } catch (e) {
                                    _toast('$e');
                                  }
                                },
                              ),
                              const Divider(),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                children: ['全部', '影视', '动漫', '直播']
                                    .map(
                                      (label) => ChoiceChip(
                                        label: Text(label),
                                        selected: _category == label,
                                        onSelected: (_) =>
                                            setState(() => _category = label),
                                      ),
                                    )
                                    .toList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                                mainAxisExtent: 226,
                                crossAxisSpacing: 16,
                                mainAxisSpacing: 16,
                              ),
                          delegate: SliverChildBuilderDelegate(
                            (context, index) => _card(sites[index]),
                            childCount: sites.length,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  Widget _card(CinemaWebsite site) {
    final check = _checks[site.id];
    return Container(
      decoration: BoxDecoration(
        color: CinemaTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: CinemaTheme.border),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                site.category == '动漫'
                    ? Icons.animation_outlined
                    : site.category == '直播'
                    ? Icons.live_tv_rounded
                    : Icons.language_rounded,
                color: CinemaTheme.copper,
                size: 24,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  site.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '管理 ${site.name}',
                enabled: !_checking,
                onSelected: (action) {
                  if (action == 'edit') {
                    unawaited(_edit(site));
                  } else {
                    unawaited(_remove(site));
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'remove', child: Text('移除')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            site.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const Spacer(),
          Text(
            _pending.contains(site.id)
                ? '正在检查首页…'
                : check?.label ?? '未检查 · ${site.category}',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: _opening ? null : () => _open(site),
                child: const Text('进入网站'),
              ),
              const Spacer(),
              if (check != null)
                Text(
                  '${check.milliseconds} ms',
                  style: const TextStyle(
                    color: CinemaTheme.muted,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
