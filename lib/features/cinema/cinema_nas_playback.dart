import 'package:flutter/material.dart';
import 'cinema_nas_media.dart';

int _number(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
List<Map<String, dynamic>> _rows(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : [];
const nasOriginalFileProfile = '__original_file__';

class CinemaNASPlaybackOptions {
  CinemaNASPlaybackOptions.fromMap(Map<String, dynamic> data)
    : profiles = _rows(data['profiles']),
      audios = _rows(data['audios']),
      subtitles = _rows(data['subtitles']),
      relay = data['isRelayOrigin'] == true,
      duration = Duration(milliseconds: _number(data['durationMs']));
  final List<Map<String, dynamic>> profiles, audios, subtitles;
  final bool relay;
  final Duration duration;
  String get defaultProfile => profiles.isEmpty
      ? nasOriginalFileProfile
      : (relay ? profiles.last : profiles.first)['id'].toString();
  bool supportsProfile(String value) =>
      value == nasOriginalFileProfile || profiles.any((p) => p['id'] == value);
  String label(String value) => value == nasOriginalFileProfile
      ? '原文件直连'
      : profiles
                .where((p) => p['id'] == value)
                .firstOrNull?['label']
                ?.toString() ??
            value;
}

class CinemaNASPlaybackSession {
  CinemaNASPlaybackSession(
    this.client,
    this.namespace,
    Map<String, dynamic> data,
  ) : url = data['url']?.toString() ?? '',
      taskId = data['taskId']?.toString() ?? '',
      resolution = data['resolution']?.toString() ?? '',
      bitrate = _number(data['bitrateBps']),
      audio = _number(data['audio']),
      subtitle = data['subtitle'] == null ? -1 : _number(data['subtitle']),
      headers = {
        for (final e
            in (data['headers'] is Map ? data['headers'] as Map : {}).entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
  final CinemaNASClient client;
  final String namespace, url, taskId, resolution;
  final int bitrate, audio, subtitle;
  final Map<String, String> headers;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (taskId.isEmpty) return;
    try {
      await client.call('closePlayback', {
        'namespace': namespace,
        'taskId': taskId,
      });
    } catch (_) {
      /* Native cleanup has its own captured task identity and expiry. */
    }
  }
}

/// Playback uses NAS streaming tasks; downloading keeps the original-file API.
class CinemaNASPlaybackClient {
  CinemaNASPlaybackClient({CinemaNASClient? client})
    : client = client ?? CinemaNASClient();
  final CinemaNASClient client;
  Map<String, dynamic> parameters(String reference) {
    final ref = parseNASMediaReference(reference);
    return {
      'namespace': ref['nas'],
      'id': int.parse(ref['id']!),
      'library': int.parse(ref['library']!),
      'path': ref['path'],
    };
  }

  Future<CinemaNASPlaybackOptions> options(String reference) async =>
      CinemaNASPlaybackOptions.fromMap(
        await client.call('playbackOptions', parameters(reference)),
      );
  Future<CinemaNASPlaybackSession> start(
    String reference, {
    String? resolution,
    int? audio,
    int? subtitle,
  }) async {
    final args = parameters(reference);
    final data = await client.call('startPlayback', {
      ...args,
      'resolution': ?resolution,
      'audio': ?audio,
      'subtitle': ?subtitle,
    });
    final session = CinemaNASPlaybackSession(
      client,
      args['namespace'] as String,
      data,
    );
    final uri = Uri.tryParse(session.url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        session.taskId.isEmpty) {
      await session.close();
      throw const FormatException('NAS 未返回有效播放流，请重试。');
    }
    return session;
  }
}

class CinemaNASPlaybackSelection {
  const CinemaNASPlaybackSelection(this.resolution, this.audio, this.subtitle);
  final String resolution;
  final int? audio, subtitle;
}

/// Direct controls shared by work details and the fullscreen video overlay.
class CinemaNASInlinePlaybackControls extends StatefulWidget {
  const CinemaNASInlinePlaybackControls({
    super.key,
    required this.options,
    required this.resolution,
    this.audio,
    this.subtitle,
    this.bitrate = 0,
    this.enabled = true,
    required this.onApply,
  });
  final CinemaNASPlaybackOptions options;
  final String resolution;
  final int? audio, subtitle;
  final int bitrate;
  final bool enabled;
  final ValueChanged<CinemaNASPlaybackSelection> onApply;

  @override
  State<CinemaNASInlinePlaybackControls> createState() =>
      _CinemaNASInlinePlaybackControlsState();
}

class _CinemaNASInlinePlaybackControlsState
    extends State<CinemaNASInlinePlaybackControls> {
  late String _resolution = _profile(widget.resolution);
  late int? _audio = widget.audio;
  late int? _subtitle = widget.subtitle;

  String _profile(String value) => widget.options.supportsProfile(value)
      ? value
      : widget.options.defaultProfile;

  @override
  void didUpdateWidget(CinemaNASInlinePlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.resolution != widget.resolution ||
        oldWidget.audio != widget.audio ||
        oldWidget.subtitle != widget.subtitle) {
      _resolution = _profile(widget.resolution);
      _audio = widget.audio;
      _subtitle = widget.subtitle;
    } else if (!widget.options.supportsProfile(_resolution)) {
      _resolution = widget.options.defaultProfile;
    }
  }

  Widget _track(
    String label,
    List<Map<String, dynamic>> rows,
    int? value,
    ValueChanged<int?> onChanged,
  ) {
    final tracks = <int, String>{};
    for (final row in rows) {
      final id = int.tryParse('${row['id']}');
      if (id != null) tracks[id] = row['label']?.toString() ?? '轨道 $id';
    }
    return DropdownButtonFormField<int>(
      // FormField initialValue otherwise retains a previous playback's value.
      key: ValueKey('$label:$value:${tracks.keys.join(',')}'),
      isExpanded: true,
      initialValue: tracks.containsKey(value) ? value : null,
      decoration: InputDecoration(labelText: label, isDense: true),
      hint: const Text('NAS 默认'),
      items: [
        for (final entry in tracks.entries)
          DropdownMenuItem(
            value: entry.key,
            child: Text(
              entry.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged:
          widget.enabled &&
              _resolution != nasOriginalFileProfile &&
              tracks.isNotEmpty
          ? onChanged
          : null,
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : 720.0;
      final fieldWidth = width >= 660
          ? (width - 24) / 3
          : width.clamp(0.0, 300.0);
      final profiles = <String, String>{
        for (final row in widget.options.profiles)
          if (row['id'] is String && (row['id'] as String).isNotEmpty)
            row['id'] as String:
                row['label']?.toString() ?? row['id'] as String,
        nasOriginalFileProfile: '原文件直连',
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 14,
            children: [
              SizedBox(
                width: fieldWidth,
                child: DropdownButtonFormField<String>(
                  key: ValueKey(
                    'nas-inline-profile:$_resolution:${profiles.keys.join(',')}',
                  ),
                  isExpanded: true,
                  initialValue: profiles.containsKey(_resolution)
                      ? _resolution
                      : null,
                  decoration: const InputDecoration(
                    labelText: '清晰度',
                    isDense: true,
                  ),
                  items: [
                    for (final entry in profiles.entries)
                      DropdownMenuItem(
                        value: entry.key,
                        child: Text(
                          entry.value,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: !widget.enabled
                      ? null
                      : (value) {
                          if (value != null) {
                            setState(() => _resolution = value);
                          }
                        },
                ),
              ),
              SizedBox(
                width: fieldWidth,
                child: _track(
                  'NAS 音轨',
                  widget.options.audios,
                  _audio,
                  (value) => setState(() => _audio = value),
                ),
              ),
              SizedBox(
                width: fieldWidth,
                child: _track(
                  'NAS 字幕',
                  widget.options.subtitles,
                  _subtitle,
                  (value) => setState(() => _subtitle = value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (widget.bitrate > 0)
            Text(
              '当前输出约 ${(widget.bitrate / 1000000).toStringAsFixed(2)} Mbps',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (_resolution == nasOriginalFileProfile)
            Text(
              '原文件使用播放器音轨与字幕。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: !widget.enabled
                ? null
                : () => widget.onApply(
                    CinemaNASPlaybackSelection(
                      _resolution,
                      _resolution == nasOriginalFileProfile ? null : _audio,
                      _resolution == nasOriginalFileProfile ? null : _subtitle,
                    ),
                  ),
            child: const Text('应用并保留播放进度'),
          ),
        ],
      );
    },
  );
}

Future<CinemaNASPlaybackSelection?> showCinemaNASPlaybackSheet(
  BuildContext context, {
  required CinemaNASPlaybackOptions options,
  required String resolution,
  int? audio,
  int? subtitle,
  int bitrate = 0,
  VoidCallback? onPlayerTracks,
  VoidCallback? onPlayerQuality,
}) => showModalBottomSheet<CinemaNASPlaybackSelection>(
  context: context,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (ctx) => _NASPlaybackPanel(
    options: options,
    resolution: resolution,
    audio: audio,
    subtitle: subtitle,
    bitrate: bitrate,
    onPlayerTracks: onPlayerTracks,
    onPlayerQuality: onPlayerQuality,
  ),
);

class _NASPlaybackPanel extends StatefulWidget {
  const _NASPlaybackPanel({
    required this.options,
    required this.resolution,
    required this.audio,
    required this.subtitle,
    required this.bitrate,
    this.onPlayerTracks,
    this.onPlayerQuality,
  });
  final CinemaNASPlaybackOptions options;
  final String resolution;
  final int? audio, subtitle;
  final int bitrate;
  final VoidCallback? onPlayerTracks, onPlayerQuality;
  @override
  State<_NASPlaybackPanel> createState() => _NASPlaybackPanelState();
}

class _NASPlaybackPanelState extends State<_NASPlaybackPanel> {
  late String _resolution = widget.resolution;
  late int? _audio = widget.audio;
  late int? _subtitle = widget.subtitle;
  Widget _track(
    String title,
    List<Map<String, dynamic>> rows,
    int? value,
    ValueChanged<int?> changed,
  ) {
    final ids = rows.map((v) => _number(v['id'])).toSet();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: DropdownButtonFormField<int>(
        isExpanded: true,
        initialValue: ids.contains(value) ? value : null,
        decoration: InputDecoration(labelText: title),
        hint: const Text('NAS 默认'),
        items: [
          for (final row in rows)
            DropdownMenuItem(
              value: _number(row['id']),
              child: Text(
                row['label']?.toString() ?? '轨道 ${row['id']}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: rows.isEmpty ? null : changed,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        MediaQuery.viewInsetsOf(context).bottom + 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .82,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'NAS 清晰度、音轨与字幕',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                widget.options.relay
                    ? '当前通过远程 UGlink 访问。最低档仍需足够带宽；反复缓冲时可切换局域网连接或下载后观看。'
                    : '当前使用所选 NAS 地址播放。',
              ),
              if (widget.bitrate > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '当前 NAS 输出约 ${(widget.bitrate / 1000000).toStringAsFixed(2)} Mbps',
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: widget.options.supportsProfile(_resolution)
                    ? _resolution
                    : widget.options.defaultProfile,
                decoration: const InputDecoration(labelText: '清晰度'),
                items: [
                  for (final p in widget.options.profiles)
                    DropdownMenuItem(
                      value: p['id'].toString(),
                      child: Text('${p['label']} · NAS 流式输出'),
                    ),
                  const DropdownMenuItem(
                    value: nasOriginalFileProfile,
                    child: Text('原文件直连 · 需要原始码率带宽'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _resolution = v);
                },
              ),
              if (_resolution != nasOriginalFileProfile) ...[
                _track(
                  'NAS 音轨',
                  widget.options.audios,
                  _audio,
                  (v) => setState(() => _audio = v),
                ),
                _track(
                  'NAS 字幕',
                  widget.options.subtitles,
                  _subtitle,
                  (v) => setState(() => _subtitle = v),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 10),
                  child: Text('所选 NAS 字幕由 NAS 输出到画面；本地字幕和偏移请使用下方播放器设置。'),
                ),
              ],
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  CinemaNASPlaybackSelection(_resolution, _audio, _subtitle),
                ),
                child: const Text('应用并保留播放进度'),
              ),
              const Divider(height: 28),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.subtitles_outlined),
                title: const Text('播放器音轨与外部字幕'),
                subtitle: const Text('保留内嵌轨道、本地字幕、字幕偏移和语言设置'),
                onTap: widget.onPlayerTracks == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.onPlayerTracks!();
                      },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('画质信息与处理'),
                subtitle: const Text('保留 Naku 原有画质、解码与增强功能'),
                onTap: widget.onPlayerQuality == null
                    ? null
                    : () {
                        Navigator.pop(context);
                        widget.onPlayerQuality!();
                      },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
