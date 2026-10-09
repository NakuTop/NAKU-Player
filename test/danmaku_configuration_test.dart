import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_service_status_tile.dart';
import 'package:kazumi/request/clients/danmaku_client.dart';
import 'package:kazumi/utils/dandan_credentials.dart';
import 'package:logger/logger.dart';

void main() {
  setUpAll(() => Logger.level = Level.off);

  for (final credentials in [
    const DandanCredentials(id: '', secret: ''),
    const DandanCredentials(id: 'test-app', secret: ''),
    const DandanCredentials(id: '', secret: 'test-only-secret'),
    const DandanCredentials(id: '  ', secret: 'test-only-secret'),
    const DandanCredentials(id: 'test-app', secret: ' \n '),
  ]) {
    test(
      'incomplete credentials stop before transport (${credentials.id})',
      () async {
        final adapter = _RecordingAdapter();
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(dio.close);
        final client = DanmakuClient(credentials: credentials, dio: dio);

        expect(credentials.isConfigured, isFalse);
        for (final path in [
          '/api/v2/search/episodes',
          '/api/v2/bangumi/bgmtv/309311',
          '/api/v2/comment/123450001',
        ]) {
          await expectLater(
            client.get('https://api.dandanplay.net$path'),
            throwsA(isA<DanmakuNotConfiguredException>()),
          );
        }
        expect(adapter.requests, isEmpty);
      },
    );
  }

  test(
    'configured client retains the required application signature',
    () async {
      const credentials = DandanCredentials(
        id: 'test-app',
        secret: 'test-only-secret',
      );
      final adapter = _RecordingAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      addTearDown(dio.close);
      final client = DanmakuClient(credentials: credentials, dio: dio);

      final result = await client.get(
        'https://api.dandanplay.net/api/v2/comment/123450001',
        queryParameters: {'withRelated': 'true'},
      );
      expect(credentials.isConfigured, isTrue);
      expect(result, {'comments': []});
      final request = adapter.requests.single;
      final timestamp = request.headers['X-Timestamp'];
      expect(request.headers['X-AppId'], 'test-app');
      final signature = base64Encode(
        sha256
            .convert(
              utf8.encode(
                'test-app$timestamp/api/v2/comment/123450001test-only-secret',
              ),
            )
            .bytes,
      );
      expect(request.headers['X-Signature'], signature);
      expect(request.queryParameters['withRelated'], 'true');
    },
  );

  test('configuration failures remain distinct from empty danmaku', () {
    final result = DanmakuLoadResult.failed(
      bangumiID: 0,
      error: const DanmakuNotConfiguredException(),
    );
    expect(result.isFailed, isTrue);
    expect(result.hasDanmakus, isFalse);
    expect(result.failureMessage, contains('尚未配置弹幕服务'));
    expect(result.failureMessage, contains('弹幕设置'));
    expect(
      danmakuFailureMessage(StateError('fixture'), fallback: '搜索失败'),
      '搜索失败',
    );
    expect(
      DanmakuLoadResult.success(danmakus: [], bangumiID: 0).status,
      DanmakuLoadStatus.empty,
    );
  });

  test('offline cache remains usable without any remote service', () async {
    final cached = DanmakuEntry(
      message: '离线弹幕',
      time: 1,
      type: 1,
      color: Colors.white,
      source: 'fixture',
    );
    final downloads = _CachedDownloads([cached]);
    final controller = PlayerDanmakuController(
      isLocalPlayback: () => true,
      downloadController: downloads,
    );
    final result = await controller.fetchDanmaku(309311, 'fixture', 1);
    expect(result.hasDanmakus, isTrue);
    expect(result.danmakus, [cached]);
    expect(result.failureMessage, isNull);
    expect(downloads.reads, 1);
  });

  test(
    'automatic loading and offline fallback report missing configuration',
    () async {
      for (final local in [false, true]) {
        final controller = PlayerDanmakuController(
          isLocalPlayback: () => local,
          downloadController: _CachedDownloads(null),
        );
        final result = await controller.fetchDanmaku(309311, 'fixture', 1);
        expect(result.isFailed, isTrue);
        expect(result.failureMessage, DanmakuNotConfiguredException.message);
      }
    },
    // These cases exercise the production singleton of an unconfigured build.
    // The independent client fixtures above cover the guard in every build.
    skip: dandanCredentials.isConfigured,
  );

  testWidgets('settings explain availability and retain the official guide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DanmakuServiceStatusTile())),
    );
    expect(
      find.text(dandanCredentials.isConfigured ? '弹幕服务已配置' : '弹幕服务尚未配置'),
      findsOneWidget,
    );
    expect(find.textContaining('官方接入说明'), findsOneWidget);
    if (!dandanCredentials.isConfigured) {
      expect(find.textContaining('已有离线弹幕仍可使用'), findsOneWidget);
    }
    expect(
      DanmakuServiceStatusTile.guideUri.toString(),
      'https://doc.dandanplay.com/open/',
    );
    expect(tester.takeException(), isNull);
  });
}

class _RecordingAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      '{"comments":[]}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _CachedDownloads implements DownloadController {
  _CachedDownloads(this.cached);
  final List<DanmakuEntry>? cached;
  int reads = 0;

  @override
  Future<List<DanmakuEntry>?> getCachedDanmakus(
    int bangumiId,
    String pluginName,
    int episode,
  ) async {
    reads++;
    return cached;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
