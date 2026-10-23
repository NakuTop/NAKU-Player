import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';

class CinemaDandanWork {
  const CinemaDandanWork(this.id, this.title, this.type);
  final int id;
  final String title, type;
}

class CinemaDandanEpisode {
  const CinemaDandanEpisode(this.id, this.title);
  final int id;
  final String title;
}

/// Only calls made by the viewer; bounded 2-hour catalogue/comment cache.
/// Episode IDs always come from the official catalogue, never concatenated IDs.
class CinemaDandanClient {
  CinemaDandanClient({DanmakuClient? client})
    : _client = client ?? DanmakuClient.instance;
  final DanmakuClient _client;
  static final _cache = <String, ({DateTime time, Object data, int bytes})>{};
  Future<dynamic> _get(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final key = '$path?${jsonEncode(query ?? const {})}';
    final cached = _cache[key];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(hours: 2)) {
      return cached.data;
    }
    final result = await _client.get(
      'https://api.dandanplay.net/api/v2/$path',
      queryParameters: query,
      cancelToken: cancelToken,
    );
    if (result is! Map || result['success'] == false) {
      throw const FormatException('弹弹play返回了错误，请检查应用凭据与配额');
    }
    // 8 MiB input bound also applies before storing a network response.
    final bytes = utf8.encode(jsonEncode(result)).length;
    if (bytes > maxDanmakuImportBytes) {
      throw const FormatException('弹幕数据超过 8 MB');
    }
    while (_cache.isNotEmpty &&
        (_cache.length >= 24 ||
            _cache.values.fold(0, (int count, row) => count + row.bytes) +
                    bytes >
                16 * 1024 * 1024)) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = (time: DateTime.now(), data: result, bytes: bytes);
    return result;
  }

  Future<List<CinemaDandanWork>> search(
    String title, {
    CancelToken? cancelToken,
  }) async {
    final text = title.trim();
    if (text.length < 2 ||
        text.length > 160 ||
        text.contains('://') ||
        RegExp(r'[/\\]').hasMatch(text)) {
      throw const FormatException('请输入 2–160 字的公开电影或剧名');
    }
    final data = await _get(
      'search/episodes',
      query: {'anime': text, 'v2': true},
      cancelToken: cancelToken,
    );
    final rows = data['animes'];
    if (rows is! List) throw const FormatException('弹弹play搜索结果无效');
    return [
      for (final row in rows.take(100))
        if (row is Map &&
            row['animeId'] is int &&
            row['animeId'] > 0 &&
            row['animeTitle'] is String)
          CinemaDandanWork(
            row['animeId'],
            '${row['animeTitle']}',
            '${row['typeDescription'] ?? ''}',
          ),
    ];
  }

  Future<List<CinemaDandanEpisode>> episodes(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw const FormatException('作品编号无效');
    final data = await _get('bangumi/$id', cancelToken: cancelToken);
    final rows = data['bangumi'] is Map ? data['bangumi']['episodes'] : null;
    if (rows is! List) throw const FormatException('弹弹play未提供该作品的分集');
    return [
      for (final row in rows.take(2000))
        if (row is Map &&
            row['episodeId'] is int &&
            row['episodeId'] > 0 &&
            row['episodeTitle'] is String)
          CinemaDandanEpisode(row['episodeId'], '${row['episodeTitle']}'),
    ];
  }

  Future<List<DanmakuEntry>> comments(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw const FormatException('弹幕库编号无效');
    final data = await _get(
      'comment/$id',
      query: {'withRelated': true, 'chConvert': 1},
      cancelToken: cancelToken,
    );
    if (data['comments'] is! List || (data['comments'] as List).isEmpty) {
      throw const FormatException('该集暂时没有弹幕，可尝试其他来源');
    }
    final entries = await compute(parseLocalDanmaku, jsonEncode(data));
    for (final entry in entries) {
      entry.source = '[弹弹play]';
    }
    return entries;
  }
}
