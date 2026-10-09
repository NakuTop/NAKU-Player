import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/features/cinema/cinema_appearance_settings.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

/// NAKU uses one black/orange theme. Expose the appearance preferences that its
/// actual theme consumes, instead of legacy palette switches it overrides.
class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late bool _systemFont = GStorage.getSetting(SettingsKeys.useSystemFont);
  late bool _windowButtons = GStorage.getSetting(SettingsKeys.showWindowButton);
  bool _saving = false;

  Future<void> _save(SettingKey<bool> key, bool value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await GStorage.putSetting(key, value);
      if (!mounted) return;
      setState(() {
        if (key == SettingsKeys.useSystemFont) _systemFont = value;
        if (key == SettingsKeys.showWindowButton) _windowButtons = value;
      });
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(message: '外观设置未能保存，请重试', context: context);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('字体与窗口'),
    body: SettingsList(
      sections: [
        SettingsSection(
          title: const Text('全局外观'),
          tiles: [
            SettingsTile(
              leading: Icons.blur_on_rounded,
              title: const Text('外观与透明度'),
              description: const Text('黑橙磨砂主题，调整整个应用的背景透明度'),
              onPressed: (_) => showCinemaAppearanceSheet(context),
            ),
            SettingsTile.switchTile(
              leading: Icons.font_download_rounded,
              title: const Text('使用系统字体'),
              description: const Text('立即应用于整个软件；关闭后使用 MI Sans 字体'),
              enabled: !_saving,
              initialValue: _systemFont,
              onToggle: (value) =>
                  _save(SettingsKeys.useSystemFont, value ?? !_systemFont),
            ),
          ],
        ),
        if (isDesktop())
          SettingsSection(
            title: const Text('窗口'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.web_asset_rounded,
                title: Text(Platform.isMacOS ? '显示系统窗口按钮' : '使用系统标题栏'),
                description: const Text('重启应用生效'),
                enabled: !_saving,
                initialValue: _windowButtons,
                onToggle: (value) => _save(
                  SettingsKeys.showWindowButton,
                  value ?? !_windowButtons,
                ),
              ),
            ],
          ),
        if (Platform.isAndroid)
          SettingsSection(
            title: const Text('屏幕'),
            tiles: [
              SettingsTile(
                leading: Icons.sixty_fps_rounded,
                title: const Text('屏幕帧率'),
                onPressed: (_) => context.pushNamed('/settings/theme/display'),
              ),
            ],
          ),
      ],
    ),
  );
}
