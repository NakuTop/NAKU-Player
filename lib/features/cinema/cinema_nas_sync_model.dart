import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'cinema_models.dart';
import 'cinema_store.dart';
import 'package:kazumi/modules/history/history_sync.dart';

/// Portable, account-scoped LWW registers. Deletions remain as tombstones.
/// Each writer publishes immutable revisions; no shared-file read/modify/write.
class CinemaNASSyncState {
  CinemaNASSyncState(this.account, this.device);
  final String account, device;
  final Map<String, Map<String, dynamic>> entries = {};
  Map<String, dynamic> baseline = {};
  int clock = 0;
  bool initialized = false;
  static const kinds = ['cf:', 'ch:', 'af:', 'ah:'];

  static void validateRecord(String key, dynamic value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('同步条目格式无效');
    }
    if (key.startsWith('cf:') || key.startsWith('ch:')) {
      final history = key.startsWith('ch:');
      CinemaStore.validateBackup({
        'version': 1,
        'sources': [],
        'favorites': history ? [] : [value],
        'history': history ? [value] : [],
      });
      final title = history
          ? CinemaHistory.fromJson(value).title
          : CinemaTitle.fromJson(value);
      if (key.substring(3) != title.key) {
        throw const FormatException('同步影片身份不一致');
      }
    } else if (key.startsWith('ah:')) {
      if (HistorySyncCodec.historyFromJson(value).key != key.substring(3)) {
        throw const FormatException('同步动漫身份不一致');
      }
    } else if (key.startsWith('af:')) {
      final subject = HistorySyncCodec.bangumiItemFromJson(
        Map<String, dynamic>.from(value['subject'] as Map),
      );
      if ('${subject.id}' != key.substring(3) ||
          value['time'] is! int ||
          value['type'] is! int ||
          value['type'] < 1 ||
          value['type'] > 5) {
        throw const FormatException('同步收藏格式无效');
      }
    } else {
      throw const FormatException('未知同步条目');
    }
  }

  Map<String, Map<String, dynamic>> decode(String text) {
    if (utf8.encode(text).length > 8 * 1024 * 1024) {
      throw const FormatException('同步文件超过8MB');
    }
    final raw = jsonDecode(text);
    if (raw is! Map ||
        raw['format'] != 'NAKU-Account-Sync' ||
        raw['version'] != 1 ||
        raw['account'] != account ||
        raw['entries'] is! Map ||
        (raw['entries'] as Map).length > 50000) {
      throw const FormatException('同步文件账号或版本不匹配');
    }
    final result = <String, Map<String, dynamic>>{};
    for (final item in (raw['entries'] as Map).entries) {
      final k = item.key;
      final v = item.value;
      if (k is! String ||
          !kinds.any(k.startsWith) ||
          v is! Map ||
          v['clock'] is! int ||
          v['clock'] < 0 ||
          v['device'] is! String ||
          !RegExp(r'^[a-f0-9-]{36}$').hasMatch(v['device']) ||
          v['deleted'] is! bool) {
        throw const FormatException('同步版本格式无效');
      }
      if (v['deleted'] != true) validateRecord(k, v['value']);
      result[k] = Map<String, dynamic>.from(v);
    }
    return result;
  }

  void merge(Map<String, Map<String, dynamic>> incoming) {
    for (final item in incoming.entries) {
      final v = item.value;
      final old = entries[item.key];
      final order = old == null
          ? 1
          : (v['clock'] as int).compareTo(old['clock'] as int);
      if (order > 0 ||
          order == 0 &&
              (v['device'] as String).compareTo(old!['device'] as String) > 0) {
        entries[item.key] = v;
      }
      if ((v['clock'] as int) > clock) clock = v['clock'] as int;
    }
  }

  /// Compare with the last successfully applied local view, including removals.
  bool observe(Map<String, dynamic> current, {int? now}) {
    var changed = false;
    for (final key in {...baseline.keys, ...current.keys}) {
      final v = current[key];
      if (const DeepCollectionEqualityForSync().equals(v, baseline[key])) {
        continue;
      }
      if (v != null) validateRecord(key, v);
      // New installations seed historical timestamps, so they cannot resurrect
      // an older favorite deleted by an already synced device.
      int stamp;
      if (!initialized &&
          !baseline.containsKey(key) &&
          !entries.containsKey(key)) {
        stamp = switch (key.substring(0, 3)) {
          'ch:' =>
            DateTime.tryParse(
                  v?['updatedAt']?.toString() ?? '',
                )?.millisecondsSinceEpoch ??
                1,
          'ah:' => (v?['lastWatchTime'] is int ? v['lastWatchTime'] as int : 1),
          'af:' => v?['time'] is int ? v['time'] as int : 1,
          _ => 1,
        };
      } else {
        final time = now ?? DateTime.now().millisecondsSinceEpoch;
        stamp = time > clock ? time : clock + 1;
      }
      if (stamp > clock) clock = stamp;
      entries[key] = {
        'clock': stamp,
        'device': device,
        'deleted': v == null,
        if (v != null) 'value': jsonDecode(jsonEncode(v)),
      };
      changed = true;
    }
    initialized = true;
    baseline = jsonDecode(jsonEncode(current)) as Map<String, dynamic>;
    return changed;
  }

  Map<String, dynamic> get visible => {
    for (final item in entries.entries)
      if (item.value['deleted'] != true) item.key: item.value['value'],
  };
  String encode() => jsonEncode({
    'format': 'NAKU-Account-Sync',
    'version': 1,
    'account': account,
    'entries': entries,
  });
}

/// Order-independent JSON comparison (map insertion order differs across OSes).
class DeepCollectionEqualityForSync {
  const DeepCollectionEqualityForSync();
  bool equals(dynamic a, dynamic b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((k) => b.containsKey(k) && equals(a[k], b[k]));
    }
    if (a is List && b is List) {
      return listEquals(a, b) ||
          a.length == b.length &&
              List.generate(
                a.length,
                (i) => i,
              ).every((i) => equals(a[i], b[i]));
    }
    return a == b;
  }
}
