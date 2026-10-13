import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:kazumi/modules/collect/collect_module.dart';
import 'package:kazumi/modules/history/history_sync.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/storage/history_storage_coordinator.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'cinema_models.dart';
import 'cinema_download_backup.dart';
import 'cinema_store.dart';
import 'cinema_website_store.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'package:kazumi/services/platform/secure_bookmark_service.dart';

class CinemaLibraryBackup {
  CinemaLibraryBackup(this.store, {this.plugins, Directory? support})
    : _support = support;
  final CinemaStore store;
  final PluginsController? plugins;
  Directory? _support;
  static const auxiliaryPaths = [
    'cinema/appearance-v1.json',
    'cinema/websites-v1.json',
    'cinema/douban-themes-v1.json',
    'cinema/ratings/ratings-v1.json',
    'cinema/watch-together-v1.json',
  ];
  Future<Directory> get support async =>
      _support ??= await getApplicationSupportDirectory();
  static String encode(Map<String, dynamic> data) {
    final digest = sha256.convert(utf8.encode(jsonEncode(data))).toString();
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'NAKU-Library',
      'version': 2,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'sha256': digest,
      'data': data,
    });
  }

  static Map<String, dynamic> decode(String text) {
    if (utf8.encode(text).length > 64 * 1024 * 1024) {
      throw const FormatException('备份超过 64MB');
    }
    final raw = jsonDecode(text);
    if (raw is! Map ||
        raw['format'] != 'NAKU-Library' ||
        raw['version'] != 2 ||
        raw['data'] is! Map) {
      throw const FormatException('不是 NAKU 2.0 片库备份');
    }
    final data = Map<String, dynamic>.from(raw['data']);
    if (sha256.convert(utf8.encode(jsonEncode(data))).toString() !=
        raw['sha256']) {
      throw const FormatException('备份校验失败，文件可能不完整');
    }
    CinemaStore.validateBackup(data['cinema']);
    if (data['settings'] is! Map ||
        data['animeHistory'] is! List ||
        data['animeFavorites'] is! List ||
        data['rules'] is! List ||
        data['auxiliary'] is! Map) {
      throw const FormatException('备份内容缺失');
    }
    GStorage.validatePortableSettings(
      Map<String, dynamic>.from(data['settings']),
    );
    CinemaDownloadBackup.decode(data['downloads']);
    for (final entry in jsonMaps(data['animeHistory'])) {
      HistorySyncCodec.historyFromJson(entry);
    }
    for (final entry in jsonMaps(data['animeFavorites'])) {
      HistorySyncCodec.bangumiItemFromJson(
        Map<String, dynamic>.from(entry['subject']),
      );
      if (entry['time'] is! int ||
          entry['type'] is! int ||
          entry['type'] < 1 ||
          entry['type'] > 5) {
        throw const FormatException('动漫收藏备份无效');
      }
    }
    if ((data['rules'] as List).length > 500) {
      throw const FormatException('动漫规则过多');
    }
    for (final entry in jsonMaps(data['rules'])) {
      Plugin.fromJson(entry);
    }
    if (data['danmakuFilters'] != null &&
        (data['danmakuFilters'] is! List ||
            (data['danmakuFilters'] as List).length > 5000 ||
            (data['danmakuFilters'] as List).any(
              (v) => v is! String || v.length > 500,
            ))) {
      throw const FormatException('弹幕屏蔽备份无效');
    }
    for (final entry in (data['auxiliary'] as Map).entries) {
      final matchFile =
          entry.key is String &&
          RegExp(
            r'^bilibili-danmaku/matches/[1-9][0-9]{0,7}\.json$',
          ).hasMatch(entry.key);
      if ((!auxiliaryPaths.contains(entry.key) && !matchFile) ||
          entry.value is! Map) {
        throw const FormatException('附加设置无效');
      }
      final value = entry.value as Map;
      if (!matchFile && value['version'] != 1) {
        throw const FormatException('附加设置版本无效');
      }
      if (matchFile) {
        if (value['reference'] is! String ||
            !RegExp(
              r'^(md|ss)[1-9][0-9]{0,17}$',
            ).hasMatch(value['reference']) ||
            value['offset'] is! int ||
            (value['offset'] as int).abs() > 2000 ||
            value['title'] is! String) {
          throw const FormatException('动漫弹幕匹配备份无效');
        }
      } else if (entry.key == 'cinema/ratings/ratings-v1.json') {
        if (value['bindings'] is! Map ||
            value['cache'] is! Map ||
            value['mappings'] is! Map) {
          throw const FormatException('评分关联备份无效');
        }
      } else if (entry.key == 'cinema/watch-together-v1.json') {
        if (value['paired'] != false &&
            (value['endpoint'] is! String ||
                parseSyncPlayEndPoint(value['endpoint']) == null ||
                value['room'] is! String ||
                (value['room'] as String).isEmpty ||
                (value['room'] as String).length > 35 ||
                value['username'] is! String ||
                (value['username'] as String).isEmpty ||
                (value['username'] as String).length > 16)) {
          throw const FormatException('配对备份无效');
        }
      } else if (entry.key == 'cinema/appearance-v1.json') {
        final opacity = value['backgroundOpacity'];
        if (opacity is! num ||
            !opacity.isFinite ||
            opacity < .22 ||
            opacity > 1) {
          throw const FormatException('外观备份无效');
        }
      } else if (entry.key == 'cinema/websites-v1.json') {
        if (value['sites'] is! List || value['restoreLastSite'] is! bool) {
          throw const FormatException('网站备份无效');
        }
        for (final item in jsonMaps(value['sites'])) {
          CinemaWebsite.fromJson(item);
        }
      } else if (value['topics'] is! Map ||
          (value['topics'] as Map).values.any(
            (v) => v is! List || v.any((t) => t is! String),
          )) {
        throw const FormatException('豆瓣主题备份无效');
      }
    }
    // Strict lists: never silently discard a malformed record during import.
    for (final name in ['animeHistory', 'animeFavorites', 'rules']) {
      if ((data[name] as List).any((v) => v is! Map)) {
        throw const FormatException('备份含无效条目');
      }
    }
    return data;
  }

  Future<Map<String, dynamic>> snapshot({bool credentials = false}) async {
    final root = await support;
    final auxiliary = <String, Object>{};
    for (final path in auxiliaryPaths) {
      if (path == 'cinema/watch-together-v1.json' && !credentials) continue;
      final file = File('${root.path}/$path');
      if (await file.exists()) {
        auxiliary[path] = jsonDecode(await file.readAsString());
      }
    }
    final matches = Directory('${root.path}/bilibili-danmaku/matches');
    if (await matches.exists()) {
      await for (final file in matches.list(followLinks: false)) {
        final name = file.uri.pathSegments.last;
        if (file is File &&
            RegExp(r'^[1-9][0-9]{0,7}\.json$').hasMatch(name) &&
            await file.length() <= 8192) {
          auxiliary['bilibili-danmaku/matches/$name'] = jsonDecode(
            await file.readAsString(),
          );
        }
      }
    }
    return {
      'cinema': await store.exportLibrary(),
      'settings': GStorage.exportPortableSettings(credentials: credentials),
      'animeHistory': GStorage.histories.values
          .map(HistorySyncCodec.historyToJson)
          .toList(),
      'animeFavorites': GStorage.collectibles.values
          .map(
            (v) => {
              'subject': HistorySyncCodec.bangumiItemToJson(v.bangumiItem),
              'time': v.time.millisecondsSinceEpoch,
              'type': v.type,
            },
          )
          .toList(),
      'danmakuFilters': GStorage.shieldList.values.toList(),
      'downloads': GStorage.downloads.values
          .map(CinemaDownloadBackup.encode)
          .toList(),
      'rules':
          plugins?.pluginList.map((p) => p.toJson()).toList() ??
          await _readRules(root),
      'auxiliary': auxiliary,
    };
  }

  Future<List<dynamic>> _readRules(Directory root) async {
    final file = File('${root.path}/plugins/v2/plugins.json');
    if (!await file.exists()) return [];
    final raw = jsonDecode(await file.readAsString());
    return raw is List
        ? raw
        : raw is Map && raw['plugins'] is List
        ? raw['plugins'] as List
        : [];
  }

  Future<String> export({bool credentials = false}) async =>
      encode(await snapshot(credentials: credentials));
  Future<File> restore(String text) async {
    final incoming = decode(text); // No mutation until every section is valid.
    final original = await snapshot(credentials: true);
    final root = await support;
    final rollback = File(
      '${root.path}/cinema/backups/pre-restore-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await rollback.parent.create(recursive: true);
    await rollback.writeAsString(encode(original), flush: true);
    try {
      await _apply(incoming, merge: true);
    } catch (_) {
      // A recovery file survives even if an I/O failure also prevents rollback.
      try {
        await _apply(original, merge: false);
      } catch (_) {}
      rethrow;
    }
    return rollback;
  }

  Future<void> _apply(Map<String, dynamic> data, {required bool merge}) async {
    await store.restoreLibrary(
      Map<String, dynamic>.from(data['cinema']),
      merge: merge,
    );
    await GStorage.importPortableSettings(
      Map<String, dynamic>.from(data['settings']),
    );
    await HistoryStorageCoordinator().run(() async {
      if (!merge) await GStorage.histories.clear();
      for (final entry in jsonMaps(data['animeHistory'])) {
        final history = HistorySyncCodec.historyFromJson(entry);
        final previous = GStorage.histories.get(history.key);
        final newer =
            previous != null &&
                previous.lastWatchTime.isAfter(history.lastWatchTime)
            ? previous
            : history;
        final progresses = {...?previous?.progresses, ...history.progresses};
        if (previous != null) {
          for (final p in previous.progresses.entries) {
            if ((progresses[p.key]?.updatedAtMs ?? 0) < p.value.updatedAtMs) {
              progresses[p.key] = p.value;
            }
          }
        }
        newer.progresses = progresses;
        await GStorage.histories.put(newer.key, newer);
      }
      await GStorage.histories.flush();
    });
    if (!merge) await GStorage.collectibles.clear();
    for (final entry in jsonMaps(data['animeFavorites'])) {
      final subject = HistorySyncCodec.bangumiItemFromJson(
        Map<String, dynamic>.from(entry['subject']),
      );
      final time = DateTime.fromMillisecondsSinceEpoch(entry['time'] as int);
      final old = GStorage.collectibles.get(subject.id);
      if (old == null || !old.time.isAfter(time)) {
        await GStorage.putCollectible(
          CollectedBangumi(subject, time, entry['type'] as int),
        );
      }
    }
    if (data['danmakuFilters'] is List) {
      final filters = {
        if (merge) ...GStorage.shieldList.values,
        ...(data['danmakuFilters'] as List).whereType<String>(),
      }.toList();
      if (!merge) await GStorage.shieldList.clear();
      await GStorage.shieldList.putAll({
        for (var i = 0; i < filters.length; i++) i: filters[i],
      });
      await GStorage.shieldList.flush();
    }
    final rules = jsonMaps(data['rules']).map(Plugin.fromJson).toList();
    if (plugins != null) {
      if (merge) {
        final existing = plugins!.pluginList.map((p) => p.name).toSet();
        await plugins!.updatePlugins(
          rules.where((p) => !existing.contains(p.name)).toList(),
        );
      } else {
        await plugins!.restoreBackupRules(rules);
      }
    } else {
      final root = await support;
      final current = merge ? await _readRules(root) : <dynamic>[];
      final combined = {
        for (final rule in rules) rule.name: rule.toJson(),
        for (final rule in current.whereType<Map>()) '${rule['name']}': rule,
      };
      final file = File('${root.path}/plugins/v2/plugins.json');
      await file.parent.create(recursive: true);
      await _atomic(file, combined.values.toList());
    }
    final root = await support;
    for (final entry in (data['auxiliary'] as Map).entries) {
      final file = File('${root.path}/${entry.key}');
      await file.parent.create(recursive: true);
      // On a fresh device include all auxiliary preferences. Local user settings
      // win on merge; avoid overwriting a live in-memory theme/catalogue.
      if (!merge || !await file.exists()) await _atomic(file, entry.value);
    }
    if (merge && data['downloads'] != null) {
      final custom = GStorage.getSetting(SettingsKeys.downloadDirectory).trim();
      final downloadRoot = custom.isNotEmpty
          ? await SecureBookmarkService.restore(custom) ??
                '${root.path}/downloads'
          : '${root.path}/downloads';
      final imported = CinemaDownloadBackup.decode(data['downloads']);
      // Validate/rebase every path before writing any download metadata.
      for (final record in imported) {
        await CinemaDownloadBackup.relocate(record, downloadRoot);
      }
      final combined = <String, DownloadRecord>{};
      for (final record in imported) {
        final current = GStorage.downloads.get(record.key);
        if (current != null) {
          for (final entry in current.episodes.entries) {
            final old = entry.value;
            final active = {
              DownloadStatus.pending,
              DownloadStatus.resolving,
              DownloadStatus.downloading,
            }.contains(old.status);
            if (active ||
                !record.episodes.containsKey(entry.key) ||
                old.status == DownloadStatus.completed &&
                    old.localM3u8Path.isNotEmpty &&
                    await File(old.localM3u8Path).exists()) {
              record.episodes[entry.key] = old;
            }
          }
        }
        combined[record.key] = record;
      }
      await GStorage.downloads.putAll(combined);
      await GStorage.downloads.flush();
    }
  }

  Future<void> _atomic(File file, Object? value) async {
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(value), flush: true);
    await temp.rename(file.path);
  }
}
