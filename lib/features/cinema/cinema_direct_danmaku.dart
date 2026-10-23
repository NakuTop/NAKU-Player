// SPDX-License-Identifier: AGPL-3.0-or-later
// Native protocol adapters informed by huangxd-/danmu_api (LogVar).
// See licenses/danmu_api/NOTICE and LICENSE for attribution and source.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:brotli/brotli.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'cinema_logvar_client.dart';
import 'cinema_media_identity.dart';
import 'cinema_bilibili_xml_window.dart';

const cinemaDirectDanmakuProviders = {
  'youku': '优酷',
  'qq': '腾讯视频',
  'qiyi': '爱奇艺',
  'imgo': '芒果TV',
  'bilibili1': 'Bilibili',
};

/// Extract only public page identifiers. No NAS URL, local file, signed media
/// query, browser cookie, user token or official Dandan credential is accepted.
Uri cinemaDirectDanmakuPage(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['http', 'https'].contains(uri.scheme) ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty ||
      value.length > 2048) {
    throw const FormatException('弹幕平台链接无效');
  }
  final host = uri.host.toLowerCase();
  const hosts = {
    'v.qq.com',
    'm.v.qq.com',
    'v.youku.com',
    'www.iqiyi.com',
    'm.iqiyi.com',
    'www.mgtv.com',
    'm.mgtv.com',
    'www.bilibili.com',
    'm.bilibili.com',
    'bilibili.com',
  };
  if (!hosts.contains(host)) throw const FormatException('弹幕平台不受支持');
  var path = uri.path;
  if (host == 'v.youku.com' && path == '/video') {
    final id = uri.queryParameters['vid'] ?? '';
    if (!RegExp(r'^[A-Za-z0-9=]{5,80}$').hasMatch(id)) {
      throw const FormatException('优酷视频编号无效');
    }
    path = '/v_show/id_$id.html';
  }
  if (path.length > 512 || path.length < 4 || path.contains('..')) {
    throw const FormatException('弹幕视频编号无效');
  }
  return Uri(scheme: 'https', host: host, path: path);
}

class _PublicEpisode {
  const _PublicEpisode(this.site, this.url);
  final String site, url;
}

class CinemaDirectDanmakuComments {
  const CinemaDirectDanmakuComments(
    this.entries, {
    this.duration = 0,
    this.partial = false,
    this.timeline,
    this.windowStart = 0,
    this.windowEnd = 0,
  });
  final List<DanmakuEntry> entries;
  final double duration;
  final bool partial;
  final CinemaDanmakuTimeline? timeline;
  final double windowStart, windowEnd;
}

/// A bounded per-player cache. Film length changes only the tiny index, not the
/// amount of comment text retained. A seek requests that position immediately.
class CinemaDirectDanmakuTimeline implements CinemaDanmakuTimeline {
  CinemaDirectDanmakuTimeline(
    this.starts,
    this.step,
    this.load, {
    required this.endSeconds,
  });
  final List<double> starts;
  final double step;
  final Future<List<DanmakuEntry>> Function(int, CancelToken?) load;
  @override
  final double endSeconds;
  final _cache = <int, List<DanmakuEntry>>{};
  bool _closed = false;
  @visibleForTesting
  int get cachedSegments => _cache.length;
  @visibleForTesting
  int get cachedEntries => _cache.values.fold(0, (n, rows) => n + rows.length);

  @override
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  }) async {
    if (_closed) throw StateError('弹幕分片已关闭');
    void check() {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (_closed) throw StateError('弹幕分片已关闭');
    }

    final near = position.clamp(0.0, endSeconds).toDouble();
    final indices = [
      for (var i = 0; i < starts.length; i++)
        if ((i + 1 < starts.length ? starts[i + 1] : endSeconds) > near - 30 &&
            starts[i] <= near + 150)
          i,
    ];
    if (indices.isEmpty) return CinemaDanmakuWindow([], near, endSeconds);
    var cursor = 0, successes = 0;
    final selected = <DanmakuEntry>[];
    Future<void> worker() async {
      while (cursor < indices.length) {
        check();
        final index = indices[cursor++];
        var entries = _cache.remove(index);
        if (entries == null) {
          for (var attempt = 0; attempt < 2; attempt++) {
            try {
              final rows = await load(index, cancelToken);
              check();
              // Keep a representative spread across a very dense segment.
              rows.sort((a, b) => a.time.compareTo(b.time));
              final stride = max(1, (rows.length / 2000).ceil());
              entries = [for (var n = 0; n < rows.length; n += stride) rows[n]];
              break;
            } catch (_) {
              check();
            }
          }
        }
        if (entries == null) continue;
        successes++;
        _cache[index] = entries;
        while (_cache.length > 6) {
          _cache.remove(_cache.keys.first);
        }
        selected.addAll(entries);
      }
    }

    await Future.wait(List.generate(min(3, indices.length), (_) => worker()));
    check();
    if (successes == 0) throw const FormatException('平台未返回当前时段弹幕');
    final seen = <String>{};
    final filtered =
        selected
            .where(
              (e) =>
                  e.time >= near - 30 &&
                  e.time <= near + 180 &&
                  e.message.length <= 120 &&
                  seen.add('${e.time}:${e.type}:${e.message}'),
            )
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    final stride = max(1, (filtered.length / 6000).ceil());
    final bounded = [
      for (var i = 0; i < filtered.length; i += stride) filtered[i],
    ];
    return CinemaDanmakuWindow(
      bounded,
      max(0.0, near - 30),
      min(endSeconds, near + 150),
      partial: successes < indices.length,
    );
  }

  @override
  void close() {
    _closed = true;
    _cache.clear();
  }
}

/// All requests run inside the player. No server process or localhost port.
class CinemaDirectDanmakuClient implements CinemaDanmakuMatcher {
  CinemaDirectDanmakuClient({Dio? dio, this.initialPosition = 0})
    : _dio = dio ?? DioFactory.createForConfig(_networkConfig());
  final Dio _dio;
  final double initialPosition;
  final _timelines = <CinemaDanmakuTimeline>[];
  bool _closed = false;
  static NetworkConfig _networkConfig() {
    try {
      return NetworkConfig.fromSettings(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 10),
      ).copyWith(enableLog: false, allowBadCertificates: false);
    } catch (_) {
      return const NetworkConfig(
        connectTimeout: Duration(seconds: 5),
        receiveTimeout: Duration(seconds: 10),
        enableLog: false,
      );
    }
  }

  static const _headers = {
    'User-Agent': 'Mozilla/5.0',
    'Accept-Encoding': 'identity',
  };
  void _check(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
    if (_closed) throw StateError('弹幕请求已关闭');
  }

  Future<({Uint8List bytes, Headers headers, int status})> _request(
    String url, {
    Map<String, dynamic>? query,
    CancelToken? token,
    Map<String, dynamic>? headers,
    String? form,
    bool allow404 = false,
    int maximumBytes = 2 * 1024 * 1024,
  }) async {
    _check(token);
    final response = await _dio.request<ResponseBody>(
      url,
      queryParameters: query,
      data: form,
      cancelToken: token,
      options: Options(
        method: form == null ? 'GET' : 'POST',
        responseType: ResponseType.stream,
        followRedirects: false,
        headers: {..._headers, ...?headers},
        validateStatus: (s) => s == 200 || (allow404 && s == 404),
      ),
    );
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      _check(token);
      if (body.length + chunk.length > maximumBytes) {
        throw const FormatException('平台弹幕数据过大');
      }
      body.add(chunk);
    }
    return (
      bytes: body.takeBytes(),
      headers: response.headers,
      status: response.statusCode!,
    );
  }

  Future<Map<String, dynamic>> _json(
    String url, {
    Map<String, dynamic>? query,
    CancelToken? token,
    Map<String, dynamic>? headers,
    String? form,
    bool allow404 = false,
  }) async {
    final response = await _request(
      url,
      query: query,
      token: token,
      headers: headers,
      form: form,
      allow404: allow404,
    );
    if (response.status == 404) return {};
    final decoded = jsonDecode(utf8.decode(response.bytes));
    if (decoded is! Map<String, dynamic>) throw const FormatException('平台响应无效');
    return decoded;
  }

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    final title = query.title.trim();
    if (title.length < 2 ||
        title.length > 160 ||
        title.contains('://') ||
        RegExp(r'[/\\\r\n]').hasMatch(title) ||
        query.episode < 1 ||
        query.season < 1) {
      throw const FormatException('公开片名或集数无效');
    }
    onProgress?.call('正在查找 ${query.label} 的平台弹幕');
    final keyword = query.series && query.season > 1
        ? '$title 第${query.season}季'
        : cinemaMediaBaseTitle(title);
    List raw = const [];
    // The public catalogue can return code=0 with an empty longData from a
    // stale edge cache. Retry that response once with a fresh cache key; never
    // loosen title/year identity or substitute short videos to fill the gap.
    for (var attempt = 0; attempt < 2; attempt++) {
      _check(cancelToken);
      final response = await _json(
        'https://api.so.360kan.com/index',
        query: {
          'force_v': '1',
          'kw': keyword,
          'from': '',
          'pageno': '1',
          'v_ap': '1',
          'tab': 'all',
          if (attempt > 0) '_': '${DateTime.now().microsecondsSinceEpoch}',
        },
        token: cancelToken,
      );
      final data = response['data'];
      final rows = data is Map && data['longData'] is Map
          ? data['longData']['rows']
          : null;
      raw = rows is List ? rows : const [];
      if (raw.isNotEmpty) break;
      if (attempt == 0) onProgress?.call('正在复查平台电影与剧集目录');
    }
    final matches = <({CinemaLogvarWork work, Map row})>[];
    for (final row in raw.take(100)) {
      if (row is! Map) continue;
      final work = CinemaLogvarWork(
        id: int.tryParse('${row['id']}') ?? 1,
        title: '${row['titleTxt'] ?? ''}',
        type: '${row['cat_name'] ?? ''}',
        year: '${row['year'] ?? ''}',
        source: '360kan',
      );
      // Official long/short title, kept explicit rather than fuzzy substring matching.
      final canonical = work.title == '后宫甄嬛传' && title == '甄嬛传'
          ? CinemaLogvarWork(
              id: work.id,
              title: title,
              type: work.type,
              year: work.year,
            )
          : work;
      if (cinemaLogvarWorkMatches(query, canonical)) {
        matches.add((work: work, row: row));
      }
    }
    final dub = cinemaMediaDub(title);
    if (!query.series) {
      int rank(CinemaLogvarWork work) =>
          cinemaMediaDub(work.title) == dub ? 0 : 1;
      matches.sort((a, b) => rank(a.work).compareTo(rank(b.work)));
    }
    if (query.year.isEmpty &&
        matches
                .map((r) => r.work.year)
                .where((v) => v.isNotEmpty)
                .toSet()
                .length >
            1) {
      throw const FormatException('找到不同年份的同名作品，未自动加载以免匹配错误');
    }
    var failed = false;
    CinemaLogvarSelection? emptyWindow;
    for (final candidate in matches.take(3)) {
      // Prefer a lightweight native JSON source; fall back to another exact work.
      final links = candidate.row['playlinks'];
      for (final site in cinemaDirectDanmakuProviders.keys) {
        _check(cancelToken);
        if (links is! Map || links[site] is! String) continue;
        try {
          final page = await _episode(candidate.row, site, query, cancelToken);
          if (page == null) continue;
          onProgress?.call(
            '正在获取${cinemaDirectDanmakuProviders[site]} · ${query.series ? '第${query.episode}集' : '正片'}弹幕',
          );
          final comments = await loadPage(
            page.url,
            token: cancelToken,
            episodeNumber: query.series ? query.episode : null,
          );
          if (comments.entries.isEmpty && comments.timeline == null) continue;
          final selection = CinemaLogvarSelection(
            candidate.work,
            CinemaLogvarEpisode(
              query.episode,
              query.series ? '第${query.episode}集' : '正片',
              query.episode,
            ),
            comments.entries,
            comments.duration,
            provider: cinemaDirectDanmakuProviders[site]!,
            partial: comments.partial,
            timeline: comments.timeline,
            windowStart: comments.windowStart,
            windowEnd: comments.windowEnd,
          );
          if (comments.entries.isEmpty) {
            emptyWindow ??= selection;
            continue;
          }
          for (final other in _timelines) {
            if (!identical(other, comments.timeline)) other.close();
          }
          return selection;
        } catch (e) {
          _check(cancelToken);
          failed = true;
        }
      }
    }
    if (emptyWindow != null) {
      for (final other in _timelines) {
        if (!identical(other, emptyWindow.timeline)) other.close();
      }
      return emptyWindow;
    }
    if (failed) throw const FormatException('已找到作品，平台弹幕暂时不可用；下次播放会自动重试');
    return null;
  }

  Future<_PublicEpisode?> _episode(
    Map row,
    String site,
    CinemaLogvarQuery query,
    CancelToken? token,
  ) async {
    if (!query.series) return _PublicEpisode(site, '${row['playlinks'][site]}');
    String? fromList(dynamic list) {
      if (list is! List || query.episode > list.length) return null;
      final item = list[query.episode - 1];
      final value = item is Map ? item['url'] : item;
      if (value is! String || !value.startsWith('http')) return null;
      final normalized = cinemaDirectDanmakuPage(value);
      // Some catalogues repeat a series landing page for every episode.
      if (list.where((e) {
            final v = e is Map ? e['url'] : e;
            if (v is! String || !v.startsWith('http')) return false;
            try {
              return cinemaDirectDanmakuPage(v) == normalized;
            } catch (_) {
              return false;
            }
          }).length >
          1) {
        return null;
      }
      return value;
    }

    if (row['seriesSite'] == site) {
      final direct = fromList(row['seriesPlaylinks']);
      if (direct != null) return _PublicEpisode(site, direct);
    }
    final cat = '${row['cat_id'] ?? (row['cat_name'] == '动漫' ? 4 : 2)}';
    final id = '${row['en_id'] ?? ''}';
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(id)) return null;
    final response = await _json(
      'https://api.so.360kan.com/episodesv2',
      query: {
        'v_ap': '1',
        's': jsonEncode([
          {'cat_id': cat, 'ent_id': id, 'site': site},
        ]),
      },
      token: token,
    );
    final rows = response['data'];
    if (rows is List && rows.isNotEmpty && rows.first is Map) {
      final series = rows.first['seriesHTML'];
      if (series is Map) {
        final value = fromList(
          series['seriesPlaylinks'] ?? series['series_playlinks'],
        );
        if (value != null) return _PublicEpisode(site, value);
      }
    }
    final start = ((query.episode - 1) ~/ 200) * 200 + 1;
    final detail = await _json(
      'https://api.web.360kan.com/v1/detail',
      query: {
        'cat': cat,
        'id': id,
        'site': site,
        'start': '$start',
        'end': '${start + 199}',
      },
      token: token,
    );
    final d = detail['data'];
    final episodes = d is Map && d['allepidetail'] is Map
        ? d['allepidetail'][site]
        : null;
    final choices = episodes is List
        ? episodes
              .whereType<Map>()
              .where(
                (e) => int.tryParse('${e['playlink_num']}') == query.episode,
              )
              .toList()
        : <Map>[];
    return choices.length == 1 && choices.single['url'] is String
        ? _PublicEpisode(site, choices.single['url'])
        : null;
  }

  /// Public for platform diagnostics; normal playback uses validated catalogue matching.
  Future<CinemaDirectDanmakuComments> loadPage(
    String value, {
    CancelToken? token,
    int? episodeNumber,
  }) async {
    final page = cinemaDirectDanmakuPage(value);
    final host = page.host;
    final result = host.endsWith('qq.com')
        ? await _tencent(page, token)
        : host.endsWith('youku.com')
        ? await _youku(page, token)
        : host.endsWith('iqiyi.com')
        ? await _iqiyi(page, token)
        : host.endsWith('mgtv.com')
        ? await _mango(page, token)
        : await _bilibili(page, token, episodeNumber);
    _check(token);
    final seen = <String>{};
    final valid =
        result.entries
            .where(
              (e) =>
                  e.time.isFinite &&
                  e.time >= 0 &&
                  e.time < 24 * 3600 &&
                  e.message.isNotEmpty &&
                  e.message.length <= 120 &&
                  seen.add(
                    '${e.time.toStringAsFixed(2)}:${e.type}:${e.message}',
                  ),
            )
            .take(80000)
            .toList()
          ..sort((a, b) => a.time.compareTo(b.time));
    return CinemaDirectDanmakuComments(
      valid,
      duration: result.duration,
      partial: result.partial,
      timeline: result.timeline,
      windowStart: result.windowStart,
      windowEnd: result.windowEnd,
    );
  }

  Future<CinemaDirectDanmakuComments> _segments(
    int count,
    Future<List<DanmakuEntry>> Function(int, CancelToken?) load,
    CancelToken? token, {
    double duration = 0,
    double step = 60,
    List<double>? starts,
  }) async {
    if (count < 0 || count > 1500) throw const FormatException('弹幕分片数量无效');
    if (count == 0) return const CinemaDirectDanmakuComments([]);
    final timeline = CinemaDirectDanmakuTimeline(
      starts ?? List.generate(count, (i) => i * step),
      step,
      load,
      endSeconds: duration > 0
          ? duration
          : (starts?.last ?? (count - 1) * step) + step,
    );
    _timelines.add(timeline);
    final window = await timeline.window(initialPosition, cancelToken: token);
    return CinemaDirectDanmakuComments(
      window.entries,
      duration: duration,
      partial: window.partial,
      timeline: timeline,
      windowStart: window.start,
      windowEnd: window.end,
    );
  }

  DanmakuEntry? _entry(
    dynamic time,
    dynamic text,
    String source, {
    int color = 0xffffff,
    int type = 1,
  }) {
    final seconds = double.tryParse('$time');
    if (seconds == null ||
        !seconds.isFinite ||
        seconds < 0 ||
        text is! String) {
      return null;
    }
    final message = RegExp(r'[<>&]').hasMatch(text)
        ? html.parseFragment(text).text?.trim() ?? ''
        : text.trim();
    if (message.isEmpty || message.length > 120) return null;
    return DanmakuEntry(
      time: seconds,
      message: message,
      type: type,
      color: Color(0xff000000 | (color & 0xffffff)),
      source: '[$source]',
    );
  }

  Map _map(dynamic value) {
    if (value is Map) return value;
    if (value is String) {
      try {
        final d = jsonDecode(value);
        if (d is Map) return d;
      } catch (_) {}
    }
    return const {};
  }

  int _color(dynamic value, {int radix = 16}) =>
      int.tryParse(
        '$value'.replaceFirst('#', '').replaceFirst('0x', ''),
        radix: radix,
      ) ??
      0xffffff;

  Future<CinemaDirectDanmakuComments> _tencent(
    Uri page,
    CancelToken? token,
  ) async {
    final vid = RegExp(
      r'/([a-zA-Z0-9]{8,20})\.html$',
    ).firstMatch(page.path)?[1];
    if (vid == null) throw const FormatException('腾讯视频编号无效');
    final base = await _json(
      'https://dm.video.qq.com/barrage/base/$vid',
      token: token,
      allow404: true,
    );
    final index = base['segment_index'];
    final segments = index is Map
        ? index.values.whereType<Map>().toList()
        : <Map>[];
    segments.sort(
      (a, b) => (double.tryParse('${a['segment_start']}') ?? 0).compareTo(
        double.tryParse('${b['segment_start']}') ?? 0,
      ),
    );
    return _segments(
      segments.length,
      (i, token) async {
        final name = '${segments[i]['segment_name'] ?? ''}';
        if (!RegExp(r'^[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*$').hasMatch(name)) {
          throw const FormatException('弹幕分片编号无效');
        }
        final json = await _json(
          'https://dm.video.qq.com/barrage/segment/$vid/$name',
          token: token,
        );
        final rows = json['barrage_list'];
        if (rows is! List) throw const FormatException('腾讯弹幕响应无效');
        return [
          for (final row in rows.whereType<Map>())
            ?_entry(
              (double.tryParse('${row['time_offset']}') ?? -1000) / 1000,
              row['content'],
              '腾讯视频',
              color: _color(_map(row['content_style'])['color']),
              type: _map(row['content_style'])['position'] == 2
                  ? 5
                  : _map(row['content_style'])['position'] == 3
                  ? 4
                  : 1,
            ),
        ];
      },
      token,
      step: (double.tryParse('${base['segment_span']}') ?? 30000) / 1000,
      starts: [
        for (var i = 0; i < segments.length; i++)
          (double.tryParse('${segments[i]['segment_start']}') ?? i * 30000) /
              1000,
      ],
    );
  }

  Future<CinemaDirectDanmakuComments> _youku(
    Uri page,
    CancelToken? token,
  ) async {
    final vid = RegExp(
      r'/v_show/id_([A-Za-z0-9=]{5,80})\.html$',
    ).firstMatch(page.path)?[1];
    if (vid == null) throw const FormatException('优酷视频编号无效');
    final info = await _json(
      'https://openapi.youku.com/v2/videos/show.json',
      query: {
        'client_id': '53e6cc67237fc59a',
        'video_id': vid,
        'package': 'com.huawei.hwvplayer.youku',
        'ext': 'show',
      },
      token: token,
    );
    final duration = double.tryParse('${info['duration']}') ?? 0;
    if (duration <= 0 || duration > 12 * 3600) {
      throw const FormatException('优酷未返回正片时长');
    }
    String? tk, enc;
    Future<void>? renewing;
    Future<void> renew(CancelToken? requestToken) {
      if (renewing != null) return renewing!;
      final next = () async {
        final response = await _request(
          'https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/',
          query: {'jsv': '2.5.1', 'appKey': '24679788'},
          token: requestToken,
        );
        final cookies = response.headers['set-cookie']?.join(';') ?? '';
        final fresh = RegExp(
          r'(?:^|[;,]\s*)_m_h5_tk=([^; ,]+)',
        ).firstMatch(cookies)?[1];
        final freshEnc = RegExp(
          r'(?:^|[;,]\s*)_m_h5_tk_enc=([^; ,]+)',
        ).firstMatch(cookies)?[1];
        if (fresh == null || freshEnc == null) {
          throw const FormatException('优酷临时访问凭据不可用');
        }
        tk = fresh;
        enc = freshEnc;
      }();
      renewing = next.whenComplete(() {
        renewing = null;
      });
      return renewing!;
    }

    await renew(token);
    // Ephemeral anonymous client identifier; never shared with another platform.
    final guid = base64Url.encode(
      List.generate(18, (_) => Random.secure().nextInt(256)),
    );
    String digest(String s) => md5.convert(utf8.encode(s)).toString();
    return _segments(
      (duration / 60).ceil(),
      (i, token) async {
        final signedToken = tk!, signedEncoding = enc!;
        final now = DateTime.now().millisecondsSinceEpoch;
        final msg = <String, dynamic>{
          'ctime': now,
          'ctype': 10004,
          'cver': 'v1.0',
          'guid': guid,
          'mat': i,
          'mcount': 1,
          'pid': 0,
          'sver': '3.1.0',
          'type': 1,
          'vid': vid,
        };
        final encoded = base64.encode(utf8.encode(jsonEncode(msg)));
        msg['msg'] = encoded;
        msg['sign'] = digest('${encoded}MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr');
        final body = jsonEncode(msg);
        final json = await _json(
          'https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/',
          query: {
            'jsv': '2.5.6',
            'appKey': '24679788',
            't': '$now',
            'sign': digest(
              '${signedToken.split('_').first}&$now&24679788&$body',
            ),
            'api': 'mopen.youku.danmu.list',
            'v': '1.0',
            'type': 'originaljson',
            'dataType': 'jsonp',
          },
          token: token,
          form: Uri(queryParameters: {'data': body}).query,
          headers: {
            'Cookie': '_m_h5_tk=$signedToken;_m_h5_tk_enc=$signedEncoding;',
            'Referer': 'https://v.youku.com/',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        );
        final result = _map(_map(json['data'])['result']);
        final rows = _map(result['data'])['result'];
        if (rows is! List) {
          if ('${json['ret']}'.contains('TOKEN') && signedToken == tk) {
            await renew(token);
          }
          throw const FormatException('优酷弹幕响应无效');
        }
        return [
          for (final row in rows.whereType<Map>())
            ?_entry(
              (double.tryParse('${row['playat']}') ?? -1000) / 1000,
              row['content'],
              '优酷',
              color: _color(_map(row['propertis'])['color'], radix: 10),
              type: _map(row['propertis'])['pos'] == 1
                  ? 5
                  : _map(row['propertis'])['pos'] == 2
                  ? 4
                  : 1,
            ),
        ];
      },
      token,
      duration: duration,
    );
  }

  Future<CinemaDirectDanmakuComments> _iqiyi(
    Uri page,
    CancelToken? token,
  ) async {
    final opaque = RegExp(r'/v_(\w+)\.html$').firstMatch(page.path)?[1];
    if (opaque == null) throw const FormatException('爱奇艺视频编号无效');
    final decoded = await _json(
      'https://pcw-api.iq.com/api/decode/$opaque',
      query: {'platformId': '3', 'modeCode': 'intl', 'langCode': 'sg'},
      token: token,
    );
    var id = '${decoded['data'] ?? ''}';
    if (!RegExp(r'^\d{1,30}$').hasMatch(id)) {
      throw const FormatException('爱奇艺未提供视频编号');
    }
    Map info = _map(
      (await _json(
        'https://pcw-api.iqiyi.com/video/video/baseinfo/$id',
        token: token,
      ))['data'],
    );
    if ((double.tryParse('${info['durationSec']}') ?? 0) <= 0 && id != opaque) {
      id = opaque;
      info = _map(
        (await _json(
          'https://pcw-api.iqiyi.com/video/video/baseinfo/$id',
          token: token,
        ))['data'],
      );
    }
    final duration = double.tryParse('${info['durationSec']}') ?? 0;
    if (info['displayBarrage'] == false) {
      return const CinemaDirectDanmakuComments([]);
    }
    if (duration <= 0) throw const FormatException('爱奇艺未提供时长');
    final padded = id.padLeft(4, '0');
    final path =
        '${padded.substring(padded.length - 4, padded.length - 2)}/${padded.substring(padded.length - 2)}';
    return _segments(
      (duration / 60).ceil(),
      (i, token) async {
        final hash = md5
            .convert(utf8.encode('${id}_60_${i + 1}cbzuw1259a'))
            .toString()
            .substring(24);
        final response = await _request(
          'https://cmts.iqiyi.com/bullet/$path/${id}_60_${i + 1}_$hash.br',
          token: token,
          allow404: true,
        );
        if (response.status == 404) return [];
        final rows = await compute(decodeCinemaIqiyiDanmaku, response.bytes);
        return [
          for (final row in rows)
            ?_entry(
              row['time'],
              row['text'],
              '爱奇艺',
              color: _color(row['color']),
            ),
        ];
      },
      token,
      duration: duration,
    );
  }

  Future<CinemaDirectDanmakuComments> _mango(
    Uri page,
    CancelToken? token,
  ) async {
    final match = RegExp(r'/(\d+)/(\d+)\.html$').firstMatch(page.path);
    if (match == null) throw const FormatException('芒果视频编号无效');
    final params = {'cid': match[1]!, 'vid': match[2]!};
    final info = await _json(
      'https://pcweb.api.mgtv.com/video/info',
      query: params,
      token: token,
    );
    final time = '${_map(_map(info['data'])['info'])['time'] ?? ''}';
    var duration = 0.0;
    for (final n in time.split(':')) {
      duration = duration * 60 + (double.tryParse(n) ?? 0);
    }
    if (duration <= 0) throw const FormatException('芒果未提供视频时长');
    final control = await _json(
      'https://galaxy.bz.mgtv.com/getctlbarrage',
      query: {
        ...params,
        'version': '8.1.39',
        'abroad': '0',
        'uuid': '',
        'os': '10.15.7',
        'platform': '0',
        'mac': '',
        'pid': '',
        'ticket': '',
      },
      token: token,
    );
    final d = _map(control['data']);
    final cdn = '${d['cdn_list'] ?? ''}'.split(',').first;
    final version = '${d['cdn_version'] ?? ''}';
    final useCDN =
        RegExp(r'^[a-zA-Z0-9.-]+\.(?:mgtv|hunantv|hitv)\.com$').hasMatch(cdn) &&
        RegExp(r'^[a-zA-Z0-9/_-]{1,200}$').hasMatch(version) &&
        !version.contains('..');
    return _segments(
      (duration / 60).ceil(),
      (i, token) async {
        final json = useCDN
            ? await _json(
                'https://$cdn/$version/$i.json',
                token: token,
                allow404: true,
              )
            : await _json(
                'https://galaxy.bz.mgtv.com/rdbarrage',
                query: {...params, 'time': '${i * 60000}'},
                token: token,
              );
        final rows = _map(json['data'])['items'];
        if (rows == null && json.isEmpty) return [];
        if (rows is! List) throw const FormatException('芒果弹幕响应无效');
        return [
          for (final row in rows.whereType<Map>())
            ?_entry(
              (double.tryParse('${row['time']}') ?? -1000) / 1000,
              row['content'],
              '芒果TV',
              color: _color(row['v2_color']),
              type: row['v2_position'] == 1
                  ? 5
                  : row['v2_position'] == 2
                  ? 4
                  : 1,
            ),
        ];
      },
      token,
      duration: duration,
    );
  }

  Future<CinemaDirectDanmakuComments> _bilibili(
    Uri page,
    CancelToken? token,
    int? episodeNumber,
  ) async {
    final client = BilibiliDanmakuClient(dio: _dio);
    final video = await client.video(page.toString(), cancelToken: token);
    final choices = episodeNumber == null
        ? [video.pages[video.selectedIndex]]
        : video.pages.where((p) => p.episodeNumber == episodeNumber).toList();
    if (choices.length != 1) {
      throw const FormatException('Bilibili 分集编号不明确，未加载以免错集');
    }
    final selected = choices.single;
    if (selected.duration <= 0) throw const FormatException('Bilibili 未提供分片时长');
    try {
      return await _segments(
        (selected.duration / 360).ceil(),
        (i, token) async {
          final response = await _request(
            'https://api.bilibili.com/x/v2/dm/web/seg.so',
            query: {
              'type': '1',
              'oid': '${selected.cid}',
              'segment_index': '${i + 1}',
            },
            headers: {'Referer': 'https://www.bilibili.com/'},
            token: token,
          );
          final rows = await compute(
            decodeCinemaBilibiliDanmaku,
            response.bytes,
          );
          return [
            for (final r in rows)
              ?_entry(
                r['time'],
                r['text'],
                'Bilibili',
                color: r['color'] as int,
                type: r['type'] as int,
              ),
          ];
        },
        token,
        duration: selected.duration,
        step: 360,
      );
    } on FormatException {
      _check(token);
      final response = await _request(
        'https://comment.bilibili.com/${selected.cid}.xml',
        headers: {'Referer': 'https://www.bilibili.com/'},
        token: token,
        maximumBytes: 4 * 1024 * 1024,
      );
      final timeline = CinemaBilibiliXmlTimeline(
        response.bytes,
        response.headers.value('content-encoding') ?? '',
        selected.duration,
      );
      _timelines.add(timeline);
      final window = await timeline.window(initialPosition, cancelToken: token);
      return CinemaDirectDanmakuComments(
        window.entries,
        duration: selected.duration,
        timeline: timeline,
        windowStart: window.start,
        windowEnd: window.end,
      );
    }
  }

  @override
  void close() {
    _closed = true;
    for (final timeline in _timelines) {
      timeline.close();
    }
    _timelines.clear();
    _dio.close(force: true);
  }
}

/// Small protobuf reader with strict wire and length validation. The platform
/// uses field 6 blocks, repeated field 2 comments, UTF-8 field 2 text/6 time/8 RGB.
List<Map<String, dynamic>> decodeCinemaIqiyiDanmaku(Uint8List compressed) {
  final bytes = Uint8List.fromList(brotliDecode(compressed));
  if (bytes.length > 4 * 1024 * 1024) throw const FormatException('爱奇艺解压数据过大');
  if (bytes.isNotEmpty && bytes.first == 60) {
    final doc = html.parse(utf8.decode(bytes));
    return [
      for (final node in doc.querySelectorAll('bulletinfo'))
        {
          'time': node.querySelector('showtime')?.text,
          'text': node.querySelector('content')?.text,
          'color': node.querySelector('color')?.text,
        },
    ];
  }
  List<({int field, Uint8List? data, int? value})> fields(Uint8List source) {
    var at = 0;
    int read() {
      var value = 0;
      for (var shift = 0; shift < 64 && at < source.length; shift += 7) {
        final b = source[at++];
        value |= (b & 127) << shift;
        if (b < 128) return value;
      }
      throw const FormatException('弹幕整数不完整');
    }

    final result = <({int field, Uint8List? data, int? value})>[];
    while (at < source.length) {
      final key = read(), field = key >> 3, wire = key & 7;
      if (field == 0) throw const FormatException('弹幕字段无效');
      if (wire == 0) {
        result.add((field: field, data: null, value: read()));
        continue;
      }
      if (wire != 1 && wire != 2 && wire != 5) {
        throw const FormatException('弹幕字段格式无效');
      }
      final length = wire == 2
          ? read()
          : wire == 1
          ? 8
          : 4;
      if (length < 0 || at + length > source.length) {
        throw const FormatException('弹幕字段长度无效');
      }
      result.add((
        field: field,
        data: wire == 2 ? Uint8List.sublistView(source, at, at + length) : null,
        value: null,
      ));
      at += length;
    }
    return result;
  }

  String get(
    List<({int field, Uint8List? data, int? value})> source,
    int field,
  ) {
    final found = source.where((f) => f.field == field).firstOrNull;
    return found?.data != null
        ? utf8.decode(found!.data!, allowMalformed: true)
        : '${found?.value ?? ''}';
  }

  final rows = <Map<String, dynamic>>[];
  for (final block in fields(
    bytes,
  ).where((f) => f.field == 6 && f.data != null)) {
    final b = fields(block.data!);
    for (final comment in b.where((f) => f.field == 2 && f.data != null)) {
      final c = fields(comment.data!);
      rows.add({
        'text': get(c, 2),
        'time': get(c, 6).isNotEmpty ? get(c, 6) : get(b, 1),
        'color': get(c, 8),
      });
    }
  }
  return rows;
}

List<Map<String, dynamic>> decodeCinemaBilibiliDanmaku(Uint8List bytes) {
  List<({int field, int? value, Uint8List? data})> fields(Uint8List source) {
    var at = 0;
    int integer() {
      var result = 0;
      for (var shift = 0; shift < 64 && at < source.length; shift += 7) {
        final byte = source[at++];
        result |= (byte & 127) << shift;
        if (byte < 128) return result;
      }
      throw const FormatException('Bilibili 弹幕整数无效');
    }

    final values = <({int field, int? value, Uint8List? data})>[];
    while (at < source.length) {
      final key = integer(), field = key >> 3, wire = key & 7;
      if (field == 0) throw const FormatException('Bilibili 弹幕字段无效');
      if (wire == 0) {
        values.add((field: field, value: integer(), data: null));
        continue;
      }
      if (![1, 2, 5].contains(wire)) {
        throw const FormatException('Bilibili 弹幕格式无效');
      }
      final length = wire == 2
          ? integer()
          : wire == 1
          ? 8
          : 4;
      if (length < 0 || at + length > source.length) {
        throw const FormatException('Bilibili 弹幕长度无效');
      }
      values.add((
        field: field,
        value: null,
        data: wire == 2 ? Uint8List.sublistView(source, at, at + length) : null,
      ));
      at += length;
    }
    return values;
  }

  final result = <Map<String, dynamic>>[];
  for (final f in fields(bytes).where((f) => f.field == 1 && f.data != null)) {
    final c = fields(f.data!);
    int number(int field, int fallback) =>
        c.where((f) => f.field == field).firstOrNull?.value ?? fallback;
    final text = c.where((f) => f.field == 7).firstOrNull?.data;
    final type = number(3, 1);
    if (text == null || ![1, 4, 5].contains(type)) continue;
    result.add({
      'time': number(2, 0) / 1000,
      'text': utf8.decode(text, allowMalformed: true),
      'type': type,
      'color': number(5, 0xffffff),
    });
  }
  return result;
}
