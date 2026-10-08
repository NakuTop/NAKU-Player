import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'cinema_models.dart';

/// A one-time addition of presets, independent of the user's current choices.
class CinemaSourcePack {
  const CinemaSourcePack({required this.id, required this.sources});

  final String id;
  final List<CinemaSource> sources;
}

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
        final favorites = _strictMaps(
          raw['favorites'],
        ).map(CinemaTitle.fromJson).toList();
        final history =
            _strictMaps(raw['history']).map(CinemaHistory.fromJson).toList()
              ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
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
          final upgraded = {
            ...raw,
            'sources': sourceMaps,
            'appliedSourcePacks': applied.toList(),
          };
          // Validate the full old document before creating either file. Keep
          // original favourites/history and unknown fields verbatim in JSON.
          await _backupBeforeSourceUpgrade(original);
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
        _favorites.addAll(favorites);
        _history.addAll(history);
      } else {
        for (final source in _defaults) {
          source.validate();
        }
        _validatePacks(_sourcePacks);
        _sources.addAll(_defaults);
        _appliedSourcePacks.addAll(_freshSourcePackIds);
      }
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
  bool isFavorite(CinemaTitle title) =>
      _favorites.any((item) => item.key == title.key);
  CinemaHistory? historyFor(CinemaTitle title) =>
      _history.where((item) => item.title.key == title.key).firstOrNull;

  Future<void> saveSource(CinemaSource source) async {
    source.validate();
    await load();
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
    _notify();
    await _persist();
  }

  Future<void> toggleFavorite(CinemaTitle title) async {
    await load();
    if (isFavorite(title)) {
      _favorites.removeWhere((item) => item.key == title.key);
    } else {
      _favorites.insert(0, title);
    }
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
    _history.removeWhere((item) => item.title.key == title.key);
    _history.insert(
      0,
      CinemaHistory(
        title: title,
        routeIndex: routeIndex,
        episodeIndex: episodeIndex,
        positionSeconds: positionSeconds,
        durationSeconds: durationSeconds,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
    if (_history.length > 200) _history.removeRange(200, _history.length);
    _notify();
    await _persist();
  }

  Future<void> removeHistory(CinemaTitle title) async {
    await load();
    _history.removeWhere((item) => item.title.key == title.key);
    _notify();
    await _persist();
  }

  Future<void> clearHistory() async {
    await load();
    _history.clear();
    _notify();
    await _persist();
  }

  Future<void> _persist() {
    final encoded = const JsonEncoder.withIndent('  ').convert({
      ..._libraryExtras,
      'version': 1,
      'sources': _sources.map((item) => item.toJson()).toList(),
      'favorites': _favorites.map((item) => item.toJson()).toList(),
      'history': _history.map((item) => item.toJson()).toList(),
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
  }
  for (final history in _strictMaps(raw['history'])) {
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
