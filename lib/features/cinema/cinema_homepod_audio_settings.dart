import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kazumi/services/platform/homepod_audio_controls.dart';

import 'cinema_theme.dart';

Future<void> showCinemaHomePodAudioSettings(
  BuildContext context, {
  HomePodAudioControls? controls,
}) => showDialog<void>(
  context: context,
  builder: (_) => AlertDialog(
    title: const Text('HomePod 低延迟输出'),
    content: SizedBox(
      width: 460,
      child: CinemaHomePodAudioSettings(controls: controls),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
  ),
);

class CinemaHomePodAudioSettings extends StatefulWidget {
  const CinemaHomePodAudioSettings({super.key, this.controls});
  final HomePodAudioControls? controls;

  @override
  State<CinemaHomePodAudioSettings> createState() =>
      _CinemaHomePodAudioSettingsState();
}

class _CinemaHomePodAudioSettingsState
    extends State<CinemaHomePodAudioSettings> {
  late final HomePodAudioControls controls;
  double? _draftReceiverVolume;

  @override
  void initState() {
    super.initState();
    controls = widget.controls ?? HomePodAudioControls.instance;
    controls.beginViewing();
  }

  @override
  void dispose() {
    controls.endViewing();
    super.dispose();
  }

  String get statusText => controls.installing
      ? '请在系统安装器中完成驱动安装'
      : switch (controls.status) {
          'connecting' => '正在连接…',
          'streaming' =>
            '已连接${controls.deviceName == null ? '' : ' · ${controls.deviceName}'}',
          'error' => '连接未建立',
          _ => controls.enabled ? '输出已开启' : '已关闭',
        };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controls,
    builder: (context, _) => SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile.adaptive(
            key: const ValueKey('homepod-system-audio-toggle'),
            contentPadding: EdgeInsets.zero,
            title: const Text('HomePod 低延迟输出'),
            subtitle: const Text(
              '将整个 Mac 的声音送到 HomePod。NAKU 可留在后台；关闭或退出后恢复电脑出声。',
            ),
            value: controls.enabled || controls.installing,
            onChanged:
                controls.supported &&
                    !controls.discovering &&
                    !controls.checkingDriver
                ? (value) {
                    setState(() => _draftReceiverVolume = null);
                    if (value) {
                      unawaited(controls.enable());
                    } else {
                      unawaited(controls.disable());
                    }
                  }
                : null,
          ),
          if (!controls.supported)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '此功能仅适用于 macOS。',
                style: TextStyle(color: CinemaTheme.muted, fontSize: 13),
              ),
            )
          else ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: ValueKey(
                'homepod-device-${controls.selectedDeviceId}-${controls.devices.length}',
              ),
              initialValue:
                  controls.devices.any(
                    (device) => device.id == controls.selectedDeviceId,
                  )
                  ? controls.selectedDeviceId
                  : null,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'HomePod',
                hintText: '选择同一网络中的扬声器',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final device in controls.devices)
                  DropdownMenuItem(
                    value: device.id,
                    child: Text(device.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged:
                  controls.enabled ||
                      controls.connecting ||
                      controls.installing ||
                      controls.checkingDriver ||
                      controls.discovering
                  ? null
                  : controls.selectDevice,
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('homepod-discover'),
              onPressed:
                  controls.discovering ||
                      controls.checkingDriver ||
                      controls.connecting ||
                      controls.installing
                  ? null
                  : () => unawaited(controls.discover()),
              icon: controls.discovering
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(controls.discovering ? '正在查找…' : '查找扬声器'),
            ),
            const SizedBox(height: 8),
            Text(
              controls.needsDriverUpdate
                  ? 'NAKU 虚拟声卡需要更新授权，再次开启时将打开安装器。'
                  : controls.driverInstalled
                  ? '${controls.driverName ?? 'NAKU 虚拟声卡'} · 已安装'
                  : '首次开启时按需安装 NAKU 虚拟声卡。',
              key: const ValueKey('homepod-driver-status'),
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              key: const ValueKey('homepod-check-driver'),
              onPressed:
                  controls.driverInstalled &&
                      !controls.needsDriverUpdate &&
                      !controls.enabled &&
                      !controls.audioRouteActive &&
                      !controls.installing &&
                      !controls.connecting &&
                      !controls.discovering &&
                      !controls.checkingDriver
                  ? () => unawaited(controls.checkDriver())
                  : null,
              icon: const Icon(Icons.graphic_eq_rounded),
              label: Text(controls.checkingDriver ? '正在检查…' : '检查声卡'),
            ),
            if (controls.driverCheckMessage != null)
              Text(
                controls.driverCheckMessage!,
                key: const ValueKey('homepod-driver-check-result'),
                style: const TextStyle(color: CinemaTheme.muted, fontSize: 13),
              ),
            const SizedBox(height: 8),
            Text(
              statusText,
              style: const TextStyle(color: CinemaTheme.muted, fontSize: 13),
            ),
            if (controls.enabled && controls.status == 'streaming') ...[
              const SizedBox(height: 14),
              Row(
                children: [
                  const Expanded(child: Text('HomePod 音量')),
                  Text(
                    '${(_draftReceiverVolume ?? controls.receiverVolume).round()}%',
                    style: const TextStyle(color: CinemaTheme.copper),
                  ),
                ],
              ),
              Slider(
                key: const ValueKey('homepod-receiver-volume'),
                value: _draftReceiverVolume ?? controls.receiverVolume,
                min: 0,
                max: 100,
                divisions: 100,
                label:
                    '${(_draftReceiverVolume ?? controls.receiverVolume).round()}%',
                semanticFormatterCallback: (value) =>
                    'HomePod 音量 ${value.round()}%',
                onChanged: controls.settingVolume || controls.connecting
                    ? null
                    : (value) => setState(() => _draftReceiverVolume = value),
                onChangeEnd: controls.settingVolume || controls.connecting
                    ? null
                    : (value) {
                        setState(() => _draftReceiverVolume = null);
                        unawaited(controls.setReceiverVolume(value));
                      },
              ),
            ],
            if (controls.enabled && controls.latencyMs != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '发送缓冲目标 · ${controls.latencyMs!.round()} ms',
                  style: const TextStyle(
                    color: CinemaTheme.copper,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
          if (controls.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                controls.error!,
                key: const ValueKey('homepod-audio-error'),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
