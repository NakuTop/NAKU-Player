import 'package:flutter/material.dart';
import 'package:kazumi/features/cinema/naku_update_page.dart';

import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/storage/storage.dart';

class UpdateSettingsPage extends StatefulWidget {
  const UpdateSettingsPage({super.key});

  @override
  State<UpdateSettingsPage> createState() => _UpdateSettingsPageState();
}

class _UpdateSettingsPageState extends State<UpdateSettingsPage> {
  bool _pluginUpdate = GStorage.getSetting(
    SettingsKeys.checkPluginUpdateOnStartup,
  );

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('更新设置'),
    body: SettingsList(
      sections: [
        SettingsSection(
          title: const Text('启动时检查更新'),
          tiles: [
            ListTile(
              leading: const Icon(Icons.update_rounded),
              title: const Text('应用自动更新'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const NakuUpdatePage()),
              ),
            ),
            SettingsTile.switchTile(
              leading: Icons.extension_rounded,
              title: const Text('规则更新'),
              initialValue: _pluginUpdate,
              onToggle: (value) {
                setState(() => _pluginUpdate = value ?? !_pluginUpdate);
                GStorage.putSetting(
                  SettingsKeys.checkPluginUpdateOnStartup,
                  _pluginUpdate,
                );
              },
            ),
          ],
        ),
      ],
    ),
  );
}
