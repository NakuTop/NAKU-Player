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
class CinemaNASInlinePlaybackControls extends StatelessWidget {
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

  void _select({String? profile, int? audioId, int? subtitleId}) {
    final selected = profile ?? resolution;
    onApply(
      CinemaNASPlaybackSelection(
        selected,
        selected == nasOriginalFileProfile ? null : audioId ?? audio,
        selected == nasOriginalFileProfile ? null : subtitleId ?? subtitle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final original = resolution == nasOriginalFileProfile;
    final profiles = <String, String>{
      for (final row in options.profiles)
        if (row['id'] is String && (row['id'] as String).isNotEmpty)
          row['id'] as String: row['label']?.toString() ?? row['id'] as String,
      nasOriginalFileProfile: '原文件直连',
    };
    Map<int, String> tracks(List<Map<String, dynamic>> rows) => {
      for (final row in rows)
        if (int.tryParse('${row['id']}') case final int id)
          id: row['label']?.toString() ?? '轨道 $id',
    };
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        CinemaPlaybackMenu<String>(
          label: '清晰度',
          icon: Icons.high_quality_outlined,
          value: resolution,
          entries: profiles,
          enabled: enabled,
          description: bitrate > 0
              ? '${options.label(resolution)} · ${(bitrate / 1000000).toStringAsFixed(2)} Mbps'
              : options.label(resolution),
          onSelected: (v) => _select(profile: v),
        ),
        CinemaPlaybackMenu<int>(
          label: 'NAS 音轨',
          icon: Icons.audiotrack_outlined,
          value: audio,
          entries: tracks(options.audios),
          enabled: enabled && !original,
          description: original ? '原文件请使用播放器音轨' : null,
          onSelected: (v) => _select(audioId: v),
        ),
        CinemaPlaybackMenu<int>(
          label: 'NAS 字幕',
          icon: Icons.subtitles_outlined,
          value: subtitle,
          entries: tracks(options.subtitles),
          enabled: enabled && !original,
          description: original ? '原文件请使用播放器字幕' : null,
          onSelected: (v) => _select(subtitleId: v),
        ),
      ],
    );
  }
}

/// Each playback setting has its own anchored menu, with immediate selection.
/// Compact, equal-height triggers keep tracks and quality visible on narrow
/// windows without placing a large configuration form over the video.
class CinemaPlaybackMenu<T> extends StatelessWidget {
  const CinemaPlaybackMenu({
    super.key,
    required this.label,
    required this.icon,
    required this.entries,
    required this.value,
    required this.onSelected,
    this.enabled = true,
    this.description,
  });
  final String label;
  final IconData icon;
  final Map<T, String> entries;
  final T? value;
  final ValueChanged<T> onSelected;
  final bool enabled;
  final String? description;

  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: description ?? label,
    enabled: enabled && entries.isNotEmpty,
    initialValue: value,
    color: const Color(0xF2222222),
    surfaceTintColor: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
    onSelected: (selected) {
      if (selected != value) onSelected(selected);
    },
    itemBuilder: (_) => [
      for (final entry in entries.entries)
        PopupMenuItem<T>(
          value: entry.key,
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: entry.key == value
                    ? const Icon(
                        Icons.check_rounded,
                        size: 18,
                        color: Color(0xFF3388FF),
                      )
                    : null,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.value,
                  style: TextStyle(
                    color: entry.key == value
                        ? const Color(0xFF3388FF)
                        : Colors.white,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
    ],
    child: Opacity(
      opacity: enabled && entries.isNotEmpty ? 1 : .38,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 2),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 14),
          ],
        ),
      ),
    ),
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
