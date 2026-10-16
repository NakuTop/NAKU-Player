import 'dart:async';
import 'dart:io';
import 'naku_android_update_page.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'naku_update_service.dart';
import 'cinema_theme.dart';

class NakuUpdatePage extends StatefulWidget {
  const NakuUpdatePage({super.key, this.android, this.androidCheck});
  @visibleForTesting
  final bool? android;
  @visibleForTesting
  final Future<void> Function()? androidCheck;
  @override
  State<NakuUpdatePage> createState() => _NakuUpdatePageState();
}

class _NakuUpdatePageState extends State<NakuUpdatePage> {
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;
  bool _reading = false;
  Timer? _refresh;
  @override
  void initState() {
    super.initState();
    if (widget.android ?? Platform.isAndroid) return;
    _read();
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) => _read());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    if (_reading) return;
    _reading = true;
    try {
      final value = await NakuUpdateService.state();
      if (mounted) {
        setState(() {
          _state = value;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '当前构建未启用 macOS 更新服务，请从项目发布页获取安装包。');
    } finally {
      _reading = false;
    }
  }

  Future<void> _change({bool? checks, bool? downloads}) async {
    setState(() => _busy = true);
    try {
      await NakuUpdateService.configure(
        automaticChecks: downloads == true ? true : checks,
        automaticDownloads: checks == false ? false : downloads,
      );
      await _read();
    } catch (_) {
      if (mounted) setState(() => _error = '保存更新设置失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _publicationBehind {
    final installed = int.tryParse('${_state?['build']}');
    final published = int.tryParse('${_state?['latestPublishedBuild']}');
    return installed != null && published != null && installed > published;
  }

  @override
  Widget build(BuildContext context) => (widget.android ?? Platform.isAndroid)
      ? NakuAndroidUpdatePage(check: widget.androidCheck)
      : Theme(
          data: CinemaTheme.of(context),
          child: Scaffold(
            appBar: AppBar(title: const Text('软件更新')),
            body: ListView(
              padding: const EdgeInsets.all(28),
              children: [
                const Text(
                  'NAKU播放器',
                  style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                Text(
                  _state == null
                      ? '正在读取版本…'
                      : '版本 ${_state!['version']}（${_state!['build']}）',
                ),
                const SizedBox(height: 24),
                SwitchListTile.adaptive(
                  title: const Text('自动检查更新'),
                  subtitle: const Text('每次启动自动检查，运行期间每小时检查一次；无需手动点击。'),
                  value: _state?['automaticChecks'] == true,
                  onChanged: _state == null || _busy
                      ? null
                      : (v) => _change(checks: v),
                ),
                SwitchListTile.adaptive(
                  title: const Text('自动下载和安装'),
                  subtitle: const Text('后台下载并验证后弹出安装提示；观看视频时不会自动重启。'),
                  value: _state?['automaticDownloads'] == true,
                  onChanged: _state == null || _busy
                      ? null
                      : (v) => _change(downloads: v),
                ),
                if ((_state?['latestPublishedVersion'] as String? ?? '')
                    .isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      '更新源最新：${_state!['latestPublishedVersion']}（${_state!['latestPublishedBuild']}）'
                      '${_publicationBehind ? '\n当前版本高于已发布版本；新构建发布到更新源后才能自动升级。' : ''}',
                      style: const TextStyle(
                        color: CinemaTheme.muted,
                        height: 1.5,
                      ),
                    ),
                  ),
                if ((_state?['status'] as String? ?? '').isNotEmpty)
                  Text(
                    _state!['status'] as String,
                    style: const TextStyle(color: CinemaTheme.muted),
                  ),
                if ((_state?['lastError'] as String? ?? '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_state!['lastError'] as String),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      onPressed: _state == null
                          ? null
                          : () async {
                              try {
                                await NakuUpdateService.check();
                              } catch (error) {
                                if (mounted)
                                  setState(() => _error = '无法检查更新：$error');
                              }
                            },
                      icon: const Icon(Icons.system_update_alt),
                      label: const Text('检查更新'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(
                        Uri.parse(
                          '${NakuUpdateService.repositoryUrl}/releases',
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      label: const Text('GitHub 发布页'),
                    ),
                  ],
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: CinemaTheme.muted),
                    ),
                  ),
                const SizedBox(height: 24),
                const Text(
                  '更新目录和安装包均验证发布者签名。升级保留片源、收藏和观看记录。',
                  style: TextStyle(color: CinemaTheme.muted, height: 1.6),
                ),
              ],
            ),
          ),
        );
}
