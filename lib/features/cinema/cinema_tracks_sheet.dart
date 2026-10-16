import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_appearance.dart';

Future<void> applyCinemaTrackPreferences(
  Player player,
  CinemaStore store,
) async {
  final native = player.platform;
  if (native is! NativePlayer) return;
  final raw = store.extras['trackPreferences'];
  if (raw is! Map) return;
  for (final pair in {
    'alang': raw['audioLanguage'],
    'slang': raw['subtitleLanguage'],
  }.entries) {
    final value = pair.value;
    if (value is String &&
        const ['', 'zh', 'en', 'ja', 'ko', 'fr', 'de', 'es'].contains(value)) {
      await native.setProperty(pair.key, value);
    }
  }
}

Future<void> showCinemaTracksSheet(
  BuildContext context,
  Player player,
  CinemaStore store,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  constraints: const BoxConstraints(maxWidth: 720),
  builder: (_) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .82,
    child: CinemaTracksPanel(player: player, store: store),
  ),
);

class CinemaTracksPanel extends StatefulWidget {
  const CinemaTracksPanel({
    super.key,
    required this.player,
    required this.store,
  });
  final Player player;
  final CinemaStore store;
  @override
  State<CinemaTracksPanel> createState() => _CinemaTracksPanelState();
}

class _CinemaTracksPanelState extends State<CinemaTracksPanel> {
  bool _busy = false;
  String? _error;
  double _delay = 0;
  String _secondary = 'no';
  late CinemaSubtitleAppearance _appearance;
  @override
  void initState() {
    super.initState();
    _appearance = CinemaSubtitleAppearance.from(
      widget.store.extras['subtitleAppearance'],
    );
    unawaited(_readNative());
  }

  Future<void> _readNative() async {
    final native = widget.player.platform;
    if (native is! NativePlayer) return;
    try {
      final delay = double.tryParse(await native.getProperty('sub-delay'));
      final secondary = await native.getProperty('secondary-sid');
      if (mounted) {
        setState(() {
          if (delay != null && delay.isFinite) _delay = delay.clamp(-10, 10);
          _secondary = secondary;
        });
      }
    } catch (_) {
      /* Playback may have ended while opening the panel. */
    }
  }

  Future<void> _act(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '当前线路暂不支持此轨道或字幕文件');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import({bool audio = false}) async {
    final files = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: audio
          ? const ['m4a', 'aac', 'mp3', 'flac', 'wav', 'opus']
          : const ['srt', 'ass', 'ssa', 'vtt'],
      dialogTitle: audio ? '加载外部音轨' : '加载本地字幕',
    );
    if (files == null || files.files.single.path == null || !mounted) return;
    await _act(
      () => audio
          ? widget.player.setAudioTrack(
              AudioTrack.uri(
                files.files.single.path!,
                title: files.files.single.name,
              ),
            )
          : widget.player.setSubtitleTrack(
              SubtitleTrack.uri(
                files.files.single.path!,
                title: files.files.single.name,
              ),
            ),
    );
  }

  Future<void> _url() async {
    final field = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('加载字幕链接'),
        content: TextField(
          controller: field,
          decoration: const InputDecoration(
            hintText: 'https://…/字幕.srt 或 .ass',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text.trim()),
            child: const Text('加载'),
          ),
        ],
      ),
    );
    field.dispose();
    if (url == null || !mounted) return;
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.userInfo.isNotEmpty) {
      setState(() => _error = '请输入 http 或 https 字幕链接');
      return;
    }
    await _act(
      () =>
          widget.player.setSubtitleTrack(SubtitleTrack.uri(url, title: '外部字幕')),
    );
  }

  Future<void> _language(String key, String value) async {
    final raw = widget.store.extras['trackPreferences'];
    final prefs = {
      if (raw is Map) ...Map<String, dynamic>.from(raw),
      key: value,
    };
    await widget.store.setExtra('trackPreferences', prefs);
    await applyCinemaTrackPreferences(widget.player, widget.store);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Tracks>(
    stream: widget.player.stream.tracks,
    initialData: widget.player.state.tracks,
    builder: (context, tracks) => StreamBuilder<Track>(
      stream: widget.player.stream.track,
      initialData: widget.player.state.track,
      builder: (context, selected) {
        final available = tracks.data ?? const Tracks(),
            current = selected.data ?? const Track();
        final raw = widget.store.extras['trackPreferences'];
        final prefs = raw is Map ? raw : const {};
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('字幕与音轨', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('可以切换片源自带轨道，或加载本地字幕和音轨。更换字幕不会暂停播放。'),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(_error!),
              ),
            const SizedBox(height: 12),
            const Text('音轨'),
            for (final track in available.audio)
              ListTile(
                dense: true,
                title: Text(
                  track.id == 'auto'
                      ? '自动选择'
                      : track.id == 'no'
                      ? '关闭音轨'
                      : '${track.title ?? '音轨 ${track.id}'} · ${track.language ?? ''} · ${track.codec ?? ''}',
                ),
                trailing: current.audio.id == track.id
                    ? const Icon(Icons.check)
                    : null,
                enabled: !_busy,
                onTap: () => _act(() => widget.player.setAudioTrack(track)),
              ),
            const Divider(),
            const Text('字幕'),
            for (final track in available.subtitle)
              ListTile(
                dense: true,
                title: Text(
                  track.id == 'auto'
                      ? '自动选择'
                      : track.id == 'no'
                      ? '关闭字幕'
                      : '${track.title ?? '字幕 ${track.id}'} · ${track.language ?? ''}',
                ),
                trailing: current.subtitle.id == track.id
                    ? const Icon(Icons.check)
                    : null,
                enabled: !_busy,
                onTap: () => _act(() => widget.player.setSubtitleTrack(track)),
              ),
            if (available.subtitle
                .where((t) => !['auto', 'no'].contains(t.id))
                .isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('这条线路没有内置字幕，可加载字幕文件。'),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.subtitles),
                  label: const Text('本地字幕'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _url,
                  icon: const Icon(Icons.link),
                  label: const Text('字幕链接'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _import(audio: true),
                  icon: const Icon(Icons.audiotrack),
                  label: const Text('外部音轨'),
                ),
              ],
            ),
            const SizedBox(height: 20),
            const Text('字幕显示'),
            Text('字幕大小 ${_appearance.fontSize.round()}'),
            Slider(
              key: const ValueKey('subtitle-font-size'),
              value: _appearance.fontSize,
              min: 18,
              max: 64,
              divisions: 46,
              onChanged: (value) => setState(
                () => _appearance = CinemaSubtitleAppearance(
                  fontSize: value,
                  bottom: _appearance.bottom,
                ),
              ),
              onChangeEnd: (_) => widget.store.setExtra(
                'subtitleAppearance',
                _appearance.toJson(),
              ),
            ),
            Text('字幕高度 ${_appearance.bottom.round()}'),
            Slider(
              key: const ValueKey('subtitle-bottom-position'),
              value: _appearance.bottom,
              min: 0,
              max: 160,
              divisions: 80,
              onChanged: (value) => setState(
                () => _appearance = CinemaSubtitleAppearance(
                  fontSize: _appearance.fontSize,
                  bottom: value,
                ),
              ),
              onChangeEnd: (_) => widget.store.setExtra(
                'subtitleAppearance',
                _appearance.toJson(),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  setState(
                    () => _appearance = const CinemaSubtitleAppearance(),
                  );
                  widget.store.setExtra(
                    'subtitleAppearance',
                    _appearance.toJson(),
                  );
                },
                child: const Text('重置字幕显示'),
              ),
            ),
            if (widget.player.platform is NativePlayer) ...[
              const SizedBox(height: 16),
              Text(
                '字幕延迟 ${_delay >= 0 ? '+' : ''}${_delay.toStringAsFixed(1)} 秒',
              ),
              Slider(
                value: _delay,
                min: -10,
                max: 10,
                divisions: 200,
                onChanged: (value) => setState(() => _delay = value),
                onChangeEnd: (value) {
                  _act(
                    () => (widget.player.platform as NativePlayer).setProperty(
                      'sub-delay',
                      '$value',
                    ),
                  );
                },
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(available.subtitle.map((t) => t.id).join(',')),
                initialValue: available.subtitle.any((t) => t.id == _secondary)
                    ? _secondary
                    : 'no',
                decoration: const InputDecoration(labelText: '第二字幕（双语）'),
                items: [
                  const DropdownMenuItem(value: 'no', child: Text('关闭')),
                  for (final track in available.subtitle.where(
                    (t) => !['auto', 'no'].contains(t.id) && !t.uri,
                  ))
                    DropdownMenuItem(
                      value: track.id,
                      child: Text(
                        '${track.title ?? '字幕 ${track.id}'} · ${track.language ?? ''}',
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value == null) return;
                        setState(() => _secondary = value);
                        _act(
                          () => (widget.player.platform as NativePlayer)
                              .setProperty('secondary-sid', value),
                        );
                      },
              ),
            ],
            const SizedBox(height: 22),
            const Text('默认语言（新打开的影片生效）'),
            for (final key in const {
              'audioLanguage': '音轨语言',
              'subtitleLanguage': '字幕语言',
            }.entries)
              DropdownButtonFormField<String>(
                initialValue:
                    const [
                      '',
                      'zh',
                      'en',
                      'ja',
                      'ko',
                      'fr',
                      'de',
                      'es',
                    ].contains(prefs[key.key])
                    ? prefs[key.key] as String? ?? ''
                    : '',
                decoration: InputDecoration(labelText: key.value),
                items: [
                  for (final language in const {
                    '': '自动',
                    'zh': '中文',
                    'en': 'English',
                    'ja': '日语',
                    'ko': '韩语',
                    'fr': '法语',
                    'de': '德语',
                    'es': '西班牙语',
                  }.entries)
                    DropdownMenuItem(
                      value: language.key,
                      child: Text(language.value),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) _act(() => _language(key.key, value));
                },
              ),
          ],
        );
      },
    ),
  );
}
