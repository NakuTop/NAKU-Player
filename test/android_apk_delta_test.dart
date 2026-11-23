import 'dart:async';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/update/android_apk_delta.dart';
import 'package:kazumi/services/update/auto_updater.dart';

class _Transport implements HttpClientAdapter {
  _Transport(this.load);
  final List<int> Function(Uri) load;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<dynamic>? cancel,
  ) async => ResponseBody.fromBytes(load(options.uri), 200);
  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('fixture/apk-delta');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final full = List<int>.generate(500, (i) => i % 200),
      patch = [1, 2, 3],
      base = 'a' * 64;
  final hash = sha256.convert(full).toString();
  AndroidApkTarget plan(bool tv, {Map<String, Object?> override = const {}}) {
    final key = tv ? 'TV' : 'Mobile',
        tag = tv ? 'android-tv-v3.2.20%2B148' : 'v3.2.20-android';
    final root =
        'https://github.com/NakuTop/NAKU-Player/releases/download/$tag/';
    final name = tv
        ? 'NAKU-TV-3.2.20-Android-universal.apk'
        : 'NAKUPlayer-3.2.20-Android-Mobile.apk';
    final file = 'NAKU-$key-147-148.gdiff.gz';
    return AndroidApkTarget(
      tv: tv,
      version: '3.2.20',
      build: 148,
      bytes: full.length,
      hash: hash,
      url: root + name,
      deltas: [
        {
          'format': 'gdiff4-gzip',
          'name': file,
          'browser_download_url': root + file,
          'base_build': 147,
          'base_sha256': base,
          'target_sha256': hash,
          'size': patch.length,
          'digest': 'sha256:${sha256.convert(patch)}',
          ...override,
        },
      ],
    );
  }

  for (final tv in [false, true]) {
    test(
      'only a qualified $tv delta for the exact base and target is selected',
      () {
        final t = plan(tv);
        expect(t.valid, isTrue);
        expect(t.patchesFor(147), hasLength(1));
        expect(t.patchesFor(146), isEmpty);
        for (final bad in [
          {'base_sha256': 'none'},
          {'target_sha256': 'b' * 64},
          {'size': full.length},
          {'format': 'older'},
          {'browser_download_url': 'https://elsewhere.invalid/a.gz'},
          {'digest': 'sha256:abcd'},
          {'name': 'NAKU-other.gdiff.gz'},
        ]) {
          expect(plan(tv, override: bad).patchesFor(147), isEmpty);
        }
      },
    );
  }
  test(
    'legacy phone full asset still parses and patch lookalike is ignored',
    () {
      final asset = {
        'name': 'NAKUPlayer-3.2.20-Android-Mobile.apk',
        'size': 500,
        'digest': 'sha256:$hash',
        'browser_download_url': plan(false).url,
      };
      UpdateInfo info(List<dynamic> assets) => UpdateInfo(
        version: '3.2.20',
        description: '',
        downloadUrl: '',
        releaseNotes: '',
        publishedAt: '',
        assets: assets,
      );
      expect(phoneApkTarget(info([asset])), isNull);
      final target = phoneApkTarget(
        info([
          {'name': 'Android-Mobile.apk.patch'},
          {...asset, 'build': 148, 'deltas': plan(false).deltas},
        ]),
      )!;
      expect(target.valid, isTrue);
      expect(target.patchesFor(147), hasLength(1));
    },
  );
  for (final scenario in [
    'phone',
    'tv',
    'different base',
    'corrupt patch',
    'bad output',
    'user cancellation',
    'cancel during merge',
  ]) {
    test('download and verify $scenario', () async {
      final dir = await Directory.systemTemp.createTemp('naku-app-update-');
      final calls = <String>[], states = <ApkUpdateStage>[];
      final cancel = CancelToken(), applying = Completer<void>();
      final dio = Dio();
      final target = plan(scenario == 'tv');
      dio.httpClientAdapter = _Transport((uri) {
        final partial = uri.path.endsWith('.gz');
        calls.add(partial ? 'patch' : 'full');
        return partial
            ? (scenario == 'corrupt patch' ? [9, 8, 7] : patch)
            : full;
      });
      messenger.setMockMethodCallHandler(channel, (method) async {
        switch (method.method) {
          case 'baseHash':
            return scenario == 'different base' ? 'b' * 64 : base;
          case 'applyDelta':
            if (scenario == 'cancel during merge') {
              scheduleMicrotask(cancel.cancel);
              await applying.future;
              throw PlatformException(code: 'CANCELLED');
            }
            final contents = scenario == 'bad output' ? [0] : full;
            await File(method.arguments['path']).writeAsBytes(contents);
            return null;
          case 'cancelDelta':
            applying.complete();
            return null;
          case 'verify':
            final out = await File(method.arguments['path']).readAsBytes();
            if (sha256.convert(out).toString() != hash)
              throw PlatformException(code: 'INVALID_UPDATE');
            return null;
        }
        throw MissingPluginException();
      });
      try {
        final download = downloadAndroidApk(
          target: target,
          installedBuild: 147,
          directory: dir.path,
          dio: dio,
          channel: channel,
          cancel: cancel,
          onStage: states.add,
          onProgress: (_, _) {
            if (scenario == 'user cancellation') cancel.cancel();
          },
        );
        if (scenario.contains('cancel')) {
          await expectLater(download, throwsA(isA<DioException>()));
          expect(calls, ['patch']);
          expect(await dir.list().isEmpty, true);
        } else {
          final result = await download;
          expect(await result.readAsBytes(), full);
          expect(await dir.list().length, 1);
          if (scenario == 'phone' || scenario == 'tv') {
            expect(calls, ['patch']);
            expect(states, [
              ApkUpdateStage.base,
              ApkUpdateStage.delta,
              ApkUpdateStage.apply,
              ApkUpdateStage.verify,
            ]);
          } else {
            expect(
              calls,
              scenario == 'different base' ? ['full'] : ['patch', 'full'],
            );
            expect(states, contains(ApkUpdateStage.fallback));
          }
        }
      } finally {
        messenger.setMockMethodCallHandler(channel, null);
        dio.close(force: true);
        await dir.delete(recursive: true);
      }
    });
  }
}
