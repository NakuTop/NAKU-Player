import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'naku_update_service.dart';
import 'cinema_theme.dart';

class NakuUpdatePage extends StatefulWidget {
  const NakuUpdatePage({super.key});
  @override
  State<NakuUpdatePage> createState() => _NakuUpdatePageState();
}

class _NakuUpdatePageState extends State<NakuUpdatePage> {
  Map<String, dynamic>? _state;
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
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
    }
  }

  Future<void> _change({bool? checks, bool? downloads}) async {
    setState(() => _busy = true);
    try {
      await NakuUpdateService.configure(
        automaticChecks: checks,
        automaticDownloads: downloads,
      );
      await _read();
    } catch (_) {
      if (mounted) setState(() => _error = '保存更新设置失败，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.data,
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
            subtitle: const Text('定期检查 GitHub 上的新版本。'),
            value: _state?['automaticChecks'] == true,
            onChanged: _state == null || _busy
                ? null
                : (v) => _change(checks: v),
          ),
          SwitchListTile.adaptive(
            title: const Text('自动下载和安装'),
            subtitle: const Text('下载已验证的更新，并在退出应用时安装。'),
            value: _state?['automaticDownloads'] == true,
            onChanged: _state == null || _busy
                ? null
                : (v) => _change(downloads: v),
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
                          if (mounted) setState(() => _error = '无法检查更新：$error');
                        }
                      },
                icon: const Icon(Icons.system_update_alt),
                label: const Text('检查更新'),
              ),
              OutlinedButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse('${NakuUpdateService.repositoryUrl}/releases'),
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
