import 'package:flutter/material.dart';

/// Navigation only: each destination edits the original persisted setting.
class CinemaSettingsDestination {
  const CinemaSettingsDestination({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.route,
    this.androidOnly = false,
  });

  final String id;
  final String title;
  final String description;
  final IconData icon;
  final String route;
  final bool androidOnly;
}

class CinemaSettingsGroup {
  const CinemaSettingsGroup(this.title, this.destinations);
  final String title;
  final List<CinemaSettingsDestination> destinations;
}

const cinemaSettingsGroups = <CinemaSettingsGroup>[
  CinemaSettingsGroup('播放与画质', [
    CinemaSettingsDestination(
      id: 'player',
      title: '播放设置',
      description: '倍速、续播、连播、控制栏与缓冲；新打开播放器时生效',
      icon: Icons.display_settings_rounded,
      route: '/settings/player',
    ),
    CinemaSettingsDestination(
      id: 'super-resolution',
      title: '超分辨率',
      description: '默认画质增强；支持情况取决于设备与视频输出',
      icon: Icons.auto_awesome_rounded,
      route: '/settings/player/super',
    ),
    CinemaSettingsDestination(
      id: 'decoder',
      title: '硬件解码器',
      description: '选择解码方式，需同时启用硬件解码',
      icon: Icons.memory_rounded,
      route: '/settings/player/decoder',
    ),
    CinemaSettingsDestination(
      id: 'renderer',
      title: '视频渲染器',
      description: 'Android 动漫播放器的视频输出方式',
      icon: Icons.tv_rounded,
      route: '/settings/player/renderer',
      androidOnly: true,
    ),
    CinemaSettingsDestination(
      id: 'keyboard',
      title: '快捷键',
      description: '通用播放操作；弹幕与截图快捷键仅用于动漫',
      icon: Icons.keyboard_rounded,
      route: '/settings/keyboard',
    ),
  ]),
  CinemaSettingsGroup('动漫与同步', [
    CinemaSettingsDestination(
      id: 'rules',
      title: '动漫规则管理',
      description: '动漫模块的播放来源；与电影、剧集片源分开管理',
      icon: Icons.extension_rounded,
      route: '/settings/plugin/',
    ),
    CinemaSettingsDestination(
      id: 'danmaku',
      title: '弹幕设置',
      description: '动漫专用：弹幕服务、显示效果与屏蔽规则',
      icon: Icons.subtitles_rounded,
      route: '/settings/danmaku/',
    ),
    CinemaSettingsDestination(
      id: 'downloads',
      title: '下载设置',
      description: '动漫专用：保存目录、并发数与弹幕缓存',
      icon: Icons.downloading_rounded,
      route: '/settings/download-settings',
    ),
    CinemaSettingsDestination(
      id: 'sync',
      title: '同步与备份',
      description: '动漫专用：Bangumi 追番与 WebDAV 记录、收藏同步',
      icon: Icons.cloud_sync_rounded,
      route: '/settings/sync',
    ),
  ]),
  CinemaSettingsGroup('界面与网络', [
    CinemaSettingsDestination(
      id: 'interface',
      title: '界面设置',
      description: '启动界面、动漫评分与追番布局',
      icon: Icons.pages_rounded,
      route: '/settings/interface',
    ),
    CinemaSettingsDestination(
      id: 'theme',
      title: '字体与窗口',
      description: '系统字体、标题栏与黑橙磨砂外观',
      icon: Icons.palette_outlined,
      route: '/settings/theme',
    ),
    CinemaSettingsDestination(
      id: 'display',
      title: '显示刷新率',
      description: 'Android 设备的显示模式',
      icon: Icons.refresh_rounded,
      route: '/settings/theme/display',
      androidOnly: true,
    ),
    CinemaSettingsDestination(
      id: 'proxy',
      title: '网络与代理',
      description: '动漫访问代理；影视播放沿用系统代理',
      icon: Icons.language_rounded,
      route: '/settings/proxy/',
    ),
  ]),
  CinemaSettingsGroup('存储与维护', [
    CinemaSettingsDestination(
      id: 'storage',
      title: '存储与日志',
      description: '图片缓存与错误日志',
      icon: Icons.storage_rounded,
      route: '/settings/storage',
    ),
    CinemaSettingsDestination(
      id: 'rule-updates',
      title: '更新设置',
      description: '动漫规则更新与应用自动更新入口',
      icon: Icons.update_rounded,
      route: '/settings/update',
    ),
    CinemaSettingsDestination(
      id: 'about',
      title: '关于 NAKU播放器',
      description: '版本、开源项目与许可证',
      icon: Icons.info_outline_rounded,
      route: '/settings/about/',
    ),
  ]),
];
