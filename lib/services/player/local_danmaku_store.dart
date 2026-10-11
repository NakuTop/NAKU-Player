import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:path_provider/path_provider.dart';

const maxDanmakuImportBytes = 8 * 1024 * 1024;

/// Accept standard Bilibili XML and DanDanPlay JSON; the HTML parser does not
/// resolve XML external entities. Imported entries are plain text, never markup.
List<DanmakuEntry> parseLocalDanmaku(String content) {
  if (utf8.encode(content).length > maxDanmakuImportBytes ||
      RegExp(
        r'<!\s*(DOCTYPE|ENTITY)',
        caseSensitive: false,
      ).hasMatch(content)) {
    throw const FormatException('文件过大或含不支持的 XML 声明');
  }
  final result = <DanmakuEntry>[];
  void add(String? message, String? parameters, {required bool xml}) {
    if (message == null || parameters == null || result.length >= 100000) {
      return;
    }
    final p = parameters.split(',');
    if (p.length < (xml ? 4 : 3)) return;
    final time = double.tryParse(p[0]), mode = int.tryParse(p[1]);
    final color = int.tryParse(p[xml ? 3 : 2]);
    if (time == null ||
        !time.isFinite ||
        time < 0 ||
        time > 604800 ||
        ![1, 4, 5].contains(mode) ||
        color == null ||
        color < 0 ||
        color > 0xffffff ||
        message.trim().isEmpty ||
        message.length > 2000) {
      return;
    }
    result.add(
      DanmakuEntry(
        message: message,
        time: time,
        type: mode!,
        color: Color(0xff000000 | color),
        source: '[Local]',
      ),
    );
  }

  if (content.trimLeft().startsWith('<')) {
    for (final node in html.parse(content).querySelectorAll('d[p]')) {
      add(node.text, node.attributes['p'], xml: true);
    }
  } else {
    final json = jsonDecode(content);
    final entries = json is List
        ? json
        : json is Map
        ? (json['comments'] ?? json['danmakus'])
        : null;
    if (entries is! List) throw const FormatException('弹幕 JSON 格式不受支持');
    for (final entry in entries) {
      if (entry is Map && entry['m'] is String && entry['p'] is String) {
        add(entry['m'] as String, entry['p'] as String, xml: false);
      }
    }
  }
  result.sort((a, b) => a.time.compareTo(b.time));
  if (result.isEmpty) throw const FormatException('文件中没有可显示的弹幕');
  return result;
}

class LocalDanmakuStore {
  LocalDanmakuStore({this.directory});
  static final instance = LocalDanmakuStore();
  final Directory? directory;
  Future<File> _file(int subject, int episode) async {
    if (subject <= 0 || episode <= 0) throw const FormatException('无效的番剧或集数');
    final root =
        directory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}/danmaku-imports',
        );
    return File('${root.path}/$subject/$episode.json');
  }

  Future<List<DanmakuEntry>?> read(int subject, int episode) async {
    try {
      final file = await _file(subject, episode);
      if (!await file.exists() || await file.length() > maxDanmakuImportBytes) {
        return null;
      }
      final content = await file.readAsString();
      final entries = parseLocalDanmaku(content);
      final metadata = jsonDecode(content);
      if (metadata is Map && metadata['source'] == '[BiliBili]') {
        for (final entry in entries) {
          entry.source = '[BiliBili]';
        }
      }
      return entries;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(
    int subject,
    int episode,
    List<DanmakuEntry> entries,
  ) async {
    final file = await _file(subject, episode);
    final data = jsonEncode({
      'version': 1,
      'source':
          entries.isNotEmpty && entries.every((e) => e.source == '[BiliBili]')
          ? '[BiliBili]'
          : '[Local]',
      'comments': entries.map((e) => e.toJson()).toList(),
    });
    if (utf8.encode(data).length > maxDanmakuImportBytes) {
      throw const FormatException('弹幕文件超过 8 MB');
    }
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> remove(int subject, int episode) async {
    final file = await _file(subject, episode);
    if (await file.exists()) await file.delete();
  }
}
