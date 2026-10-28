import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'cinema_season_subtitle_controller.dart';
import 'cinema_subtitle_auto_sync.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_store.dart';
import 'cinema_online_subtitles.dart';
import 'cinema_subtitle_appearance.dart';
import 'cinema_live_subtitles.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_subtitle_sync_panel.dart';
import 'package:kazumi/services/platform/naku_device.dart';
import 'cinema_tv_auxiliary.dart';

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
  CinemaStore store, {
  String title = '',
  String imdbId = '',
  Widget? nasControls,
  CinemaLiveSubtitles? liveSubtitles,
  String category = '',
  String episodeName = '',
  int? episodeNumber,
  CinemaSeasonSubtitleController? automation,
  CinemaSubtitleAutoSync? autoSync,
  Future<void> Function(CinemaOnlineSubtitleSelection selection)?
  onSubtitleApplied,
}) => NakuDevice.isTV
    ? showCinemaTVPanel<void>(
        context,
        title: '字幕',
        builder: (_) => CinemaTracksPanel(
          player: player,
          store: store,
          title: title,
          imdbId: imdbId,
          liveSubtitles: liveSubtitles,
          category: category,
          episodeName: episodeName,
          episodeNumber: episodeNumber,
          automation: automation,
          autoSync: autoSync,
          onSubtitleApplied: onSubtitleApplied,
        ),
      )
    : showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 680),
        builder: (_) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .85,
          child: CinemaTracksPanel(
            player: player,
            store: store,
            title: title,
            imdbId: imdbId,
            nasControls: nasControls,
            liveSubtitles: liveSubtitles,
            category: category,
            episodeName: episodeName,
            episodeNumber: episodeNumber,
            automation: automation,
            autoSync: autoSync,
            onSubtitleApplied: onSubtitleApplied,
          ),
        ),
      );

class CinemaTracksPanel extends StatefulWidget {
  const CinemaTracksPanel({
    super.key,
    required this.player,
    required this.store,
    this.title = '',
    this.imdbId = '',
    this.nasControls,
    this.liveSubtitles,
    this.category = '',
    this.episodeName = '',
    this.episodeNumber,
    this.automation,
    this.autoSync,
    this.onSubtitleApplied,
  });
  final Player player;
  final CinemaStore store;
  final String title, imdbId, category, episodeName;
  final Widget? nasControls;
  final CinemaLiveSubtitles? liveSubtitles;
  final int? episodeNumber;
  final CinemaSeasonSubtitleController? automation;
  final CinemaSubtitleAutoSync? autoSync;
  final Future<void> Function(CinemaOnlineSubtitleSelection selection)?
  onSubtitleApplied;
  @override
  State<CinemaTracksPanel> createState() => _CinemaTracksPanelState();
}

class _CinemaTracksPanelState extends State<CinemaTracksPanel> {
  int _tab = 0;
  bool _busy = false, _showLive = false;
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
          if (delay != null && delay.isFinite) {
            _delay = delay.clamp(-21600, 21600);
          }
          _secondary = secondary;
        });
      }
    } catch (_) {
      /* Backend may be closing. */
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
      if (mounted) setState(() => _error = '操作未完成，请检查文件、链接或当前播放线路');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _selectNativeSubtitle(SubtitleTrack track) async {
    widget.automation?.beginManualSelection();
    await widget.player.setSubtitleTrack(track);
    final session = cinemaExternalSubtitleState(widget.player);
    if (!session.ownsTrack(track)) {
      if (widget.automation != null) {
        await widget.automation!.rememberNativeSelection(track);
      } else {
        await session.disableSavedSelection?.call();
      }
    }
  }

  Future<void> _import() async {
    final files = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'ass', 'ssa', 'vtt'],
      dialogTitle: '加载本地字幕',
    );
    if (files == null || files.files.single.path == null || !mounted) return;
    await _act(() async {
      final file = File(files.files.single.path!);
      if (await file.length() > 4 * 1024 * 1024) {
        throw const FormatException('字幕文件过大');
      }
      widget.automation?.beginManualSelection();
      final text = CinemaOnlineSubtitles.decodeSubtitle(
        await file.readAsBytes(),
      );
      await applyCinemaExternalSubtitle(
        widget.player,
        text,
        title: files.files.single.name,
        language: 'und',
      );
      await widget.automation?.rememberCurrent();
    });
  }

  Future<void> _url() async {
    final field = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      useRootNavigator: !NakuDevice.isTV,
      animationStyle: NakuDevice.isTV ? AnimationStyle.noAnimation : null,
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
    // Dialog reverse animation can still read its controller.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    field.dispose();
    if (url == null || !mounted) return;
    await _act(() async {
      final client = CinemaOnlineSubtitles();
      widget.automation?.beginManualSelection();
      try {
        final text = await client.download(url);
        if (!mounted) return;
        final name = Uri.tryParse(url)?.pathSegments.lastOrNull ?? '';
        await applyCinemaExternalSubtitle(
          widget.player,
          text,
          title:
              RegExp(
                r'\.(srt|ass|ssa|vtt)$',
                caseSensitive: false,
              ).hasMatch(name)
              ? name
              : '链接字幕',
          language: 'und',
        );
        await widget.automation?.rememberCurrent();
      } finally {
        client.close();
      }
    });
  }

  Future<void> _language(String key, String value) async {
    final raw = widget.store.extras['trackPreferences'];
    await widget.store.setExtra('trackPreferences', {
      if (raw is Map) ...Map<String, dynamic>.from(raw),
      key: value,
    });
    await applyCinemaTrackPreferences(widget.player, widget.store);
  }

  Widget _languages(String key, String label) {
    final raw = widget.store.extras['trackPreferences'];
    final prefs = raw is Map ? raw : const {};
    const languages = {
      '': '自动',
      'zh': '中文',
      'en': 'English',
      'ja': '日语',
      'ko': '韩语',
      'fr': '法语',
      'de': '德语',
      'es': '西班牙语',
    };
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: DropdownButtonFormField<String>(
        initialValue: languages.containsKey(prefs[key])
            ? prefs[key] as String? ?? ''
            : '',
        decoration: InputDecoration(labelText: label),
        isExpanded: true,
        items: [
          for (final language in languages.entries)
            DropdownMenuItem(value: language.key, child: Text(language.value)),
        ],
        onChanged: _busy
            ? null
            : (value) {
                if (value != null) _act(() => _language(key, value));
              },
      ),
    );
  }

  Widget _automatic() {
    final controller = widget.automation;
    if (controller == null) return const SizedBox.shrink();
    return ValueListenableBuilder<String>(
      valueListenable: controller.status,
      builder: (context, status, _) => Column(
        children: [
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('记住字幕与整季续载'),
            subtitle: Text(status),
            value: controller.automaticEnabled,
            onChanged: _busy
                ? null
                : (value) => _act(() => controller.setAutomaticEnabled(value)),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text(
              '首次请手动搜索或导入字幕。记住本视频的文件和校准；剧集选用字幕后，自动补齐同季其他集。',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subtitleTab(Tracks available, Track current, bool external) {
    final session = cinemaExternalSubtitleState(widget.player);
    final realTracks = available.subtitle.where(
      (track) =>
          !['auto', 'no'].contains(track.id) && !session.ownsTrack(track),
    );
    final selected = available.subtitle
        .where((t) => t.id == current.subtitle.id)
        .firstOrNull;
    final active = external || !['auto', 'no'].contains(current.subtitle.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '当前字幕文件',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () => _act(() => _selectNativeSubtitle(SubtitleTrack.no())),
              icon: const Icon(Icons.subtitles_off_outlined, size: 16),
              label: const Text('关闭字幕'),
            ),
          ],
        ),
        Container(
          key: const ValueKey('subtitle-current-file'),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.surfaceContainerHighest.withValues(alpha: .5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                active
                    ? Icons.description_outlined
                    : Icons.subtitles_off_outlined,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      external
                          ? session.title
                          : active
                          ? selected?.title ?? '片源字幕 ${current.subtitle.id}'
                          : '当前没有加载字幕',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                    const SizedBox(height: 3),
                    ValueListenableBuilder<String>(
                      valueListenable: session.sourceLabel,
                      builder: (context, source, _) => Text(
                        external
                            ? '$source · 已记忆本视频设置'
                            : active
                            ? '片源内置字幕'
                            : '可在下方搜索或选择字幕',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (external)
          CinemaSubtitleQuickSyncPanel(
            key: ValueKey('quick-${session.sourceIdentity}'),
            player: widget.player,
            autoSync: widget.autoSync,
          )
        else if (active && widget.player.platform is NativePlayer) ...[
          Row(
            children: [
              for (final shift in const [-.5, .5])
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(right: shift < 0 ? 8 : 0),
                    child: OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _act(() async {
                              final value = (_delay + shift).clamp(
                                -21600.0,
                                21600.0,
                              );
                              await (widget.player.platform as NativePlayer)
                                  .setProperty('sub-delay', '$value');
                              session.setDelay(value);
                              if (mounted) setState(() => _delay = value);
                            }),
                      icon: Icon(
                        shift < 0
                            ? Icons.keyboard_double_arrow_left
                            : Icons.keyboard_double_arrow_right,
                        size: 18,
                      ),
                      label: Text(shift < 0 ? '提前 0.5 秒' : '延后 0.5 秒'),
                    ),
                  ),
                ),
            ],
          ),
          Text(
            '字幕偏移 ${_delay.toStringAsFixed(2)} 秒',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            '自动对齐与对白预览适用于外挂字幕。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (external)
          ExpansionTile(
            key: const PageStorageKey('subtitle-manual-sync'),
            tilePadding: EdgeInsets.zero,
            title: const Text('精细校准与慢速回听'),
            subtitle: const Text('双点漂移、精确偏移与重置'),
            children: [
              CinemaSubtitleSyncPanel(
                key: ValueKey(session.sourceIdentity),
                player: widget.player,
              ),
            ],
          ),
        ExpansionTile(
          key: const PageStorageKey('subtitle-file-options'),
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: !active,
          title: const Text('选择或更换字幕'),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          widget.automation?.beginManualSelection();
                          showCinemaOnlineSubtitles(
                            context,
                            widget.player,
                            title: widget.title,
                            imdbId: widget.imdbId,
                            category: widget.category,
                            episodeName: widget.episodeName,
                            episodeNumber: widget.episodeNumber,
                            onApplied: widget.onSubtitleApplied,
                          );
                        },
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('搜索字幕'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('本地文件'),
                ),
                IconButton(
                  onPressed: _busy ? null : _url,
                  tooltip: '加载字幕链接',
                  icon: const Icon(Icons.link),
                ),
                if (widget.liveSubtitles != null && Platform.isWindows)
                  OutlinedButton(
                    onPressed: () => setState(() => _showLive = !_showLive),
                    child: const Text('实时生成字幕'),
                  ),
              ],
            ),
            if (_showLive && widget.liveSubtitles != null)
              CinemaLiveSubtitleControls(controller: widget.liveSubtitles!),
            for (final track in realTracks)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  current.subtitle.id == track.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(
                  '${track.title ?? '字幕 ${track.id}'} · ${track.language ?? ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: _busy
                    ? null
                    : () => _act(() => _selectNativeSubtitle(track)),
              ),
            if (realTracks.isEmpty && !external)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('片源未提供独立字幕轨道'),
              ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('自动字幕与整季下载'),
          children: [
            _automatic(),
            if (widget.automation case final controller?)
              ListenableBuilder(
                listenable: controller.prefetch,
                builder: (context, _) {
                  final prefetch = controller.prefetch;
                  if (!prefetch.belongsTo(controller.seriesIdentity) ||
                      prefetch.total == 0) {
                    return const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('匹配并加载一集字幕后，在后台预下载本季其他剧集。'),
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (prefetch.busy)
                        LinearProgressIndicator(
                          value: prefetch.completed / prefetch.total,
                        ),
                      const SizedBox(height: 8),
                      Text(prefetch.status),
                      if (!prefetch.busy && prefetch.failed > 0)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: () =>
                                controller.prefetchSeason(retry: true),
                            child: const Text('重试未匹配剧集'),
                          ),
                        ),
                      const SizedBox(height: 12),
                    ],
                  );
                },
              ),
            _languages('subtitleLanguage', '内置字幕默认语言'),
            const SizedBox(height: 12),
          ],
        ),
      ],
    );
  }

  Widget _audioTab(Tracks available, Track current) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (widget.nasControls != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: widget.nasControls!,
        ),
      for (final track in available.audio)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            current.audio.id == track.id
                ? Icons.radio_button_checked
                : Icons.radio_button_off,
          ),
          title: Text(
            track.id == 'auto'
                ? '自动选择'
                : track.id == 'no'
                ? '关闭音轨'
                : '${track.title ?? '音轨 ${track.id}'} · ${track.language ?? ''} · ${track.codec ?? ''}',
          ),
          onTap: _busy
              ? null
              : () => _act(() => widget.player.setAudioTrack(track)),
        ),
      const SizedBox(height: 16),
      _languages('audioLanguage', '音轨默认语言'),
    ],
  );
  Widget _displayTab(Tracks available) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Container(
        padding: const EdgeInsets.all(20),
        color: Colors.black26,
        child: Text(
          '字幕显示预览\nSubtitle preview',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: _appearance.fontSize, color: Colors.white),
        ),
      ),
      const SizedBox(height: 20),
      Text('字幕大小 ${_appearance.fontSize.round()}'),
      Slider(
        key: const ValueKey('subtitle-font-size'),
        value: _appearance.fontSize,
        min: 18,
        max: 64,
        divisions: 46,
        onChanged: (v) => setState(
          () => _appearance = CinemaSubtitleAppearance(
            fontSize: v,
            bottom: _appearance.bottom,
          ),
        ),
        onChangeEnd: (_) =>
            widget.store.setExtra('subtitleAppearance', _appearance.toJson()),
      ),
      Text('字幕高度 ${_appearance.bottom.round()}'),
      Slider(
        key: const ValueKey('subtitle-bottom-position'),
        value: _appearance.bottom,
        min: 0,
        max: 160,
        divisions: 80,
        onChanged: (v) => setState(
          () => _appearance = CinemaSubtitleAppearance(
            fontSize: _appearance.fontSize,
            bottom: v,
          ),
        ),
        onChangeEnd: (_) =>
            widget.store.setExtra('subtitleAppearance', _appearance.toJson()),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: () {
            setState(() => _appearance = const CinemaSubtitleAppearance());
            widget.store.setExtra('subtitleAppearance', _appearance.toJson());
          },
          child: const Text('重置字幕显示'),
        ),
      ),
      if (widget.player.platform is NativePlayer)
        Padding(
          padding: const EdgeInsets.only(top: 20),
          child: DropdownButtonFormField<String>(
            key: ValueKey(available.subtitle.map((t) => t.id).join(',')),
            initialValue:
                available.subtitle.any((t) => t.id == _secondary && !t.uri)
                ? _secondary
                : 'no',
            isExpanded: true,
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
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _busy
                ? null
                : (v) {
                    if (v == null) return;
                    setState(() => _secondary = v);
                    _act(
                      () => (widget.player.platform as NativePlayer)
                          .setProperty('secondary-sid', v),
                    );
                  },
          ),
        ),
    ],
  );
  Future<void> _tvDelay(double? shift) => _act(() async {
    widget.autoSync?.cancel();
    final session = cinemaExternalSubtitleState(widget.player);
    final external = session.active.value && session.cues.isNotEmpty;
    final value =
        (shift == null ? 0.0 : (external ? session.delay : _delay) + shift)
            .clamp(-21600.0, 21600.0);
    if (external) {
      session.setDelay(value);
    } else if (widget.player.platform case final NativePlayer native) {
      await native.setProperty('sub-delay', '$value');
    } else {
      throw const FormatException('当前播放器暂不支持字幕偏移');
    }
    if (mounted) setState(() => _delay = value);
  });

  Widget _tvTracks(Tracks available, Track current, bool external) {
    final session = cinemaExternalSubtitleState(widget.player);
    final tracks = available.subtitle.where(
      (t) => !['auto', 'no'].contains(t.id) && !session.ownsTrack(t),
    );
    return ValueListenableBuilder(
      valueListenable: session.timing,
      builder: (context, timing, _) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 6, 24, 24),
        children: [
          Text(
            external
                ? '当前：${session.title}'
                : current.subtitle.id == 'no'
                ? '字幕已关闭'
                : current.subtitle.id == 'auto'
                ? '当前：自动选择内嵌字幕'
                : '当前：${current.subtitle.title ?? '内嵌字幕'}',
            style: const TextStyle(fontSize: 18),
          ),
          const SizedBox(height: 12),
          CinemaTVAuxiliaryAction(
            key: const ValueKey('tv-online-subtitle-entry'),
            autofocus: true,
            label: '在线搜索字幕',
            subtitle: '自动带入片名和当前季集；搜索期间保持暂停',
            onPressed: _busy
                ? null
                : () async {
                    widget.automation?.beginManualSelection();
                    await showCinemaOnlineSubtitles(
                      context,
                      widget.player,
                      title: widget.title,
                      imdbId: widget.imdbId,
                      category: widget.category,
                      episodeName: widget.episodeName,
                      episodeNumber: widget.episodeNumber,
                      onApplied: widget.onSubtitleApplied,
                    );
                    if (mounted) setState(() {});
                  },
          ),
          CinemaTVAuxiliaryAction(
            label: '关闭字幕',
            selected: !external && current.subtitle.id == 'no',
            onPressed: _busy
                ? null
                : () => _act(() => _selectNativeSubtitle(SubtitleTrack.no())),
          ),
          CinemaTVAuxiliaryAction(
            label: '自动选择内嵌字幕',
            selected: !external && current.subtitle.id == 'auto',
            onPressed: _busy
                ? null
                : () => _act(() => _selectNativeSubtitle(SubtitleTrack.auto())),
          ),
          for (final track in tracks)
            CinemaTVAuxiliaryAction(
              key: ValueKey('tv-subtitle-${track.id}'),
              label: track.title ?? '内嵌字幕 ${track.id}',
              subtitle: track.language,
              selected: !external && current.subtitle.id == track.id,
              onPressed: _busy
                  ? null
                  : () => _act(() => _selectNativeSubtitle(track)),
            ),
          if (external || widget.player.platform is NativePlayer) ...[
            const SizedBox(height: 16),
            Text(
              '字幕偏移 ${(external ? session.delay : _delay).toStringAsFixed(1)} 秒',
              style: const TextStyle(fontSize: 19),
            ),
            CinemaTVAuxiliaryAction(
              label: '提前 0.5 秒',
              onPressed: _busy ? null : () => _tvDelay(-.5),
            ),
            CinemaTVAuxiliaryAction(
              label: '延后 0.5 秒',
              onPressed: _busy ? null : () => _tvDelay(.5),
            ),
            CinemaTVAuxiliaryAction(
              label: '偏移归零',
              onPressed: _busy ? null : () => _tvDelay(null),
            ),
          ],
          if (widget.automation case final automation?)
            ValueListenableBuilder<String>(
              valueListenable: automation.status,
              builder: (context, status, _) => CinemaTVAuxiliaryAction(
                label: '记住字幕与整季续载：${automation.automaticEnabled ? '开启' : '关闭'}',
                subtitle: status,
                selected: automation.automaticEnabled,
                onPressed: _busy
                    ? null
                    : () => _act(
                        () => automation.setAutomaticEnabled(
                          !automation.automaticEnabled,
                        ),
                      ),
              ),
            ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null)
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: cinemaExternalSubtitleState(widget.player).active,
    builder: (context, external, _) => StreamBuilder<Tracks>(
      stream: widget.player.stream.tracks,
      initialData: widget.player.state.tracks,
      builder: (context, tracks) => StreamBuilder<Track>(
        stream: widget.player.stream.track,
        initialData: widget.player.state.track,
        builder: (context, selected) {
          final available = tracks.data ?? const Tracks(),
              current = selected.data ?? const Track();
          if (NakuDevice.isTV) return _tvTracks(available, current, external);
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 12, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '字幕与音轨',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '完成',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: SizedBox(
                  width: double.infinity,
                  child: CupertinoSlidingSegmentedControl<int>(
                    groupValue: _tab,
                    children: const {
                      0: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('字幕'),
                      ),
                      1: Text('音轨'),
                      2: Text('显示'),
                    },
                    onValueChanged: (v) {
                      if (v != null) setState(() => _tab = v);
                    },
                  ),
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 8,
                  ),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              Expanded(
                child: ListView(
                  key: ValueKey('tracks-tab-$_tab'),
                  padding: const EdgeInsets.all(24),
                  children: [
                    switch (_tab) {
                      1 => _audioTab(available, current),
                      2 => _displayTab(available),
                      _ => _subtitleTab(available, current, external),
                    },
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
