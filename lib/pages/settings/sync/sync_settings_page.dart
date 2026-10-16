import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/features/cinema/cinema_nas_sync.dart';
import 'package:kazumi/features/cinema/cinema_settings_host_binding.dart';
import 'sync_settings_widgets.dart';

/// One account service for movie, TV, anime and NAS library records.
class SyncSettingsPage extends StatelessWidget {
  const SyncSettingsPage({
    super.key,
    this.sync,
    this.onConnectNAS,
    this.onBackup,
  });
  final CinemaNASSync? sync;
  final VoidCallback? onConnectNAS, onBackup;

  @override
  Widget build(BuildContext context) {
    final host = CinemaSettingsHostBinding.instance;
    final account = sync ?? host.accountSync;
    void connect() {
      if (onConnectNAS != null) {
        onConnectNAS!();
        return;
      }
      if (!host.openNASAccount()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先返回主界面，再打开 NAS 账号登录。')));
      }
    }

    void backup() {
      if (onBackup != null) {
        onBackup!();
        return;
      }
      if (!host.openLibraryBackup()) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('请先返回主界面，再打开完整片库备份。')));
      }
    }

    Widget content() => SyncPageBody(
      children: [
        const SyncPageIntro(
          icon: Icons.cloud_sync_outlined,
          title: '统一同步历史与收藏',
          description: '使用同一个 NAS 账号保存电影、剧集、动漫和 NAS 影片的观看进度与收藏。',
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('NAS 账号', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text(account?.status ?? '从主界面连接 NAS 账号后启用统一同步。'),
                const SizedBox(height: 12),
                if (account != null)
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动同步全部历史和收藏'),
                    subtitle: const Text('包含电影、剧集、动漫和 NAS；离线继续本地保存，恢复连接后重试。'),
                    value: account.enabled,
                    onChanged: account.busy || account.account == null
                        ? null
                        : (value) => unawaited(account.setEnabled(value)),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: connect,
                      icon: const Icon(Icons.dns_outlined),
                      label: Text(
                        account?.account == null ? '登录 NAS 账号' : '管理 NAS 账号',
                      ),
                    ),
                    if (account != null)
                      OutlinedButton.icon(
                        onPressed:
                            account.busy ||
                                account.paused ||
                                !account.enabled ||
                                account.account == null
                            ? null
                            : () => unawaited(account.sync()),
                        icon: account.busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.sync),
                        label: const Text('立即同步'),
                      ),
                  ],
                ),
                if (account?.lastSuccess != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '上次成功同步：${account!.lastSuccess!.toLocal().toString().split('.').first}',
                    ),
                  ),
                const SizedBox(height: 12),
                const Text('同步不包含账号密码和下载视频文件。其他客户端接入 Naku 同步协议后，可使用同账号共享记录。'),
              ],
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('完整片库备份与迁移'),
            subtitle: const Text('手动导出或恢复片库、片源与设置；下载视频文件需单独复制。'),
            trailing: const Icon(Icons.chevron_right),
            onTap: backup,
          ),
        ),
        ExpansionTile(
          title: const Text('其他动漫同步服务'),
          subtitle: const Text('保留已有 Bangumi 和 WebDAV 配置，按需使用。'),
          children: [
            ListTile(
              title: const Text('Bangumi 追番状态'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed('/settings/bangumi/'),
            ),
            ListTile(
              title: const Text('WebDAV 动漫同步'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.pushNamed('/settings/webdav/'),
            ),
          ],
        ),
      ],
    );
    return SettingsDetailScaffold(
      title: const Text('同步与备份'),
      body: account == null
          ? content()
          : ListenableBuilder(
              listenable: account,
              builder: (_, _) => content(),
            ),
    );
  }
}
