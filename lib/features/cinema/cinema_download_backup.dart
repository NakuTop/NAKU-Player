import 'dart:convert';
import 'dart:io';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:path/path.dart' as p;
import 'cinema_models.dart';

/// Download metadata is portable; machine paths and security bookmarks are not.
/// Files are separately copied using the normal id_rule/episode folder layout.
class CinemaDownloadBackup {
  static bool _component(String value) =>
      value.isNotEmpty &&
      value.length <= 200 &&
      value != '.' &&
      value != '..' &&
      !RegExp(r'[/\\\x00-\x1f]').hasMatch(value);

  static Map<String, dynamic> encode(DownloadRecord record) => {
    'id': record.bangumiId,
    'name': record.bangumiName,
    'cover': record.bangumiCover,
    'rule': record.pluginName,
    'createdAt': record.createdAt.millisecondsSinceEpoch,
    'media': record.mediaMetadata,
    'source': record.sourceLabel,
    'episodes': [
      for (final episode in record.episodes.values)
        {
          'number': episode.episodeNumber,
          'name': episode.episodeName,
          'road': episode.road,
          'status': episode.status,
          'progress': episode.progressPercent,
          'segments': episode.totalSegments,
          'downloaded': episode.downloadedSegments,
          'file': episode.localM3u8Path.isEmpty
              ? ''
              : p.basename(episode.localM3u8Path),
          'url': episode.networkM3u8Url,
          'completedAt': episode.completedAt?.millisecondsSinceEpoch,
          'bytes': episode.totalBytes,
          'page': episode.episodePageUrl,
          'danmaku': episode.danmakuData,
          'danmakuId': episode.danDanBangumiID,
          'headers': episode.requestHeadersJson,
        },
    ],
  };

  static List<DownloadRecord> decode(Object? value) {
    if (value == null) return [];
    if (value is! List || value.length > 5000) {
      throw const FormatException('下载记录备份无效');
    }
    final records = <DownloadRecord>[];
    final keys = <String>{};
    for (final raw in value) {
      if (raw is! Map ||
          raw['episodes'] is! List ||
          (raw['episodes'] as List).length > 5000 ||
          raw['id'] is! int ||
          raw['createdAt'] is! int ||
          (raw['createdAt'] as int).abs() > 8640000000000000 ||
          raw['rule'] is! String ||
          !_component(raw['rule']) ||
          !_component('${raw['id']}_${raw['rule']}')) {
        throw const FormatException('下载记录备份无效');
      }
      String string(Map data, String key, {int limit = 65536}) {
        final value = data[key];
        if (value is! String || value.length > limit) {
          throw const FormatException('下载记录字段无效');
        }
        return value;
      }

      int integer(Map data, String key, {int max = 1 << 53}) {
        final value = data[key];
        if (value is! int || value < 0 || value > max) {
          throw const FormatException('下载记录数值无效');
        }
        return value;
      }

      final episodes = <int, DownloadEpisode>{};
      for (final episode in raw['episodes'] as List) {
        if (episode is! Map ||
            episode['progress'] is! num ||
            !(episode['progress'] as num).isFinite ||
            episode['progress'] < 0 ||
            episode['progress'] > 1 ||
            episode['completedAt'] != null &&
                (episode['completedAt'] is! int ||
                    (episode['completedAt'] as int).abs() > 8640000000000000)) {
          throw const FormatException('下载分集备份无效');
        }
        final number = integer(episode, 'number', max: 100000);
        final file = string(episode, 'file', limit: 200);
        if (file.isNotEmpty && !_component(file)) {
          throw const FormatException('下载文件名无效');
        }
        final url = string(episode, 'url');
        if (url.isNotEmpty &&
            !{'http', 'https'}.contains(Uri.tryParse(url)?.scheme)) {
          throw const FormatException('下载地址无效');
        }
        final headers = string(episode, 'headers');
        if (headers.isNotEmpty) {
          final parsed = jsonDecode(headers);
          if (parsed is! Map ||
              parsed.length > 50 ||
              parsed.entries.any(
                (e) => e.key is! String || e.value is! String,
              )) {
            throw const FormatException('下载请求头无效');
          }
        }
        if (episodes.containsKey(number)) {
          throw const FormatException('下载分集重复');
        }
        episodes[number] = DownloadEpisode(
          number,
          string(episode, 'name'),
          integer(episode, 'road', max: 100000),
          integer(episode, 'status', max: 5),
          (episode['progress'] as num).toDouble(),
          integer(episode, 'segments'),
          integer(episode, 'downloaded'),
          file,
          '',
          url,
          episode['completedAt'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(episode['completedAt']),
          '',
          integer(episode, 'bytes'),
          string(episode, 'page'),
          danmakuData: string(episode, 'danmaku', limit: 16 * 1024 * 1024),
          danDanBangumiID: integer(episode, 'danmakuId'),
          requestHeadersJson: headers,
        );
      }
      final media = string(raw, 'media', limit: 4 * 1024 * 1024);
      if (media.isNotEmpty) {
        final metadata = jsonDecode(media);
        if (metadata is! Map ||
            metadata['title'] is! Map ||
            metadata['source'] is! Map ||
            metadata['routeIndex'] is! int) {
          throw const FormatException('影视下载作品备份无效');
        }
        final title = CinemaTitle.fromJson(
          Map<String, dynamic>.from(metadata['title']),
        );
        CinemaSource.fromJson(Map<String, dynamic>.from(metadata['source']));
        if (metadata['routeIndex'] < 0 ||
            metadata['routeIndex'] >= title.routes.length) {
          throw const FormatException('影视下载线路备份无效');
        }
      }
      final record = DownloadRecord(
        raw['id'],
        string(raw, 'name'),
        string(raw, 'cover'),
        raw['rule'],
        episodes,
        DateTime.fromMillisecondsSinceEpoch(raw['createdAt']),
        mediaMetadata: media,
        sourceLabel: string(raw, 'source'),
      );
      if (!keys.add(record.key)) {
        throw const FormatException('下载作品重复');
      }
      records.add(record);
    }
    return records;
  }

  static Future<void> relocate(DownloadRecord record, String root) async {
    final base = p.normalize(p.absolute(root));
    for (final episode in record.episodes.values) {
      final directory = p.join(
        base,
        '${record.bangumiId}_${record.pluginName}',
        '${episode.episodeNumber}',
      );
      // Never adopt a directory that traverses a link outside the picked root.
      var current = directory;
      while (current != base) {
        if (await FileSystemEntity.isLink(current)) {
          throw const FormatException('下载目录包含符号链接，请复制实际文件夹');
        }
        current = p.dirname(current);
      }
      final file = episode.localM3u8Path.isEmpty
          ? ''
          : p.join(directory, episode.localM3u8Path);
      if (file.isNotEmpty && await FileSystemEntity.isLink(file)) {
        throw const FormatException('下载视频包含符号链接');
      }
      final present =
          file.isNotEmpty &&
          await File(file).exists() &&
          await File(file).length() > 0;
      episode.localM3u8Path = file;
      episode.downloadDirectory = directory;
      if (episode.status != DownloadStatus.completed || !present) {
        episode.status = DownloadStatus.paused;
        episode.errorMessage = present
            ? '迁移后可手动继续下载'
            : '请将视频复制到当前下载目录后重新导入，或继续下载';
      }
    }
  }
}
