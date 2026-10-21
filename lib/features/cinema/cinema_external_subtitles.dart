import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'cinema_subtitle_appearance.dart';
import 'cinema_subtitle_timing.dart';

class CinemaSubtitleCue {
  const CinemaSubtitleCue(this.start, this.end, this.text);
  final int start, end;
  final String text;
}

int? _time(String value) {
  final match = RegExp(
    r'^(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  return ((int.parse(match[1] ?? '0') * 60 + int.parse(match[2]!)) * 60 +
              int.parse(match[3]!)) *
          1000 +
      int.parse(match[4]!.padRight(3, '0'));
}

String _plainAss(String text) {
  var drawing = false;
  final result = StringBuffer();
  for (final part in RegExp(r'\{[^}]*\}|[^\{]+').allMatches(text)) {
    final value = part[0]!;
    if (value.startsWith('{')) {
      final mode = RegExp(r'\\p(\d+)').firstMatch(value);
      if (mode != null) drawing = int.parse(mode[1]!) > 0;
    } else if (!drawing) {
      result.write(value);
    }
  }
  return result
      .toString()
      .replaceAll(r'\N', '\n')
      .replaceAll(r'\n', '\n')
      .replaceAll(r'\h', ' ')
      .trim();
}

/// Normalize timed text for the Flutter text renderer; preserve both languages.
List<CinemaSubtitleCue> cinemaSubtitleCues(String source) {
  final text = source
      .replaceFirst('\uFEFF', '')
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n');
  final cues = <CinemaSubtitleCue>[];
  if (RegExp(
    r'^\[Events\]',
    multiLine: true,
    caseSensitive: false,
  ).hasMatch(text)) {
    var events = false;
    var columns = <String>[];
    for (final line in text.split('\n')) {
      if (line.trim().startsWith('[')) {
        events = line.trim().toLowerCase() == '[events]';
        continue;
      }
      if (!events) continue;
      if (line.toLowerCase().startsWith('format:')) {
        columns = line
            .substring(7)
            .split(',')
            .map((v) => v.trim().toLowerCase())
            .toList();
      } else if (line.toLowerCase().startsWith('dialogue:') &&
          columns.isNotEmpty) {
        final values = line.substring(9).split(',');
        if (values.length < columns.length || columns.last != 'text') continue;
        final startIndex = columns.indexOf('start'),
            endIndex = columns.indexOf('end');
        if (startIndex < 0 || endIndex < 0) continue;
        final start = _time(values[startIndex]), end = _time(values[endIndex]);
        final plain = _plainAss(values.skip(columns.length - 1).join(','));
        if (start != null && end != null && end > start && plain.isNotEmpty) {
          cues.add(CinemaSubtitleCue(start, end, plain));
        }
      }
    }
  } else {
    final blocks = text.trim().split(RegExp(r'\n\s*\n'));
    for (final block in blocks) {
      final lines = block.split('\n');
      final index = lines.indexWhere((line) => line.contains('-->'));
      if (index < 0 || index + 1 >= lines.length) continue;
      final pair = lines[index].split('-->');
      if (pair.length != 2) continue;
      final start = _time(pair[0]),
          end = _time(pair[1].trim().split(RegExp(r'\s+')).first);
      final plain = lines
          .skip(index + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&amp;', '&')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .trim();
      if (start != null && end != null && end > start && plain.isNotEmpty) {
        cues.add(CinemaSubtitleCue(start, end, plain));
      }
    }
  }
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

String cinemaSubtitleSrt(String source) {
  final cues = cinemaSubtitleCues(source);
  if (cues.isEmpty) throw const FormatException('字幕中没有可显示的时间轴与对白');
  final merged = <String, CinemaSubtitleCue>{};
  for (final cue in cues) {
    final key = '${cue.start}:${cue.end}';
    final previous = merged[key];
    merged[key] = previous == null
        ? cue
        : CinemaSubtitleCue(
            cue.start,
            cue.end,
            {...previous.text.split('\n'), ...cue.text.split('\n')}.join('\n'),
          );
  }
  String stamp(int value) =>
      '${(value ~/ 3600000).toString().padLeft(2, '0')}:'
      '${(value ~/ 60000 % 60).toString().padLeft(2, '0')}:'
      '${(value ~/ 1000 % 60).toString().padLeft(2, '0')},${(value % 1000).toString().padLeft(3, '0')}';
  var index = 0;
  return merged.values
      .map(
        (cue) =>
            '${++index}\n${stamp(cue.start)} --> ${stamp(cue.end)}\n${cue.text}\n',
      )
      .join('\n');
}

final _sessions = Expando<CinemaExternalSubtitleState>();
CinemaExternalSubtitleState cinemaExternalSubtitleState(Player player) =>
    _sessions[player] ??= CinemaExternalSubtitleState(player);
Future<void> closeCinemaExternalSubtitles(Player player) async =>
    _sessions[player]?.close();

class CinemaExternalSubtitleState {
  CinemaExternalSubtitleState(this.player) {
    if (player.platform is NativePlayer) {
      (player.platform as NativePlayer).release.add(close);
      _subscriptions.add(
        player.stream.position.listen((position) {
          _position = position;
          _update();
        }),
      );
      _subscriptions.add(
        player.stream.track.listen((track) {
          final selected =
              track.subtitle.id == _nativeId || track.subtitle.id == _filePath;
          if (selected && _cues.isNotEmpty) {
            active.value = true;
            _position = player.state.position;
            _update();
          } else if (active.value) {
            active.value = false;
            text.value = '';
          }
        }),
      );
      _subscriptions.add(
        player.stream.subtitle.listen((lines) {
          _secondary = lines.length > 1 ? lines[1] : '';
          _update();
        }),
      );
    }
  }
  final Player player;
  final active = ValueNotifier<bool>(false);
  final text = ValueNotifier<String>('');
  final timing = ValueNotifier<CinemaSubtitleTiming>(
    const CinemaSubtitleTiming(),
  );
  final _subscriptions = <StreamSubscription<dynamic>>[];
  List<CinemaSubtitleCue> _cues = [];
  String _nativeId = '', _filePath = '';
  String _secondary = '';
  Duration _position = Duration.zero;
  double get delay => timing.value.offsetSeconds;
  List<CinemaSubtitleCue> get cues => List.unmodifiable(_cues);
  String get sourceIdentity => _filePath;
  ({Duration subtitle, Duration media})? firstSyncAnchor;
  CinemaSubtitleTiming? Function(String fingerprint)? readSavedTiming;
  Future<void> Function(String fingerprint, CinemaSubtitleTiming value)?
  saveTiming;
  String fingerprint = '';
  bool _closed = false;
  Directory? folder;
  final files = <File>[];
  void select(String normalized, String path, String id, double offset) {
    _cues = cinemaSubtitleCues(normalized);
    _position = player.state.position;
    _filePath = path;
    _nativeId = id;
    firstSyncAnchor = null;
    fingerprint = sha256.convert(utf8.encode(normalized)).toString();
    timing.value =
        readSavedTiming?.call(fingerprint) ??
        CinemaSubtitleTiming(offsetSeconds: offset);
    active.value = true;
    _update();
  }

  void updatePosition(Duration value) {
    _position = value;
    _update();
  }

  void setDelay(double value) {
    setTiming(timing.value.withOffset(value));
  }

  void setTiming(CinemaSubtitleTiming value) {
    if (!value.scale.isFinite || value.scale < .5 || value.scale > 2) {
      throw const FormatException('字幕时间轴倍率无效');
    }
    value.withOffset(value.offsetSeconds);
    timing.value = value;
    _update();
    final save = saveTiming;
    if (active.value && fingerprint.isNotEmpty && save != null) {
      // A disk failure must not interrupt the currently applied calibration.
      unawaited(save(fingerprint, value).catchError((Object _) {}));
    }
  }

  void _update() {
    if (_closed || !active.value) return;
    final at = timing.value.subtitleTime(_position).inMilliseconds;
    final lines = <String>{};
    for (final cue in _cues) {
      if (cue.start > at) break;
      if (cue.end > at) lines.addAll(cue.text.split('\n'));
    }
    if (_secondary.isNotEmpty) lines.add(_secondary);
    final value = lines.join('\n');
    if (text.value != value) text.value = value;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    readSavedTiming = null;
    saveTiming = null;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    for (final file in files) {
      try {
        if (await file.exists()) await file.delete();
      } on FileSystemException {
        /* MPV may still be releasing a handle. */
      }
    }
    final directory = folder;
    try {
      if (directory != null && await directory.exists()) {
        await directory.delete();
      }
    } on FileSystemException {
      /* Never recursively delete a directory with unexpected content. */
    }
    active.dispose();
    text.dispose();
    timing.dispose();
  }
}

Future<void> applyCinemaExternalSubtitle(
  Player player,
  String text, {
  String title = '在线字幕',
  String language = 'zh',
  bool Function()? isCurrent,
}) async {
  void checkCurrent() {
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Subtitle selection was superseded');
    }
  }

  checkCurrent();
  final normalized = text.length > 32768
      ? await compute(cinemaSubtitleSrt, text)
      : cinemaSubtitleSrt(text);
  checkCurrent();
  final native = player.platform;
  if (native is! NativePlayer) {
    await player.setSubtitleTrack(
      SubtitleTrack.data(normalized, title: title, language: language),
    );
    checkCurrent();
    return;
  }
  final session = cinemaExternalSubtitleState(player);
  session.folder ??= await Directory.systemTemp.createTemp(
    'naku-player-subtitle-',
  );
  checkCurrent();
  final file = File(
    '${session.folder!.path}/subtitle-${session.files.length}.srt',
  );
  session.files.add(file);
  await file.writeAsString(normalized, flush: true);
  checkCurrent();
  // Clear the forced HLS format left by older playback setup before probing
  // the independent subtitle input.
  await native.setProperty('demuxer-lavf-format', '');
  checkCurrent();
  await player.setSubtitleTrack(
    SubtitleTrack.uri(file.path, title: title, language: language),
  );
  checkCurrent();
  final selected = await native.getProperty('sid');
  checkCurrent();
  if (selected == 'no' || selected == 'auto' || selected.isEmpty) {
    throw const FormatException('播放器未选中字幕轨道，请重试');
  }
  final external = await native.getProperty(
    'current-tracks/sub/external-filename',
  );
  checkCurrent();
  if (external.replaceAll('\\', '/').toLowerCase() !=
      file.path.replaceAll('\\', '/').toLowerCase()) {
    throw const FormatException('播放器没有接收新的字幕文件，请重试');
  }
  // Track menus use MPV's numeric ID rather than the temporary file URI.
  await player.setSubtitleTrack(SubtitleTrack(selected, title, language));
  checkCurrent();
  final offset = double.tryParse(await native.getProperty('sub-delay')) ?? 0;
  checkCurrent();
  session.select(normalized, file.path, selected, offset);
}

class CinemaExternalSubtitleOverlay extends StatelessWidget {
  const CinemaExternalSubtitleOverlay({
    super.key,
    required this.player,
    required this.appearance,
  });
  final Player player;
  final CinemaSubtitleAppearance appearance;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: cinemaExternalSubtitleState(player).text,
    builder: (context, text, _) => text.isEmpty
        ? const SizedBox.shrink()
        : IgnorePointer(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, appearance.bottom),
                child: RepaintBoundary(
                  child: Text(
                    text,
                    textAlign: TextAlign.center,
                    style: appearance.configuration.style,
                  ),
                ),
              ),
            ),
          ),
  );
}
