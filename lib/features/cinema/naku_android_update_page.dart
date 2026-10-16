import 'package:flutter/material.dart';
import 'package:kazumi/request/config/api_endpoints.dart';
import 'package:kazumi/services/update/auto_updater.dart';
import 'package:url_launcher/url_launcher.dart';
import 'cinema_theme.dart';

class NakuAndroidUpdatePage extends StatefulWidget {
  const NakuAndroidUpdatePage({super.key, this.check});
  final Future<void> Function()? check;
  @override
  State<NakuAndroidUpdatePage> createState() => _NakuAndroidUpdatePageState();
}

class _NakuAndroidUpdatePageState extends State<NakuAndroidUpdatePage> {
  bool _busy = false;
  String? _error;
  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.check ?? AutoUpdater().manualCheckForUpdates)();
    } catch (_) {
      if (mounted) setState(() => _error = '检查更新失败，请重试或打开发布页。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: Scaffold(
      appBar: AppBar(title: const Text('软件更新')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'NAKU Player Android',
            style: TextStyle(fontSize: 25, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          const Text('当前版本 ${ApiEndpoints.version}'),
          const SizedBox(height: 20),
          const Text(
            '使用 NAKU 独立安卓更新源，自动匹配手机或电视安装包。检查后由你确认下载，安装时由 Android 系统确认。',
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _check,
            icon: const Icon(Icons.system_update_alt),
            label: Text(_busy ? '正在检查…' : '检查更新'),
          ),
          OutlinedButton.icon(
            onPressed: () => launchUrl(
              Uri.parse('${ApiEndpoints.projectUrl}/releases'),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('GitHub 发布页'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(_error!),
            ),
          const SizedBox(height: 24),
          const Text('请直接覆盖安装，保留已有片源、收藏、观看记录和 NAS 登录。'),
        ],
      ),
    ),
  );
}
