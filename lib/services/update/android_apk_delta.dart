import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

const androidUpdateChannel = MethodChannel('naku/tv-updater');
const maxAndroidApkBytes = 500 * 1024 * 1024;
final _sha = RegExp(r'^[a-f0-9]{64}$');

enum ApkUpdateStage {
  base('正在核对已安装版本'),
  delta('正在下载差分包'),
  apply('正在合成安装包'),
  fallback('正在改用完整安装包'),
  full('正在下载安装包'),
  verify('正在校验安装包');

  const ApkUpdateStage(this.label);
  final String label;
}

class AndroidApkTarget {
  const AndroidApkTarget({
    required this.tv,
    required this.version,
    required this.build,
    required this.url,
    required this.bytes,
    required this.hash,
    this.deltas = const [],
  });
  final bool tv;
  final int build, bytes;
  final String version, url, hash;
  final List<dynamic> deltas;
  String get tag => tv ? 'android-tv-v$version+$build' : 'v$version-android';
  String get name => tv
      ? 'NAKU-TV-$version-Android-universal.apk'
      : 'NAKUPlayer-$version-Android-Mobile.apk';
  Map<String, Object> arguments(File file) => {
    'path': file.path,
    'version': version,
    'build': build,
    'sha256': hash,
    'bytes': bytes,
  };

  bool officialUrl(String address, String name) {
    final uri = Uri.tryParse(address);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        !uri.hasPort &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        uri.pathSegments.length == 6 &&
        uri.pathSegments.take(4).join('/') ==
            'NakuTop/NAKU-Player/releases/download' &&
        uri.pathSegments[4] == tag &&
        uri.pathSegments[5] == name;
  }

  bool get valid =>
      build > 0 &&
      bytes > 0 &&
      bytes <= maxAndroidApkBytes &&
      _sha.hasMatch(hash) &&
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) &&
      officialUrl(url, name);

  List<({String url, String hash, String baseHash, int bytes})> patchesFor(
    int installedBuild,
  ) {
    final matches = <({String url, String hash, String baseHash, int bytes})>[];
    final filename =
        'NAKU-${tv ? 'TV' : 'Mobile'}-$installedBuild-$build.gdiff.gz';
    for (final row in deltas.whereType<Map>().take(32)) {
      final size = row['size'],
          base = row['base_sha256'],
          digest = row['digest'],
          link = row['browser_download_url'];
      if (row['format'] != 'gdiff4-gzip' ||
          row['base_build'] != installedBuild ||
          installedBuild >= build ||
          row['target_sha256'] != hash ||
          base is! String ||
          !_sha.hasMatch(base) ||
          row['name'] != filename ||
          link is! String ||
          !officialUrl(link, filename) ||
          digest is! String ||
          !digest.startsWith('sha256:') ||
          !_sha.hasMatch(digest.substring(7)) ||
          size is! int ||
          size <= 0 ||
          size >= bytes) {
        continue;
      }
      matches.add((
        url: link,
        hash: digest.substring(7),
        baseHash: base,
        bytes: size,
      ));
    }
    return matches..sort((a, b) => a.bytes.compareTo(b.bytes));
  }
}

Future<File> downloadAndroidApk({
  required AndroidApkTarget target,
  required String directory,
  required int installedBuild,
  required Dio dio,
  required CancelToken cancel,
  required ProgressCallback onProgress,
  required MethodChannel channel,
  void Function(ApkUpdateStage)? onStage,
}) async {
  if (!target.valid || installedBuild >= target.build) {
    throw const FormatException('安装包与更新信息不匹配');
  }
  void check() {
    if (cancel.isCancelled) throw cancel.cancelError!;
  }

  void stage(ApkUpdateStage value) {
    check();
    onStage?.call(value);
  }

  final dir = Directory(directory);
  await dir.create(recursive: true);
  final prefix =
      'naku-${target.tv ? 'tv' : 'mobile'}-${target.version}-${target.build}-';
  // Completed files can survive a cancelled system installer. Reuse only after native verification.
  await for (final file in dir.list(followLinks: false)) {
    if (file is! File) continue;
    final name = file.uri.pathSegments.last;
    if (!RegExp(
      r'^naku-(mobile|tv)-\d+\.\d+\.\d+-\d+-\d+\.apk(?:\.part|\.gdiff\.gz)?$',
    ).hasMatch(name)) {
      continue;
    }
    check();
    if (name.startsWith(prefix) &&
        name.endsWith('.apk') &&
        await file.length() == target.bytes) {
      try {
        await channel.invokeMethod<void>('verify', target.arguments(file));
        check();
        return file;
      } catch (_) {
        check();
      }
    }
    // Housekeeping avoids racing another active download or Android's pending installer.
    if ((await file.lastModified()).isBefore(
      DateTime.now().subtract(const Duration(days: 2)),
    )) {
      try {
        await file.delete();
      } on FileSystemException {
        /* already reclaimed */
      }
    }
  }
  final apk = File(
    '${dir.path}/$prefix${DateTime.now().microsecondsSinceEpoch}.apk',
  );
  final partial = File('${apk.path}.part'),
      patch = File('${apk.path}.gdiff.gz');
  Future<void> fetch(String url, File file, int bytes, String hash) async {
    final response = await dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {'Accept': 'application/octet-stream'},
      ),
      cancelToken: cancel,
    );
    final body = response.data;
    if (body == null) throw const FormatException('下载内容为空');
    final output = await file.open(mode: FileMode.write);
    var received = 0;
    try {
      await for (final chunk in body.stream) {
        check();
        received += chunk.length;
        if (received > bytes) throw const FormatException('更新包大小不一致');
        await output.writeFrom(chunk);
        onProgress(received, bytes);
      }
    } finally {
      await output.close();
    }
    check();
    if (received != bytes ||
        (await sha256.bind(file.openRead()).first).toString() != hash) {
      throw const FormatException('文件完整性验证失败');
    }
    check();
  }

  Future<void> remove(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<void> verify() async {
    stage(ApkUpdateStage.verify);
    await channel.invokeMethod<void>('verify', target.arguments(apk));
    check();
  }

  try {
    var fallback = false;
    final candidates = target.patchesFor(installedBuild);
    if (candidates.isNotEmpty) {
      try {
        stage(ApkUpdateStage.base);
        final base = await channel.invokeMethod<String>('baseHash');
        check();
        final selected = candidates
            .where((p) => p.baseHash == base)
            .firstOrNull;
        if (selected != null) {
          stage(ApkUpdateStage.delta);
          await fetch(selected.url, patch, selected.bytes, selected.hash);
          stage(ApkUpdateStage.apply);
          var applying = true;
          unawaited(
            cancel.whenCancel.then((_) async {
              if (applying) {
                try {
                  await channel.invokeMethod<void>('cancelDelta', {
                    'path': apk.path,
                  });
                } on PlatformException {
                  /* task already ended */
                }
              }
            }),
          );
          try {
            await channel.invokeMethod<void>('applyDelta', {
              ...target.arguments(apk),
              'baseBuild': installedBuild,
            });
          } finally {
            applying = false;
          }
          await verify();
          return apk;
        }
      } catch (_) {
        check();
      }
      await remove(apk);
      await remove(patch);
      fallback = true;
    }
    stage(fallback ? ApkUpdateStage.fallback : ApkUpdateStage.full);
    await fetch(target.url, partial, target.bytes, target.hash);
    await partial.rename(apk.path);
    await verify();
    return apk;
  } catch (_) {
    await remove(apk);
    rethrow;
  } finally {
    await remove(partial);
    await remove(patch);
  }
}
