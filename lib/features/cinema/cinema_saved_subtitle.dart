import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_timing.dart';

final _writes = Expando<Future<void>>();

class CinemaSavedSubtitle {
  const CinemaSavedSubtitle({
    this.text = '',
    this.title = '已保存字幕',
    this.language = 'zh',
    this.timing = const CinemaSubtitleTiming(),
    this.inheritToSeason = false,
    this.seasonPrefetch = true,
    this.disabled = false,
    this.nativeTrack,
    this.origin = 'legacy',
    this.sourceLabel = '旧版保存字幕',
    this.workTitle = '',
    this.workType = '',
  });
  final String text, title, language, origin, sourceLabel, workTitle, workType;
  final String? nativeTrack;
  final CinemaSubtitleTiming timing;
  final bool inheritToSeason, seasonPrefetch, disabled;
  String get fingerprint => sha256.convert(utf8.encode(text)).toString();
  CinemaSavedSubtitle withTiming(CinemaSubtitleTiming value) =>
      CinemaSavedSubtitle(
        text: text,
        origin: origin,
        sourceLabel: sourceLabel,
        workTitle: workTitle,
        workType: workType,
        title: title,
        language: language,
        timing: value,
        inheritToSeason: inheritToSeason,
        seasonPrefetch: seasonPrefetch,
      );
  Map<String, dynamic> toJson() => disabled
      ? {'version': 1, 'disabled': true}
      : nativeTrack != null
      ? {
          'version': 1,
          'nativeTrack': nativeTrack,
          'title': title,
          'language': language,
        }
      : {
          'version': 1,
          'text': text,
          'origin': origin,
          'sourceLabel': sourceLabel,
          'workTitle': workTitle,
          'workType': workType,
          'fingerprint': fingerprint,
          'title': title,
          'language': language,
          'scale': timing.scale,
          'offset': timing.offsetSeconds,
          'inheritToSeason': inheritToSeason,
          'seasonPrefetch': seasonPrefetch,
        };

  static CinemaSavedSubtitle? parse(Object? value) {
    if (value is! Map || value['version'] != 1) return null;
    if (value['disabled'] == true) {
      return const CinemaSavedSubtitle(disabled: true);
    }
    if (value['nativeTrack'] is String) {
      final id = value['nativeTrack'] as String;
      final title = value['title'], language = value['language'];
      if (!RegExp(r'^(auto|[0-9]+)$').hasMatch(id) ||
          title is! String ||
          title.length > 512 ||
          language is! String ||
          language.length > 32) {
        return null;
      }
      return CinemaSavedSubtitle(
        nativeTrack: id,
        title: title,
        language: language,
      );
    }
    final text = value['text'], title = value['title'];
    final language = value['language'];
    final scale = value['scale'], offset = value['offset'];
    if (text is! String ||
        text.isEmpty ||
        title is! String ||
        title.length > 512 ||
        language is! String ||
        language.length > 32 ||
        scale is! num ||
        !scale.isFinite ||
        scale < .5 ||
        scale > 2 ||
        offset is! num ||
        !offset.isFinite ||
        offset.abs() > 21600 ||
        value['inheritToSeason'] is! bool ||
        (value['seasonPrefetch'] != null && value['seasonPrefetch'] is! bool) ||
        sha256.convert(utf8.encode(text)).toString() != value['fingerprint']) {
      return null;
    }
    final origin = value['origin'] ?? 'legacy';
    final source = value['sourceLabel'] ?? '旧版保存字幕';
    final work = value['workTitle'] ?? '';
    final type = value['workType'] ?? '';
    if (!['manual', 'automatic', 'legacy'].contains(origin) ||
        source is! String ||
        source.length > 200 ||
        work is! String ||
        work.length > 512 ||
        !['', 'movie', 'series'].contains(type)) {
      return null;
    }
    return CinemaSavedSubtitle(
      origin: origin as String,
      sourceLabel: source,
      workTitle: work,
      workType: type as String,
      text: text,
      title: title,
      language: language,
      timing: CinemaSubtitleTiming(
        scale: scale.toDouble(),
        offsetSeconds: offset.toDouble(),
      ),
      inheritToSeason: value['inheritToSeason'] as bool,
      seasonPrefetch: value['seasonPrefetch'] as bool? ?? true,
    );
  }
}

/// Remember the exact selected file for a video, rather than asking an online
/// catalogue to choose a possibly different cut whenever it is reopened.
/// Only a hashed media identity is used as a filename; no playback URL is kept.
class CinemaSavedSubtitleStore {
  CinemaSavedSubtitleStore(this.store, String mediaIdentity)
    : _key = sha256.convert(utf8.encode(mediaIdentity)).toString();
  final CinemaStore store;
  final String _key;
  static const maxFileBytes = 4 * 1024 * 1024;
  static const maxTotalBytes = 32 * 1024 * 1024;
  static const maxEntries = 64;

  Future<void> flush() => _writes[store] ?? Future<void>.value();
  Future<File> _file() async =>
      File('${(await store.subtitleCacheDirectory()).path}/$_key.json');

  Future<CinemaSavedSubtitle?> read() async {
    await flush();
    return _read();
  }

  Future<CinemaSavedSubtitle?> _read() async {
    final file = await _file();
    if (!await file.exists() || await file.length() > maxFileBytes) return null;
    try {
      return CinemaSavedSubtitle.parse(jsonDecode(await file.readAsString()));
    } on FormatException {
      return null;
    }
  }

  Future<void> save(CinemaSavedSubtitle value) => _enqueue(() => _write(value));
  Future<void> clear() => _enqueue(() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  });

  Future<void> disable() => save(const CinemaSavedSubtitle(disabled: true));

  Future<void> updateTiming(String content, CinemaSubtitleTiming timing) =>
      _enqueue(() async {
        final current = await _read();
        if (current == null ||
            current.disabled ||
            current.fingerprint != content) {
          return;
        }
        await _write(current.withTiming(timing));
      });

  Future<void> _enqueue(Future<void> Function() action) {
    final previous = _writes[store] ?? Future<void>.value();
    late Future<void> pending;
    pending = previous
        .catchError((Object _) {})
        .then((_) => action())
        .whenComplete(() {
          if (identical(_writes[store], pending)) _writes[store] = null;
        });
    _writes[store] = pending;
    return pending;
  }

  Future<void> _write(CinemaSavedSubtitle value) async {
    final bytes = utf8.encode(jsonEncode(value.toJson()));
    if (bytes.length > maxFileBytes) throw const FormatException('字幕文件过大，无法记忆');
    final file = await _file();
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(file.path);
    final entries = <({File file, int bytes, DateTime modified})>[];
    await for (final item in file.parent.list(followLinks: false)) {
      if (item is! File ||
          !RegExp(
            r'^[a-f0-9]{64}\.json$',
          ).hasMatch(item.uri.pathSegments.last)) {
        continue;
      }
      final stat = await item.stat();
      entries.add((file: item, bytes: stat.size, modified: stat.modified));
    }
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    var bytesTotal = entries.fold(0, (int total, entry) => total + entry.bytes);
    var count = entries.length;
    for (final entry in entries) {
      if (count <= maxEntries && bytesTotal <= maxTotalBytes) break;
      if (entry.file.path == file.path) continue;
      await entry.file.delete();
      bytesTotal -= entry.bytes;
      count--;
    }
  }
}
