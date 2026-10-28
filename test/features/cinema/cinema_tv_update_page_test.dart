import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_update_page.dart';
import 'package:kazumi/features/cinema/cinema_tv_update_service.dart';

class _Service extends CinemaTVUpdateService {
  bool allowed = false;
  int downloads = 0, installs = 0, permissions = 0;
  bool available = true;
  @override
  Future<CinemaTVInstalledVersion> installed() async =>
      CinemaTVInstalledVersion(
        version: '1.1.0',
        build: 2,
        directory: '/unused',
        canInstall: allowed,
      );
  @override
  Future<CinemaTVUpdateRelease?> check(
    CinemaTVInstalledVersion current,
  ) async => available
      ? const CinemaTVUpdateRelease(
          version: '1.2.0',
          build: 3,
          notes: 'Improved TV playback',
          url: 'https://example.invalid/update.apk',
          sha256: 'unused',
          bytes: 100,
        )
      : null;
  @override
  Future<File> download(
    CinemaTVInstalledVersion current,
    CinemaTVUpdateRelease release, {
    required CancelToken cancel,
    required void Function(int, int) onProgress,
  }) async {
    downloads++;
    onProgress(100, 100);
    return File('/unused.apk');
  }

  @override
  Future<bool> install(File file, CinemaTVUpdateRelease release) async {
    installs++;
    return allowed;
  }

  @override
  Future<void> openInstallPermission() async {
    permissions++;
  }
}

void main() {
  testWidgets(
    'TV updater presents one primary remote action and stays within 960x540',
    (tester) async {
      tester.view.physicalSize = const Size(960, 540);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: CinemaTVUpdatePage(service: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('NAKU TV 1.1.0 · 2'), findsOneWidget);
      expect(find.text('下载并安装 1.2.0'), findsOneWidget);
      expect(find.textContaining('GitHub'), findsNothing);
      expect(service.downloads, 0);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(service.downloads, 1);
      expect(service.installs, 1);
      expect(find.text('允许安装并继续'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission return continues verified update without a second download',
    (tester) async {
      final service = _Service();
      addTearDown(service.dispose);
      await tester.pumpWidget(
        MaterialApp(home: CinemaTVUpdatePage(service: service)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载并安装 1.2.0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('允许安装并继续'));
      await tester.pumpAndSettle();
      expect(service.permissions, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      service.allowed = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(service.downloads, 1);
      expect(service.installs, 2);
      expect(find.text('继续安装'), findsOneWidget);
      expect(find.textContaining('请在系统安装器中确认更新'), findsOneWidget);
    },
  );

  testWidgets('empty TV channel does not claim a phone release is an update', (
    tester,
  ) async {
    final service = _Service()..available = false;
    addTearDown(service.dispose);
    await tester.pumpWidget(
      MaterialApp(home: CinemaTVUpdatePage(service: service)),
    );
    await tester.pumpAndSettle();
    expect(find.text('未发现可安装的 TV 新版本。'), findsOneWidget);
    expect(find.text('重新检查'), findsOneWidget);
    expect(service.downloads, 0);
  });
}
