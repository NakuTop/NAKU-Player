// SPDX-License-Identifier: AGPL-3.0-or-later
// Native adaptation of huangxd-/danmu_api's aiyifan and renren protocols.
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'cinema_logvar_client.dart';
import 'cinema_overseas_danmaku_parser.dart';

final class CinemaDanmakuRegionRestricted implements Exception {
  const CinemaDanmakuRegionRestricted();
  @override
  String toString() => '弹幕来源限制了当前访问地区';
}

String aiyifanAppSignature(String query, String timestamp, String key) =>
    md5.convert(utf8.encode('$query$timestamp$key')).toString();

String renrenAppSignature(
  String path,
  String timestamp,
  Map<String, dynamic> params,
  String key,
) {
  final names = params.keys.toList()..sort();
  final message =
      '${path}t$timestamp${names.map((k) => k + params[k].toString()).join()}$key';
  return md5.convert(utf8.encode(message)).toString();
}

String _text(dynamic value) =>
    (html.parseFragment(value is String ? value : '').text ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
Map _map(dynamic value) => value is Map ? value : const {};
List<Map> _rows(dynamic value) =>
    value is List ? value.whereType<Map>().take(100000).toList() : [];
bool _identifier(String value) =>
    RegExp(r'^[a-zA-Z0-9_-]{1,100}$').hasMatch(value);
int _id(String value) => int.parse(
  md5.convert(utf8.encode(value)).toString().substring(0, 12),
  radix: 16,
);

List<DanmakuEntry> _entries(List<OverseasComment> values) => [
  for (final value in values)
    DanmakuEntry(
      time: value.time,
      message: value.message,
      color: Color(value.color),
      type: value.type,
      source: value.source,
    ),
];

List<DanmakuEntry> parseAiyifanComments(List<Map> rows) => _entries(
  parseOverseasComments((rows: rows, renren: false, leadInSeconds: 0)),
);

List<DanmakuEntry> parseRenrenComments(
  List<Map> rows, {
  double leadInSeconds = 0,
}) => _entries(
  parseOverseasComments((
    rows: rows,
    renren: true,
    leadInSeconds: leadInSeconds,
  )),
);

/// Drop the owned token when finished so an external, long-lived token does not
/// retain a completed request/response through its non-removable future listener.
final class _CancellationLink {
  _CancellationLink(CancelToken? parent, this.owned) {
    unawaited(parent?.whenCancel.then(_cancel));
    if (parent?.isCancelled == true) owned?.cancel(parent!.cancelError);
  }
  CancelToken? owned;
  void _cancel(DioException error) => owned?.cancel(error);
  void dispose() => owned = null;
}

class CinemaOverseasDanmakuClient implements CinemaDanmakuMatcher {
  CinemaOverseasDanmakuClient({Dio? dio, DateTime Function()? now})
    : _dio = dio ?? DioFactory.createForConfig(_config()),
      _now = now ?? DateTime.now;
  final Dio _dio;
  final DateTime Function() _now;
  final _activeRequests = <CancelToken>{};
  final _activeMatches = <CancelToken>{};
  bool _closed = false;
  ({String publicKey, String privateKey, DateTime fetched})? _signing;

  static NetworkConfig _config() {
    try {
      return NetworkConfig.fromSettings(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 8),
      ).copyWith(enableLog: false, allowBadCertificates: false);
    } catch (_) {
      return const NetworkConfig(
        connectTimeout: Duration(seconds: 5),
        receiveTimeout: Duration(seconds: 8),
        enableLog: false,
      );
    }
  }

  void _check(CancelToken? token) {
    if (token?.isCancelled == true) throw token!.cancelError!;
    if (_closed) throw StateError('弹幕请求已关闭');
  }

  Future<dynamic> _request(
    String url, {
    CancelToken? token,
    Map<String, dynamic>? headers,
    Object? body,
    bool allow404 = false,
  }) async {
    _check(token);
    const limit = 8 * 1024 * 1024;
    final requestToken = CancelToken();
    final link = _CancellationLink(token, requestToken);
    _activeRequests.add(requestToken);
    try {
      final response = await _dio.request<ResponseBody>(
        url,
        data: body == null ? null : jsonEncode(body),
        cancelToken: requestToken,
        options: Options(
          method: body == null ? 'GET' : 'POST',
          followRedirects: false,
          responseType: ResponseType.stream,
          headers: {
            'User-Agent': 'Mozilla/5.0',
            'Accept-Encoding': 'identity',
            if (body != null) 'Content-Type': 'application/json;charset=utf-8',
            ...?headers,
          },
          validateStatus: (s) => s == 200 || s == 403 || allow404 && s == 404,
        ),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final part in response.data!.stream) {
        _check(token);
        if (bytes.length + part.length > limit) {
          throw const FormatException('平台弹幕数据过大');
        }
        bytes.add(part);
      }
      _check(token);
      if (response.statusCode == 404) return const [];
      final raw = bytes.takeBytes();
      if (response.statusCode == 403) {
        final text = utf8.decode(raw, allowMalformed: true);
        Object? detail;
        try {
          detail = jsonDecode(text);
        } catch (_) {}
        if (detail is Map &&
                (detail['error_code'] == 1009 ||
                    detail['error_name'] == 'country_banned') ||
            RegExp(
              r'^\s*error code:\s*1009\s*$',
              caseSensitive: false,
            ).hasMatch(text)) {
          throw const CinemaDanmakuRegionRestricted();
        }
        throw const FormatException('平台弹幕请求被拒绝（403）');
      }

      // Large JSON, UTF-8 and gzip work must not monopolize Flutter's UI isolate.
      final result =
          raw.length >= 32 * 1024 ||
              raw.length > 2 && raw[0] == 31 && raw[1] == 139
          ? await compute(decodeOverseasResponse, raw)
          : await decodeOverseasResponse(raw);
      _check(token);
      return result;
    } finally {
      _activeRequests.remove(requestToken);
      link.dispose();
    }
  }

  Future<List<DanmakuEntry>> _parseComments(
    List<Map> rows,
    CancelToken? token, {
    bool renren = false,
    double leadInSeconds = 0,
  }) async {
    _check(token);
    final batch = (rows: rows, renren: renren, leadInSeconds: leadInSeconds);
    final values = rows.length >= 256
        ? await compute(parseOverseasComments, batch)
        : parseOverseasComments(batch);
    _check(token);
    return _entries(values);
  }

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    if (query.title.trim().length < 2 ||
        query.title.length > 160 ||
        query.title.contains('://') ||
        RegExp(r'[/\\\r\n]').hasMatch(query.title) ||
        query.season < 1 ||
        query.episode < 1 ||
        query.episode > 5000) {
      throw const FormatException('公开片名或集数无效');
    }
    _check(cancelToken);
    final operation = CancelToken();
    final link = _CancellationLink(cancelToken, operation);
    _activeMatches.add(operation);
    final children = [CancelToken(), CancelToken()];
    final calls = [matchRenren, matchAiyifan];
    final answer = Completer<CinemaLogvarSelection?>();
    var remaining = calls.length, failures = 0;
    void cancelChildren(Object reason) {
      for (final token in children) {
        token.cancel(reason);
      }
    }

    unawaited(
      operation.whenCancel.then((error) {
        if (!answer.isCompleted) answer.completeError(error);
        cancelChildren(error);
      }),
    );
    try {
      for (var index = 0; index < calls.length; index++) {
        final call = calls[index], child = children[index];
        unawaited(() async {
          try {
            final value = await call(
              query,
              cancelToken: child,
              onProgress: (message) {
                if (!answer.isCompleted && !operation.isCancelled) {
                  onProgress?.call(message);
                }
              },
            );
            if (value != null && !answer.isCompleted) {
              _check(operation);
              answer.complete(value);
              cancelChildren('已匹配到平台弹幕');
            }
          } catch (_) {
            failures++;
          } finally {
            if (--remaining == 0 && !answer.isCompleted) {
              if (operation.isCancelled) {
                answer.completeError(operation.cancelError!);
              } else if (failures > 0) {
                answer.completeError(
                  const FormatException('海外平台弹幕暂时无法连接，下次播放会重试'),
                );
              } else {
                answer.complete(null);
              }
            }
          }
        }());
      }
      return await answer.future;
    } finally {
      cancelChildren('弹幕匹配已结束');
      _activeMatches.remove(operation);
      link.dispose();
    }
  }

  bool _matches(
    CinemaLogvarQuery query,
    CinemaLogvarWork work, [
    Iterable<String> aliases = const [],
  ]) {
    if (cinemaLogvarWorkMatches(query, work)) return true;
    final season = CinemaLogvarQuery.parse(work.title, category: '电视剧').season;
    for (final alias in aliases) {
      if (cinemaLogvarWorkMatches(
        query,
        CinemaLogvarWork(
          id: work.id,
          title: query.series ? '$alias 第$season季' : alias,
          type: work.type,
          source: work.source,
          year: work.year,
        ),
      )) {
        return true;
      }
    }
    return false;
  }

  List<({CinemaLogvarWork work, Map row})> _unambiguous(
    CinemaLogvarQuery query,
    List<({CinemaLogvarWork work, Map row})> candidates,
  ) {
    if (candidates.length > 1) {
      final years = candidates.map((c) => c.work.year).toSet();
      if (years.contains('') || query.year.isEmpty && years.length > 1) {
        return [];
      }
    }
    return candidates.take(3).toList();
  }

  CinemaLogvarSelection _selection(
    CinemaLogvarQuery q,
    CinemaLogvarWork work,
    String episodeId,
    List<DanmakuEntry> entries,
    String provider,
  ) => CinemaLogvarSelection(
    work,
    CinemaLogvarEpisode(
      _id(episodeId),
      q.series ? '第${q.episode}集' : '正片',
      q.episode,
    ),
    entries,
    0,
    provider: provider,
  );

  Future<({String publicKey, String privateKey, DateTime fetched})> _aiConfig(
    CancelToken? token, {
    bool refresh = false,
  }) async {
    final cached = _signing;
    if (!refresh &&
        cached != null &&
        _now().difference(cached.fetched) < const Duration(minutes: 30)) {
      return cached;
    }
    final t = '${_now().millisecondsSinceEpoch ~/ 1000}';
    final q = '_t=$t';
    final data = _map(
      await _request(
        'https://api.tripdata.app/api/home/config?$q',
        token: token,
        headers: _aiHeaders(q, t, '', '57688*1-331@'),
      ),
    );
    final p = _map(_map(_map(data['data'])['list'])['pConfig']);
    final keys = p['privateKey'];
    final privateKey = keys is List && keys.isNotEmpty
        ? '${keys.first}'
        : '${keys ?? ''}';
    final publicKey = '${p['publicKey'] ?? ''}';
    if (privateKey.isEmpty || publicKey.isEmpty) {
      throw const FormatException('爱一帆平台配置暂不可用');
    }
    return _signing = (
      publicKey: publicKey,
      privateKey: privateKey,
      fetched: _now(),
    );
  }

  Map<String, dynamic> _aiHeaders(String q, String t, String pub, String key) =>
      {
        'User-Agent': 'okhttp-okgo/jeasonlzy',
        'Accept-Language': 'zh-CN,zh;q=0.8',
        'BundleId': 'com.cqcsy.ifvod',
        'AppVersion': '1.7.8',
        'System': 'Android',
        'SystemVersion': '17',
        'DeviceInfo': 'NAKU',
        'Version': 'V3',
        'Lang': '0',
        'DeviceId': '2da4a414036a4332782795a031dcab6b4',
        'Lat': '0.0',
        'Lng': '0.0',
        'x-timestamp': t,
        'x-pub': pub,
        'x-sign': aiyifanAppSignature(q, t, key),
      };

  Future<Map> _aiCall(
    String path,
    CancelToken? token, {
    Map<String, dynamic>? params,
    Object? body,
  }) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      _check(token);
      final config = await _aiConfig(token, refresh: attempt > 0);
      final t = '${_now().millisecondsSinceEpoch ~/ 1000}';
      final q = params == null || params.isEmpty
          ? '_t=$t'
          : params.entries.map((e) => '${e.key}=${e.value}').join('&');
      try {
        final data = _map(
          await _request(
            'https://api.tripdata.app/$path?$q',
            token: token,
            body: body,
            headers: _aiHeaders(q, t, config.publicKey, config.privateKey),
          ),
        );
        if (data['ret'] == 200) return data;
      } catch (error) {
        _check(token);
        if (error is CinemaDanmakuRegionRestricted || attempt == 1) rethrow;
      }
    }
    throw const FormatException('爱一帆平台请求暂不可用');
  }

  Future<Map<String, String>> _aiYears(String title, CancelToken? token) async {
    try {
      final config = await _aiConfig(token);
      final params = {
        'tags': title,
        'orderby': '4',
        'page': '1',
        'size': '30',
        'desc': '1',
        'isserial': '-1',
      };
      final raw = params.entries.map((e) => '${e.key}=${e.value}').join('&');
      final vv = md5
          .convert(
            utf8.encode(
              '${config.publicKey}&${raw.toLowerCase()}&${config.privateKey}',
            ),
          )
          .toString();
      final url = Uri.https('rankv21.tripdata.app', '/v3/list/briefsearch', {
        ...params,
        'vv': vv,
        'pub': config.publicKey,
      });
      final data = _map(await _request(url.toString(), token: token));
      return {
        for (final group in _rows(_map(data['data'])['info']))
          for (final row in _rows(group['result']))
            if (_identifier('${row['contxt']}') &&
                RegExp(r'^(19|20)\d{2}-').hasMatch('${row['postTime']}'))
              '${row['contxt']}': '${row['postTime']}'.substring(0, 4),
      };
    } catch (_) {
      _check(token);
      return {};
    }
  }

  Future<CinemaLogvarSelection?> matchAiyifan(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    _check(cancelToken);
    onProgress?.call('正在查找爱一帆 · ${query.label}');
    final data = await _aiCall(
      'api/List/GetTitleGetData',
      cancelToken,
      body: {'SearchCriteria': query.title},
    );
    final rows = _rows(_map(data['data'])['list']);
    final years = await _aiYears(query.title, cancelToken);
    final matches = <({CinemaLogvarWork work, Map row})>[];
    for (final row in rows.take(60)) {
      final key = '${row['mediaKey'] ?? row['mediaId'] ?? ''}';
      if (!_identifier(key)) continue;
      final work = CinemaLogvarWork(
        id: _id(key),
        title: _text(row['title']),
        type: '${row['mediaType'] ?? row['contentType'] ?? ''}',
        year: years[key] ?? '',
        source: 'aiyifan',
      );
      if (_matches(query, work)) matches.add((work: work, row: row));
    }
    for (final candidate in _unambiguous(query, matches)) {
      _check(cancelToken);
      final media = '${candidate.row['mediaKey'] ?? candidate.row['mediaId']}';
      final response = await _aiCall(
        'api/Video/VideoChooseGather',
        cancelToken,
        body: {'mediaKey': media},
      );
      final eps = _rows(_map(response['data'])['list']);
      final matching = eps
          .where(
            (e) =>
                cinemaLogvarEpisodeNumber(
                  _text(e['episodeTitle'] ?? e['title']),
                ) ==
                query.episode,
          )
          .toList();
      final Map? ep = query.series
          ? matching.length == 1
                ? matching.single
                : null
          : eps.length == 1
          ? eps.single
          : null;
      if (ep == null) continue;
      var video = '${ep['uniqueID'] ?? ''}', type = '${ep['videoType'] ?? 1}';
      if (!_identifier(video)) {
        final key = '${ep['episodeKey'] ?? ''}';
        if (!_identifier(key)) continue;
        final detail = await _aiCall(
          'api/Video/VideoDetails',
          cancelToken,
          params: {'mediaKey': media, 'videoType': type, 'episodeKey': key},
        );
        final info = _map(_map(detail['data'])['detailInfo']);
        video = '${info['uniqueID'] ?? ''}';
        type = '${info['videoType'] ?? type}';
      }
      if (!_identifier(video) || !RegExp(r'^\d{1,3}$').hasMatch(type)) continue;
      final comments = await _aiCall(
        'api/Video/GetBarrages',
        cancelToken,
        params: {'mediaKey': media, 'videoId': video, 'videoType': type},
      );
      final entries = await _parseComments(
        _rows(_map(comments['data'])['list']),
        cancelToken,
      );
      if (entries.isNotEmpty) {
        return _selection(query, candidate.work, video, entries, '爱一帆');
      }
    }
    return null;
  }

  // Renren distinguishes an explicit empty value (episodeId=) from a flag
  // (episodeId). Uri's default query encoding drops '=' for empty strings,
  // which makes the TV gateway reject a correctly signed request with 403.
  Uri _rrUri(
    String host,
    String path,
    Map<String, dynamic> params,
  ) => Uri.https(host, path).replace(
    query: params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value.toString())}',
        )
        .join('&'),
  );

  static const _rrKey = 'cf65GPholnICgyw1xbrpA79XVkizOdMq';
  Map<String, dynamic> _rrHeaders(String path, Map<String, dynamic> params) {
    final t = '${_now().millisecondsSinceEpoch}';
    return {
      'clientVersion': '1.2.2',
      'p': 'Android',
      'deviceid': 'tWEtIN7JG2DTDkBBigvj6A%3D%3D',
      'token': '',
      'umid': '',
      'aliid': 'aYN4D0XfSREDAJaw3UAjG33K',
      'clienttype': 'android_qwtv_RRSP',
      'pkt': 'rrmj',
      't': t,
      'sign': renrenAppSignature(path, t, params, _rrKey),
      'isAgree': '1',
      'et': '2',
      'User-Agent': 'okhttp/3.12.13',
    };
  }

  Future<Map> _rrTv(
    String path,
    Map<String, dynamic> params,
    CancelToken? token,
  ) async {
    final uri = _rrUri('api.gorafie.com', path, params);
    final data = _map(
      await _request(
        uri.toString(),
        token: token,
        headers: _rrHeaders(path, params),
      ),
    );
    if (data['code'] != '0000') throw const FormatException('人人视频平台暂不可用');
    return _map(data['data']);
  }

  Future<List<Map>> _rrSearch(String title, CancelToken? token) async {
    final result = <Map>[];
    var validResponse = false;
    for (final host in ['api.pleasfun.com', 'api.cluuid.cn']) {
      _check(token);
      final win = host == 'api.pleasfun.com';
      final path = win
          ? '/search/comprehensive/precise-mixed'
          : '/search/v5/season';
      final params = win
          ? {'keywords': title, 'searchAfter': '', 'size': '30'}
          : {
              'keywords': title,
              'order': 'match',
              'search_after': '',
              'size': '30',
            };
      try {
        final response = _map(
          await _request(
            _rrUri(host, path, params).toString(),
            token: token,
            headers: {
              'aliId': win
                  ? '5946EF765BB146CC88231241A61D23BC'
                  : '5946EF76-5BB1-46CC-8823-1241A61D23BC',
              'User-Agent': win ? 'Boost.Beast/351' : 'Mozilla/5.0',
              'ct': win ? 'win_rrsp_gw' : 'mac_rrsp',
              'cv': win ? '1.24.2' : '1.2.3',
              'token': '',
            },
          ),
        );
        if (response['code'] != '0000') continue;
        validResponse = true;
        final data = response['data'];
        if (data is List) result.addAll(_rows(data));
        if (data is Map) {
          result.addAll(_rows(data['seasonList']));
          result.addAll(_rows(data['fuzzySeasonList']));
          for (final series in _rows(data['seriesList'])) {
            result.addAll(_rows(series['seasonList']));
          }
        }
        if (result.isNotEmpty) break;
      } catch (_) {
        _check(token);
      }
    }
    if (!validResponse) throw const FormatException('人人视频目录暂时无法连接');
    return result;
  }

  Iterable<String> _rrAliases(Map row) sync* {
    final h = _map(row['highlights']);
    for (final value in [
      h['alias'],
      h['original_name'],
      row['alias'],
      row['enName'],
    ]) {
      if (value is! String) continue;
      for (final part in value.split(RegExp(r'[,，]'))) {
        final text = _text(part);
        if (text.isNotEmpty) yield text;
      }
    }
  }

  Future<CinemaLogvarSelection?> matchRenren(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    _check(cancelToken);
    onProgress?.call('正在查找人人视频 · ${query.label}');
    final rows = await _rrSearch(query.title, cancelToken);
    final matches = <({CinemaLogvarWork work, Map row})>[];
    final seen = <String>{};
    for (final row in rows.take(100)) {
      final id = '${row['id'] ?? ''}';
      if (!_identifier(id) || !seen.add(id)) continue;
      final work = CinemaLogvarWork(
        id: _id(id),
        title: [
          row['title'],
          row['alias'],
          row['name'],
        ].map(_text).firstWhere((v) => v.isNotEmpty, orElse: () => ''),
        year: '${row['year'] ?? ''}',
        type: '${row['classify'] ?? row['cat'] ?? ''}',
        source: 'renren',
      );
      if (_matches(query, work, _rrAliases(row))) {
        matches.add((work: work, row: row));
      }
    }
    for (final candidate in _unambiguous(query, matches)) {
      _check(cancelToken);
      final series = '${candidate.row['id']}';
      final params = <String, dynamic>{
        'isAgeLimit': 'false',
        'seriesId': series,
        'episodeId': '',
        'clarity': 'HD',
        'caption': '0',
        'hevcOpen': '1',
      };
      final detail = await _rrTv('/qwtv/drama/details', params, cancelToken);
      final info = _map(detail['dramaInfo']);
      final work = CinemaLogvarWork(
        id: candidate.work.id,
        title: candidate.work.title,
        year: '${info['year'] ?? candidate.work.year}',
        type: '${info['dramaType'] ?? candidate.work.type}',
        source: 'renren',
      );
      if (!_matches(query, work, [
        ..._rrAliases(candidate.row),
        _text(info['enName']),
      ])) {
        continue;
      }
      final episodes = _rows(detail['episodeList']);
      final matching = episodes
          .where(
            (e) =>
                int.tryParse('${e['episodeNo']}') == query.episode ||
                cinemaLogvarEpisodeNumber(_text(e['title'])) == query.episode,
          )
          .toList();
      final Map? ep = query.series
          ? matching.length == 1
                ? matching.single
                : null
          : episodes.length == 1
          ? episodes.single
          : null;
      if (ep == null || !_identifier('${ep['sid'] ?? ''}')) continue;
      final sid = '${ep['sid']}';
      Map episodeDetail = detail;
      if (query.series) {
        episodeDetail = await _rrTv('/qwtv/drama/details', {
          ...params,
          'episodeId': sid,
        }, cancelToken);
      }
      final watch = _map(episodeDetail['watchInfo']);
      final play = _map(watch['m3u8'] ?? watch['tria4kPlayInfo']);
      final leadInMs = double.tryParse('${play['startingLength'] ?? 0}') ?? 0;
      List<Map>? comments;
      final path = '/v1/produce/danmu/EPISODE/$sid';
      for (final host in [
        'static-dm.qwdjapp.com',
        'static-dm.lequkeji.com',
        'static-dm.rrmj.plus',
      ]) {
        try {
          final response = await _request(
            Uri.https(host, path).toString(),
            token: cancelToken,
            headers: _rrHeaders(path, {}),
            allow404: true,
          );
          if (response is List) {
            comments = _rows(response);
            break;
          }
          if (response is Map && response['data'] is List) {
            comments = _rows(response['data']);
            break;
          }
        } catch (_) {
          _check(cancelToken);
        }
      }
      final entries = await _parseComments(
        comments ?? [],
        cancelToken,
        renren: true,
        leadInSeconds: max(0, leadInMs) / 1000,
      );
      if (entries.isNotEmpty) {
        return _selection(query, work, sid, entries, '人人视频');
      }
    }
    return null;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final token in [..._activeMatches, ..._activeRequests]) {
      token.cancel('closed');
    }
    _dio.close(force: true);
    _signing = null;
  }
}
