import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_desktop_window_settings.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naku/desktop-controls-widget-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowControls controls;
  late String saved;
  late List<MethodCall> calls;
  setUp(() {
    saved = '{}';
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'configure') {
        final args = call.arguments as Map;
        if (args['shortcut'] == 'control-option-b' && args['hotkeyEnabled'] == true) {
          throw PlatformException(code: 'conflict', message: '快捷键已被其他应用占用');
        }
        return {
          'registered': args['hotkeyEnabled'],
          'hidden': false,
          'reduceTransparency': false,
        };
      }
      return null;
    });
    controls = DesktopWindowControls(
      supported: true,
      channel: channel,
      read: () => saved,
      save: (value) async => saved = value,
    );
  });
  tearDown(() {
    controls.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showCinemaDesktopWindowSettings(context, controls: controls),
              child: const Text('窗口设置'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('窗口设置'));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(360, 640), const Size(1200, 900)]) {
    testWidgets('window controls fit $size and persist pause and opacity', (
      tester,
    ) async {
      await mount(tester, size);
      final pause = find.byKey(const ValueKey('desktop-pause-on-hide'));
      await tester.ensureVisible(pause);
      await tester.tap(pause);
      await tester.pumpAndSettle();
      expect(controls.preferences.pauseOnHide, isTrue);
      final transparent = find.byKey(const ValueKey('desktop-translucent'));
      await tester.ensureVisible(transparent);
      await tester.tap(transparent);
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(
        find.byKey(const ValueKey('desktop-opacity')),
      );
      slider.onChanged!(.55);
      await tester.pump();
      expect(find.text('55%'), findsOneWidget);
      slider.onChangeEnd!(.55);
      await tester.pumpAndSettle();
      expect(jsonDecode(saved)['opacity'], .55);
      expect(jsonDecode(saved)['translucent'], isTrue);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('窗口设置'));
      await tester.pumpAndSettle();
      expect(find.text('55%'), findsOneWidget);
    });
  }

  testWidgets(
    'a shortcut conflict restores the old selection and displays the reason',
    (tester) async {
      await mount(tester, const Size(900, 900));
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('⌃⌥B').last);
      await tester.pumpAndSettle();
      expect(controls.preferences.shortcut, 'command-b');
      expect(find.text('⌘B'), findsOneWidget);
      expect(find.text('快捷键已被其他应用占用'), findsOneWidget);
      expect(saved, '{}');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hide button closes its dialog before invoking the native hide', (
    tester,
  ) async {
    await mount(tester, const Size(900, 900));
    await tester.tap(find.text('立即隐藏'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(calls.where((call) => call.method == 'hide'), hasLength(1));
  });
}
