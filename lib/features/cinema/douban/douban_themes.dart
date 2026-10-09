import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'douban_models.dart';

/// The topics returned by Douban accumulate across launches. A later partial
/// response never replaces earlier discoveries or silently evicts older ones.
class DoubanThemeCatalog extends ChangeNotifier {
  /// An isolated in-memory catalogue unless a file is provided (also for tests).
  DoubanThemeCatalog({File? storageFile})
    : _file = storageFile,
      _persistent = storageFile != null;

  DoubanThemeCatalog.persistent() : _persistent = true;

  static final shared = DoubanThemeCatalog.persistent();
  // Bound corrupt/untrusted disk input rather than evicting legitimate topics.
  static const _maximumFileBytes = 4 * 1024 * 1024;
  final bool _persistent;
  File? _file;
  final _topics = <DoubanKind, List<String>>{};
  final _seedCursor = <DoubanKind, int>{};
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  int _revision = 0, _savedRevision = 0;
  String? _storageError;
  bool _readFailed = false;

  String? get storageError => _storageError;

  List<String> topics(DoubanKind kind) =>
      List.unmodifiable(_topics[kind] ?? const <String>[]);

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!_persistent) return;
    try {
      final file = _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/douban-themes-v1.json',
      );
      if (!await file.exists()) {
        if (_storageError != null) {
          _storageError = null;
          notifyListeners();
        }
        return;
      }
      if (await file.length() > _maximumFileBytes) {
        throw const FormatException('Theme catalogue is too large');
      }
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map || raw['version'] != 1 || raw['topics'] is! Map) {
        throw const FormatException('Invalid theme catalogue');
      }
      final saved = raw['topics'] as Map;
      for (final kind in DoubanKind.values) {
        final values = saved[kind.name];
        if (values != null && values is! List) {
          throw const FormatException('Invalid topic list');
        }
      }
      for (final kind in DoubanKind.values) {
        // Network discovery can finish before disk I/O: merge both, never let
        // a delayed restore replace newly discovered topics.
        _topics[kind] = {
          ..._valid(saved[kind.name] is List ? saved[kind.name] as List : []),
          ...?_topics[kind],
        }.toList();
        final cursors = raw['seedCursor'];
        final cursor = cursors is Map ? cursors[kind.name] : null;
        if (!_seedCursor.containsKey(kind) && cursor is int && cursor >= 0) {
          _seedCursor[kind] = cursor;
        }
      }
      _storageError = null;
      notifyListeners();
    } catch (_) {
      // Never overwrite an unreadable existing file with an empty catalogue.
      // Current discoveries remain usable and the original file is preserved.
      _readFailed = true;
      _storageError = '暂时无法读取已保存的主题，本次发现的主题仍可使用。';
      notifyListeners();
    }
  }

  static Iterable<String> _valid(Iterable<Object?> values) sync* {
    for (final value in values.whereType<String>()) {
      final topic = value.trim();
      if (topic.isNotEmpty &&
          topic.length <= 120 &&
          !RegExp(r'[,\x00-\x1f\x7f]').hasMatch(topic)) {
        yield topic;
      }
    }
  }

  List<String> remember(
    DoubanKind kind,
    Iterable<String> incoming, {
    Iterable<String> selected = const [],
  }) {
    final old = _topics[kind] ?? const <String>[];
    final values = {...old, ..._valid(incoming), ..._valid(selected)}.toList();
    if (!listEquals(old, values)) {
      _topics[kind] = values;
      ++_revision;
      unawaited(flush());
    }
    return List.unmodifiable(values);
  }

  /// Continue exploring from the previous launch instead of repeatedly asking
  /// Douban for the same first two themes.
  String? nextSeed(DoubanKind kind) {
    final values = _topics[kind] ?? const <String>[];
    if (values.isEmpty) return null;
    final cursor = _seedCursor[kind] ?? 0;
    final seed = values[cursor % values.length];
    _seedCursor[kind] = cursor + 1;
    ++_revision;
    unawaited(flush());
    return seed;
  }

  Future<void> retryPersistence() async {
    if (_readFailed) {
      _readFailed = false;
      _initialization = null;
      await initialize();
    }
    await flush();
  }

  /// Serialize atomic snapshots; a slower older write cannot replace a newer
  /// response. No exit hook is needed: each discovery schedules its own write.
  Future<void> flush() async {
    if (!_persistent) return;
    await initialize();
    if (_readFailed) return;
    final task = _writes.then((_) async {
      if (_revision == _savedRevision) return;
      final revision = _revision;
      final encoded = jsonEncode({
        'version': 1,
        'topics': {
          for (final kind in DoubanKind.values) kind.name: topics(kind),
        },
        'seedCursor': {
          for (final kind in DoubanKind.values)
            kind.name: _seedCursor[kind] ?? 0,
        },
      });
      if (utf8.encode(encoded).length > _maximumFileBytes) {
        throw const FormatException('Theme catalogue is too large');
      }
      final file = _file!;
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename(file.path);
      _savedRevision = revision;
      if (_storageError != null) {
        _storageError = null;
        notifyListeners();
      }
    });
    _writes = task.catchError((Object _) {
      _storageError = '主题暂时无法保存，下次打开可能无法恢复，请稍后重试。';
      notifyListeners();
    });
    await _writes;
  }
}
