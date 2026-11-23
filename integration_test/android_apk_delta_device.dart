// Entry point for a disposable Android emulator. Build only with flutter build apk --debug -t ...
// The fixture serves a release record and its patch. A request for the full APK fails the test.
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:kazumi/features/cinema/cinema_tv_update_service.dart';
import 'package:kazumi/services/update/android_apk_delta.dart';
import 'package:kazumi/services/update/auto_updater.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: Scaffold(body: Text('验证差分升级'))));
  const fixture = String.fromEnvironment('NAKU_DELTA_FIXTURE');
  if (!fixture.startsWith('http://10.0.2.2:'))
    throw StateError('The emulator fixture is required');
  try {
    final dio = Dio();
    final phases = <ApkUpdateStage>[];
    final state = (await androidUpdateChannel.invokeMapMethod<String, dynamic>(
      'state',
    ))!;
    final tv = state['package'] == cinemaTVPackage;
    final kind = tv ? 'TV' : 'Mobile';
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final uri = options.uri;
          if (uri.toString() == cinemaTVFeedUrl)
            options.path = '$fixture/TV.json';
          else if (uri.host == 'github.com' && uri.path.endsWith('.gdiff.gz'))
            options.path = '$fixture/${uri.pathSegments.last}';
          else if (uri.host != '10.0.2.2') {
            handler.reject(
              DioException(
                requestOptions: options,
                error: 'Unexpected full download',
              ),
            );
            return;
          }
          handler.next(options);
        },
      ),
    );
    final File file;
    final AndroidApkTarget target;
    if (tv) {
      final service = CinemaTVUpdateService(dio: dio);
      final installed = await service.installed();
      final release = (await service.check(installed))!;
      file = await service.download(
        installed,
        release,
        cancel: CancelToken(),
        onProgress: (_, _) {},
        onStage: phases.add,
      );
      target = AndroidApkTarget(
        tv: true,
        version: release.version,
        build: release.build,
        url: release.url,
        bytes: release.bytes,
        hash: release.sha256,
      );
    } else {
      final raw = (await dio.get<Map>('$fixture/Mobile.json')).data!;
      target = phoneApkTarget(
        UpdateInfo(
          version: raw['tag_name'],
          description: '',
          downloadUrl: '',
          releaseNotes: '',
          publishedAt: '',
          assets: raw['assets'],
        ),
      )!;
      file = await downloadAndroidApk(
        target: target,
        directory: state['directory'],
        installedBuild: state['build'],
        dio: dio,
        channel: androidUpdateChannel,
        cancel: CancelToken(),
        onProgress: (_, _) {},
        onStage: phases.add,
      );
    }
    if (!phases.contains(ApkUpdateStage.apply) ||
        phases.contains(ApkUpdateStage.fallback) ||
        phases.contains(ApkUpdateStage.full)) {
      throw StateError('Expected patch-only update: $phases');
    }
    final accepted = await androidUpdateChannel.invokeMethod<bool>(
      'install',
      target.arguments(file),
    );
    if (accepted != true) throw StateError('Installer could not open');
    debugPrint('NAKU_DELTA_DEVICE_OK $kind ${target.build} ${target.hash}');
  } catch (error, stack) {
    debugPrint('NAKU_DELTA_DEVICE_ERROR $error\n$stack');
  }
}
