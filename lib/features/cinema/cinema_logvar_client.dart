import 'dart:convert';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'cinema_media_identity.dart';
import 'cinema_online_subtitles.dart' show CinemaSubtitleQuery;

class CinemaLogvarQuery {
  const CinemaLogvarQuery({
    required this.title,
    this.series = false,
    this.season = 1,
    this.episode = 1,
    this.year = '',
  });
  final String title, year;
  final bool series;
  final int season, episode;

  factory CinemaLogvarQuery.parse(
    String title, {
    String category = '',
    String episodeName = '',
    int fallbackEpisode = 1,
    String year = '',
  }) {
    final parsed = CinemaSubtitleQuery.parse(
      title,
      category: category,
      episodeName: episodeName,
      fallbackEpisode: fallbackEpisode,
    );
    return CinemaLogvarQuery(
      title: parsed.title,
      series: parsed.type == 'series',
      season: parsed.season,
      episode: parsed.episode,
      year: RegExp(r'(?:19|20)\d{2}').firstMatch(year)?.group(0) ?? '',
    );
  }

  String get label => series ? '$title · 第 $season 季 第 $episode 集' : title;
}

class CinemaLogvarWork {
  const CinemaLogvarWork({
    required this.id,
    required this.title,
    this.type = '',
    this.source = '',
    this.year = '',
  });
  final int id;
  final String title, type, source, year;
}

class CinemaLogvarEpisode {
  const CinemaLogvarEpisode(this.id, this.title, this.number);
  final int id;
  final String title;
  final int? number;
}

class CinemaLogvarSelection {
  const CinemaLogvarSelection(
    this.work,
    this.episode,
    this.entries,
    this.duration, {
    this.provider = 'NAS',
    this.partial = false,
    this.timeline,
    this.windowStart = 0,
    this.windowEnd = 0,
  });
  final CinemaLogvarWork work;
  final CinemaLogvarEpisode episode;
  final List<DanmakuEntry> entries;
  final double duration;
  final String provider;
  final bool partial;
  final CinemaDanmakuTimeline? timeline;
  final double windowStart, windowEnd;
  String get label => '$provider · ${work.title} · ${episode.title}';
}

abstract interface class CinemaDanmakuMatcher {
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  });
  void close();
}

class CinemaDanmakuWindow {
  const CinemaDanmakuWindow(
    this.entries,
    this.start,
    this.end, {
    this.partial = false,
  });
  final List<DanmakuEntry> entries;
  final double start, end;
  final bool partial;
}

abstract interface class CinemaDanmakuTimeline {
  double get endSeconds;
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  });
  void close();
}

int? _number(String? value) {
  if (value == null) return null;
  final number = int.tryParse(value);
  if (number != null) return number;
  const digits = '零一二三四五六七八九';
  var total = 0, unit = 0;
  for (final char in value.split('')) {
    if (char == '十' || char == '百') {
      total += (unit == 0 ? 1 : unit) * (char == '十' ? 10 : 100);
      unit = 0;
    } else {
      unit = char == '两' ? 2 : digits.indexOf(char);
      if (unit < 0) return null;
    }
  }
  return total + unit;
}

int? _season(String title) {
  final chinese = RegExp(r'第\s*([零一二两三四五六七八九十百\d]+)\s*季').firstMatch(title);
  if (chinese != null) return _number(chinese[1]);
  return int.tryParse(
    RegExp(
          r'\b(?:Season\s*|S)(\d{1,2})(?:\b|E)',
          caseSensitive: false,
        ).firstMatch(title)?[1] ??
        '',
  );
}

bool _extra(String title) => RegExp(
  r'预告|預告|花絮|特辑|特輯|幕后|幕後|解说|解說|片段|抢先看|搶先看|trailer|teaser|behind.the.scenes',
  caseSensitive: false,
).hasMatch(title);

int? cinemaLogvarEpisodeNumber(String title) {
  if (_extra(title)) return null;
  final cn = RegExp(r'第\s*([零一二两三四五六七八九十百\d]+)\s*[集话話]').firstMatch(title);
  if (cn != null) return _number(cn[1]);
  final code = RegExp(
    r'(?:\bS\d{1,2}[ ._-]*|(?:^|[^a-z0-9]))E(\d{1,4})(?!\d)',
    caseSensitive: false,
  ).firstMatch(title);
  if (code != null) return int.tryParse(code[1]!);
  final numeric = RegExp(
    r'^\s*(\d{1,4})(?:\s*[集话話]|\s*[-:：.]|\s*$)',
  ).firstMatch(title);
  return int.tryParse(numeric?[1] ?? '');
}

String _cleanTitle(
  String value,
) => cinemaMediaBaseTitle(CinemaSubtitleQuery.parse(value).title)
    .replaceAll(
      RegExp(r'\s*from\s+[a-z0-9_&.-]+\s*$', caseSensitive: false),
      '',
    )
    .replaceAll(RegExp(r'【(?:电影|電影|电视剧|電視劇|动漫|動畫|综艺|綜藝|纪录片|紀錄片)】'), '')
    .replaceAll(RegExp(r'^\s*(?:【[^】]{1,40}】|\[[^\]]{1,40}\])\s*'), '')
    .replaceAll(
      RegExp(
        r'[（(]\s*(?:(?:19|20)\d{2}|电影|電影|电视剧|電視劇|国语|國語|普通话|粵語|粤语|原声|原聲|中字|高清|超清|4K|1080P|720P)\s*[）)]',
        caseSensitive: false,
      ),
      '',
    )
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');

bool cinemaLogvarWorkMatches(CinemaLogvarQuery query, CinemaLogvarWork work) {
  if (_extra(work.title) ||
      RegExp(
        r'dandan|弹弹|彈彈',
        caseSensitive: false,
      ).hasMatch('${work.source} ${work.title}')) {
    return false;
  }
  if (_cleanTitle(query.title) != _cleanTitle(work.title)) return false;
  final candidateSeason = _season(work.title);
  if (query.series && (candidateSeason ?? 1) != query.season) return false;
  if (!query.series && candidateSeason != null) return false;
  final movie = RegExp(
    r'movie|电影|電影',
    caseSensitive: false,
  ).hasMatch(work.type);
  final series = RegExp(
    r'tv|series|电视剧|電視劇|连续剧|連續劇',
    caseSensitive: false,
  ).hasMatch(work.type);
  if (query.series && movie || !query.series && series) return false;
  if (query.year.isNotEmpty &&
      work.year.isNotEmpty &&
      query.year != work.year) {
    return false;
  }
  return true;
}

/// Independent LogVar transport: no official credentials, redirects or logging
/// of token-bearing paths. NAS playback URLs and local filenames never leave.
class CinemaLogvarClient implements CinemaDanmakuMatcher {
  CinemaLogvarClient(this.configuration, {Dio? dio})
    : _dio =
          dio ??
          DioFactory.createForConfig(
            NetworkConfig(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 45),
              enableLog: false,
              followSystemProxy: !LogvarConfiguration.isPrivateHost(
                configuration.baseUrl.host,
              ),
            ),
          );
  final LogvarConfiguration configuration;
  final Dio _dio;

  Future<Map<String, dynamic>> _get(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    final response = await _dio.get<ResponseBody>(
      configuration.endpoint(path, query).toString(),
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: false,
      ),
      cancelToken: cancelToken,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data!.stream) {
      if (cancelToken?.isCancelled == true) {
        throw cancelToken!.cancelError!;
      }
      if (bytes.length + chunk.length > maxDanmakuImportBytes) {
        throw const FormatException('弹幕响应超过 8 MB');
      }
      bytes.add(chunk);
    }
    final data = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (data is! Map<String, dynamic> || data['success'] == false) {
      throw const FormatException('NAS 弹幕源未返回有效结果，请尝试其他平台');
    }
    return data;
  }

  Future<List<CinemaLogvarWork>> search(
    String title, {
    int? season,
    int? episode,
    CancelToken? cancelToken,
  }) async {
    final clean = title.trim();
    if (clean.length < 2 ||
        clean.length > 160 ||
        clean.contains('://') ||
        RegExp(r'[/\\\r\n]').hasMatch(clean)) {
      throw const FormatException('请输入 2–160 字的公开电影或剧名');
    }
    final data = await _get(
      'search/anime',
      query: {'keyword': clean, 'season': ?season, 'episode': ?episode},
      cancelToken: cancelToken,
    );
    final rows = data['animes'];
    if (rows is! List) throw const FormatException('NAS 弹幕搜索结果无效');
    return [
      for (final row in rows.take(150))
        if (row is Map &&
            row['animeId'] is int &&
            row['animeId'] > 0 &&
            row['animeTitle'] is String)
          CinemaLogvarWork(
            id: row['animeId'],
            title: row['animeTitle'],
            type: '${row['typeDescription'] ?? row['type'] ?? ''}',
            source: '${row['source'] ?? ''}',
            year:
                RegExp(r'(?:19|20)\d{2}')
                    .firstMatch(
                      '${row['startDate'] ?? ''} ${row['animeTitle']}',
                    )
                    ?.group(0) ??
                '',
          ),
    ];
  }

  Future<List<CinemaLogvarEpisode>> episodes(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw const FormatException('作品编号无效');
    final data = await _get('bangumi/$id', cancelToken: cancelToken);
    final rows = data['bangumi'] is Map ? data['bangumi']['episodes'] : null;
    if (rows is! List) throw const FormatException('该作品没有可用分集');
    return [
      for (final row in rows.take(3000))
        if (row is Map &&
            row['episodeId'] is int &&
            row['episodeId'] > 0 &&
            row['episodeTitle'] is String &&
            !_extra(row['episodeTitle']))
          CinemaLogvarEpisode(
            row['episodeId'],
            row['episodeTitle'],
            cinemaLogvarEpisodeNumber(row['episodeTitle']) ??
                int.tryParse('${row['episodeNumber'] ?? ''}'),
          ),
    ];
  }

  Future<({List<DanmakuEntry> entries, double duration})> comments(
    int id, {
    CancelToken? cancelToken,
  }) async {
    if (id <= 0) throw const FormatException('弹幕编号无效');
    // Request the complete response explicitly; never mistake segment metadata
    // for an empty but successful comment file.
    final data = await _get(
      'comment/$id',
      query: {'format': 'json', 'duration': true, 'segmentflag': false},
      cancelToken: cancelToken,
    );
    if (data['segmentList'] is List) {
      throw const FormatException('服务返回了分片索引，请关闭服务端强制分片后重试');
    }
    final entries = await compute(parseLocalDanmaku, jsonEncode(data));
    for (final entry in entries) {
      entry.source = '[NAS LogVar]';
    }
    final duration = data['videoDuration'];
    return (
      entries: entries,
      duration: duration is num && duration.isFinite && duration > 0
          ? duration.toDouble()
          : 0.0,
    );
  }

  @override
  Future<CinemaLogvarSelection?> match(
    CinemaLogvarQuery query, {
    CancelToken? cancelToken,
    void Function(String)? onProgress,
  }) async {
    onProgress?.call('正在搜索 ${query.label}');
    final rows = await search(
      query.title,
      season: query.series ? query.season : null,
      episode: query.series ? query.episode : null,
      cancelToken: cancelToken,
    );
    final works = rows
        .where((work) => cinemaLogvarWorkMatches(query, work))
        .toList();
    if (query.year.isEmpty &&
        works.map((w) => w.year).where((y) => y.isNotEmpty).toSet().length >
            1) {
      throw const FormatException('找到不同年份的同名作品，请手动选择');
    }
    Object? failure;
    for (final work in works.take(4)) {
      if (cancelToken?.isCancelled == true) {
        throw cancelToken!.cancelError!;
      }
      try {
        onProgress?.call('正在核对 ${work.title} 的分集');
        final catalogue = await episodes(work.id, cancelToken: cancelToken);
        final choices = query.series
            ? catalogue.where((e) => e.number == query.episode).toList()
            : catalogue.length == 1
            ? catalogue
            : catalogue
                  .where(
                    (e) => _cleanTitle(e.title) == _cleanTitle(query.title),
                  )
                  .toList();
        if (choices.isEmpty || (query.series && choices.length != 1)) continue;
        if (query.series &&
            _season(choices.single.title) != null &&
            _season(choices.single.title) != query.season) {
          continue;
        }
        for (final choice in choices.take(3)) {
          try {
            onProgress?.call('正在下载 ${work.title} · ${choice.title}');
            final loaded = await comments(choice.id, cancelToken: cancelToken);
            return CinemaLogvarSelection(
              work,
              choice,
              loaded.entries,
              loaded.duration,
            );
          } catch (e) {
            if (e is DioException && CancelToken.isCancel(e)) rethrow;
            failure = e;
          }
        }
      } catch (e) {
        if (e is DioException && CancelToken.isCancel(e)) rethrow;
        failure = e;
      }
    }
    if (failure != null) {
      throw const FormatException('作品已匹配，但平台暂未返回可用弹幕，可重试或换平台');
    }
    return null;
  }

  @override
  void close() => _dio.close(force: true);
}
