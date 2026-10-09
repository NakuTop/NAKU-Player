import 'package:flutter/material.dart';
import 'cinema_appearance.dart';
import 'cinema_theme.dart';

Future<void> showCinemaAppearanceSheet(
  BuildContext context, {
  CinemaAppearance? appearance,
}) async {
  final settings = appearance ?? CinemaAppearance.instance;
  await settings.initialize();
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Theme(
        data: CinemaTheme.dataFor(settings),
        child: AlertDialog(
          title: const Text('外观'),
          content: SizedBox(
            width: 440,
            child: CinemaAppearanceSettings(appearance: settings),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    ),
  );
  await settings.flush();
}

class CinemaAppearanceSettings extends StatelessWidget {
  const CinemaAppearanceSettings({super.key, this.appearance});
  final CinemaAppearance? appearance;
  @override
  Widget build(BuildContext context) {
    final settings = appearance ?? CinemaAppearance.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final transparent = 1 - settings.backgroundOpacity;
        final percent = (transparent * 100).round();
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '背景透明度',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    '$percent%',
                    style: const TextStyle(
                      color: CinemaTheme.copper,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                '只调整背景浓淡，文字、海报和播放按钮保持清晰。',
                style: TextStyle(
                  color: CinemaTheme.muted,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              Slider(
                value: transparent,
                min: 0,
                max: 1 - CinemaAppearance.minimumBackgroundOpacity,
                divisions: 78,
                label: '$percent%',
                semanticFormatterCallback: (value) =>
                    '背景透明度 ${(value * 100).round()}%',
                onChanged: settings.reduceTransparency
                    ? null
                    : (value) => settings.setBackgroundOpacity(1 - value),
                onChangeEnd: settings.reduceTransparency
                    ? null
                    : (_) => settings.flush(),
              ),
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '不透明',
                    style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                  ),
                  Text(
                    '更通透',
                    style: TextStyle(color: CinemaTheme.muted, fontSize: 12),
                  ),
                ],
              ),
              if (settings.reduceTransparency) ...[
                const SizedBox(height: 16),
                const Text(
                  'macOS 已启用「减少透明度」，当前使用不透明背景。关闭该系统选项后，将恢复这里保存的透明度。',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
              ],
              const SizedBox(height: 20),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF6B432A), Color(0xFF1C2633)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: CinemaTheme.backgroundFor(settings),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: CinemaTheme.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.play_circle_fill_rounded,
                        color: CinemaTheme.copper,
                        size: 32,
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'NAKU播放器',
                              style: TextStyle(
                                color: CinemaTheme.text,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              '黑橙 · 磨砂玻璃',
                              style: TextStyle(
                                color: CinemaTheme.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: settings.restoreDefault,
                child: const Text('恢复默认外观'),
              ),
              if (settings.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          settings.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: settings.retrySave,
                        child: const Text('重试保存'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
