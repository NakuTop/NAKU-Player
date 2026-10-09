import 'package:flutter/material.dart';

import 'cinema_theme.dart';

/// Shared settings entry; source editing remains owned by the home store.
class CinemaSettingsPage extends StatelessWidget {
  const CinemaSettingsPage({
    super.key,
    required this.onSources,
    required this.onAppearance,
    required this.onUpdates,
    required this.enabledSourceCount,
    required this.sourceCount,
  });

  final VoidCallback onSources;
  final VoidCallback onAppearance;
  final VoidCallback onUpdates;
  final int enabledSourceCount;
  final int sourceCount;

  @override
  Widget build(BuildContext context) => ListView(
    key: const PageStorageKey('cinema-settings-scroll'),
    padding: const EdgeInsets.fromLTRB(28, 6, 28, 32),
    children: [
      Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: CinemaGlass(
            blur: false,
            child: Column(
              children: [
                _entry(
                  key: 'settings-sources',
                  icon: Icons.video_library_outlined,
                  title: '片源管理',
                  subtitle: '已启用 $enabledSourceCount / $sourceCount 个片源',
                  onTap: onSources,
                ),
                const Divider(height: 1, indent: 68, endIndent: 20),
                _entry(
                  key: 'settings-appearance',
                  icon: Icons.blur_on_rounded,
                  title: '外观与透明度',
                  subtitle: '调整磨砂玻璃背景的透明度',
                  onTap: onAppearance,
                ),
                const Divider(height: 1, indent: 68, endIndent: 20),
                _entry(
                  key: 'settings-updates',
                  icon: Icons.system_update_alt_rounded,
                  title: '软件更新',
                  subtitle: '检查新版本与更新记录',
                  onTap: onUpdates,
                ),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Widget _entry({
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) => ListTile(
    key: ValueKey(key),
    contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
    leading: Icon(icon, color: CinemaTheme.copper, size: 23),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w500)),
    subtitle: Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Text(
        subtitle,
        style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
      ),
    ),
    trailing: const Icon(
      Icons.chevron_right_rounded,
      color: CinemaTheme.muted,
      size: 21,
    ),
    onTap: onTap,
  );
}
