import 'dart:io';
import 'cinema_android_nas.dart';
import 'package:flutter/services.dart';
import 'cinema_models.dart';

int nasInt(dynamic value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;
List<Map<String, dynamic>> nasRows(dynamic value) => value is List
    ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : [];

/// Only file records returned by the NAS details API are offered for playback.
List<({String label, String path})> nasFiles(Map<String, dynamic> detail) {
  final result = <({String label, String path})>[];
  final seen = <String>{};
  void add(dynamic path, String label) {
    if (path is String && path.isNotEmpty && seen.add(path)) {
      result.add((label: label, path: path));
    }
  }

  for (final file in nasRows(detail['file_information'])) {
    add(
      file['path'] ?? file['file_path'],
      file['name']?.toString() ?? '原画版本 ${result.length + 1}',
    );
  }
  for (final episode in nasRows(detail['tv_info'])) {
    for (final file in nasRows(episode['file_info'])) {
      add(
        file['path'],
        '第 ${episode['episode'] ?? ''} 集 · ${episode['ep_name'] ?? file['name'] ?? '原画'}',
      );
    }
  }
  return result;
}

const cinemaNASSource = CinemaSource(
  id: 'nas-movies',
  name: 'NAS 影视中心',
  kind: CinemaSourceKind.direct,
  url: 'https://nas.naku.invalid/',
);

bool isNASMediaReference(String value) {
  final uri = Uri.tryParse(value);
  return uri?.scheme == 'https' &&
      uri?.host == 'nas.naku.invalid' &&
      uri?.path == '/media';
}

String nasMediaReference({
  required String namespace,
  required int id,
  required int library,
  required String path,
}) => Uri.https('nas.naku.invalid', '/media', {
  'nas': namespace,
  'id': '$id',
  'library': '$library',
  'path': path,
}).toString();

Map<String, String> parseNASMediaReference(String value) {
  final uri = Uri.tryParse(value);
  if (!isNASMediaReference(value) ||
      uri == null ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port != 443 ||
      uri.queryParametersAll.values.any((v) => v.length != 1) ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(uri.queryParameters['nas'] ?? '') ||
      (int.tryParse(uri.queryParameters['id'] ?? '') ?? 0) <= 0 ||
      (int.tryParse(uri.queryParameters['library'] ?? '') ?? 0) <= 0 ||
      !(uri.queryParameters['path'] ?? '').startsWith('/') ||
      uri.queryParameters.keys.any(
        (k) => !{'nas', 'id', 'library', 'path'}.contains(k),
      )) {
    throw const FormatException('NAS 资源记录无效，请重新打开影视中心。');
  }
  return uri.queryParameters;
}

/// Persist stable identities only. Session-bearing URLs are resolved in memory.
class CinemaNASClient {
  static const channel = MethodChannel('naku/nas-movies');
  String namespace = '';
  Future<dynamic> _invoke(String method, [Map<String, dynamic>? args]) =>
      Platform.isAndroid
      ? CinemaAndroidNAS.instance.invoke(method, args)
      : channel.invokeMethod<dynamic>(method, args);
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    final value = Map<String, dynamic>.from(
      await _invoke(method, args) as Map? ?? {},
    );
    if (value['namespace'] is String) namespace = value['namespace'] as String;
    return value;
  }

  Future<String> asset(
    Map<String, dynamic> row,
    String path, {
    bool poster = false,
  }) async =>
      await _invoke('asset', {
        'id': row['ug_video_info_id'] is num
            ? (row['ug_video_info_id'] as num).toInt()
            : int.tryParse('${row['ug_video_info_id']}') ?? 0,
        'library': row['media_lib_set_id'] is num
            ? (row['media_lib_set_id'] as num).toInt()
            : int.tryParse('${row['media_lib_set_id']}') ?? 0,
        'path': path,
        'poster': poster,
      }) ??
      '';
  Future<void> logout() async {
    await _invoke('logout');
  }

  Future<String> resolveReference(String reference) async {
    final ref = parseNASMediaReference(reference);
    await call('ensure', {'namespace': ref['nas']});
    return asset({
      'ug_video_info_id': int.parse(ref['id']!),
      'media_lib_set_id': int.parse(ref['library']!),
    }, ref['path']!);
  }
}

CinemaTitle createCinemaNASTitle({
  required String namespace,
  required Map<String, dynamic> row,
  required List<({String label, String path})> files,
  Map<String, dynamic>? detail,
}) {
  final metadata = {
    ...row,
    if (detail?['video_info'] case final Map info)
      ...Map<String, dynamic>.from(info),
    // Playback identity belongs to the selected film or season, not a parent
    // work returned in metadata. Never replace NAS IDs with provider IDs.
    for (final key in ['ug_video_info_id', 'media_lib_set_id', 'type'])
      if (row.containsKey(key)) key: row[key],
  };
  String text(String key) {
    final value = metadata[key];
    return value is String ? value.trim() : '';
  }

  final douban = parseCinemaDoubanId(metadata['douban_id']);
  final year = int.tryParse('${metadata['year']}') ?? 0;
  int integer(dynamic value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;
  CinemaEpisode episode(({String label, String path}) file) => CinemaEpisode(
    name: file.label,
    url: nasMediaReference(
      namespace: namespace,
      id: integer(row['ug_video_info_id']),
      library: integer(row['media_lib_set_id']),
      path: file.path,
    ),
  );
  final television = integer(row['type']) == 2;
  return CinemaTitle(
    id: '$namespace:${row['ug_video_info_id']}',
    sourceId: cinemaNASSource.id,
    title: text('name').isEmpty ? 'NAS 影片' : text('name'),
    poster: text('poster_path').startsWith('https://scraper.ugnas.com/')
        ? text('poster_path')
        : '',
    description: text('introduction'),
    year: year >= 1000 && year <= 9999 ? '$year' : '',
    doubanId: douban.length <= 12 ? douban : '',
    imdbId: parseCinemaImdbId(metadata['imdb_id']),
    // NAS score may originate from TMDB; do not label it a Douban score.
    aliases: text('alias'),
    category: television ? '电视剧' : '电影',
    routes: television
        ? [CinemaRoute(name: 'NAS 原画', episodes: files.map(episode).toList())]
        : [
            for (final file in files)
              CinemaRoute(name: file.label, episodes: [episode(file)]),
          ],
  );
}
