import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'cinema_models.dart';
import 'cinema_library_identity.dart';

/// A one-time addition of presets, independent of the user's current choices.
class CinemaSourcePack {
  const CinemaSourcePack({required this.id, required this.sources});

  final String id;
  final List<CinemaSource> sources;
}

/// Restores only the removed work, once, without replacing newer user activity.
class CinemaLibraryUndo {
  CinemaLibraryUndo._(this._restore);

  final Future<bool> Function() _restore;
  bool _used = false;

  Future<bool> restore() async {
    if (_used) return false;
    _used = true;
    return _restore();
  }
}

typedef _RemovedLibraryEntry = ({int index, Map<String, dynamic> document});

/// Stored apart from Kazumi's Bangumi history and favourites.
class CinemaStore extends ChangeNotifier {
  CinemaStore({
    File? file,
    List<CinemaSource>? defaults,
    List<CinemaSourcePack>? sourcePacks,
  }) : _file = file,
       _defaults = List.unmodifiable(defaults ?? bundledCinemaSources),
       _sourcePacks = List.unmodifiable(
         sourcePacks ??
             (defaults == null ? bundledCinemaSourcePacks : const []),
       ),
       // A new library already has its explicitly chosen defaults. Mark the
       // current packs handled without inserting anything into custom defaults.
       _freshSourcePackIds = {
         for (final pack in sourcePacks ?? bundledCinemaSourcePacks) pack.id,
       };
  File? _file;
  final List<CinemaSource> _defaults;
  final List<CinemaSourcePack> _sourcePacks;
  final Set<String> _freshSourcePackIds;
  final Set<String> _appliedSourcePacks = {};
  Map<String, dynamic> _libraryExtras = {};
  final Map<String, Map<String, dynamic>> _sourceDocuments = {};
  final Map<String, Map<String, dynamic>> _favoriteDocuments = {};
  final Map<String, Map<String, dynamic>> _historyDocuments = {};
  List<CinemaTitle>? _identityTitles;
  final Map<(bool, String), Set<String>> _identityMatches = {};
  final List<CinemaSource> _sources = [];
  final List<CinemaTitle> _favorites = [];
  final List<CinemaHistory> _history = [];
  Future<void>? _loading;
  Future<void> _writeTail = Future.value();
  bool _loaded = false;
  bool _disposed = false;
  String? lastError;

  bool get loaded => _loaded;
  List<CinemaSource> get sources => List.unmodifiable(_sources);
  List<CinemaSource> get enabledSources =>
      _sources.where((source) => source.enabled).toList();
  List<CinemaTitle> get favorites => List.unmodifiable(_favorites);
  List<CinemaHistory> get history => List.unmodifiable(_history);

  Future<void> load() {
    if (_loaded) return Future.value();
    return _loading ??= _read().whenComplete(() => _loading = null);
  }

  Future<void> _read() async {
    try {
      _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/library-v1.json',
      );
      if (await _file!.exists()) {
        final original = await _file!.readAsBytes();
        final raw = _validatedLibrary(jsonDecode(utf8.decode(original)));
        final sourceMaps = _strictMaps(raw['sources']);
        final sources = sourceMaps.map(CinemaSource.fromJson).toList();
        final favoriteMaps = _strictMaps(raw['favorites']);
        final historyMaps = _strictMaps(raw['history']);
        // Keep stable order for ties; the first history is the most recently
        // watched complete source/route/episode snapshot, never mixed fields.
        final sortedHistory = historyMaps.indexed.toList()
          ..sort((a, b) {
            final comparison = CinemaHistory.fromJson(
              b.$2,
            ).updatedAt.compareTo(CinemaHistory.fromJson(a.$2).updatedAt);
            return comparison == 0 ? a.$1.compareTo(b.$1) : comparison;
          });
        final context = [
          ...favoriteMaps.expand((map) => _recordTitles(map, history: false)),
          ...historyMaps.expand((map) => _recordTitles(map, history: true)),
        ];
        final compactFavorites = _consolidateRecords(
          favoriteMaps,
          history: false,
          context: context,
        );
        final compactHistory = _consolidateRecords(
          sortedHistory.map((entry) => entry.$2).toList(),
          history: true,
          context: context,
        );
        final needsConsolidation =
            compactFavorites.length != favoriteMaps.length ||
            compactHistory.length != historyMaps.length;
        final applied = _readAppliedPacks(raw);
        final pending = _sourcePacks
            .where((pack) => !applied.contains(pack.id))
            .toList();
        _validatePacks(_sourcePacks);
        if (pending.isNotEmpty) {
          final ids = sources.map((source) => source.id).toSet();
          final urls = sources
              .map((source) => _canonicalUrl(source.url))
              .toSet();
          final additions = <CinemaSource>[];
          for (final pack in pending) {
            for (final source in pack.sources) {
              final url = _canonicalUrl(source.url);
              if (ids.contains(source.id) || urls.contains(url)) continue;
              additions.add(source);
              ids.add(source.id);
              urls.add(url);
            }
            // Even a skipped preset is handled: removing a user-owned duplicate
            // later must not cause the corresponding preset to come back.
            applied.add(pack.id);
          }
          final lastMovieSource = sources.lastIndexWhere(
            (source) => source.kind == CinemaSourceKind.maccms,
          );
          final insertion = lastMovieSource + 1;
          sources.insertAll(insertion, additions);
          sourceMaps.insertAll(
            insertion,
            additions.map((source) => source.toJson()),
          );
        }
        if (pending.isNotEmpty || needsConsolidation) {
          final upgraded = {
            ...raw,
            if (pending.isNotEmpty) 'sources': sourceMaps,
            if (pending.isNotEmpty) 'appliedSourcePacks': applied.toList(),
            if (needsConsolidation) 'favorites': compactFavorites,
            if (needsConsolidation) 'history': compactHistory,
          };
          // Back up exact original bytes before either migration writes. A
          // library-only consolidation must not mark a source pack installed.
          if (needsConsolidation) {
            await _backupBeforeWorkConsolidation(original);
          }
          if (pending.isNotEmpty) await _backupBeforeSourceUpgrade(original);
          await _writeEncoded(
            const JsonEncoder.withIndent('  ').convert(upgraded),
          );
        }
        _libraryExtras = Map.of(raw)
          ..removeWhere(
            (key, _) => const {
              'version',
              'sources',
              'favorites',
              'history',
              'appliedSourcePacks',
            }.contains(key),
          );
        _appliedSourcePacks.addAll(applied);
        _sources.addAll(sources);
        for (final map in sourceMaps) {
          _sourceDocuments[map['id'] as String] = map;
        }
        for (final map in compactFavorites) {
          final title = CinemaTitle.fromJson(map);
          _favorites.add(title);
          _favoriteDocuments[title.key] = map;
        }
        for (final map in compactHistory) {
          final item = CinemaHistory.fromJson(map);
          _history.add(item);
          _historyDocuments[item.title.key] = map;
        }
      } else {
        for (final source in _defaults) {
          source.validate();
        }
        _validatePacks(_sourcePacks);
        _sources.addAll(_defaults);
        _appliedSourcePacks.addAll(_freshSourcePackIds);
      }
      _invalidateIdentityCache();
      _loaded = true;
      lastError = null;
      _notify();
    } catch (error) {
      lastError = '本地影院资料读取失败：$error';
      _notify();
      rethrow;
    }
  }

  CinemaSource? sourceById(String id) =>
      _sources.where((source) => source.id == id).firstOrNull;
  bool isFavorite(CinemaTitle title) => _favoriteMatches(title).isNotEmpty;

  /// Route and episode indexes belong to a source. A different source's latest
  /// work history must never silently become this source's resume position.
  CinemaHistory? historyFor(CinemaTitle title) =>
      _history.where((item) => item.title.key == title.key).firstOrNull;

  /// For display/navigation: open the returned title to resume its saved source.
  CinemaHistory? historyForWork(CinemaTitle title) {
    final matches = _historyMatches(title);
    return _history
        .where((item) => matches.contains(item.title.key))
        .firstOrNull;
  }

  List<CinemaTitle> get _identityContext => _identityTitles ??= [
    ..._favoriteDocuments.values.expand(
      (m) => _recordTitles(m, history: false),
    ),
    ..._historyDocuments.values.expand((m) => _recordTitles(m, history: true)),
  ];

  void _invalidateIdentityCache() {
    _identityTitles = null;
    _identityMatches.clear();
  }

  Set<String> _matches(CinemaTitle title, {required bool history}) {
    final key = (history, _identitySignature(title));
    final cached = _identityMatches[key];
    if (cached != null) return cached;
    final result = _matchingRecordKeys(
      title,
      history ? _historyDocuments.values : _favoriteDocuments.values,
      history: history,
      context: _identityContext,
    );
    if (_identityMatches.length >= 512) {
      _identityMatches.remove(_identityMatches.keys.first);
    }
    _identityMatches[key] = result;
    return result;
  }

  Set<String> _favoriteMatches(CinemaTitle title) =>
      _matches(title, history: false);
  Set<String> _historyMatches(CinemaTitle title) =>
      _matches(title, history: true);

  Future<void> saveSource(CinemaSource source) async {
    source.validate();
    await load();
    final document = Map<String, dynamic>.of(_sourceDocuments[source.id] ?? {})
      ..remove('headers')
      ..remove('rule');
    _sourceDocuments[source.id] = {...document, ...source.toJson()};
    final index = _sources.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      _sources.add(source);
    } else {
      _sources[index] = source;
    }
    _notify();
    await _persist();
  }

  Future<void> removeSource(String id) async {
    await load();
    _sources.removeWhere((source) => source.id == id);
    _sourceDocuments.remove(id);
    _notify();
    await _persist();
  }

  Future<void> toggleFavorite(CinemaTitle title) async {
    await load();
    final matches = _favoriteMatches(title);
    if (matches.isNotEmpty) {
      _favorites.removeWhere((item) => matches.contains(item.key));
      _favoriteDocuments.removeWhere((key, _) => matches.contains(key));
    } else {
      _favorites.insert(0, title);
      _favoriteDocuments[title.key] = title.toJson();
    }
    _invalidateIdentityCache();
    _notify();
    await _persist();
  }

  Future<void> recordProgress({
    required CinemaTitle title,
    required int routeIndex,
    required int episodeIndex,
    required int positionSeconds,
    int durationSeconds = 0,
  }) async {
    await load();
    if (routeIndex < 0 ||
        episodeIndex < 0 ||
        positionSeconds < 0 ||
        durationSeconds < 0) {
      throw const FormatException('播放进度不能为负数');
    }
    final matches = _historyMatches(title);
    final previous = [
      for (final item in _history)
        if (matches.contains(item.title.key))
          _historyDocuments[item.title.key]!,
    ];
    var identityChanged =
        previous.length != 1 ||
        _identitySignature(_recordTitle(previous.single, history: true)) !=
            _identitySignature(title);
    final item = CinemaHistory(
      title: title,
      routeIndex: routeIndex,
      episodeIndex: episodeIndex,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      updatedAt: DateTime.now().toUtc(),
    );
    final sameSource =
        _historyDocuments[title.key] ??
        previous
            .expand((m) => [m, ..._mergedEntries(m)])
            .where((m) => _recordTitle(m, history: true).key == title.key)
            .firstOrNull;
    final document = _mergeKnownDocument(sameSource, item.toJson());
    final combined = _mergeRecordDocuments(
      document,
      previous.where((m) => _recordTitle(m, history: true).key != title.key),
      history: true,
    );
    _history.removeWhere((item) => matches.contains(item.title.key));
    _historyDocuments.removeWhere((key, _) => matches.contains(key));
    _history.insert(0, item);
    _historyDocuments[title.key] = combined;
    if (_history.length > 200) {
      identityChanged = true;
      final removed = _history
          .sublist(200)
          .map((item) => item.title.key)
          .toSet();
      _history.removeRange(200, _history.length);
      _historyDocuments.removeWhere((key, _) => removed.contains(key));
    }
    if (identityChanged) _invalidateIdentityCache();
    _notify();
    await _persist();
  }

  Future<CinemaLibraryUndo?> removeFavorite(CinemaTitle title) =>
      _removeLibraryEntry(title, history: false);

  Future<CinemaLibraryUndo?> removeHistory(CinemaTitle title) =>
      _removeLibraryEntry(title, history: true);

  Future<CinemaLibraryUndo?> _removeLibraryEntry(
    CinemaTitle title, {
    required bool history,
  }) async {
    await load();
    final matches = _matches(title, history: history);
    if (matches.isEmpty) return null;
    final documents = history ? _historyDocuments : _favoriteDocuments;
    final orderedKeys = history
        ? _history.map((item) => item.title.key)
        : _favorites.map((item) => item.key);
    final removed = <_RemovedLibraryEntry>[
      for (final entry in orderedKeys.indexed)
        if (matches.contains(entry.$2))
          (
            index: entry.$1,
            // Preserve merged source identities, timestamps and unknown fields.
            document: Map<String, dynamic>.from(
              jsonDecode(jsonEncode(documents[entry.$2])) as Map,
            ),
          ),
    ];
    if (history) {
      _history.removeWhere((item) => matches.contains(item.title.key));
    } else {
      _favorites.removeWhere((item) => matches.contains(item.key));
    }
    documents.removeWhere((key, _) => matches.contains(key));
    _invalidateIdentityCache();
    _notify();
    try {
      await _persist();
    } catch (_) {
      _restoreLibraryEntries(removed, history: history);
      // A queued concurrent save may already contain the deletion. Append the
      // compensating snapshot without allowing another failure to hide it.
      try {
        await _persist();
      } catch (_) {}
      rethrow;
    }
    return CinemaLibraryUndo._(() async {
      if (!_restoreLibraryEntries(removed, history: history)) return false;
      await _persist();
      return true;
    });
  }

  bool _restoreLibraryEntries(
    List<_RemovedLibraryEntry> removed, {
    required bool history,
  }) {
    final documents = history ? _historyDocuments : _favoriteDocuments;
    final originals = removed
        .expand((entry) => _recordTitles(entry.document, history: history))
        .toList();
    final context = [..._identityContext, ...originals];
    if (originals.any(
      (title) => _matchingRecordKeys(
        title,
        documents.values,
        history: history,
        context: context,
      ).isNotEmpty,
    )) {
      // Watching or favoriting this work again takes precedence over undo.
      return false;
    }
    for (final entry in removed) {
      final document = entry.document;
      if (history) {
        final item = CinemaHistory.fromJson(document);
        _history.insert(entry.index.clamp(0, _history.length), item);
        _historyDocuments[item.title.key] = document;
      } else {
        final item = CinemaTitle.fromJson(document);
        _favorites.insert(entry.index.clamp(0, _favorites.length), item);
        _favoriteDocuments[item.key] = document;
      }
    }
    if (history) {
      final ordered = _history.indexed.toList()
        ..sort((a, b) {
          final updated = b.$2.updatedAt.compareTo(a.$2.updatedAt);
          return updated == 0 ? a.$1.compareTo(b.$1) : updated;
        });
      _history
        ..clear()
        ..addAll(ordered.take(200).map((entry) => entry.$2));
      final kept = _history.map((item) => item.title.key).toSet();
      _historyDocuments.removeWhere((key, _) => !kept.contains(key));
    }
    _invalidateIdentityCache();
    _notify();
    return true;
  }

  Future<void> clearHistory() async {
    await load();
    _history.clear();
    _historyDocuments.clear();
    _invalidateIdentityCache();
    _notify();
    await _persist();
  }

  Future<void> _persist() {
    final encoded = const JsonEncoder.withIndent('  ').convert({
      ..._libraryExtras,
      'version': 1,
      'sources': _sources
          .map(
            (item) =>
                _mergeKnownDocument(_sourceDocuments[item.id], item.toJson()),
          )
          .toList(),
      'favorites': _favorites
          .map((item) => _favoriteDocuments[item.key]!)
          .toList(),
      'history': _history
          .map((item) => _historyDocuments[item.title.key]!)
          .toList(),
      'appliedSourcePacks': _appliedSourcePacks.toList(),
    });
    // A failed write is reported to its caller and does not poison later writes.
    final next = _writeTail.catchError((Object _) {}).then((_) async {
      try {
        await _writeEncoded(encoded);
        lastError = null;
      } catch (error) {
        lastError = '本地影院资料保存失败：$error';
        _notify();
        rethrow;
      }
    });
    _writeTail = next;
    return next;
  }

  Future<void> _writeEncoded(String encoded) async {
    final file = _file!;
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(encoded, flush: true);
    await temporary.rename(file.path);
  }

  Future<void> _backupBeforeSourceUpgrade(List<int> original) async {
    final backup = File('${_file!.path}.pre-0.3.0.bak');
    if (await backup.exists()) return;
    final temporary = File('${backup.path}.tmp');
    await temporary.writeAsBytes(original, flush: true);
    await temporary.rename(backup.path);
  }

  Future<void> _backupBeforeWorkConsolidation(List<int> original) async {
    final base = '${_file!.path}.pre-work-dedup-v1';
    var backup = File('$base.bak');
    if (await backup.exists()) {
      if (listEquals(await backup.readAsBytes(), original)) return;
      var suffix = DateTime.now().microsecondsSinceEpoch;
      do {
        backup = File('$base.$suffix.bak');
        suffix++;
      } while (await backup.exists());
    }
    final temporary = File('${backup.path}.tmp');
    await temporary.writeAsBytes(original, flush: true);
    await temporary.rename(backup.path);
  }

  /// Await this before closing the player or the application.
  Future<void> flush() => _writeTail;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

// The visible arrays remain one record per work. Removed source snapshots
// remain here so unknown per-entry data and stronger identity evidence survive.
const _workEntriesKey = 'nakuWorkEntriesV1';

List<Map<String, dynamic>> _mergedEntries(Map<String, dynamic> document) {
  if (!document.containsKey(_workEntriesKey)) return const [];
  final result = _strictMaps(document[_workEntriesKey]);
  if (result.any((entry) => entry.containsKey(_workEntriesKey))) {
    throw const FormatException('影院合并记录不可嵌套，原文件已保留');
  }
  return result;
}

String _identitySignature(CinemaTitle title) => jsonEncode([
  title.sourceId,
  title.id,
  title.title,
  title.year,
  title.category,
  title.doubanId,
]);

CinemaTitle _recordTitle(
  Map<String, dynamic> document, {
  required bool history,
}) {
  final title = history
      ? Map<String, dynamic>.from(document['title'] as Map)
      : document;
  // Identity checks never need to parse stored media routes or signed URLs.
  return CinemaTitle.fromJson({
    for (final key in [
      'id',
      'sourceId',
      'title',
      'year',
      'category',
      'doubanId',
    ])
      key: title[key],
  });
}

Iterable<CinemaTitle> _recordTitles(
  Map<String, dynamic> document, {
  required bool history,
}) sync* {
  yield _recordTitle(document, history: history);
  for (final original in _mergedEntries(document)) {
    yield _recordTitle(original, history: history);
  }
}

Set<String> _matchingRecordKeys(
  CinemaTitle query,
  Iterable<Map<String, dynamic>> documents, {
  required bool history,
  required Iterable<CinemaTitle> context,
}) {
  final records = documents.toList();
  final groups = groupCinemaLibraryTitles([
    ...context,
    ...records.expand((m) => _recordTitles(m, history: history)),
    query,
  ]);
  final group = groups
      .where((g) => g.variants.any((v) => v.key == query.key))
      .firstOrNull;
  if (group == null) return {};
  final keys = group.variants.map((v) => v.key).toSet();
  return {
    for (final record in records)
      if (_recordTitles(
        record,
        history: history,
      ).any((v) => keys.contains(v.key)))
        _recordTitle(record, history: history).key,
  };
}

List<Map<String, dynamic>> _consolidateRecords(
  List<Map<String, dynamic>> originals, {
  required bool history,
  required List<CinemaTitle> context,
}) {
  final groups = groupCinemaLibraryTitles(context);
  final groupByKey = <String, int>{};
  for (var i = 0; i < groups.length; i++) {
    for (final title in groups[i].variants) {
      groupByKey[title.key] = i;
    }
  }
  final compact = <Map<String, dynamic>>[];
  final savedByGroup = <int, Set<int>>{};
  for (final original in originals) {
    final title = _recordTitle(original, history: history);
    final group = groupByKey[title.key];
    final matches = savedByGroup[group] ?? const <int>{};
    final int index;
    if (matches.length == 1) {
      index = matches.single;
      compact[index] = _mergeRecordDocuments(compact[index], [
        original,
      ], history: history);
    } else {
      // Multiple possible saved works must not be joined through weak metadata.
      index = compact.length;
      compact.add(original);
    }
    for (final identity in _recordTitles(original, history: history)) {
      final group = groupByKey[identity.key];
      if (group != null) savedByGroup.putIfAbsent(group, () => {}).add(index);
    }
  }
  return compact;
}

Map<String, dynamic> _mergeRecordDocuments(
  Map<String, dynamic> primary,
  Iterable<Map<String, dynamic>> others, {
  required bool history,
}) {
  var result = Map<String, dynamic>.of(primary)..remove(_workEntriesKey);
  final key = _recordTitle(primary, history: history).key;
  final archived = <String, Map<String, dynamic>>{};
  // Newer visible snapshots precede already archived snapshots for a source.
  final candidates = [
    ...others,
    ..._mergedEntries(primary),
    ...others.expand(_mergedEntries),
  ];
  for (final document in candidates) {
    final clean = Map<String, dynamic>.of(document)..remove(_workEntriesKey);
    final candidateKey = _recordTitle(clean, history: history).key;
    if (candidateKey == key) {
      result = _mergeKnownDocument(clean, result);
    } else {
      final newer = archived[candidateKey];
      archived[candidateKey] = newer == null
          ? clean
          : _mergeKnownDocument(clean, newer);
    }
  }
  if (archived.isNotEmpty) result[_workEntriesKey] = archived.values.toList();
  return result;
}

/// Preserve unrecognized fields on an existing entry while honoring every
/// explicit replacement (including removed headers/rules) in known fields.
Map<String, dynamic> _mergeKnownDocument(
  Map<String, dynamic>? old,
  Map<String, dynamic> fresh,
) {
  if (old == null) return fresh;
  final result = {...old, ...fresh};
  if (old['title'] is Map<String, dynamic> &&
      fresh['title'] is Map<String, dynamic>) {
    result['title'] = _mergeKnownDocument(
      old['title'] as Map<String, dynamic>,
      fresh['title'] as Map<String, dynamic>,
    );
  }
  for (final field in ['routes', 'episodes']) {
    if (old[field] is! List || fresh[field] is! List) continue;
    final previous = _strictMaps(old[field]);
    result[field] = _strictMaps(fresh[field]).map((entry) {
      final candidates = previous
          .where(
            (other) => field == 'episodes'
                ? other['url'] == entry['url']
                : other['name'] == entry['name'],
          )
          .toList();
      return candidates.length == 1
          ? _mergeKnownDocument(candidates.single, entry)
          : entry;
    }).toList();
  }
  return result;
}

List<Map<String, dynamic>> _strictMaps(Object? value) {
  if (value is! List || value.any((item) => item is! Map<String, dynamic>)) {
    throw const FormatException('影院资料列表包含无效条目，原文件已保留');
  }
  return value.map((item) => Map<String, dynamic>.from(item as Map)).toList();
}

void _stringField(
  Map<String, dynamic> map,
  String key, {
  bool required = false,
  bool nonempty = false,
}) {
  if (!map.containsKey(key) && !required) return;
  final value = map[key];
  if (value is! String || (nonempty && value.trim().isEmpty)) {
    throw FormatException('影院资料字段 $key 无效，原文件已保留');
  }
}

void _validateTitleMap(Map<String, dynamic> map) {
  for (final key in ['id', 'sourceId', 'title']) {
    _stringField(map, key, required: true, nonempty: true);
  }
  for (final key in [
    'poster',
    'description',
    'category',
    'categoryId',
    'year',
    'remarks',
  ]) {
    _stringField(map, key);
  }
  for (final route in _strictMaps(
    map.containsKey('routes') ? map['routes'] : const [],
  )) {
    _stringField(route, 'name', required: true);
    for (final episode in _strictMaps(route['episodes'])) {
      _stringField(episode, 'name', required: true);
      _stringField(episode, 'url', required: true, nonempty: true);
      requireHttpUrl(episode['url'] as String);
    }
  }
  CinemaTitle.fromJson(map);
}

Set<String> _readAppliedPacks(Map<String, dynamic> raw) {
  if (!raw.containsKey('appliedSourcePacks')) return {};
  final value = raw['appliedSourcePacks'];
  if (value is! List ||
      value.any((id) => id is! String || id.trim().isEmpty) ||
      value.toSet().length != value.length) {
    throw const FormatException('片源升级记录无效，原文件已保留');
  }
  return value.cast<String>().toSet();
}

Map<String, dynamic> _validatedLibrary(Object? value) {
  if (value is! Map<String, dynamic> || value['version'] != 1) {
    throw const FormatException('影院本地数据格式无法识别，原文件已保留');
  }
  final raw = Map<String, dynamic>.of(value);
  final ids = <String>{};
  for (final map in _strictMaps(raw['sources'])) {
    for (final key in ['id', 'name', 'kind', 'url']) {
      _stringField(map, key, required: true, nonempty: true);
    }
    _stringField(map, 'description');
    if ((map.containsKey('enabled') && map['enabled'] is! bool) ||
        (map['rule'] != null && map['rule'] is! Map<String, dynamic>)) {
      throw const FormatException('片源配置字段无效，原文件已保留');
    }
    if (map.containsKey('headers')) {
      final headers = map['headers'];
      if (headers is! Map<String, dynamic> ||
          headers.values.any((value) => value is! String)) {
        throw const FormatException('片源请求头资料无效，原文件已保留');
      }
    }
    final source = CinemaSource.fromJson(map);
    if (!ids.add(source.id)) {
      throw const FormatException('片源 ID 重复，原文件已保留');
    }
  }
  for (final title in _strictMaps(raw['favorites'])) {
    _validateTitleMap(title);
    for (final archived in _mergedEntries(title)) {
      _validateTitleMap(archived);
    }
  }
  final historyRecords = _strictMaps(raw['history']);
  for (final history in [
    ...historyRecords,
    ...historyRecords.expand(_mergedEntries),
  ]) {
    final title = history['title'];
    if (title is! Map<String, dynamic>) {
      throw const FormatException('观看记录影片资料无效，原文件已保留');
    }
    _validateTitleMap(title);
    for (final key in [
      'routeIndex',
      'episodeIndex',
      'positionSeconds',
      'durationSeconds',
    ]) {
      if (key == 'durationSeconds' && !history.containsKey(key)) continue;
      final number = history[key];
      if (number is! int || number < 0) {
        throw FormatException('观看记录字段 $key 无效，原文件已保留');
      }
    }
    _stringField(history, 'updatedAt', required: true);
    if (DateTime.tryParse(history['updatedAt'] as String) == null) {
      throw const FormatException('观看记录时间无效，原文件已保留');
    }
    CinemaHistory.fromJson(history);
  }
  _readAppliedPacks(raw);
  return raw;
}

void _validatePacks(List<CinemaSourcePack> packs) {
  final ids = <String>{};
  for (final pack in packs) {
    if (pack.id.trim().isEmpty || !ids.add(pack.id)) {
      throw const FormatException('片源升级包 ID 无效');
    }
    for (final source in pack.sources) {
      source.validate();
    }
  }
}

String _canonicalUrl(String value) {
  final uri = requireHttpUrl(value);
  final scheme = uri.scheme.toLowerCase();
  final keys = uri.queryParametersAll.keys.toList()..sort();
  return Uri(
    scheme: scheme,
    host: uri.host.toLowerCase(),
    port: uri.hasPort && uri.port != (scheme == 'https' ? 443 : 80)
        ? uri.port
        : null,
    path: uri.path.replaceFirst(RegExp(r'/+$'), ''),
    queryParameters: keys.isEmpty
        ? null
        : {for (final key in keys) key: uri.queryParametersAll[key]!},
  ).toString();
}

const cinema030SourcePack = CinemaSourcePack(
  id: 'cinema-sources-0.3.0',
  sources: [
    CinemaSource(
      id: 'maccms-jisu',
      name: '极速影视',
      kind: CinemaSourceKind.maccms,
      url: 'https://jszyapi.com/api.php/provide/vod/',
      description: '第三方目录 · 电影短样本 1920×808，非全片验证',
    ),
    CinemaSource(
      id: 'maccms-ruyi',
      name: '如意影视',
      kind: CinemaSourceKind.maccms,
      url: 'https://cj.rycjapi.com/api.php/provide/vod',
      description: '第三方目录 · 电影短样本 1920×808，非全片验证',
    ),
    CinemaSource(
      id: 'maccms-360',
      name: '360影视',
      kind: CinemaSourceKind.maccms,
      url: 'https://360zy.com/api.php/provide/vod',
      description: '第三方备用目录 · 剧集短样本 1920×1080，电影需另行核验',
    ),
  ],
);

const bundledCinemaSourcePacks = [cinema030SourcePack];

/// Public third-party catalogues verified on 2026-10-08. Availability and quality
/// are claims of each provider; these are not Netflix or studio endpoints.
final List<CinemaSource> bundledCinemaSources = [
  const CinemaSource(
    id: 'maccms-guangsu',
    name: '光速影视',
    kind: CinemaSourceKind.maccms,
    url: 'https://api.guangsuapi.com/api.php/provide/vod/',
    description: '第三方 MacCMS 目录 · 电影 / 剧集 / 动漫',
  ),
  const CinemaSource(
    id: 'maccms-modu',
    name: '魔都影视',
    kind: CinemaSourceKind.maccms,
    url: 'https://www.mdzyapi.com/api.php/provide/vod/',
    description: '第三方备用目录 · 短样本 1920×1080，非全片验证',
  ),
  const CinemaSource(
    id: 'maccms-haohua',
    name: '豪华影视',
    kind: CinemaSourceKind.maccms,
    url: 'https://hhzyapi.com/api.php/provide/vod/',
    description: '第三方备用目录 · 短样本 1920×808 宽银幕，非全片验证',
  ),
  const CinemaSource(
    id: 'maccms-wujin',
    name: '无尽影视',
    kind: CinemaSourceKind.maccms,
    url: 'https://api.wujinapi.me/api.php/provide/vod/',
    description: '第三方 MacCMS 目录 · 电影样本发现时间轴异常，请按片核验',
  ),
  ...cinema030SourcePack.sources,
  CinemaSource(
    id: 'kazumi-dm84',
    name: 'DM84',
    kind: CinemaSourceKind.kazumi,
    url: 'https://dmbus.cc/',
    description: 'Kazumi XPath 动漫搜索规则',
    rule:
        jsonDecode(r'''
{
  "api": "5",
  "type": "anime",
  "name": "DM84",
  "version": "1.4",
  "muliSources": true,
  "useWebview": true,
  "useNativePlayer": true,
  "userAgent": "",
  "adBlocker": true,
  "baseURL": "https://dmbus.cc/",
  "searchURL": "https://dmbus.cc/s----------.html?wd=@keyword",
  "searchList": "//div/div[3]/ul/li",
  "searchName": "//div/a[2]",
  "searchResult": "//div/a[2]",
  "chapterRoads": "//div/div[4]/div/ul",
  "chapterResult": "//li/a"
}
''')
            as Map<String, dynamic>,
  ),
  CinemaSource(
    id: 'kazumi-mxdm',
    name: 'MXdm',
    kind: CinemaSourceKind.kazumi,
    url: 'https://www.dcc3.com',
    description: 'Kazumi XPath 动漫搜索规则',
    rule:
        jsonDecode(r'''
{
  "api": "5",
  "type": "anime",
  "name": "MXdm",
  "version": "2.4",
  "muliSources": true,
  "useWebview": true,
  "useNativePlayer": true,
  "usePost": false,
  "useLegacyParser": false,
  "adBlocker": true,
  "userAgent": "",
  "baseURL": "https://www.dcc3.com",
  "searchURL": "https://www.dcc3.com/search/?wd=@keyword",
  "searchList": "//div[contains(@class, 'search')]/ul/li",
  "searchName": "//h3/a",
  "searchResult": "//h3/a",
  "chapterRoads": "//div[@class='playlist']/div[@class='row']/ul",
  "chapterResult": "//li/a"
}
''')
            as Map<String, dynamic>,
  ),
  CinemaSource(
    id: 'kazumi-moonci',
    name: 'moonci',
    kind: CinemaSourceKind.kazumi,
    url: 'https://www.moonci.com/',
    description: 'Kazumi XPath 动漫搜索规则',
    rule:
        jsonDecode(r'''
{
  "api": "8",
  "type": "anime",
  "name": "moonci",
  "version": "1.0",
  "muliSources": true,
  "useWebview": true,
  "useNativePlayer": true,
  "usePost": false,
  "useLegacyParser": false,
  "adBlocker": false,
  "userAgent": "",
  "baseURL": "https://www.moonci.com/",
  "searchURL": "https://www.moonci.com/search/-------------.html?wd=@keyword",
  "searchList": "//ul[contains(@class, 'hl-one-list')]/li[contains(@class, 'hl-list-item')]",
  "searchName": ".//div[contains(@class, 'hl-item-title')]/a",
  "searchResult": ".//div[contains(@class, 'hl-item-title')]/a",
  "chapterRoads": "//div[contains(@class, 'hl-play-source')]//ul[contains(@class, 'hl-plays-list')]",
  "chapterResult": ".//a[contains(@href, '/play/')]",
  "referer": "",
  "searchMode": "xpath",
  "chapterMode": "xpath",
  "antiCrawlerConfig": {
    "enabled": false,
    "captchaType": 1,
    "captchaImage": "",
    "captchaInput": "",
    "captchaButton": "",
    "captchaDetectType": 1,
    "captchaDetectValue": "",
    "captchaScript": ""
  }
}
''')
            as Map<String, dynamic>,
  ),
];
