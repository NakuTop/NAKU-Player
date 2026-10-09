import 'package:flutter/material.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'cinema_theme.dart';

/// Uses Kazumi's existing persisted key, including the optional confirmation.
class CinemaWindowCloseSettings extends StatefulWidget {
  const CinemaWindowCloseSettings({
    super.key,
    this.readBehavior,
    this.saveBehavior,
  });

  final int Function()? readBehavior;
  final Future<void> Function(int)? saveBehavior;

  @override
  State<CinemaWindowCloseSettings> createState() =>
      _CinemaWindowCloseSettingsState();
}

class _CinemaWindowCloseSettingsState extends State<CinemaWindowCloseSettings> {
  int? _behavior;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    try {
      final stored =
          widget.readBehavior?.call() ??
          GStorage.getSetting(SettingsKeys.exitBehavior);
      _behavior = [0, 1, 2].contains(stored) ? stored : 2;
    } catch (_) {
      _error = '关闭设置暂时无法读取，请重新打开设置。';
    }
  }

  Future<void> _save(int value) async {
    if (_saving || value == _behavior) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await (widget.saveBehavior?.call(value) ??
          GStorage.putSetting(SettingsKeys.exitBehavior, value));
      if (mounted) setState(() => _behavior = value);
    } catch (_) {
      if (mounted) setState(() => _error = '关闭设置未保存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ListTile(
        key: const ValueKey('settings-window-close'),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 22,
          vertical: 14,
        ),
        leading: const Icon(Icons.close_rounded, color: CinemaTheme.copper),
        title: const Text('关闭窗口时'),
        subtitle: const Padding(
          padding: EdgeInsets.only(top: 5),
          child: Text(
            '隐藏后可从托盘恢复。菜单中的“退出”始终退出应用。',
            style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
        ),
        trailing: DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            key: const ValueKey('window-close-behavior'),
            value: _behavior,
            hint: const Text('暂不可用'),
            items: const [
              DropdownMenuItem(value: 0, child: Text('退出播放器')),
              DropdownMenuItem(value: 1, child: Text('隐藏到托盘')),
              DropdownMenuItem(value: 2, child: Text('每次都询问')),
            ],
            onChanged: _saving || _behavior == null
                ? null
                : (value) {
                    if (value != null) _save(value);
                  },
          ),
        ),
      ),
      if (_saving || _error != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(68, 0, 22, 12),
          child: Text(
            _error ?? '正在保存…',
            style: const TextStyle(color: CinemaTheme.muted, fontSize: 12),
          ),
        ),
    ],
  );
}
