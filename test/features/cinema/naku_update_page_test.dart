import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/naku_update_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naku/updater');
  late Map<String, dynamic> state;
  late List<MethodCall> calls;
  setUp(() {
    state = {
      'version': '2.3.0',
      'build': '29',
      'automaticChecks': false,
      'automaticDownloads': false,
      'latestPublishedVersion': '2.0.3',
      'latestPublishedBuild': '25',
      'status': '当前没有可安装的新版本',
      'lastError': '',
    };
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'state') return state;
          if (call.method == 'configure') {
            state.addAll(Map<String, dynamic>.from(call.arguments as Map));
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Android software update uses its own enabled check and never calls Sparkle',
    (tester) async {
      var checked = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NakuUpdatePage(
            android: true,
            androidCheck: () async {
              checked++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('NAKU Player Android'), findsOneWidget);
      expect(find.text('自动下载和安装'), findsNothing);
      await tester.tap(find.text('检查更新'));
      await tester.pumpAndSettle();
      expect(checked, 1);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('explains when installed build is newer than published feed', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NakuUpdatePage()));
    await tester.pumpAndSettle();
    expect(find.textContaining('更新源最新：2.0.3（25）'), findsOneWidget);
    expect(find.textContaining('新构建发布到更新源后才能自动升级'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Windows update page never polls the macOS Sparkle bridge', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await tester.pumpWidget(const MaterialApp(home: NakuUpdatePage()));
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('NAKU播放器 · Windows'), findsOneWidget);
      expect(find.text('自动下载和安装'), findsNothing);
      expect(calls, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('automatic download enables checks in the same native request', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NakuUpdatePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动下载和安装'));
    await tester.pumpAndSettle();
    final call = calls.singleWhere((call) => call.method == 'configure');
    expect(call.arguments, {
      'automaticChecks': true,
      'automaticDownloads': true,
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disabling checks also disables automatic downloads', (
    tester,
  ) async {
    state['automaticChecks'] = true;
    state['automaticDownloads'] = true;
    await tester.pumpWidget(const MaterialApp(home: NakuUpdatePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动检查更新'));
    await tester.pumpAndSettle();
    expect(calls.singleWhere((call) => call.method == 'configure').arguments, {
      'automaticChecks': false,
      'automaticDownloads': false,
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('manual check asks native Sparkle to show its update window', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: NakuUpdatePage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'check'), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
