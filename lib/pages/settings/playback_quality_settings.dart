import 'package:flutter/material.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_dropdown_tile.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'package:kazumi/services/storage/storage.dart';

class PlaybackQualitySettings extends StatefulWidget {
  const PlaybackQualitySettings({super.key, this.onApply});
  final Future<void> Function(PlaybackQualityPreferences)? onApply;
  @override
  State<PlaybackQualitySettings> createState() =>
      _PlaybackQualitySettingsState();
}

class _PlaybackQualitySettingsState extends State<PlaybackQualitySettings> {
  var _settings = PlaybackQualityPreferences.read();
  bool _busy = false;
  Future<void> _save<T>(SettingKey<T> key, T value) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final old = GStorage.getSetting(key);
      await GStorage.putSetting(key, value);
      final updated = PlaybackQualityPreferences.read();
      try {
        await widget.onApply?.call(updated);
      } catch (_) {
        await GStorage.putSetting(key, old);
        await widget.onApply?.call(_settings);
        rethrow;
      }
      if (mounted) setState(() => _settings = updated);
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '当前输出无法应用此设置，已保留原设置');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('画质与流畅度'),
    body: SettingsList(
      sections: [
        SettingsSection(
          title: const Text('片源与缓冲'),
          tiles: [
            SettingsTile.switchTile(
              title: const Text('优先最高码率'),
              description: const Text(
                '开启时选可用的最高码率，关闭时优先约5 Mbps以节省带宽。单一1080p片源不会变成4K；换片时生效。',
              ),
              initialValue: _settings.highestBitrate,
              enabled: !_busy,
              onToggle: (v) => _save(
                SettingsKeys.highestVideoBitrate,
                v ?? !_settings.highestBitrate,
              ),
            ),
            SettingsDropdownTile<int>(
              leading: Icons.memory_rounded,
              title: const Text('影视缓冲上限'),
              description: const Text('较大缓冲适合高码率4K；低内存模式优先。下次打开播放器生效。'),
              value: _settings.bufferMegabytes,
              options: const {
                32: '32 MB',
                64: '64 MB',
                128: '128 MB',
                256: '256 MB',
              },
              enabled: !_busy,
              onChanged: (v) => _save(SettingsKeys.videoBufferMegabytes, v),
            ),
          ],
        ),
        SettingsSection(
          title: const Text('本地处理'),
          tiles: [
            SettingsTile.switchTile(
              title: const Text('影视精细缩放'),
              description: const Text(
                '高质量缩放、色度重建与去色带，适合真人影视；动漫可同时使用已有的Anime4K超分。',
              ),
              initialValue: _settings.fineScaling,
              enabled: !_busy,
              onToggle: (v) => _save(
                SettingsKeys.fineVideoScaling,
                v ?? !_settings.fineScaling,
              ),
            ),
            SettingsTile.switchTile(
              title: const Text('帧节奏平滑（实验）'),
              description: const Text(
                '尝试按显示器刷新节奏混合帧，减少24/30帧画面的抖动。需要输出支持显示同步；不是AI运动补偿插帧，源帧率保持不变。',
              ),
              initialValue: _settings.smoothMotion,
              enabled: !_busy,
              onToggle: (v) => _save(
                SettingsKeys.smoothVideoMotion,
                v ?? !_settings.smoothMotion,
              ),
            ),
          ],
          bottomInfo: const Text(
            '设置对电影、剧集与动漫共用。在播放器的“画质信息”内修改可立即应用本地处理；若出现重影或掉帧，请关闭平滑或降低超分档位。',
          ),
        ),
      ],
    ),
  );
}
