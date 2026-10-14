import 'dart:async';
import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'cinema_theme.dart';

Future<void> showCinemaDesktopWindowSettings(
  BuildContext context, {
  DesktopWindowControls? controls,
}) => showDialog<void>(
  context: context,
  builder: (_) => AlertDialog(
    title: const Text('窗口与快捷隐藏'),
    content: SizedBox(
      width: 460,
      child: CinemaDesktopWindowSettings(controls: controls),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  ),
);

class CinemaDesktopWindowSettings extends StatefulWidget {
  const CinemaDesktopWindowSettings({super.key, this.controls});
  final DesktopWindowControls? controls;
  @override
  State<CinemaDesktopWindowSettings> createState() =>
      _CinemaDesktopWindowSettingsState();
}

class _CinemaDesktopWindowSettingsState
    extends State<CinemaDesktopWindowSettings> {
  DesktopWindowControls get controls =>
      widget.controls ?? DesktopWindowControls.instance;
  double? _draftOpacity;

  @override
  void initState() {
    super.initState();
    unawaited(controls.initialize());
  }

  Future<void> _commitOpacity(double value) async {
    await controls.update(controls.preferences.copyWith(opacity: value));
    if (mounted) setState(() => _draftOpacity = null);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controls,
    builder: (context, _) {
      final settings = controls.preferences;
      final editable = controls.supported && !controls.saving;
      final opacity = _draftOpacity ?? settings.opacity;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile.adaptive(
              key: const ValueKey('desktop-global-hotkey'),
              contentPadding: EdgeInsets.zero,
              title: const Text('全局隐藏 / 显示快捷键'),
              subtitle: const Text('切换到其他应用后也可使用；再次按下恢复原来的页面。'),
              value: settings.hotkeyEnabled,
              onChanged: editable
                  ? (value) =>
                        controls.update(settings.copyWith(hotkeyEnabled: value))
                  : null,
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'desktop-shortcut-${settings.shortcut}-${controls.error}',
              ),
              initialValue: settings.shortcut,
              decoration: const InputDecoration(
                labelText: '隐藏 / 显示',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final entry in desktopHideShortcuts.entries)
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)),
              ],
              onChanged: editable
                  ? (value) {
                      if (value != null) {
                        controls.update(settings.copyWith(shortcut: value));
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            Text(
              settings.hotkeyEnabled && controls.registered
                  ? '快捷键已注册 · F8 / F9 可能需要同时按 fn'
                  : settings.hotkeyEnabled
                  ? '快捷键尚未注册，可选择其他组合或使用托盘恢复。'
                  : '快捷键已关闭，仍可从菜单或托盘隐藏 / 显示。',
              style: const TextStyle(
                color: CinemaTheme.muted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            if (settings.hotkeyEnabled && !controls.registered)
              TextButton(
                onPressed: editable
                    ? () => controls.update(settings, retryHotkey: true)
                    : null,
                child: const Text('重新注册快捷键'),
              ),
            SwitchListTile.adaptive(
              key: const ValueKey('desktop-pause-on-hide'),
              contentPadding: EdgeInsets.zero,
              title: const Text('隐藏时自动暂停'),
              subtitle: const Text('默认关闭。电影、剧集和动漫共用；开启后隐藏即暂停，恢复窗口后手动继续播放。'),
              value: settings.pauseOnHide,
              onChanged: editable
                  ? (value) =>
                        controls.update(settings.copyWith(pauseOnHide: value))
                  : null,
            ),
            const Divider(height: 28),
            SwitchListTile.adaptive(
              key: const ValueKey('desktop-translucent'),
              contentPadding: EdgeInsets.zero,
              title: const Text('整窗半透明'),
              subtitle: const Text('默认关闭。调整整个窗口，包括视频与按钮；背景磨砂仍由「外观与透明度」控制。'),
              value: settings.translucent,
              onChanged: editable
                  ? (value) =>
                        controls.update(settings.copyWith(translucent: value))
                  : null,
            ),
            Row(
              children: [
                const Expanded(child: Text('窗口不透明度')),
                Text(
                  '${(opacity * 100).round()}%',
                  style: const TextStyle(color: CinemaTheme.copper),
                ),
              ],
            ),
            Slider(
              key: const ValueKey('desktop-opacity'),
              value: opacity,
              min: DesktopWindowPreferences.minimumOpacity,
              max: 1,
              divisions: 70,
              label: '${(opacity * 100).round()}%',
              onChanged:
                  editable &&
                      settings.translucent &&
                      !controls.reduceTransparency
                  ? (value) {
                      setState(() => _draftOpacity = value);
                      unawaited(controls.previewOpacity(value));
                    }
                  : null,
              onChangeEnd:
                  editable &&
                      settings.translucent &&
                      !controls.reduceTransparency
                  ? _commitOpacity
                  : null,
            ),
            if (controls.reduceTransparency)
              const Text(
                'macOS 已启用「减少透明度」，窗口暂保持不透明，保存的设置会保留。',
                style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
              ),
            if (controls.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  controls.error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.visibility_off_outlined),
                  label: const Text('立即隐藏'),
                  onPressed: editable
                      ? () {
                          Navigator.of(context).pop();
                          unawaited(controls.hide());
                        }
                      : null,
                ),
                TextButton(
                  onPressed: editable
                      ? () async {
                          await controls.update(
                            const DesktopWindowPreferences(),
                          );
                          if (mounted) setState(() => _draftOpacity = null);
                        }
                      : null,
                  child: const Text('恢复默认窗口设置'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
