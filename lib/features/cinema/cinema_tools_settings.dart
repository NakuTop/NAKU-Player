import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'cinema_library_backup.dart';
import 'cinema_media_cache.dart';
import 'cinema_source_subscriptions.dart';
import 'cinema_store.dart';
import 'cinema_theme.dart';

class CinemaToolsSettingsPage extends StatefulWidget {
  const CinemaToolsSettingsPage({
    super.key,
    required this.store,
    this.initialTab = 0,
  });
  final CinemaStore store;
  final int initialTab;
  @override
  State<CinemaToolsSettingsPage> createState() =>
      _CinemaToolsSettingsPageState();
}

class _CinemaToolsSettingsPageState extends State<CinemaToolsSettingsPage> {
  bool _busy = false, _credentials = false;
  String? _status;
  late final _subscriptions = CinemaSourceSubscriptions(widget.store);
  final _cache = CinemaMediaCache.instance;
  CinemaCachePreferences? _draftCache;
  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final message = await action();
      if (mounted) setState(() => _status = message);
    } catch (error) {
      if (mounted) {
        setState(
          () => _status = error is FormatException
              ? error.message
              : '操作未完成，请检查网络或保存位置后重试',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _input(String title, String hint) async {
    final field = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: field,
            minLines: 2,
            maxLines: 8,
            decoration: InputDecoration(hintText: hint),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: const Text('下一步'),
          ),
        ],
      ),
    );
    field.dispose();
    return text;
  }

  Future<bool> _preview(CinemaSourceImport parsed) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('导入 ${parsed.sources.length} 个影视接口'),
          content: SizedBox(
            width: 540,
            height: 320,
            child: ListView(
              children: [
                Text('已有接口会保留名称、启用状态和排序。跳过 ${parsed.skipped} 个不支持或重复的条目。'),
                for (final source in parsed.sources)
                  ListTile(
                    title: Text(source.name),
                    subtitle: Text(source.url, maxLines: 2),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入'),
            ),
          ],
        ),
      ) ??
      false;
  Future<String> _import({bool file = false}) async {
    String? text;
    if (file) {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final path = result?.files.single.path;
      if (path != null) {
        final input = File(path);
        if (await input.length() > 2 * 1024 * 1024) {
          throw const FormatException('片源清单超过 2MB');
        }
        text = await input.readAsString();
      }
    } else {
      text = await _input('批量导入片源', '粘贴包含 sources 或 sites 的 JSON');
    }
    if (text == null || !mounted) return '已取消';
    final parsed = parseCinemaSourceImport(text);
    if (!await _preview(parsed)) return '已取消';
    return '已添加 ${await _subscriptions.import(parsed)} 个影视接口';
  }

  Future<String> _subscribe() async {
    final url = await _input('添加片源订阅', 'https://…/sources.json');
    if (url == null || !mounted) return '已取消';
    // Preview a bounded remote document before saving a subscription.
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('订阅地址无效');
    }
    final parsed = parseCinemaSourceImport(
      await _subscriptions.transport.text(uri, const {}),
    );
    if (!mounted || !await _preview(parsed)) return '已取消';
    return '订阅已保存，新增 ${await _subscriptions.subscribe(url, preloaded: parsed)} 个接口；每天自动检查更新';
  }

  Future<String> _save(String text, String name) async {
    final file = await FilePicker.platform.saveFile(
      dialogTitle: '保存文件',
      fileName: name,
      type: FileType.custom,
      allowedExtensions: const ['json'],
      bytes: utf8.encode(text),
    );
    return file == null ? '已取消' : '已保存到 $file';
  }

  CinemaLibraryBackup _backup() {
    PluginsController? plugins;
    try {
      plugins = inject<PluginsController>();
    } catch (_) {}
    return CinemaLibraryBackup(widget.store, plugins: plugins);
  }

  Future<String> _restore() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    final path = result?.files.single.path;
    if (path == null || !mounted) return '已取消';
    final file = File(path);
    if (await file.length() > 64 * 1024 * 1024) {
      throw const FormatException('备份超过 64MB');
    }
    final text = await file.readAsString();
    final data = CinemaLibraryBackup.decode(text);
    if (!mounted) return '已取消';
    final cinema = data['cinema'] as Map;
    final accepted =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('合并恢复片库'),
            content: Text(
              '电影剧集收藏 ${(cinema['favorites'] as List).length} 条、历史 ${(cinema['history'] as List).length} 条；动漫收藏 ${(data['animeFavorites'] as List).length} 条、历史 ${(data['animeHistory'] as List).length} 条；下载作品 ${(data['downloads'] as List? ?? []).length} 部。\n\n保留已有片源顺序，观看记录采用较新的进度。下载文件按当前下载目录关联；换电脑时请先复制视频文件夹，并在下载设置中选择该目录。缺少的视频保持暂停。恢复前会保存一份本地备份。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('合并恢复'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted) return '已取消';
    final recovery = await _backup().restore(text);
    try {
      inject<DownloadController>().refreshRecords();
    } catch (_) {}
    final raw = widget.store.extras['mediaCache'];
    if (raw is Map) await _cache.configure(CinemaCachePreferences.parse(raw));
    return '片库已合并；新设备重启后读取外观设置。恢复前备份：${recovery.path}';
  }

  Future<void> _configure(CinemaCachePreferences prefs) => _run(() async {
    await widget.store.setExtra('mediaCache', prefs.toJson());
    await _cache.configure(prefs);
    _draftCache = null;
    if (mounted) setState(() {});
    return '缓存设置已保存';
  });

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    initialIndex: widget.initialTab,
    child: Scaffold(
      backgroundColor: CinemaTheme.background,
      appBar: AppBar(
        title: const Text('播放与片库'),
        bottom: const TabBar(
          tabs: [
            Tab(text: '订阅与导入'),
            Tab(text: '视频缓存'),
            Tab(text: '备份与迁移'),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(_status!),
            ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      '订阅支持 JSON 和 TVBox 的直接 MacCMS API。影视来源与动漫规则分开管理。',
                    ),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _run(_subscribe),
                          icon: const Icon(Icons.rss_feed),
                          label: const Text('添加订阅'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _run(_import),
                          child: const Text('粘贴 JSON'),
                        ),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() => _import(file: true)),
                          child: const Text('导入文件'),
                        ),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () => _save(
                                    _subscriptions.export(),
                                    'NAKU-sources.json',
                                  ),
                                ),
                          child: const Text('导出片源'),
                        ),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _subscriptions.refresh();
                                  return '订阅已刷新';
                                }),
                          child: const Text('刷新订阅'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    for (final sub in _subscriptions.subscriptions)
                      ListTile(
                        title: Text('${sub['name']}'),
                        subtitle: Text('${sub['url']}\n更新：${sub['updatedAt']}'),
                        trailing: IconButton(
                          tooltip: '取消订阅（保留已添加片源）',
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _subscriptions.remove('${sub['url']}');
                                  return '已取消订阅，原片源保留';
                                }),
                        ),
                      ),
                    const Divider(),
                  ],
                ),
                ListenableBuilder(
                  listenable: _cache,
                  builder: (context, _) {
                    final prefs = _draftCache ?? _cache.preferences;
                    return ListView(
                      padding: const EdgeInsets.all(24),
                      children: [
                        SwitchListTile(
                          value: prefs.enabled,
                          title: const Text('后台预缓存'),
                          subtitle: const Text(
                            'HLS 分段缓存可跨播放复用；暂停时继续填充，卡顿时让出带宽',
                          ),
                          onChanged: _busy
                              ? null
                              : (v) => _configure(
                                  CinemaCachePreferences(
                                    enabled: v,
                                    quotaMB: prefs.quotaMB,
                                    forwardSeconds: prefs.forwardSeconds,
                                    nextSeconds: prefs.nextSeconds,
                                  ),
                                ),
                        ),
                        Text('磁盘上限 ${prefs.quotaMB} MB'),
                        Slider(
                          value: prefs.quotaMB.toDouble(),
                          min: 128,
                          max: 8192,
                          onChangeEnd: (_) {
                            final prefs = _draftCache;
                            if (prefs != null) _configure(prefs);
                          },
                          onChanged: (v) => setState(
                            () => _draftCache = CinemaCachePreferences(
                              enabled: prefs.enabled,
                              quotaMB: v.round(),
                              forwardSeconds: prefs.forwardSeconds,
                              nextSeconds: prefs.nextSeconds,
                            ),
                          ),
                        ),
                        Text('向前预缓存 ${prefs.forwardSeconds} 秒'),
                        Slider(
                          value: prefs.forwardSeconds.toDouble(),
                          min: 30,
                          max: 900,
                          divisions: 29,
                          onChangeEnd: (_) {
                            final prefs = _draftCache;
                            if (prefs != null) _configure(prefs);
                          },
                          onChanged: (v) => setState(
                            () => _draftCache = CinemaCachePreferences(
                              enabled: prefs.enabled,
                              quotaMB: prefs.quotaMB,
                              forwardSeconds: v.round(),
                              nextSeconds: prefs.nextSeconds,
                            ),
                          ),
                        ),
                        Text('下一集预热 ${prefs.nextSeconds} 秒'),
                        Slider(
                          value: prefs.nextSeconds.toDouble(),
                          min: 0,
                          max: 300,
                          divisions: 10,
                          onChangeEnd: (_) {
                            final prefs = _draftCache;
                            if (prefs != null) _configure(prefs);
                          },
                          onChanged: (v) => setState(
                            () => _draftCache = CinemaCachePreferences(
                              enabled: prefs.enabled,
                              quotaMB: prefs.quotaMB,
                              forwardSeconds: prefs.forwardSeconds,
                              nextSeconds: v.round(),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '已缓存 ${(_cache.bytesUsed / 1048576).toStringAsFixed(1)} MB · 本次命中 ${_cache.hits} 段',
                        ),
                        if (_cache.error != null) Text(_cache.error!),
                        const Text(
                          '缓存为播放器的临时加速数据。需要长期离线观看时，请使用下载选集。直播清单和密钥不会写入磁盘缓存。',
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: _busy
                                ? null
                                : () => _run(() async {
                                    await _cache.clear();
                                    return '视频缓存已清理';
                                  }),
                            icon: const Icon(Icons.cleaning_services),
                            label: const Text('清理缓存'),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const Text(
                      '完整片库备份包含影视片源与订阅、电影剧集和动漫收藏历史、下载记录、动漫规则、弹幕屏蔽及匹配、评分关联和主要设置。视频文件需单独复制下载目录，恢复前在下载设置中选择新目录。',
                    ),
                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: _credentials,
                      title: const Text('包含账号凭据（仅保存到自己的安全位置）'),
                      subtitle: const Text(
                        '默认排除 WebDAV 密码、Bangumi 令牌和房间配对；片源清单可能含自定义请求头',
                      ),
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _credentials = value ?? false),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _run(
                                  () async => _save(
                                    await _backup().export(
                                      credentials: _credentials,
                                    ),
                                    'NAKU-library-${DateTime.now().toIso8601String().substring(0, 10)}.json',
                                  ),
                                ),
                          icon: const Icon(Icons.save_alt),
                          label: const Text('导出完整片库'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : () => _run(_restore),
                          icon: const Icon(Icons.restore),
                          label: const Text('导入并合并片库'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      '备份采用版本化 JSON 与 SHA-256 完整性校验，可迁移到另一台安装 NAKU 2.0 的设备。下载媒体和账号凭据不包含在备份中。',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
