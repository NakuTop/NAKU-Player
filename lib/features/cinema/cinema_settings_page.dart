import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'cinema_theme.dart';
import 'cinema_settings_catalog.dart';
import 'cinema_window_close_settings.dart';

/// Shared settings entry; source editing remains owned by the home store.
class CinemaSettingsPage extends StatelessWidget {
  const CinemaSettingsPage({
    super.key,
    required this.onSources,
    required this.onAppearance,
    required this.onUpdates,
    required this.enabledSourceCount,
    required this.sourceCount,
    this.onOpenRoute,
  });

  final VoidCallback onSources;
  final VoidCallback onAppearance;
  final VoidCallback onUpdates;
  final int? enabledSourceCount;
  final int? sourceCount;
  final ValueChanged<String>? onOpenRoute;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? 16.0 : 28.0;
      final width = (constraints.maxWidth - inset * 2).clamp(0.0, 1080.0);
      final twoColumns = width >= 900;
      final columnWidth = twoColumns ? (width - 20) / 2 : width;
      final android = Theme.of(context).platform == TargetPlatform.android;
      void openRoute(String route) {
        final callback = onOpenRoute;
        if (callback != null) {
          callback(route);
        } else {
          context.pushNamed(route);
        }
      }

      return ListView(
        key: const PageStorageKey('cinema-settings-scroll'),
        padding: EdgeInsets.fromLTRB(inset, 6, inset, 32),
        children: [
          Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CinemaGlass(
                    blur: false,
                    child: Column(
                      children: [
                        _entry(
                          key: 'settings-sources',
                          icon: Icons.video_library_outlined,
                          title: '片源管理',
                          subtitle:
                              sourceCount == null || enabledSourceCount == null
                              ? '电影和剧集的影视接口'
                              : '已启用 $enabledSourceCount / $sourceCount 个片源',
                          onTap: onSources,
                        ),
                        const Divider(height: 1, indent: 68, endIndent: 20),
                        _entry(
                          key: 'settings-appearance',
                          icon: Icons.blur_on_rounded,
                          title: '外观与透明度',
                          subtitle: '调整全局磨砂玻璃背景的透明度',
                          onTap: onAppearance,
                        ),
                        const Divider(height: 1, indent: 68, endIndent: 20),
                        const CinemaWindowCloseSettings(),
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
                  const SizedBox(height: 24),
                  Wrap(
                    spacing: 20,
                    runSpacing: 24,
                    children: [
                      for (final group in cinemaSettingsGroups)
                        SizedBox(
                          width: columnWidth,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                                child: Text(
                                  group.title,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              CinemaGlass(
                                blur: false,
                                child: Column(
                                  children: [
                                    for (final destination
                                        in group.destinations)
                                      if (!destination.androidOnly || android)
                                        _entry(
                                          key: 'settings-${destination.id}',
                                          icon: destination.icon,
                                          title: destination.title,
                                          subtitle: destination.description,
                                          onTap: () =>
                                              openRoute(destination.route),
                                        ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
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
