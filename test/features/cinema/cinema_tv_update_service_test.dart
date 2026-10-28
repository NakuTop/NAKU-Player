import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_update_service.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.response);
  final ResponseBody Function(RequestOptions) response;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async => response(options);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tv-updater');
  const installed = CinemaTVInstalledVersion(
    version: '1.0.0',
    build: 1,
    directory: '/unused',
    canInstall: true,
  );
  final bytes = utf8.encode('a test APK; native verification is mocked');
  Map<String, dynamic> release({String version = '1.1.0', int build = 2}) {
    final tag = 'android-tv-v$version+$build';
    final name = 'NAKU-TV-$version-Android-universal.apk';
    return {
      'tag_name': tag,
      'draft': false,
      'prerelease': false,
      'body': 'TV update',
      'assets': [
        {
          'name': name,
          'state': 'uploaded',
          'size': bytes.length,
          'digest': 'sha256:${sha256.convert(bytes)}',
          'browser_download_url':
              'https://github.com/NakuTop/NAKU-Player/releases/download/${Uri.encodeComponent(tag)}/$name',
        },
      ],
    };
  }

  test('TV channel ignores phone, macOS, prerelease and draft releases', () {
    final phone = release()..['tag_name'] = 'v99.0.0';
    final draft = release(version: '9.0.0', build: 9)..['draft'] = true;
    final pre = release(version: '8.0.0', build: 8)..['prerelease'] = true;
    expect(
      cinemaTVSelectUpdate([phone, draft, pre, release()], installed)!.version,
      '1.1.0',
    );
    expect(cinemaTVSelectUpdate([phone], installed), isNull);
  });

  test('semantic version and Android build both prevent downgrades', () {
    expect(
      cinemaTVSelectUpdate([release(version: '0.9.0', build: 8)], installed),
      isNull,
    );
    expect(
      cinemaTVSelectUpdate([release(version: '8.0.0', build: 1)], installed),
      isNull,
    );
    expect(
      cinemaTVSelectUpdate([
        release(version: '1.0.0', build: 2),
      ], installed)!.build,
      2,
    );
    expect(
      cinemaTVSelectUpdate([
        release(version: '1.2.0', build: 8),
        release(version: '1.10.0', build: 9),
      ], installed)!.version,
      '1.10.0',
    );
  });

  test(
    'only a unique TV universal APK with trusted URL and SHA256 is accepted',
    () {
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (asset) => asset['name'] = 'NAKU-Android-Mobile.apk',
        (asset) => asset['digest'] = '',
        (asset) => asset['digest'] = 'sha256:bad',
        (asset) => asset['size'] = cinemaTVMaxUpdateBytes + 1,
        (asset) =>
            asset['browser_download_url'] = 'http://github.com/NakuTop/a.apk',
        (asset) => asset['browser_download_url'] =
            'https://github.com/Other/Repo/releases/download/a/b.apk',
      ]) {
        final item = release();
        mutation((item['assets'] as List).single);
        expect(cinemaTVSelectUpdate([item], installed), isNull);
      }
      final duplicate = release();
      (duplicate['assets'] as List).add((duplicate['assets'] as List).single);
      expect(cinemaTVSelectUpdate([duplicate], installed), isNull);
    },
  );

  late Directory directory;
  late Dio dio;
  late CinemaTVUpdateService service;
  final nativeCalls = <String>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-tv-update-test-');
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          if (call.method == 'state') {
            return {
              'package': cinemaTVPackage,
              'version': '1.0.0',
              'build': 1,
              'directory': directory.path,
              'canInstall': true,
            };
          }
          if (call.method == 'install') return true;
          return null;
        });
    dio = Dio();
    dio.httpClientAdapter = _Adapter(
      (options) => options.uri.host == 'api.github.com'
          ? ResponseBody.fromString(jsonEncode([release()]), 200)
          : ResponseBody(
              Stream.fromIterable([
                Uint8List.fromList(bytes.take(8).toList()),
                Uint8List.fromList(bytes.skip(8).toList()),
              ]),
              200,
            ),
    );
    service = CinemaTVUpdateService(dio: dio, channel: channel);
  });
  tearDown(() async {
    service.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'check uses installed TV version and strict channel selection',
    () async {
      final current = await service.installed();
      final candidate = await service.check(current);
      expect(candidate!.version, '1.1.0');
      expect(current.build, 1);
    },
  );

  test(
    'static TV feed avoids API rate limits and failed static feed falls back',
    () async {
      final requests = <String>[];
      final current = await service.installed();
      dio.httpClientAdapter = _Adapter((options) {
        requests.add(options.uri.toString());
        return ResponseBody.fromString(jsonEncode([release()]), 200);
      });
      expect((await service.check(current))!.build, 2);
      expect(requests, [cinemaTVFeedUrl]);
      requests.clear();
      dio.httpClientAdapter = _Adapter((options) {
        requests.add(options.uri.toString());
        return options.uri.host == 'raw.githubusercontent.com'
            ? ResponseBody.fromString('not published', 404)
            : ResponseBody.fromString(jsonEncode([release()]), 200);
      });
      expect((await service.check(current))!.build, 2);
      expect(requests, [cinemaTVFeedUrl, cinemaTVReleasesUrl]);
    },
  );

  test(
    'download reports progress, hashes bytes, then asks native verification and install',
    () async {
      final current = await service.installed();
      final candidate = cinemaTVSelectUpdate([release()], current)!;
      final progress = <int>[];
      final file = await service.download(
        current,
        candidate,
        cancel: CancelToken(),
        onProgress: (received, total) => progress.add(received),
      );
      expect(await file.readAsBytes(), bytes);
      expect(progress.last, bytes.length);
      expect(nativeCalls, ['state', 'verify']);
      expect(await service.install(file, candidate), isTrue);
      expect(nativeCalls.last, 'install');
      expect(
        await directory.list().where((f) => f.path.endsWith('.part')).isEmpty,
        isTrue,
      );
    },
  );

  test(
    'checksum mismatch removes partial APK and never asks installer',
    () async {
      final current = await service.installed();
      final item = release();
      ((item['assets'] as List).single as Map)['digest'] = 'sha256:${'0' * 64}';
      final candidate = cinemaTVSelectUpdate([item], current)!;
      await expectLater(
        service.download(
          current,
          candidate,
          cancel: CancelToken(),
          onProgress: (_, _) {},
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await directory.list().isEmpty, isTrue);
      expect(nativeCalls, ['state']);
    },
  );

  test(
    'download cancellation removes partial data and a fresh retry succeeds',
    () async {
      final current = await service.installed();
      final candidate = cinemaTVSelectUpdate([release()], current)!;
      final cancel = CancelToken();
      await expectLater(
        service.download(
          current,
          candidate,
          cancel: cancel,
          onProgress: (_, _) => cancel.cancel(),
        ),
        throwsA(isA<DioException>()),
      );
      expect(await directory.list().isEmpty, isTrue);
      final retry = await service.download(
        current,
        candidate,
        cancel: CancelToken(),
        onProgress: (_, _) {},
      );
      expect(await retry.exists(), isTrue);
    },
  );

  test('native package/signature rejection removes downloaded APK', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'verify') {
            throw PlatformException(code: 'INVALID_UPDATE');
          }
          return null;
        });
    final current = CinemaTVInstalledVersion(
      version: '1.0.0',
      build: 1,
      directory: directory.path,
      canInstall: true,
    );
    final candidate = cinemaTVSelectUpdate([release()], current)!;
    await expectLater(
      service.download(
        current,
        candidate,
        cancel: CancelToken(),
        onProgress: (_, _) {},
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(await directory.list().isEmpty, isTrue);
  });
}
