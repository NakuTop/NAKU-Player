import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ffi' as ffi;
import 'package:ffi/ffi.dart';
import 'package:crypto/crypto.dart';
import 'cinema_subtitle_catalogs.dart';
import 'cinema_subtitle_fallbacks.dart';
import 'cinema_media_identity.dart';
import 'cinema_subtitle_network.dart';
import 'cinema_external_subtitles.dart';
import 'package:dio/dio.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

/// Parse locally; never send a NAS path or playback URL to a public catalog.
class CinemaSubtitleQuery {
  const CinemaSubtitleQuery(this.title, this.type, this.season, this.episode);
  final String title, type;
  final int season, episode;

  static int _number(String value) {
    final number = int.tryParse(value);
    if (number != null) return number;
    const digits = '零一二三四五六七八九';
    if (value == '两') return 2;
    if (value.contains('十')) {
      final parts = value.split('十');
      return (parts.first.isEmpty ? 1 : digits.indexOf(parts.first)) * 10 +
          (parts.last.isEmpty ? 0 : digits.indexOf(parts.last));
    }
    return digits.indexOf(value);
  }

  factory CinemaSubtitleQuery.parse(
    String title, {
    String category = '',
    String episodeName = '',
    int? fallbackEpisode,
  }) {
    final combined = '$title $episodeName';
    final code = RegExp(
      r'(?:^|[^a-z0-9])S(\d{1,2})[ ._-]*E(\d{1,3})(?!\d)',
      caseSensitive: false,
    ).firstMatch(combined);
    final season = RegExp(r'第\s*([零一二两三四五六七八九十\d]+)\s*季').firstMatch(combined);
    final episode = RegExp(
      r'第\s*([零一二两三四五六七八九十\d]+)\s*[集话話]',
    ).firstMatch(episodeName.isEmpty ? title : episodeName);
    final englishEpisode = RegExp(
      r'(?:^|[^a-z0-9])(?:episode\s*|e)(\d{1,4})(?!\d)',
      caseSensitive: false,
    ).firstMatch(episodeName);
    final crossed = RegExp(
      r'(?:^|[^a-z0-9])(\d{1,3})x(\d{1,4})(?!\d)',
      caseSensitive: false,
    ).firstMatch(combined);
    final englishSeason = RegExp(
      r'\b(?:Season\s*|S)(\d{1,2})(?!\d)',
      caseSensitive: false,
    ).firstMatch(combined);
    // Genre labels such as 剧情片/喜剧片 contain 剧, but describe films.
    final movieCategory = RegExp(
      r'电影|電影|片|\bmovie\b|\bfilm\b',
      caseSensitive: false,
    ).hasMatch(category);
    final series =
        code != null ||
        crossed != null ||
        episode != null ||
        season != null ||
        englishSeason != null ||
        (!movieCategory &&
            RegExp(
              '剧|劇|动漫|動畫|series|tv',
              caseSensitive: false,
            ).hasMatch(category));
    final release = RegExp(
      r'[ ._-]+S\d{1,2}[ ._-]*E\d{1,3}(?!\d).*',
      caseSensitive: false,
    );
    final name = release.hasMatch(title)
        ? title.replaceFirst(release, '').replaceAll(RegExp(r'[._]+'), ' ')
        : title;
    final clean = name
        .replaceAll(RegExp(r'第\s*[零一二两三四五六七八九十\d]+\s*[季集话話]'), '')
        .replaceAll(
          RegExp(
            r'\bS\d{1,2}(?:[ ._-]*E\d{1,3})?\b|\bSeason\s*\d+',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return CinemaSubtitleQuery(
      clean,
      series ? 'series' : 'movie',
      code != null
          ? int.parse(code[1]!)
          : crossed != null
          ? int.parse(crossed[1]!)
          : season != null
          ? _number(season[1]!)
          : englishSeason != null
          ? int.parse(englishSeason[1]!)
          : 1,
      code != null
          ? int.parse(code[2]!)
          : crossed != null
          ? int.parse(crossed[2]!)
          : episode != null
          ? _number(episode[1]!)
          : englishEpisode != null
          ? int.parse(englishEpisode[1]!)
          : int.tryParse(episodeName.trim()) ?? fallbackEpisode ?? 1,
    );
  }
}

/// The episode actually searched, captured before any asynchronous catalog work.
class CinemaOnlineSubtitleSelection {
  const CinemaOnlineSubtitleSelection({
    required this.query,
    required this.imdbId,
    required this.row,
    required this.applyToSeason,
  });

  final CinemaSubtitleQuery query;
  final String imdbId;
  final Map<String, dynamic> row;
  final bool applyToSeason;
}

bool cinemaSubtitleLanguageMatches(String language, String selected) {
  final lang = language.toLowerCase().replaceAll('_', '-');
  if (selected == 'zh-eng') {
    return cinemaSubtitleLanguageMatches(lang, 'zh') ||
        cinemaSubtitleLanguageMatches(lang, 'eng');
  }
  return selected == 'all' ||
      (selected == 'zh'
          ? [
                  'chi',
                  'zho',
                  'zht',
                  'zhe',
                  'zhs',
                  'zh',
                  'cmn',
                  'chs',
                  'cht',
                ].contains(lang) ||
                lang.startsWith('zh-')
          : selected == 'eng'
          ? ['eng', 'en'].contains(lang)
          : selected == 'jpn'
          ? ['jpn', 'ja'].contains(lang)
          : lang == selected);
}

/// Metadata must not substitute a different episode, even when a catalog returns
/// a complete season pack. Entries with no episode code are checked by their
/// catalog's requested episode; explicit codes must match exactly.
bool cinemaSubtitleEpisodeMatches(String name, int season, int episode) {
  final codes = RegExp(
    r'S(\d{1,2})[ ._-]*E(\d{1,3})(?!\d)',
    caseSensitive: false,
  ).allMatches(name);
  if (codes.isNotEmpty) {
    return codes.any(
      (code) => int.parse(code[1]!) == season && int.parse(code[2]!) == episode,
    );
  }
  final chinese = RegExp(r'第\s*([零一二两三四五六七八九十\d]+)\s*季').firstMatch(name);
  if (chinese != null && CinemaSubtitleQuery._number(chinese[1]!) != season) {
    return false;
  }
  final english = RegExp(
    r'\bS(\d{1,2})(?!\d)',
    caseSensitive: false,
  ).firstMatch(name);
  return english == null || int.parse(english[1]!) == season;
}

/// Only local release tags are compared; filenames and paths are never sent to
/// public catalogs. Matching a release helps selection but cannot prove sync.
int cinemaSubtitleReleaseScore(String subtitleName, String playbackName) {
  if (playbackName.trim().isEmpty) return 0;
  Set<String> tags(String value) =>
      RegExp(
        r'(?<![A-Z0-9])(?:AMZN|NETFLIX|NF|HULU|DSNP|DSNY|HMAX|MAX|WEB[ ._-]?DL|WEBRIP|BLU[ ._-]?RAY|BDRIP|HDTV|REMUX|FLUX|NTB|NTG|CMRG|TBS|CAKES|GGEZ|GGWP|1080P|2160P|720P)(?![A-Z0-9])',
        caseSensitive: false,
      ).allMatches(value).map((match) {
        final tag = match[0]!.toUpperCase().replaceAll(RegExp(r'[ ._-]'), '');
        return switch (tag) {
          'NETFLIX' => 'NF',
          'DSNY' => 'DSNP',
          'MAX' => 'HMAX',
          _ => tag,
        };
      }).toSet();
  final wanted = tags(playbackName), found = tags(subtitleName);
  if (wanted.isEmpty || found.isEmpty) return 0;
  const format = {'WEBDL', 'WEBRIP', 'BLURAY', 'BDRIP', 'HDTV', 'REMUX'};
  var score = 0;
  for (final tag in wanted.intersection(found)) {
    score += format.contains(tag)
        ? 4
        : tag.endsWith('P')
        ? 1
        : 8;
  }
  if (wanted.intersection(format).isNotEmpty &&
      found.intersection(format).isNotEmpty &&
      wanted.intersection(found).intersection(format).isEmpty) {
    score -= 8;
  }
  return score;
}

String cinemaSubtitleLanguageLabel(Map<String, dynamic> row) {
  if (cinemaSubtitleLanguageMatches('${row['lang']}', 'zh')) {
    final traditional = '${row['subtitleFileName']}'.contains('繁');
    final simplified = '${row['subtitleFileName']}'.contains('简');
    final chinese = traditional
        ? '繁体中文'
        : simplified
        ? '简体中文'
        : '中文';
    return row['bilingual'] == true ? '$chinese / English 双语' : chinese;
  }
  return cinemaSubtitleLanguageMatches('${row['lang']}', 'eng')
      ? 'English'
      : '${row['lang']}';
}

Map<String, dynamic>? _verifiedDialogueLanguage(
  String text,
  Map<String, dynamic> row,
) {
  final cues = cinemaSubtitleCues(text);
  final chinese = cues
      .where((cue) => RegExp(r'[\u4e00-\u9fff]').hasMatch(cue.text))
      .length;
  final latin = cues
      .where((cue) => RegExp(r'[A-Za-z]{2,}').hasMatch(cue.text))
      .length;
  final kana = cues
      .where((cue) => RegExp(r'[\u3040-\u30ff]').hasMatch(cue.text))
      .length;
  // Read actual dialogue, not ASS font names or a catalog's language badge.
  if (chinese > 0 && chinese * 10 >= cues.length && kana < chinese / 2) {
    return {
      ...row,
      'lang': 'zh',
      'bilingual': latin >= (chinese / 3).ceil(),
      'chineseCueCount': chinese,
      'cueCount': cues.length,
      'firstCueMilliseconds': cues.first.start,
      'lastCueMilliseconds': cues.last.end,
    };
  }
  if (cinemaSubtitleLanguageMatches('${row['lang']}', 'eng') &&
      latin > 0 &&
      kana == 0) {
    return {
      ...row,
      'lang': 'eng',
      'bilingual': false,
      'cueCount': cues.length,
      'firstCueMilliseconds': cues.first.start,
      'lastCueMilliseconds': cues.last.end,
    };
  }
  return null;
}

/// Public catalogs receive only the query / IMDb ID, never NAS credentials.
/// File parsing/language checks do not establish which work a subtitle belongs
/// to. Automatic loading also needs a matching title or scoped metadata proof.
bool cinemaSubtitleCandidateMatches(
  Map<String, dynamic> row,
  CinemaSubtitleQuery query, {
  String imdbId = '',
}) {
  final file =
      '${row['archiveEntry'] ?? row['subtitleFileName'] ?? row['movieReleaseName'] ?? ''}';
  if (query.type == 'movie' && cinemaExplicitSubtitleEpisode(file)) {
    return false;
  }
  if (row['identityVerified'] == true &&
      row['matchedQuery'] == cinemaMediaTitleKey(query.title) &&
      row['matchedWorkType'] == query.type) {
    return true;
  }
  final aliases = cinemaSubtitleAliases(
    query.title,
    imdbId: imdbId,
  ).map(cinemaMediaTitleKey).where((v) => v.isNotEmpty).toSet();
  for (final field in [file, '${row['releaseFormat'] ?? ''}']) {
    var name = field
        .split(RegExp(r'[/\\]'))
        .last
        .replaceFirst(RegExp(r'\.(srt|ass|ssa|vtt)$', caseSensitive: false), '')
        .replaceFirst(RegExp(r'^\s*[\[【][^\]】]{1,60}[\]】]\s*'), '');
    name = name
        .split(
          RegExp(
            r'(?:[ ._-]+|(?<=\p{Script=Han}))(?:S\d{1,2}[ ._-]*E\d{1,4}|(?:19|20)\d{2}|\d{3,4}p|2160|1080|720|BluRay|BDRip|WEB(?:[ ._-]?DL|Rip)?|HDTV|DVDRip)(?:\b|[ ._-])|第\s*[零一二两三四五六七八九十百\d]+\s*[季集话話]',
            caseSensitive: false,
            unicode: true,
          ),
        )
        .first;
    if (aliases.contains(cinemaMediaTitleKey(name))) return true;
  }
  return false;
}

class CinemaOnlineSubtitles {
  CinemaOnlineSubtitles({Dio? dio, this.useFallbackCatalog = true})
    : _dio = dio ?? _createDio();
  final bool useFallbackCatalog;
  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        headers: {
          'User-Agent': 'NAKUPlayer/2.8.0',
          'Accept': 'application/json',
        },
      ),
    );
    NetworkConfig config;
    try {
      config = NetworkConfig.fromSettings();
    } catch (_) {
      config = const NetworkConfig();
    }
    final adapter = config
        .copyWith(allowBadCertificates: false)
        .createAdapter();
    dio.httpClientAdapter =
        Platform.isWindows && config.followSystemProxy && !config.hasProxy
        ? CinemaSubtitleNetworkAdapter(
            primary: adapter,
            systemProxy: SystemProxyService.findProxy,
          )
        : adapter;
    return dio;
  }

  final Dio _dio;
  late final _catalogs = CinemaSubtitleCatalogs(_dio);
  final _verified = <String, String>{};
  final _archives = <String, Future<List<int>>>{};

  /// A selected season archive is a better source for its other episodes than
  /// a fresh web search. List only; never extract archive paths onto disk.
  Future<List<Map<String, dynamic>>> seasonFiles(
    Map<String, dynamic> selected,
  ) async {
    if (selected['archiveEntry'] is! String) return const [];
    final url = selected['url'];
    if (url is! String) return const [];
    final bytes = await _archives.putIfAbsent(url, () => _downloadBytes(url));
    final names = await listArchiveSubtitles(bytes);
    return [
      for (final name in names)
        {
          ...selected,
          'archiveEntry': name,
          'subtitleFileName': name,
          'verified': false,
        },
    ];
  }

  Future<Map<String, dynamic>?> verifyFile(
    Map<String, dynamic> row, {
    required String language,
  }) async {
    final text = await download(
      '${row['url']}',
      archiveEntry: row['archiveEntry'] as String?,
    );
    final identified = _verifiedDialogueLanguage(text, row);
    if (identified == null ||
        !cinemaSubtitleLanguageMatches('${identified['lang']}', language)) {
      return null;
    }
    return {...identified, 'verified': true};
  }

  static Future<List<String>> listArchiveSubtitles(List<int> bytes) async {
    if ((!Platform.isMacOS && !Platform.isWindows) ||
        bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('该字幕压缩格式暂不可读取');
    }
    final folder = await Directory.systemTemp.createTemp('naku-subtitle-');
    Process? process;
    Timer? timer;
    try {
      final file = File('${folder.path}/subtitle.archive');
      await file.writeAsBytes(bytes, flush: true);
      process = await Process.start(
        Platform.isMacOS
            ? '/usr/bin/tar'
            : '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe',
        ['-tf', file.path],
      );
      timer = Timer(const Duration(seconds: 15), () => process?.kill());
      final errors = process.stderr.drain<void>();
      final output = BytesBuilder(copy: false);
      await for (final part in process.stdout) {
        if (output.length + part.length > 256 * 1024) {
          throw const FormatException('字幕包文件目录过大');
        }
        output.add(part);
      }
      await errors;
      if (await process.exitCode != 0) throw const FormatException('字幕包目录无法读取');
      return utf8
          .decode(output.takeBytes())
          .split('\n')
          .map((s) => s.trim())
          .where(
            (name) =>
                name.isNotEmpty &&
                name.length <= 1024 &&
                !name.startsWith('/') &&
                !name.contains('..') &&
                !name.contains(':') &&
                !name.contains('\u0000') &&
                RegExp(
                  r'\.(srt|ass|ssa|vtt)$',
                  caseSensitive: false,
                ).hasMatch(name),
          )
          .take(1000)
          .toList();
    } finally {
      timer?.cancel();
      process?.kill();
      await folder.delete(recursive: true);
    }
  }

  Future<CinemaSubtitleCatalogResult> aggregate(
    String query,
    String type, {
    String imdbId = '',
    String year = '',
    int season = 1,
    int episode = 1,
    String language = 'zh-eng',
    String mediaRelease = '',
    void Function(List<Map<String, dynamic>> rows)? onVerified,
  }) async {
    final fallbackNames = cinemaSubtitleAliases(query, imdbId: imdbId);
    var resolvedType = fallbackNames.contains('American Horror Story')
        ? 'series'
        : type;
    final status = <String, String>{};
    final candidates = useFallbackCatalog
        ? cinemaSubtitleFallbacks(
            title: CinemaSubtitleQuery.parse(query).title,
            imdbId: imdbId,
            type: resolvedType,
            season: season,
            episode: episode,
          )
        : <Map<String, dynamic>>[];
    final rows = <Map<String, dynamic>>[];
    final fingerprints = <String>{};
    bool eligible(Map<String, dynamic> row) {
      final lang = '${row['lang']}';
      if (!cinemaSubtitleLanguageMatches(lang, language) &&
          !['all', '', 'null', 'und'].contains(lang)) {
        return false;
      }
      if (!cinemaSubtitleCandidateMatches(
        row,
        CinemaSubtitleQuery(query, resolvedType, season, episode),
        imdbId: imdbId,
      )) {
        return false;
      }
      if (resolvedType != 'series') return true;
      return cinemaSubtitleEpisodeMatches(
        '${row['archiveEntry'] ?? row['subtitleFileName'] ?? row['movieReleaseName'] ?? ''}',
        season,
        episode,
      );
    }

    int compare(Map<String, dynamic> a, Map<String, dynamic> b) {
      final chineseA = cinemaSubtitleLanguageMatches('${a['lang']}', 'zh')
          ? 1
          : 0;
      final chineseB = cinemaSubtitleLanguageMatches('${b['lang']}', 'zh')
          ? 1
          : 0;
      final languageOrder = chineseB.compareTo(chineseA);
      if (languageOrder != 0) return languageOrder;
      final releaseOrder = (b['releaseScore'] as int? ?? 0).compareTo(
        a['releaseScore'] as int? ?? 0,
      );
      if (releaseOrder != 0) return releaseOrder;
      return '${a['subtitleFileName'] ?? a['movieReleaseName'] ?? ''}'
          .compareTo('${b['subtitleFileName'] ?? b['movieReleaseName'] ?? ''}');
    }

    void sortResults() => rows.sort(compare);

    Future<void> verify(Map<String, dynamic> row) async {
      if (!eligible(row)) return;
      try {
        final text = await download(
          '${row['url']}',
          archiveEntry: row['archiveEntry'] as String?,
        );
        final identified = _verifiedDialogueLanguage(text, row);
        if (identified == null ||
            !cinemaSubtitleLanguageMatches('${identified['lang']}', language)) {
          return;
        }
        if (!fingerprints.add(sha256.convert(utf8.encode(text)).toString())) {
          return;
        }
        rows.add({
          ...identified,
          'verified': true,
          'releaseScore': cinemaSubtitleReleaseScore(
            '${row['archiveEntry'] ?? row['subtitleFileName'] ?? row['movieReleaseName'] ?? ''} ${row['releaseFormat'] ?? ''}',
            mediaRelease,
          ),
        });
        sortResults();
        onVerified?.call(List.of(rows));
      } catch (error) {
        status['${row['provider'] ?? '字幕'}资源验证'] = cinemaSubtitleFailureMessage(
          error,
        );
      }
    }

    final seedVerification = Future.wait(candidates.map(verify));
    var works = <Map<String, dynamic>>[];
    try {
      final metadataId = RegExp(r'^tt\d+$').hasMatch(imdbId) ? imdbId : query;
      if (RegExp(r'^tt\d+$').hasMatch(metadataId)) {
        final response = await _dio.getUri<dynamic>(
          Uri.https(
            'v3-cinemeta.strem.io',
            '/meta/$resolvedType/$metadataId.json',
          ),
        );
        if (response.data is Map && response.data['meta'] is Map) {
          works = [Map<String, dynamic>.from(response.data['meta'])];
        }
      } else {
        works = await search(query, resolvedType);
      }
    } catch (_) {
      status['作品匹配'] = '目录暂不可用，继续检索字幕网站';
    }
    final aliases = fallbackNames.map(cinemaMediaTitleKey).toSet();
    final explicitId = RegExp(r'^tt\d+$').hasMatch(imdbId)
        ? imdbId
        : RegExp(r'^tt\d+$').hasMatch(query)
        ? query
        : '';
    works = works.where((work) {
      if (work['type'] != null && work['type'] != resolvedType) return false;
      final workYear = RegExp(
        r'(?:19|20)\d{2}',
      ).firstMatch('${work['year'] ?? work['releaseInfo'] ?? ''}')?.group(0);
      if (year.isNotEmpty && workYear != year) return false;
      if (explicitId.isNotEmpty) return work['id'] == explicitId;
      final names = [
        work['name'],
        work['original_name'],
        work['originalTitle'],
        if (work['aliases'] is List) ...(work['aliases'] as List),
      ];
      return names.whereType<String>().any(
        (name) => aliases.contains(cinemaMediaTitleKey(name)),
      );
    }).toList();
    if (works.map((w) => w['id']).toSet().length > 1) {
      works = []; // An ambiguous same-title remake needs a year or an IMDb ID.
      status['作品匹配'] = '存在同名作品，未自动选择不确定的作品编号';
    }
    final names = <String>{
      ...fallbackNames,
      CinemaSubtitleQuery.parse(query).title,
      if (works.isNotEmpty) '${works.first['name'] ?? ''}',
    }..removeWhere((name) => name.isEmpty || RegExp(r'^tt\d+$').hasMatch(name));
    await Future.wait([
      for (final name in names.take(3))
        () async {
          final found = await _catalogs.search(
            name,
            resolvedType,
            season: season,
            episode: episode,
          );
          candidates.addAll(found.rows);
          for (final item in found.status.entries) {
            status[item.key] = item.value;
          }
        }(),
      () async {
        try {
          final selected = RegExp(r'^tt\d+$').hasMatch(imdbId)
              ? imdbId
              : RegExp(r'^tt\d+$').hasMatch(query)
              ? query
              : works.isEmpty
              ? fallbackNames.contains('American Horror Story')
                    ? 'tt1844624'
                    : ''
              : '${works.first['id']}';
          if (selected.isEmpty) {
            status['OpenSubtitles'] = '未匹配作品编号';
            return;
          }
          final workType = works.isNotEmpty
              ? '${works.first['type'] ?? resolvedType}'
              : resolvedType;
          final found = await subtitles(
            selected,
            workType,
            season: season,
            episode: episode,
          );
          candidates.addAll([
            for (final row in found)
              {
                ...row,
                'provider': 'OpenSubtitles',
                'identityVerified': true,
                'matchedQuery': cinemaMediaTitleKey(query),
                'matchedWorkType': resolvedType,
                'matchedWorkId': selected,
              },
          ]);
          status['OpenSubtitles'] = '${found.length} 条候选';
        } catch (_) {
          status['OpenSubtitles'] = '暂不可访问';
        }
      }(),
    ]);
    await seedVerification;
    final seen = <String>{};
    final packages = candidates
        .where(
          (row) =>
              row['kind'] == 'package' &&
              eligible(row) &&
              seen.add('${row['url']}'),
        )
        .toList();
    final episodeCode =
        'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
    packages.sort(
      (a, b) =>
          ('${b['subtitleFileName']}'.toUpperCase().contains(episodeCode)
                  ? 1
                  : 0)
              .compareTo(
                '${a['subtitleFileName']}'.toUpperCase().contains(episodeCode)
                    ? 1
                    : 0,
              ),
    );
    // Limit each provider separately so an unavailable site's candidates cannot
    // occupy the entire download budget ahead of a working Chinese source.
    final providerCount = <String, int>{};
    packages.removeWhere((package) {
      final provider = '${package['provider']}';
      final count = (providerCount[provider] ?? 0) + 1;
      providerCount[provider] = count;
      return count > 6;
    });
    for (var offset = 0; offset < packages.length; offset += 3) {
      await Future.wait(
        packages.skip(offset).take(3).map((package) async {
          try {
            final files = (await _catalogs.files(
              package,
            )).where(eligible).toList();
            files.sort((a, b) {
              final chinese =
                  (cinemaSubtitleLanguageMatches('${b['lang']}', 'zh') ? 1 : 0)
                      .compareTo(
                        cinemaSubtitleLanguageMatches('${a['lang']}', 'zh')
                            ? 1
                            : 0,
                      );
              return chinese != 0
                  ? chinese
                  : cinemaSubtitleReleaseScore(
                      '${b['subtitleFileName']}',
                      mediaRelease,
                    ).compareTo(
                      cinemaSubtitleReleaseScore(
                        '${a['subtitleFileName']}',
                        mediaRelease,
                      ),
                    );
            });
            await Future.wait(files.take(8).map(verify));
          } catch (error) {
            status['${package['provider']}下载'] = cinemaSubtitleFailureMessage(
              error,
            );
          }
        }),
      );
    }
    final directCandidates = candidates
        .where((row) => row['kind'] != 'package')
        .where(eligible)
        .toList();
    directCandidates.sort(
      (a, b) =>
          cinemaSubtitleReleaseScore(
            '${b['subtitleFileName'] ?? b['movieReleaseName'] ?? ''}',
            mediaRelease,
          ).compareTo(
            cinemaSubtitleReleaseScore(
              '${a['subtitleFileName'] ?? a['movieReleaseName'] ?? ''}',
              mediaRelease,
            ),
          ),
    );
    final direct = <Map<String, dynamic>>[];
    final languageCount = <String, int>{};
    final directSeen = <String>{};
    for (final row in directCandidates) {
      final lang = cinemaSubtitleLanguageMatches('${row['lang']}', 'zh')
          ? 'zh'
          : 'eng';
      final key = '${row['url']}:${row['archiveEntry'] ?? ''}';
      if ((languageCount[lang] ?? 0) >= 12 || !directSeen.add(key)) continue;
      languageCount[lang] = (languageCount[lang] ?? 0) + 1;
      direct.add(row);
    }
    for (var offset = 0; offset < direct.length; offset += 3) {
      await Future.wait(direct.skip(offset).take(3).map(verify));
    }
    sortResults();
    final chineseCount = rows
        .where((row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'zh'))
        .length;
    final englishCount = rows
        .where((row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'eng'))
        .length;
    status['可用对白'] = '中文 $chineseCount 条，English $englishCount 条（已检查实际对白）';
    final adapter = _dio.httpClientAdapter;
    if (adapter is CinemaSubtitleNetworkAdapter &&
        adapter.recoveredHosts.isNotEmpty) {
      status['字幕源连接'] = '部分源的系统代理连接失败，已自动通过 HTTPS 直连恢复';
    }
    return CinemaSubtitleCatalogResult(rows, status);
  }

  Future<List<Map<String, dynamic>>> _rows(Uri uri, String key) async {
    final data = (await _dio.getUri<dynamic>(uri)).data;
    if (data is! Map || data[key] is! List) {
      throw const FormatException('字幕服务返回无效数据');
    }
    return (data[key] as List)
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
  }

  Future<List<Map<String, dynamic>>> search(String query, String type) {
    if (!['movie', 'series'].contains(type)) {
      throw const FormatException('作品类型无效');
    }
    return _rows(
      Uri.parse(
        'https://v3-cinemeta.strem.io/catalog/$type/top/search=${Uri.encodeComponent(CinemaSubtitleQuery.parse(query).title)}.json',
      ),
      'metas',
    );
  }

  Future<List<Map<String, dynamic>>> subtitles(
    String id,
    String type, {
    int season = 1,
    int episode = 1,
  }) async {
    if (!RegExp(r'^tt\d+$').hasMatch(id) ||
        !['movie', 'series'].contains(type) ||
        season < 0 ||
        episode < 1) {
      throw const FormatException('请选择作品及正确的季、集');
    }
    final video = type == 'series' ? '$id:$season:$episode' : id;
    final rows = await _rows(
      Uri.https('opensubtitles-v3.strem.io', '/subtitles/$type/$video.json'),
      'subtitles',
    );
    final seen = <String>{};
    return rows.where((v) {
      final url = Uri.tryParse('${v['url']}');
      return url != null &&
          url.scheme == 'https' &&
          url.host.isNotEmpty &&
          url.userInfo.isEmpty &&
          seen.add(url.toString());
    }).toList();
  }

  Future<String> download(String url, {String? archiveEntry}) async {
    final key = '$url:${archiveEntry ?? ''}';
    if (_verified.containsKey(key)) return _verified[key]!;
    List<int> bytes;
    try {
      bytes = await (archiveEntry == null
          ? _downloadBytes(url)
          : _archives.putIfAbsent(url, () => _downloadBytes(url)));
    } catch (_) {
      // A transient network failure must be retried on the next search.
      _archives.remove(url);
      rethrow;
    }
    if (archiveEntry != null) {
      bytes = await extractSubtitle(bytes, archiveEntry);
    }
    final text = decodeSubtitle(bytes);
    _verified[key] = text;
    // Season prefetch reuses this client across many episodes. Keep complete
    // season archives reusable without retaining every verified file in RAM.
    while (_archives.length > 2) {
      _archives.remove(_archives.keys.first);
    }
    var characters = _verified.values.fold(
      0,
      (int total, text) => total + text.length,
    );
    while (_verified.length > 16 || characters > 4 * 1024 * 1024) {
      final first = _verified.keys.first;
      characters -= _verified.remove(first)!.length;
    }
    return text;
  }

  Future<List<int>> _downloadBytes(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('字幕链接无效');
    }
    const limit = 8 * 1024 * 1024;
    final cancel = CancelToken();
    final response = await _dio.getUri<List<int>>(
      uri,
      options: Options(responseType: ResponseType.bytes),
      cancelToken: cancel,
      onReceiveProgress: (count, total) {
        if (count > limit || total > limit) cancel.cancel('字幕文件过大');
      },
    );
    final bytes = response.data;
    if (bytes == null || bytes.isEmpty || bytes.length > limit) {
      throw const FormatException('字幕文件无效');
    }
    return bytes;
  }

  static Future<List<int>> extractSubtitle(
    List<int> bytes,
    String entry,
  ) async {
    if ((!Platform.isWindows && !Platform.isMacOS) ||
        entry.startsWith('/') ||
        entry.contains(':') ||
        entry.contains('\u0000') ||
        entry.contains('..') ||
        !RegExp(
          r'\.(srt|ass|ssa|vtt)$',
          caseSensitive: false,
        ).hasMatch(entry)) {
      throw const FormatException('该字幕压缩格式暂不可读取');
    }
    final folder = await Directory.systemTemp.createTemp('naku-subtitle-');
    Process? process;
    Timer? timer;
    try {
      final file = File('${folder.path}/subtitle.archive');
      await file.writeAsBytes(bytes, flush: true);
      final pattern = entry
          .replaceAll('[', '[[]')
          .replaceAll('*', '[*]')
          .replaceAll('?', '[?]');
      process = await Process.start(
        Platform.isMacOS
            ? '/usr/bin/tar'
            : '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32\\tar.exe',
        ['-xOf', file.path, '--', pattern],
      );
      timer = Timer(const Duration(seconds: 20), () => process?.kill());
      final errors = process.stderr.drain<void>();
      final output = BytesBuilder(copy: false);
      await for (final part in process.stdout) {
        if (output.length + part.length > 8 * 1024 * 1024) {
          process.kill();
          throw const FormatException('字幕解压后过大');
        }
        output.add(part);
      }
      await errors;
      if (await process.exitCode != 0 || output.isEmpty) {
        throw const FormatException('字幕解压失败');
      }
      return output.takeBytes();
    } finally {
      timer?.cancel();
      process?.kill();
      if (folder.parent.absolute.path == Directory.systemTemp.absolute.path &&
          folder.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last
              .startsWith('naku-subtitle-')) {
        await folder.delete(recursive: true);
      }
    }
  }

  static String _decodeMacChinese(List<int> bytes) {
    final core = ffi.DynamicLibrary.open(
      '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
    );
    final create = core
        .lookupFunction<
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint8>,
            ffi.IntPtr,
            ffi.Uint32,
            ffi.Uint8,
          ),
          ffi.Pointer<ffi.Void> Function(
            ffi.Pointer<ffi.Void>,
            ffi.Pointer<ffi.Uint8>,
            int,
            int,
            int,
          )
        >('CFStringCreateWithBytes');
    final length = core
        .lookupFunction<
          ffi.IntPtr Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)
        >('CFStringGetLength');
    final character = core
        .lookupFunction<
          ffi.Uint16 Function(ffi.Pointer<ffi.Void>, ffi.IntPtr),
          int Function(ffi.Pointer<ffi.Void>, int)
        >('CFStringGetCharacterAtIndex');
    final release = core
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Void>),
          void Function(ffi.Pointer<ffi.Void>)
        >('CFRelease');
    final input = calloc<ffi.Uint8>(bytes.length);
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      // kCFStringEncodingGB_18030_2000; strict conversion returns NULL for
      // malformed bytes instead of silently replacing subtitle dialogue.
      final value = create(ffi.nullptr, input, bytes.length, 0x80000632, 0);
      if (value == ffi.nullptr) throw const FormatException('字幕编码无法读取');
      try {
        return String.fromCharCodes(
          List.generate(length(value), (index) => character(value, index)),
        );
      } finally {
        release(value);
      }
    } finally {
      calloc.free(input);
    }
  }

  static String _decodeLegacyChinese(List<int> bytes) {
    if (Platform.isMacOS) return _decodeMacChinese(bytes);
    if (!Platform.isWindows) {
      throw const FormatException('字幕编码不是 UTF-8 / UTF-16');
    }
    final convert = ffi.DynamicLibrary.open('kernel32.dll')
        .lookupFunction<
          ffi.Int32 Function(
            ffi.Uint32,
            ffi.Uint32,
            ffi.Pointer<ffi.Uint8>,
            ffi.Int32,
            ffi.Pointer<ffi.Uint16>,
            ffi.Int32,
          ),
          int Function(
            int,
            int,
            ffi.Pointer<ffi.Uint8>,
            int,
            ffi.Pointer<ffi.Uint16>,
            int,
          )
        >('MultiByteToWideChar');
    final input = calloc<ffi.Uint8>(bytes.length);
    try {
      input.asTypedList(bytes.length).setAll(0, bytes);
      // GB18030 includes GBK; strict conversion rejects invalid byte sequences.
      for (final page in [54936, 936]) {
        final count = convert(page, 8, input, bytes.length, ffi.nullptr, 0);
        if (count == 0) continue;
        final output = calloc<ffi.Uint16>(count);
        try {
          if (convert(page, 8, input, bytes.length, output, count) == count) {
            return String.fromCharCodes(output.asTypedList(count));
          }
        } finally {
          calloc.free(output);
        }
      }
      throw const FormatException('字幕编码无法读取');
    } finally {
      calloc.free(input);
    }
  }

  static String decodeSubtitle(List<int> bytes) {
    String text;
    if (bytes.length >= 2 &&
        ((bytes[0] == 0xff && bytes[1] == 0xfe) ||
            (bytes[0] == 0xfe && bytes[1] == 0xff))) {
      if (bytes.length.isOdd) throw const FormatException('字幕编码无效');
      final little = bytes[0] == 0xff;
      text = String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          little ? bytes[i] | bytes[i + 1] << 8 : bytes[i] << 8 | bytes[i + 1],
      ]);
    } else {
      try {
        text = utf8.decode(bytes).replaceFirst('\uFEFF', '');
      } on FormatException {
        text = _decodeLegacyChinese(bytes);
      }
    }
    if (RegExp(
      r'<(?:!doctype|html|head|body)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      throw const FormatException('字幕服务返回网页，请换一条字幕重试');
    }
    if (cinemaSubtitleCues(text).isEmpty) {
      throw const FormatException('未返回可用字幕');
    }
    return text;
  }

  void close() => _dio.close(force: true);
}

Future<void> showCinemaOnlineSubtitles(
  BuildContext context,
  Player player, {
  String title = '',
  String imdbId = '',
  String category = '',
  String episodeName = '',
  int? episodeNumber,
  Future<void> Function(CinemaOnlineSubtitleSelection selection)? onApplied,
}) async {
  try {
    await player.pause();
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('无法暂停播放，请手动暂停后重试：$error')));
    }
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (ctx) {
      final media = MediaQuery.of(ctx);
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: (media.size.height - media.viewInsets.bottom) * .85,
          child: SafeArea(
            child: CinemaOnlineSubtitlesPanel(
              player: player,
              title: title,
              imdbId: imdbId,
              category: category,
              episodeName: episodeName,
              episodeNumber: episodeNumber,
              onApplied: onApplied,
            ),
          ),
        ),
      );
    },
  );
}

class CinemaOnlineSubtitlesPanel extends StatefulWidget {
  const CinemaOnlineSubtitlesPanel({
    super.key,
    required this.player,
    this.title = '',
    this.imdbId = '',
    this.client,
    this.category = '',
    this.episodeName = '',
    this.episodeNumber,
    this.onApplied,
  });
  final Player player;
  final String title, imdbId;
  final String category, episodeName;
  final int? episodeNumber;
  final CinemaOnlineSubtitles? client;
  final Future<void> Function(CinemaOnlineSubtitleSelection selection)?
  onApplied;
  @override
  State<CinemaOnlineSubtitlesPanel> createState() =>
      _CinemaOnlineSubtitlesPanelState();
}

class _CinemaOnlineSubtitlesPanelState
    extends State<CinemaOnlineSubtitlesPanel> {
  late final _client = widget.client ?? CinemaOnlineSubtitles();
  late final _initial = CinemaSubtitleQuery.parse(
    widget.title,
    category: widget.category,
    episodeName: widget.episodeName,
    fallbackEpisode: widget.episodeNumber,
  );
  late final _query = TextEditingController(text: _initial.title);
  late final _season = TextEditingController(text: '${_initial.season}'),
      _episode = TextEditingController(text: '${_initial.episode}');
  late String _type = _initial.type;
  String _language = 'zh-eng';
  bool _busy = false, _applying = false;
  bool _applyToSeason = true;
  int _searchGeneration = 0;
  late final Future<bool> _openingPause;
  CinemaSubtitleQuery? _resultQuery;
  String _resultImdbId = '';
  String? _error, _selected;
  List<Map<String, dynamic>> _subtitles = [];
  Map<String, String> _sourceStatus = {};
  @override
  void initState() {
    super.initState();
    _openingPause = _pausePlayback();
  }

  Future<bool> _pausePlayback() async {
    try {
      await widget.player.pause();
      return mounted;
    } catch (error) {
      if (mounted) {
        setState(() => _error = '无法暂停播放，搜索尚未开始：$error');
      }
      return false;
    }
  }

  bool _currentSearch(int generation) =>
      mounted && generation == _searchGeneration && !_applying;

  @override
  void dispose() {
    ++_searchGeneration;
    if (widget.client == null) _client.close();
    _query.dispose();
    _season.dispose();
    _episode.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function(int generation) action) async {
    if (_busy || _applying) return;
    final generation = ++_searchGeneration;
    setState(() {
      _busy = true;
      _error = null;
      _subtitles = [];
      _sourceStatus = {};
      _selected = null;
      _resultQuery = null;
      _resultImdbId = '';
    });
    try {
      await _openingPause;
      if (!_currentSearch(generation) || !await _pausePlayback()) return;
      if (!_currentSearch(generation)) return;
      await action(generation);
    } on DioException catch (error) {
      if (_currentSearch(generation)) {
        setState(
          () => _error = error.response?.statusCode == 429
              ? '字幕服务请求过多，请稍后重试。'
              : '无法连接字幕服务，请检查网络和应用代理设置后重试。',
        );
      }
    } on FormatException catch (error) {
      if (_currentSearch(generation)) {
        setState(() => _error = error.message.toString());
      }
    } catch (_) {
      if (_currentSearch(generation)) {
        setState(() => _error = '字幕加载失败，请换一条字幕重试。');
      }
    } finally {
      if (_currentSearch(generation)) setState(() => _busy = false);
    }
  }

  Future<void> _search() => _run((generation) async {
    final query = _query.text.trim();
    if (query.isEmpty) {
      setState(() => _error = '请输入片名或 IMDb ID');
      return;
    }
    final parsed = CinemaSubtitleQuery.parse(query, category: _type);
    if (parsed.type == 'series') {
      setState(() {
        _type = 'series';
        if (RegExp(
          r'第.*季|\bS\d+|\bSeason\s*\d+',
          caseSensitive: false,
        ).hasMatch(query)) {
          _season.text = '${parsed.season}';
        }
        if (RegExp(r'第.*[集话話]|E\d+', caseSensitive: false).hasMatch(query)) {
          _episode.text = '${parsed.episode}';
        }
      });
    }
    final season = int.tryParse(_season.text),
        episode = int.tryParse(_episode.text);
    if (_type == 'series' &&
        (season == null || season < 0 || episode == null || episode < 1)) {
      setState(() => _error = '请输入正确的季、集数');
      return;
    }
    final snapshot = CinemaSubtitleQuery(
      parsed.title,
      _type,
      season ?? 1,
      episode ?? 1,
    );
    final imdbId = RegExp(r'^tt\d+$').hasMatch(query)
        ? query
        : parsed.title == _initial.title
        ? widget.imdbId
        : '';
    final result = await _client.aggregate(
      query,
      snapshot.type,
      imdbId: imdbId,
      season: snapshot.season,
      episode: snapshot.episode,
      language: _language,
      mediaRelease: widget.episodeName,
      onVerified: (rows) {
        if (_currentSearch(generation)) {
          setState(() {
            _selected = 'aggregate';
            _subtitles = rows;
            _resultQuery = snapshot;
            _resultImdbId = imdbId;
          });
        }
      },
    );
    if (_currentSearch(generation)) {
      setState(() {
        _selected = 'aggregate';
        _subtitles = result.rows;
        _resultQuery = snapshot;
        _resultImdbId = imdbId;
        _sourceStatus = result.status;
        if (result.rows.isEmpty) _error = '未找到可直接加载的当前语言字幕。不可下载的候选资源已过滤。';
      });
    }
  });
  bool _matches(Map<String, dynamic> row) {
    final lang = row['lang']?.toString() ?? '';
    return cinemaSubtitleLanguageMatches(lang, _language);
  }

  void _clearResults(String _) => setState(() {
    ++_searchGeneration;
    _selected = null;
    _subtitles = [];
    _error = null;
    _resultQuery = null;
    _resultImdbId = '';
  });

  @override
  Widget build(BuildContext context) {
    final rows = _subtitles.where(_matches).toList();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('在线搜索字幕', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('一键聚合中英文字幕，中文优先。自动匹配作品、季集并检查实际对白；时间轴仍需匹配片源版本。仅发送片名和作品编号。'),
        const Text('搜索期间保持暂停；选择字幕或关闭面板后，由你手动继续播放。'),
        TextField(
          controller: _query,
          enabled: !_busy,
          decoration: const InputDecoration(
            labelText: '片名或 IMDb ID',
            hintText: '可尝试英文片名',
          ),
          onChanged: _clearResults,
          onSubmitted: (_) => _search(),
        ),
        if (widget.imdbId.isNotEmpty)
          TextButton(
            onPressed: _busy
                ? null
                : () {
                    _query.text = widget.imdbId;
                    _search();
                  },
            child: Text('使用本片编号 ${widget.imdbId}'),
          ),
        DropdownButtonFormField<String>(
          key: ValueKey('subtitle-type-$_type'),
          initialValue: _type,
          decoration: const InputDecoration(labelText: '作品类型'),
          items: const [
            DropdownMenuItem(value: 'movie', child: Text('电影')),
            DropdownMenuItem(value: 'series', child: Text('剧集 / 动漫')),
          ],
          onChanged: _busy
              ? null
              : (v) => setState(() {
                  _type = v!;
                  _subtitles = [];
                  _selected = null;
                }),
        ),
        if (_type == 'series')
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _season,
                  onChanged: _clearResults,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '季（特别篇为 0）'),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: _episode,
                  onChanged: _clearResults,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '集'),
                ),
              ),
            ],
          ),
        if (_type == 'series' && widget.onApplied != null)
          CheckboxListTile(
            key: const ValueKey('subtitle-apply-to-season'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _applyToSeason,
            onChanged: _applying
                ? null
                : (value) => setState(() => _applyToSeason = value ?? true),
            title: const Text('后台下载本季字幕，后续剧集自动加载并沿用匹配的对齐设置'),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy || _applying ? null : _search,
          icon: const Icon(Icons.search),
          label: const Text('聚合搜索字幕'),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        for (final item in _sourceStatus.entries)
          Text(
            '${item.key}：${item.value}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        const Divider(),
        DropdownButtonFormField<String>(
          key: ValueKey('subtitle-language-$_language'),
          initialValue: _language,
          decoration: const InputDecoration(labelText: '字幕语言'),
          items: const [
            DropdownMenuItem(value: 'zh-eng', child: Text('中文 + English（默认）')),
            DropdownMenuItem(value: 'zh', child: Text('中文（简体 / 繁体）')),
            DropdownMenuItem(value: 'eng', child: Text('English')),
          ],
          onChanged: _busy
              ? null
              : (v) {
                  setState(() => _language = v!);
                  if (_selected != null) unawaited(_search());
                },
        ),
        if (_selected != null)
          Text(
            '中文字幕 ${_subtitles.where((row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'zh')).length} 条 · English ${_subtitles.where((row) => cinemaSubtitleLanguageMatches('${row['lang']}', 'eng')).length} 条',
          ),
        if (_selected != null && rows.isEmpty && !_busy)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  _subtitles.isEmpty
                      ? '此季集暂无可用字幕。'
                      : '当前语言暂无字幕；已找到 ${_subtitles.length} 条其他语言字幕。',
                ),
                if (_subtitles.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _language = 'zh-eng'),
                    child: const Text('显示中英文字幕'),
                  ),
              ],
            ),
          ),
        for (final row in rows)
          ListTile(
            leading: const Icon(Icons.subtitles_outlined),
            title: Text(
              '${row['subtitleFileName'] ?? row['movieReleaseName'] ?? '字幕 ${row['id']}'}',
            ),
            subtitle: Text(
              '${row['provider'] ?? ''} · ${cinemaSubtitleLanguageLabel(row)} · 已校验实际对白与格式\n'
              '${(row['releaseScore'] as int? ?? 0) > 0 ? '含当前片源版本标记 · ' : ''}时间轴需匹配片源；不同发行版请使用字幕校准',
            ),
            trailing: const Icon(Icons.download_done),
            onTap: _applying
                ? null
                : () async {
                    final snapshot = _resultQuery;
                    if (snapshot == null) return;
                    final selection = CinemaOnlineSubtitleSelection(
                      query: snapshot,
                      imdbId: _resultImdbId,
                      row: Map<String, dynamic>.unmodifiable(row),
                      applyToSeason:
                          snapshot.type == 'series' && _applyToSeason,
                    );
                    // A verified row can be chosen before slower sources finish.
                    // Their eventual result must not replace this selection.
                    ++_searchGeneration;
                    setState(() {
                      _applying = true;
                      _busy = false;
                      _error = null;
                    });
                    var applied = false;
                    try {
                      if (!await _pausePlayback()) return;
                      final text = await _client.download(
                        '${row['url']}',
                        archiveEntry: row['archiveEntry'] as String?,
                      );
                      if (!mounted) return;
                      await applyCinemaExternalSubtitle(
                        widget.player,
                        text,
                        title: '${row['subtitleFileName'] ?? '在线字幕'}',
                        language: '${row['lang']}',
                        isCurrent: () => mounted,
                      );
                      applied = true;
                      if (!mounted) return;
                      await widget.onApplied?.call(selection);
                      if (context.mounted) Navigator.pop(context);
                    } catch (error) {
                      if (mounted) {
                        setState(
                          () => _error = applied
                              ? '字幕已加载，但后续同季设置保存失败：$error'
                              : error is FormatException
                              ? '字幕加载失败：${error.message}'
                              : '播放器未能接收字幕：$error',
                        );
                      }
                    } finally {
                      if (mounted) setState(() => _applying = false);
                    }
                  },
          ),
      ],
    );
  }
}
