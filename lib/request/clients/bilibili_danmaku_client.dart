import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';

class BilibiliDanmakuPage {
  const BilibiliDanmakuPage(
    this.cid,
    this.name, {
    this.episodeNumber,
    this.duration = 0,
  });
  final int cid;
  final String name;
  final int? episodeNumber;
  final double duration;
}

class BilibiliAnimeCandidate {
  const BilibiliAnimeCandidate(
    this.reference,
    this.title, {
    this.originalTitle = '',
    this.year,
  });
  final String reference, title, originalTitle;
  final int? year;
}

class BilibiliDanmakuVideo {
  const BilibiliDanmakuVideo(this.title, this.pages, this.selectedIndex);
  final String title;
  final List<BilibiliDanmakuPage> pages;
  final int selectedIndex;
}

/// Only extracts identifiers from known public Bilibili URLs. The supplied URL
/// is never fetched, and cookies/application secrets are never attached.
class BilibiliDanmakuLink {
  const BilibiliDanmakuLink(this.kind, this.id, this.page);
  final String kind, id;
  final int page;
  static BilibiliDanmakuLink parse(String text) {
    final value = text.trim();
    final short = RegExp(
      r'^(BV[0-9A-Za-z]{10}|av[0-9]+|ep[0-9]+|ss[0-9]+|md[0-9]+)$',
    ).firstMatch(value);
    var id = short?.group(1);
    var page = 1;
    if (id == null) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !['https', 'http'].contains(uri.scheme) ||
          ![
            'www.bilibili.com',
            'm.bilibili.com',
            'bilibili.com',
          ].contains(uri.host) ||
          uri.userInfo.isNotEmpty ||
          (uri.hasPort && uri.port != 443 && uri.port != 80)) {
        throw const FormatException('请粘贴 B 站完整视频/番剧链接，或 BV、av、ep、ss、md 编号');
      }
      id = RegExp(
        r'^/(?:video/(BV[0-9A-Za-z]{10}|av[0-9]+)|bangumi/play/(ep[0-9]+|ss[0-9]+)|bangumi/media/(md[0-9]+))/?$',
      ).firstMatch(uri.path)?.groups([1, 2, 3]).whereType<String>().firstOrNull;
      page = int.tryParse(uri.queryParameters['p'] ?? '1') ?? 0;
    }
    if (id == null || page <= 0) throw const FormatException('视频链接或分 P 编号无效');
    final kind = id.substring(0, 2);
    final number = kind == 'BV' ? id : id.substring(2);
    if (kind != 'BV' && (int.tryParse(number) ?? 0) <= 0) {
      throw const FormatException('视频编号无效');
    }
    return BilibiliDanmakuLink(kind, number, page);
  }
}

class BilibiliDanmakuClient {
  BilibiliDanmakuClient({
    Dio? dio,
    Future<List<BilibiliAnimeCandidate>> Function(String)? animeSearchFallback,
  }) : _dio = dio,
       _animeSearchFallback = animeSearchFallback ?? _searchBundledCatalog;
  final Dio? _dio;
  final Future<List<BilibiliAnimeCandidate>> Function(String)
  _animeSearchFallback;
  static Future<List<dynamic>>? _catalog;

  static Future<List<BilibiliAnimeCandidate>> _searchBundledCatalog(
    String query,
  ) async {
    final catalog = await (_catalog ??= rootBundle
        .loadString('assets/data/bangumi_bilibili.json')
        .then(
          (value) => (jsonDecode(value) as Map)['catalog'] as List<dynamic>,
        ));
    String normalize(String value) => value.toLowerCase().replaceAll(
      RegExp(r'[^\p{L}\p{N}]', unicode: true),
      '',
    );
    final key = normalize(query);
    if (key.isEmpty) return const [];
    final matches = catalog.whereType<Map>().where(
      (row) => (row['names'] as List).whereType<String>().any(
        (name) =>
            normalize(name) == key ||
            (key.length >= 2 && normalize(name).contains(key)),
      ),
    );
    return [
      for (final row in matches.take(30))
        BilibiliAnimeCandidate(
          row['reference'] as String,
          row['title'] as String,
          originalTitle: row['originalTitle'] as String,
          year: row['year'] as int?,
        ),
    ];
  }

  Dio get _http => _dio ?? DioFactory.apiDio;
  static const _headers = {
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
        'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36',
    'Referer': 'https://www.bilibili.com/',
    'Accept-Encoding': 'identity',
  };

  Future<List<BilibiliAnimeCandidate>> searchAnime(
    String keyword, {
    CancelToken? cancelToken,
  }) => _search(keyword, cancelToken: cancelToken);

  Future<List<BilibiliAnimeCandidate>> searchFilms(
    String keyword, {
    CancelToken? cancelToken,
  }) => _search(keyword, cancelToken: cancelToken, films: true);

  Future<List<BilibiliAnimeCandidate>> _search(
    String keyword, {
    CancelToken? cancelToken,
    bool films = false,
  }) async {
    try {
      return await _searchRemote(
        keyword,
        cancelToken: cancelToken,
        films: films,
      );
    } catch (error) {
      if (films || cancelToken?.isCancelled == true || keyword.trim().isEmpty) {
        rethrow;
      }
      final local = await _animeSearchFallback(keyword.trim());
      if (local.isNotEmpty) return local;
      rethrow;
    }
  }

  Future<List<BilibiliAnimeCandidate>> _searchRemote(
    String keyword, {
    CancelToken? cancelToken,
    bool films = false,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) throw const FormatException('请输入动漫名称');
    final response = await _http.get<dynamic>(
      'https://api.bilibili.com/x/web-interface/search/type',
      queryParameters: {
        'search_type': films ? 'media_ft' : 'media_bangumi',
        'keyword': query.substring(0, query.length.clamp(0, 160)),
      },
      options: Options(
        headers: _headers,
        receiveTimeout: const Duration(seconds: 12),
      ),
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data is! Map || data['code'] != 0 || data['data'] is! Map) {
      throw const FormatException('B 站番剧搜索暂时不可用，请稍后重试');
    }
    final entries = data['data']['result'];
    if (entries is! List) return const [];
    return [
      for (final e in entries.take(30))
        if (e is Map && e['season_id'] is int && e['season_id'] > 0)
          BilibiliAnimeCandidate(
            'ss${e['season_id']}',
            html.parseFragment('${e['title'] ?? ''}').text ?? '',
            originalTitle:
                html.parseFragment('${e['org_title'] ?? ''}').text ?? '',
            year: e['pubtime'] is num && e['pubtime'] > 0
                ? DateTime.fromMillisecondsSinceEpoch(
                    (e['pubtime'] as num).toInt() * 1000,
                    isUtc: true,
                  ).year
                : null,
          ),
    ];
  }

  Future<BilibiliDanmakuVideo> video(
    String input, {
    CancelToken? cancelToken,
  }) async {
    var link = BilibiliDanmakuLink.parse(input);
    if (link.kind == 'md') {
      final response = await _http.get<dynamic>(
        'https://api.bilibili.com/pgc/review/user',
        queryParameters: {'media_id': link.id},
        options: Options(
          headers: _headers,
          receiveTimeout: const Duration(seconds: 12),
        ),
        cancelToken: cancelToken,
      );
      final data = response.data;
      final media = data is Map && data['code'] == 0 && data['result'] is Map
          ? data['result']['media']
          : null;
      final season = media is Map ? media['season_id'] : null;
      if (season is! int || season <= 0) {
        throw const FormatException('B 站未提供该番剧的分集资料');
      }
      link = BilibiliDanmakuLink('ss', '$season', 1);
    }
    final ugc = link.kind == 'BV' || link.kind == 'av';
    final response = await _http.get<dynamic>(
      'https://api.bilibili.com/${ugc ? 'x/web-interface/view' : 'pgc/view/web/season'}',
      queryParameters: {
        switch (link.kind) {
          'BV' => 'bvid',
          'av' => 'aid',
          'ep' => 'ep_id',
          _ => 'season_id',
        }: link.id,
      },
      options: Options(
        headers: _headers,
        receiveTimeout: const Duration(seconds: 15),
      ),
      cancelToken: cancelToken,
    );
    final data = response.data;
    if (data is! Map || data['code'] != 0) {
      throw const FormatException('B 站暂未提供该视频资料，请检查链接或稍后重试');
    }
    final detail = data[ugc ? 'data' : 'result'];
    if (detail is! Map) throw const FormatException('无法读取 B 站视频资料');
    final list = detail[ugc ? 'pages' : 'episodes'];
    final pages = <BilibiliDanmakuPage>[];
    var selection = 0;
    if (list is List) {
      for (final item in list.take(1000)) {
        if (item is! Map || item['cid'] is! int || item['cid'] <= 0) continue;
        if ((ugc && item['page'] == link.page) ||
            (!ugc &&
                link.kind == 'ep' &&
                '${item['id'] ?? item['ep_id']}' == link.id)) {
          selection = pages.length;
        }
        pages.add(
          BilibiliDanmakuPage(
            item['cid'] as int,
            ugc
                ? 'P${item['page']} · ${item['part'] ?? ''}'
                : '${item['title'] ?? ''} ${item['long_title'] ?? ''}'.trim(),
            episodeNumber: ugc
                ? item['page'] as int?
                : int.tryParse('${item['title']}'),
            duration: item['duration'] is num
                ? (item['duration'] as num).toDouble() / (ugc ? 1 : 1000)
                : 0,
          ),
        );
      }
    }
    if (pages.isEmpty || (ugc && link.page > pages.length)) {
      throw const FormatException('未找到这个视频的分集弹幕');
    }
    return BilibiliDanmakuVideo(
      '${detail['title'] ?? 'Bilibili 视频'}',
      pages,
      selection,
    );
  }

  Future<List<DanmakuEntry>> comments(
    int cid, {
    CancelToken? cancelToken,
  }) async {
    if (cid <= 0) throw const FormatException('弹幕编号无效');
    final response = await _http.get<ResponseBody>(
      'https://comment.bilibili.com/$cid.xml',
      options: Options(
        headers: _headers,
        responseType: ResponseType.stream,
        receiveTimeout: const Duration(seconds: 20),
      ),
      cancelToken: cancelToken,
    );
    final compressed = await _boundedBytes(response.data!.stream);
    var bytes = compressed;
    if (compressed.isNotEmpty && compressed.first != 60) {
      final encoding = response.headers.value('content-encoding');
      if (compressed.length >= 2 &&
          compressed[0] == 0x1f &&
          compressed[1] == 0x8b) {
        bytes = await _boundedBytes(
          gzip.decoder.bind(Stream.value(compressed)),
        );
      } else if (encoding == 'deflate') {
        try {
          bytes = await _boundedBytes(
            zlib.decoder.bind(Stream.value(compressed)),
          );
        } on FormatException {
          bytes = await _boundedBytes(
            ZLibDecoder(raw: true).bind(Stream.value(compressed)),
          );
        }
      }
    }
    final entries = await compute(parseLocalDanmaku, utf8.decode(bytes));
    for (final entry in entries) {
      entry.source = '[BiliBili]';
    }
    return entries;
  }

  Future<Uint8List> _boundedBytes(Stream<List<int>> stream) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxDanmakuImportBytes) {
        throw const FormatException('弹幕超过 8 MB，请使用较小的本地文件');
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}
