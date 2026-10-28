import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

const cinemaTVPackage = 'com.nakutop.nakuplayer.tv';
const cinemaTVFeedUrl =
    'https://raw.githubusercontent.com/NakuTop/NAKU-Player/main/android-tv-update.json';
const cinemaTVReleasesUrl =
    'https://api.github.com/repos/NakuTop/NAKU-Player/releases?per_page=100';
const cinemaTVMaxUpdateBytes = 500 * 1024 * 1024;

class CinemaTVInstalledVersion {
  const CinemaTVInstalledVersion({
    required this.version,
    required this.build,
    required this.directory,
    required this.canInstall,
  });
  final String version;
  final int build;
  final String directory;
  final bool canInstall;
}

class CinemaTVUpdateRelease {
  const CinemaTVUpdateRelease({
    required this.version,
    required this.build,
    required this.notes,
    required this.url,
    required this.sha256,
    required this.bytes,
  });
  final String version, notes, url, sha256;
  final int build, bytes;
}

List<int>? _versionParts(String value) {
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value)) return null;
  return value.split('.').map(int.parse).toList();
}

int _compareVersion(String first, String second) {
  final a = _versionParts(first), b = _versionParts(second);
  if (a == null || b == null) throw const FormatException('版本格式不正确');
  for (var index = 0; index < 3; index++) {
    final result = a[index].compareTo(b[index]);
    if (result != 0) return result;
  }
  return 0;
}

/// TV releases have a dedicated tag namespace. A phone/macOS release can never
/// become a TV update, even if it is newer or is GitHub's latest release.
CinemaTVUpdateRelease? cinemaTVSelectUpdate(
  List<dynamic> releases,
  CinemaTVInstalledVersion installed,
) {
  final candidates = <CinemaTVUpdateRelease>[];
  for (final raw in releases) {
    if (raw is! Map || raw['draft'] != false || raw['prerelease'] != false) {
      continue;
    }
    final tag = raw['tag_name'];
    if (tag is! String) continue;
    final match = RegExp(
      r'^android-tv-v(\d+\.\d+\.\d+)\+(\d+)$',
    ).firstMatch(tag);
    if (match == null) continue;
    final version = match[1]!, build = int.parse(match[2]!);
    if (build <= installed.build ||
        _compareVersion(version, installed.version) < 0) {
      continue;
    }
    final assets = raw['assets'];
    if (assets is! List) continue;
    final expectedName = 'NAKU-TV-$version-Android-universal.apk';
    final matching = assets
        .whereType<Map>()
        .where(
          (asset) =>
              asset['name'] == expectedName && asset['state'] == 'uploaded',
        )
        .toList();
    if (matching.length != 1) continue;
    final asset = matching.single;
    final digest = asset['digest'], size = asset['size'];
    final url = asset['browser_download_url'];
    if (digest is! String ||
        !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest) ||
        size is! int ||
        size <= 0 ||
        size > cinemaTVMaxUpdateBytes ||
        url is! String) {
      continue;
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 6 ||
        uri.pathSegments.take(4).join('/') !=
            'NakuTop/NAKU-Player/releases/download' ||
        uri.pathSegments[4] != tag ||
        uri.pathSegments[5] != expectedName) {
      continue;
    }
    candidates.add(
      CinemaTVUpdateRelease(
        version: version,
        build: build,
        notes: raw['body'] is String
            ? (raw['body'] as String).substring(
                0,
                (raw['body'] as String).length.clamp(0, 6000),
              )
            : '',
        url: url,
        sha256: digest.substring(7).toLowerCase(),
        bytes: size,
      ),
    );
  }
  candidates.sort((a, b) {
    final version = _compareVersion(b.version, a.version);
    return version != 0 ? version : b.build.compareTo(a.build);
  });
  return candidates.firstOrNull;
}

class CinemaTVUpdateService {
  CinemaTVUpdateService({Dio? dio, MethodChannel? channel})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              headers: {
                'User-Agent': 'NAKU-TV-Updater',
                'Accept': 'application/vnd.github+json',
              },
            ),
          ),
      _channel = channel ?? const MethodChannel('naku/tv-updater');
  final Dio _dio;
  final MethodChannel _channel;

  Future<CinemaTVInstalledVersion> installed() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('state');
    if (value == null ||
        value['package'] != cinemaTVPackage ||
        value['version'] is! String ||
        _versionParts(value['version']) == null ||
        value['build'] is! int ||
        value['directory'] is! String) {
      throw const FormatException('无法读取 TV 安装信息');
    }
    return CinemaTVInstalledVersion(
      version: value['version'],
      build: value['build'],
      directory: value['directory'],
      canInstall: value['canInstall'] == true,
    );
  }

  Future<CinemaTVUpdateRelease?> check(CinemaTVInstalledVersion current) async {
    Object? firstFailure;
    for (final url in [cinemaTVFeedUrl, cinemaTVReleasesUrl]) {
      try {
        final response = await _dio.get<String>(
          url,
          options: Options(responseType: ResponseType.plain),
        );
        final text = response.data ?? '';
        if (text.length > 4 * 1024 * 1024) {
          throw const FormatException('更新信息过大');
        }
        final decoded = jsonDecode(text);
        if (decoded is! List) throw const FormatException('更新源响应不正确');
        return cinemaTVSelectUpdate(decoded, current);
      } catch (error) {
        firstFailure ??= error;
      }
    }
    throw firstFailure!;
  }

  Future<File> download(
    CinemaTVInstalledVersion current,
    CinemaTVUpdateRelease release, {
    required CancelToken cancel,
    required void Function(int received, int total) onProgress,
  }) async {
    final directory = Directory(current.directory);
    await directory.create(recursive: true);
    final basename =
        'naku-tv-${release.version}-${release.build}-${DateTime.now().microsecondsSinceEpoch}';
    final partial = File('${directory.path}/$basename.part');
    final result = File('${directory.path}/$basename.apk');
    IOSink? sink;
    try {
      if (await result.exists()) await result.delete();
      final response = await _dio.get<ResponseBody>(
        release.url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Accept': 'application/octet-stream'},
        ),
        cancelToken: cancel,
      );
      final body = response.data;
      if (body == null) throw const FormatException('下载内容为空');
      sink = partial.openWrite();
      var received = 0;
      await for (final chunk in body.stream) {
        if (cancel.isCancelled) throw cancel.cancelError!;
        received += chunk.length;
        if (received > release.bytes || received > cinemaTVMaxUpdateBytes) {
          throw const FormatException('安装包大小与更新信息不一致');
        }
        sink.add(chunk);
        await sink.flush();
        onProgress(received, release.bytes);
      }
      await sink.close();
      sink = null;
      if (cancel.isCancelled) throw cancel.cancelError!;
      if (received != release.bytes ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.sha256) {
        throw const FormatException('安装包校验失败，请重新下载');
      }
      await partial.rename(result.path);
      await _channel.invokeMethod<void>('verify', _arguments(result, release));
      if (cancel.isCancelled) throw cancel.cancelError!;
      return result;
    } catch (_) {
      await sink?.close();
      if (await partial.exists()) await partial.delete();
      if (await result.exists()) await result.delete();
      rethrow;
    }
  }

  Map<String, Object> _arguments(File file, CinemaTVUpdateRelease release) => {
    'path': file.path,
    'version': release.version,
    'build': release.build,
    'sha256': release.sha256,
    'bytes': release.bytes,
  };

  /// Verification is repeated natively immediately before granting the installer
  /// read access. Android remains responsible for the user's install consent.
  Future<bool> install(File file, CinemaTVUpdateRelease release) async =>
      await _channel.invokeMethod<bool>('install', _arguments(file, release)) ==
      true;
  Future<void> openInstallPermission() =>
      _channel.invokeMethod<void>('permission');
  void dispose() => _dio.close(force: true);
}
