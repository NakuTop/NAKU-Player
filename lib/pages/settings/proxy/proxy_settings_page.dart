import 'package:flutter/material.dart';
import 'package:kazumi/features/cinema/cinema_media_routing.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/network/proxy_manager.dart';
import 'package:kazumi/services/storage/storage.dart';

class ProxySettingsPage extends StatefulWidget {
  const ProxySettingsPage({super.key});

  @override
  State<ProxySettingsPage> createState() => _ProxySettingsPageState();
}

class _ProxySettingsPageState extends State<ProxySettingsPage> {
  Future<void> _setProxyEnabled(bool value) async {
    if (value && !GStorage.getSetting(SettingsKeys.proxyConfigured)) {
      KazumiDialog.showToast(message: '请先在代理配置中完成测试');
      return;
    }
    await GStorage.putSetting(SettingsKeys.proxyEnable, value);
    if (value) {
      ProxyManager.applyProxy();
    } else {
      ProxyManager.clearProxy();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final proxyEnabled = GStorage.getSetting(SettingsKeys.proxyEnable);
    return SettingsDetailScaffold(
      title: const Text('网络设置'),
      body: SettingsList(
        sections: [
          const NetworkMirrorSettings(),
          SettingsSection(
            title: const Text('视频连接'),
            tiles: [
              if (Theme.of(context).platform == TargetPlatform.macOS)
                SettingsTile.switchTile(
                  leading: Icons.alt_route_rounded,
                  title: const Text('影视自动选择直连 / 代理'),
                  description: const Text(
                    '比较真实媒体片段，按片源及 CDN 记住较快路径；连接失败或持续变慢时重新比较。NAS 局域网保持直连。',
                  ),
                  initialValue: GStorage.getSetting(
                    SettingsKeys.mediaAutoRouting,
                  ),
                  onToggle: (value) async {
                    await GStorage.putSetting(
                      SettingsKeys.mediaAutoRouting,
                      value ?? true,
                    );
                    CinemaMediaRouter.instance.close();
                    if (mounted) setState(() {});
                  },
                ),
              SettingsTile.switchTile(
                leading: Icons.video_settings_rounded,
                title: const Text('视频直连'),
                enabled:
                    Theme.of(context).platform != TargetPlatform.macOS ||
                    !GStorage.getSetting(SettingsKeys.mediaAutoRouting),
                description: const Text(
                  '视频和下载不经过系统或应用代理；关闭则跟随代理设置。更改在重新播放及新下载请求时生效。',
                ),
                initialValue: GStorage.getSetting(
                  SettingsKeys.mediaDirectConnection,
                ),
                onToggle: (value) async {
                  await GStorage.putSetting(
                    SettingsKeys.mediaDirectConnection,
                    value ?? false,
                  );
                  DioFactory.resetDownloadClient();
                  if (mounted) setState(() {});
                },
              ),
            ],
          ),
          SettingsSection(
            title: const Text('代理'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.vpn_key_rounded,
                onToggle: (value) => _setProxyEnabled(value ?? !proxyEnabled),
                title: const Text('启用代理'),
                description: const Text('启用后网络请求将通过代理服务器'),
                initialValue: proxyEnabled,
              ),
              SettingsTile(
                leading: Icons.tune_rounded,
                onPressed: (_) async {
                  await context.pushNamed('/settings/proxy/editor');
                  if (mounted) setState(() {});
                },
                title: const Text('代理配置'),
                description: const Text('配置代理服务器地址和认证信息'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
