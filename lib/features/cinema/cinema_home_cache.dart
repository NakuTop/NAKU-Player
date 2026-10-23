import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Disposable homepage metadata, separate from downloads and the user library.
/// Each entry is replaced atomically, so one failed write cannot clear others.
class CinemaHomeCache {
  CinemaHomeCache({Directory? directory}) : _directory = directory;

  static final instance = CinemaHomeCache();
  static const maxEntries = 256;
  static const maxBytes = 24 * 1024 * 1024;
  static const maxEntryBytes = 4 * 1024 * 1024;
  static final _ownedFile = RegExp(r'^(catalog|resource)-[a-f0-9]{64}\.json$');
  Directory? _directory;
  Future<void>? _loading, _writing;
  final _entries = <String, Map<String, dynamic>>{};
  final _pending = <String, Map<String, dynamic>>{};
  String? lastError;

  Future<Directory> get _dir async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/cinema/home-cache',
  );

  String _id(String bucket, String key) {
    if (bucket != 'catalog' && bucket != 'resource') {
      throw ArgumentError.value(bucket, 'bucket');
    }
    // Source configurations may contain private query parameters. Neither
    // filenames nor cache payloads need to retain that configuration verbatim.
    return '$bucket-${sha256.convert(utf8.encode(key))}.json';
  }

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final path = (await _dir).path;
      final restored = await Isolate.run(() async {
        final directory = Directory(path);
        if (!await directory.exists()) return <String, Map<String, dynamic>>{};
        final files = <File>[];
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is File &&
              _ownedFile.hasMatch(entity.uri.pathSegments.last)) {
            files.add(entity);
          }
        }
        final dated = <(File, FileStat)>[];
        for (final file in files) {
          dated.add((file, await file.stat()));
        }
        dated.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
        var bytes = 0;
        final values = <String, Map<String, dynamic>>{};
        for (final (file, stat) in dated) {
          if (values.length >= maxEntries) break;
          if (stat.size > maxEntryBytes || bytes + stat.size > maxBytes) {
            continue;
          }
          try {
            final value = jsonDecode(await file.readAsString());
            if (value is Map && value['version'] == 1 && value['data'] is Map) {
              values[file.uri.pathSegments.last] = Map<String, dynamic>.from(
                value['data'],
              );
              bytes += stat.size;
            }
          } catch (_) {
            // An interrupted/corrupt optional entry does not hide other cards.
          }
        }
        return values;
      });
      _entries.addEntries(restored.entries.toList().reversed);
    } catch (error) {
      lastError = error.toString();
    }
  }

  /// Call [load] before the first paint; reads after that require no disk I/O.
  Map<String, dynamic>? get(String bucket, String key) =>
      _entries[_id(bucket, key)];

  Future<void> put(String bucket, String key, Map<String, dynamic> data) async {
    await load();
    final id = _id(bucket, key);
    _entries.remove(id);
    _entries[id] = data;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    _pending[id] = data;
    _startWrites();
    await flush();
  }

  void _startWrites() {
    if (_writing != null) return;
    _writing = _drain().whenComplete(() {
      _writing = null;
      if (_pending.isNotEmpty) _startWrites();
    });
  }

  Future<void> flush() async {
    while (_writing != null) {
      await _writing;
    }
  }

  Future<void> _drain() async {
    try {
      final path = (await _dir).path;
      while (_pending.isNotEmpty) {
        final entry = _pending.entries.first;
        _pending.remove(entry.key);
        final filename = entry.key;
        final data = entry.value;
        await Isolate.run(() async {
          final encoded = utf8.encode(jsonEncode({'version': 1, 'data': data}));
          if (encoded.length > maxEntryBytes) return;
          final file = File('$path/$filename');
          await file.parent.create(recursive: true);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsBytes(encoded, flush: true);
          await temporary.rename(file.path);
        });
      }
      await _prune(path);
    } catch (error) {
      lastError = error.toString();
      _pending.clear();
    }
  }

  Future<void> _prune(String path) => Isolate.run(() async {
    final files = <(File, FileStat)>[];
    await for (final entity in Directory(path).list(followLinks: false)) {
      if (entity is File && _ownedFile.hasMatch(entity.uri.pathSegments.last)) {
        files.add((entity, await entity.stat()));
      }
    }
    files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
    var retained = 0, bytes = 0;
    for (final (file, stat) in files) {
      if (retained >= maxEntries || bytes + stat.size > maxBytes) {
        await file.delete();
      } else {
        retained++;
        bytes += stat.size;
      }
    }
  });
}
