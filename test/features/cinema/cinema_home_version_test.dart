import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_page.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  late Directory directory;
  late CinemaStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('home-version-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [],
    );
    await store.load();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, String version, String build) async {
    PackageInfo.setMockInitialValues(
      appName: 'NAKU播放器',
      packageName: 'com.shenminghao.yingchuan',
      version: version,
      buildNumber: build,
      buildSignature: '',
    );
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaHomePage(
          store: store,
          enableWatchTogether: false,
          enableSearchDiscovery: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sidebar and About show the installed version and build', (
    tester,
  ) async {
    await mount(tester, '1.5.2', '15');
    final versionLabel = find.byKey(const ValueKey('cinema-app-version'));
    expect(tester.widget<Text>(versionLabel).data, 'NAKU播放器  1.5.2+15');
    await tester.ensureVisible(versionLabel);
    await tester.tap(versionLabel);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AboutDialog>(find.byType(AboutDialog)).applicationVersion,
      '1.5.2+15',
    );
    expect(find.textContaining('1.5.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing platform version does not invent an old release', (
    tester,
  ) async {
    await mount(tester, '', '');
    final versionLabel = find.byKey(const ValueKey('cinema-app-version'));
    expect(tester.widget<Text>(versionLabel).data, 'NAKU播放器  版本信息暂不可用');
    await tester.ensureVisible(versionLabel);
    await tester.tap(versionLabel);
    await tester.pumpAndSettle();
    expect(
      tester.widget<AboutDialog>(find.byType(AboutDialog)).applicationVersion,
      '版本信息暂不可用',
    );
    expect(find.textContaining('1.5.0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
