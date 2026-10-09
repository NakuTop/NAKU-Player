import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/features/cinema/cinema_startup_preferences.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';

class InterfaceSettingsPage extends StatefulWidget {
  const InterfaceSettingsPage({
    super.key,
    this.startupPreferences = const CinemaStartupPreferences(),
  });

  final CinemaStartupPreferences startupPreferences;

  @override
  State<InterfaceSettingsPage> createState() => _InterfaceSettingsPageState();
}

class _InterfaceSettingsPageState extends State<InterfaceSettingsPage> {
  late bool showRating;
  CinemaStartupTarget? _startup;
  bool _savingStartup = false;
  String? _startupError;
  static const _exitBehaviorTitles = ['退出 NAKU播放器', '隐藏到托盘', '每次都询问'];
  int _exitBehavior = GStorage.getSetting(
    SettingsKeys.exitBehavior,
  ).clamp(0, _exitBehaviorTitles.length - 1);

  @override
  void initState() {
    super.initState();
    showRating = GStorage.getSetting(SettingsKeys.showRating);
    try {
      _startup = widget.startupPreferences.read();
    } catch (_) {
      _startupError = '启动设置暂时无法读取，请重新打开设置。';
    }
  }

  Future<void> updateDefaultPage(String page) async {
    if (_savingStartup || _startup == null || page == _startup!.location) {
      return;
    }
    setState(() {
      _savingStartup = true;
      _startupError = null;
    });
    try {
      final target = CinemaStartupTarget.fromStored(page);
      await widget.startupPreferences.save(target);
      if (mounted) setState(() => _startup = target);
    } catch (_) {
      if (mounted) setState(() => _startupError = '启动页面未保存，请重试。');
    } finally {
      if (mounted) setState(() => _savingStartup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsDetailScaffold(
      title: Text('界面设置'),
      body: SettingsList(
        sections: [
          SettingsSection(
            title: Text('启动'),
            tiles: [
              SettingsDropdownTile<String>(
                leading: Icons.home_rounded,
                title: const Text('启动页面'),
                description: Text(
                  _startupError ??
                      (_savingStartup ? '正在保存…' : '下次启动 NAKU播放器时打开此页面'),
                ),
                value: _startup?.location ?? '',
                options: CinemaStartupPreferences.options,
                fallbackLabel: '暂不可用',
                enabled: !_savingStartup && _startup != null,
                onChanged: updateDefaultPage,
              ),
            ],
          ),
          SettingsSection(
            title: Text('动漫展示'),
            tiles: [
              SettingsTile.switchTile(
                leading: Icons.star_rounded,
                onToggle: (value) async {
                  showRating = value ?? !showRating;
                  await GStorage.putSetting(
                    SettingsKeys.showRating,
                    showRating,
                  );
                  setState(() {});
                },
                title: Text('显示动漫评分'),
                description: Text('仅影响动漫概览和番剧列表，不改变电影、剧集与豆瓣榜单评分'),
                initialValue: showRating,
              ),
            ],
          ),
          if (isDesktop())
            SettingsSection(
              title: const Text('窗口行为'),
              tiles: [
                SettingsDropdownTile<int>(
                  leading: Icons.exit_to_app_rounded,
                  title: const Text('关闭窗口时'),
                  description: const Text('设置点击窗口关闭按钮后的行为'),
                  value: _exitBehavior,
                  options: {
                    for (var i = 0; i < _exitBehaviorTitles.length; i++)
                      i: _exitBehaviorTitles[i],
                  },
                  onChanged: (value) {
                    setState(() => _exitBehavior = value);
                    GStorage.putSetting(SettingsKeys.exitBehavior, value);
                  },
                ),
              ],
            ),
        ],
      ),
    );
  }
}
