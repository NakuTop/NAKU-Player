import 'package:flutter/foundation.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'cinema_theme.dart';
import 'cinema_settings_catalog.dart';
import 'cinema_window_close_settings.dart';
import 'cinema_desktop_window_settings.dart';
import 'cinema_homepod_audio_settings.dart';
import 'cinema_navigation_preferences.dart';

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
    this.onTools,
    this.platform,
    this.navigationPreferences,
  });

  final TargetPlatform? platform;
  final VoidCallback onSources;
  final VoidCallback? onTools;
  final VoidCallback onAppearance;
  final VoidCallback onUpdates;
  final int? enabledSourceCount;
  final int? sourceCount;
  final ValueChanged<String>? onOpenRoute;
  final CinemaNavigationPreferences? navigationPreferences;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final inset = constraints.maxWidth < 600 ? 16.0 : 28.0;
      final width = (constraints.maxWidth - inset * 2).clamp(0.0, 1080.0);
      final twoColumns = width >= 900;
      final columnWidth = twoColumns ? (width - 20) / 2 : width;
      final refined =
          (platform ?? Theme.of(context).platform) == TargetPlatform.macOS &&
          constraints.maxWidth >= 800;
      final android =
          (platform ?? defaultTargetPlatform) == TargetPlatform.android;
      void openRoute(String route) {
        final callback = onOpenRoute;
        if (callback != null) {
          callback(route);
        } else {
          context.pushNamed(route);
        }
      }

      if (refined) {
        return _desktopSettings(
          context,
          width: width.toDouble(),
          inset: inset,
          openRoute: openRoute,
        );
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
                  _groupSurface(
                    refined: refined,
                    child: Column(
                      children: [
                        _entry(
                          key: 'settings-sources',
                          icon: Icons.video_library_outlined,
                          title: '片源管理',
                          compact: refined,
                          subtitle:
                              sourceCount == null || enabledSourceCount == null
                              ? (refined ? '' : '电影和剧集的影视接口')
                              : '已启用 $enabledSourceCount / $sourceCount 个片源',
                          onTap: onSources,
                        ),
                        if (onTools != null)
                          _entry(
                            key: 'settings-tools-v2',
                            icon: Icons.tune_rounded,
                            title: '播放缓存与片库迁移',
                            compact: refined,
                            subtitle: refined ? '' : '影视订阅、批量导入、缓存与完整片库备份',
                            onTap: onTools!,
                          ),
                        if (!refined)
                          const Divider(height: 1, indent: 68, endIndent: 20),
                        _entry(
                          key: 'settings-appearance',
                          icon: Icons.blur_on_rounded,
                          title: '外观与透明度',
                          compact: refined,
                          subtitle: refined ? '' : '调整全局磨砂玻璃背景的透明度',
                          onTap: onAppearance,
                        ),
                        if (!android && !NakuDevice.isTV)
                          _animeNavigationToggle(compact: refined),
                        if (!refined)
                          const Divider(height: 1, indent: 68, endIndent: 20),
                        if (!android) const CinemaWindowCloseSettings(),
                        if (Theme.of(context).platform ==
                            TargetPlatform.macOS) ...[
                          if (!refined)
                            const Divider(height: 1, indent: 68, endIndent: 20),
                          _entry(
                            key: 'settings-desktop-window',
                            icon: Icons.visibility_off_outlined,
                            title: '窗口与快捷隐藏',
                            compact: refined,
                            subtitle: refined ? '' : '全局隐藏 / 显示快捷键、隐藏时暂停与整窗半透明',
                            onTap: () =>
                                showCinemaDesktopWindowSettings(context),
                          ),
                          _entry(
                            key: 'settings-homepod-audio',
                            icon: Icons.speaker_group_outlined,
                            title: 'HomePod 低延迟输出',
                            compact: refined,
                            subtitle: refined ? '' : '将整个 Mac 的声音送到 HomePod',
                            onTap: () => showCinemaHomePodAudioSettings(context),
                          ),
                        ],
                        if (!refined)
                          const Divider(height: 1, indent: 68, endIndent: 20),
                        if (!android)
                          _entry(
                            key: 'settings-updates',
                            icon: Icons.system_update_alt_rounded,
                            title: '软件更新',
                            compact: refined,
                            subtitle: refined ? '' : '检查新版本与更新记录',
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
                                  android && group.title == '动漫与同步'
                                      ? '账号与同步'
                                      : group.title,
                                  style: TextStyle(
                                    fontSize: refined ? 15 : 17,
                                    fontWeight: FontWeight.w600,
                                    color: refined
                                        ? CinemaTheme.muted
                                        : CinemaTheme.text,
                                  ),
                                ),
                              ),
                              _groupSurface(
                                refined: refined,
                                child: Column(
                                  children: [
                                    for (final destination
                                        in group.destinations)
                                      if ((!destination.androidOnly ||
                                              android) &&
                                          (NakuDevice.canDownload ||
                                              destination.id != 'downloads') &&
                                          (!android ||
                                              !{
                                                'rules',
                                                'danmaku',
                                                'keyboard',
                                              }.contains(destination.id)))
                                        _entry(
                                          key: 'settings-${destination.id}',
                                          icon: destination.icon,
                                          title: destination.title,
                                          compact: refined,
                                          subtitle: refined
                                              ? _essentialDescription(
                                                  destination.id,
                                                )
                                              : destination.description,
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

  Widget _desktopSettings(
    BuildContext context, {
    required double width,
    required double inset,
    required ValueChanged<String> openRoute,
  }) {
    final destinations = {
      for (final group in cinemaSettingsGroups)
        for (final destination in group.destinations)
          destination.id: destination,
    };
    Widget destination(String id) {
      final item = destinations[id]!;
      return _entry(
        key: 'settings-$id',
        icon: item.icon,
        title: item.title,
        compact: true,
        subtitle: _essentialDescription(id),
        onTap: () => openRoute(item.route),
      );
    }

    Widget group(String title, List<Widget> children) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: CinemaTheme.text,
              ),
            ),
          ),
        ),
        ...children,
      ],
    );
    return ListView(
      key: const PageStorageKey('cinema-settings-scroll'),
      padding: EdgeInsets.fromLTRB(inset, 18, inset, 112),
      children: [
        Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            child: CinemaGlass(
              key: const ValueKey('cinema-settings-matte'),
              interactive: false,
              radius: 24,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        group('播放与片源', [
                          destination('quality'),
                          destination('player'),
                          destination('danmaku'),
                          _entry(
                            key: 'settings-sources',
                            icon: Icons.video_library_outlined,
                            title: '片源管理',
                            compact: true,
                            subtitle:
                                sourceCount == null ||
                                    enabledSourceCount == null
                                ? ''
                                : '已启用 $enabledSourceCount / $sourceCount 个片源',
                            onTap: onSources,
                          ),
                          if (onTools != null)
                            _entry(
                              key: 'settings-tools-v2',
                              icon: Icons.tune_rounded,
                              title: '播放缓存与片库迁移',
                              compact: true,
                              subtitle: '',
                              onTap: onTools!,
                            ),
                        ]),
                        const SizedBox(height: 34),
                        group('进阶与动漫', [
                          destination('super-resolution'),
                          destination('decoder'),
                          destination('keyboard'),
                          destination('rules'),
                          if (NakuDevice.canDownload) destination('downloads'),
                        ]),
                      ],
                    ),
                  ),
                  SizedBox(width: width >= 960 ? 64 : 32),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        group('外观与窗口', [
                          _animeNavigationToggle(compact: true),
                          _entry(
                            key: 'settings-appearance',
                            icon: Icons.blur_on_rounded,
                            title: '外观与透明度',
                            compact: true,
                            subtitle: '',
                            onTap: onAppearance,
                          ),
                          destination('interface'),
                          destination('theme'),
                          if (Theme.of(context).platform ==
                              TargetPlatform.macOS)
                            _entry(
                              key: 'settings-desktop-window',
                              icon: Icons.visibility_off_outlined,
                              title: '窗口与快捷隐藏',
                              compact: true,
                              subtitle: '',
                              onTap: () =>
                                  showCinemaDesktopWindowSettings(context),
                            ),
                          _entry(
                            key: 'settings-window-close-entry',
                            icon: Icons.close_rounded,
                            title: '关闭窗口时',
                            compact: true,
                            subtitle: '',
                            onTap: () => _openWindowClose(context),
                          ),
                        ]),
                        const SizedBox(height: 34),
                        group('系统与同步', [
                          _entry(
                            key: 'settings-homepod-audio',
                            icon: Icons.speaker_group_outlined,
                            title: 'HomePod 低延迟输出',
                            compact: true,
                            subtitle: '',
                            onTap: () => showCinemaHomePodAudioSettings(context),
                          ),
                          destination('sync'),
                          destination('proxy'),
                          destination('storage'),
                          _entry(
                            key: 'settings-updates',
                            icon: Icons.system_update_alt_rounded,
                            title: '软件更新',
                            compact: true,
                            subtitle: '',
                            onTap: onUpdates,
                          ),
                          destination('rule-updates'),
                          destination('about'),
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _animeNavigationToggle({required bool compact}) {
    final preferences =
        navigationPreferences ?? CinemaNavigationPreferences.instance;
    return ListenableBuilder(
      listenable: preferences,
      builder: (context, _) => Column(
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('settings-anime-navigation'),
            contentPadding: EdgeInsets.symmetric(horizontal: compact ? 10 : 22),
            secondary: const Icon(
              Icons.animation_rounded,
              color: CinemaTheme.muted,
            ),
            title: const Text('显示动漫入口', style: TextStyle(fontSize: 14)),
            value: preferences.showAnime,
            onChanged: preferences.saving ? null : preferences.setShowAnime,
          ),
          if (preferences.error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 0, 22, 10),
              child: Text(
                preferences.error!,
                style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  void _openWindowClose(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      content: const SizedBox(width: 520, child: CinemaWindowCloseSettings()),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    ),
  );

  Widget _groupSurface({required bool refined, required Widget child}) =>
      refined ? child : CinemaGlass(blur: false, child: child);

  String _essentialDescription(String id) => switch (id) {
    'player' => '新打开播放器时生效',
    'super-resolution' => '支持情况取决于设备与视频输出',
    'decoder' => '需同时启用硬件解码',
    'keyboard' => '弹幕快捷键用于动漫',
    'downloads' => '动漫专用',
    'proxy' => '动漫代理；影视沿用系统代理',
    _ => '',
  };

  Widget _entry({
    required String key,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool compact = false,
  }) => ListTile(
    key: ValueKey(key),
    contentPadding: EdgeInsets.symmetric(
      horizontal: compact ? 10 : 22,
      vertical: compact ? 8 : 14,
    ),
    minLeadingWidth: compact ? 20 : null,
    horizontalTitleGap: compact ? 12 : null,
    shape: compact
        ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))
        : null,
    leading: Icon(
      icon,
      color: compact ? CinemaTheme.muted : CinemaTheme.copper,
      size: compact ? 19 : 23,
    ),
    title: Text(
      title,
      style: TextStyle(
        fontSize: compact ? 14 : null,
        fontWeight: FontWeight.w500,
      ),
    ),
    subtitle: subtitle.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              subtitle,
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
            ),
          ),
    trailing: Icon(
      Icons.chevron_right_rounded,
      color: CinemaTheme.muted,
      size: compact ? 16 : 21,
    ),
    onTap: onTap,
  );
}
