import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_appearance.dart';
import 'package:kazumi/features/cinema/cinema_appearance_settings.dart';
import 'package:kazumi/features/cinema/cinema_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'rapid edits and concurrent flush keep the latest preference across restart',
    () async {
      final dir = Directory.systemTemp.createTempSync('naku-appearance-');
      final file = File('${dir.path}/appearance.json');
      await file.writeAsString(
        jsonEncode({'version': 1, 'backgroundOpacity': .88}),
      );
      final settings = CinemaAppearance(
        settingsFile: file,
        observeNativeAccessibility: false,
      );
      final restart = CinemaAppearance(
        settingsFile: file,
        observeNativeAccessibility: false,
      );
      addTearDown(() async {
        settings.dispose();
        restart.dispose();
        await dir.delete(recursive: true);
      });
      // A user's first drag wins over the asynchronous old preference read.
      settings.setBackgroundOpacity(.33);
      await settings.initialize();
      expect(settings.backgroundOpacity, .33);
      final first = settings.flush();
      for (var i = 22; i <= 79; i++) {
        settings.setBackgroundOpacity(i / 100);
      }
      final second = settings.flush();
      settings.setBackgroundOpacity(.61);
      await Future.wait([first, second, settings.flush()]);
      expect(jsonDecode(file.readAsStringSync())['backgroundOpacity'], .61);
      expect(await File('${file.path}.tmp').exists(), isFalse);
      await restart.initialize();
      expect(restart.backgroundOpacity, .61);
      expect(restart.error, isNull);
    },
  );

  test(
    'bad settings preserve defaults; failed save can be retried without losing preview',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'naku-appearance-errors-',
      );
      final corrupt = File('${dir.path}/corrupt.json');
      await corrupt.writeAsString('{broken');
      final settings = CinemaAppearance(
        settingsFile: corrupt,
        observeNativeAccessibility: false,
      );
      await settings.initialize();
      expect(
        settings.backgroundOpacity,
        CinemaAppearance.defaultBackgroundOpacity,
      );
      expect(settings.error, isNotNull);
      expect(await corrupt.readAsString(), '{broken');
      settings.restoreDefault();
      await settings.flush();
      expect(settings.error, isNull);
      expect(
        jsonDecode(await corrupt.readAsString())['backgroundOpacity'],
        CinemaAppearance.defaultBackgroundOpacity,
      );
      final blocker = File('${dir.path}/blocked');
      await blocker.writeAsString('file, not directory');
      final failing = CinemaAppearance(
        settingsFile: File('${blocker.path}/appearance.json'),
        observeNativeAccessibility: false,
      );
      addTearDown(() async {
        settings.dispose();
        failing.dispose();
        await dir.delete(recursive: true);
      });
      await failing.initialize();
      failing.setBackgroundOpacity(.45);
      await failing.flush();
      expect(failing.backgroundOpacity, .45);
      expect(failing.error, contains('未能保存'));
      await blocker.delete();
      await failing.flush();
      expect(failing.error, isNull);
      expect(
        jsonDecode(
          await File('${blocker.path}/appearance.json').readAsString(),
        )['backgroundOpacity'],
        .45,
      );
    },
  );

  test(
    'native accessibility overrides density while retaining the saved preference',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'naku-appearance-accessibility-',
      );
      const channel = MethodChannel('naku/appearance-test-accessibility');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {'reduceTransparency': true, 'reduceMotion': true},
      );
      final file = File('${dir.path}/appearance.json');
      final settings = CinemaAppearance(
        settingsFile: file,
        nativeChannel: channel,
        observeNativeAccessibility: true,
      );
      addTearDown(() async {
        settings.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });
      await settings.initialize();
      expect(settings.reduceTransparency, isTrue);
      expect(settings.reduceMotion, isTrue);
      expect(settings.effectiveBackgroundOpacity, 1);
      settings.setBackgroundOpacity(.35);
      await settings.flush();
      expect(jsonDecode(file.readAsStringSync())['backgroundOpacity'], .35);
      await _nativeMessage(channel, {
        'reduceTransparency': false,
        'reduceMotion': false,
      });
      expect(settings.effectiveBackgroundOpacity, .35);
      expect(settings.reduceMotion, isFalse);
    },
  );

  testWidgets(
    'a pushed route updates without recreating state or dimming foreground on unfocus',
    (tester) async {
      final settings = _MemoryAppearance();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) =>
              CinemaAppearanceScope(appearance: settings, child: child!),
          home: const Scaffold(body: Text('home')),
        ),
      );
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(builder: (_) => const _Probe()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('increment'));
      await tester.pump();
      settings.setBackgroundOpacity(.72);
      await tester.pump();
      final scaffold = tester.widget<Scaffold>(
        find.byKey(const ValueKey('appearance-probe')),
      );
      expect(scaffold.backgroundColor!.a, closeTo(.72, .001));
      expect(find.text('count:1'), findsOneWidget);
      expect(
        Theme.of(tester.element(find.text('count:1'))).colorScheme.onSurface.a,
        1,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(settings.effectiveBackgroundOpacity, .72);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('appearance-probe')))
            .backgroundColor,
        scaffold.backgroundColor,
      );
      expect(find.text('count:1'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    },
  );

  testWidgets(
    'system opaque mode removes glass filtering and disables transitions across the scope',
    (tester) async {
      final settings = _MemoryAppearance()
        ..accessibility(transparency: true, motion: true);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              CinemaAppearanceScope(appearance: settings, child: child!),
          home: const _Probe(),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('motion:true'), findsOneWidget);
      expect(
        tester
            .widget<Scaffold>(find.byKey(const ValueKey('appearance-probe')))
            .backgroundColor!
            .a,
        1,
      );
      settings.setBackgroundOpacity(.35);
      settings.accessibility(transparency: false, motion: false);
      await tester.pump();
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(find.text('motion:false'), findsOneWidget);
      expect(settings.effectiveBackgroundOpacity, .35);
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    },
  );

  testWidgets(
    'slider updates density and percentage while foreground stays opaque',
    (tester) async {
      final settings = _MemoryAppearance();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 440,
                child: CinemaAppearanceSettings(appearance: settings),
              ),
            ),
          ),
        ),
      );
      tester.widget<Slider>(find.byType(Slider)).onChanged!(.65);
      await tester.pump();
      expect(settings.backgroundOpacity, closeTo(.35, .001));
      expect(find.text('65%'), findsOneWidget);
      expect(
        CinemaTheme.dataFor(settings).colorScheme.onSurface,
        CinemaTheme.text,
      );
      await tester.tap(find.text('恢复默认外观'));
      await tester.pump();
      expect(
        settings.backgroundOpacity,
        CinemaAppearance.defaultBackgroundOpacity,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      settings.dispose();
    },
  );
}

Future<void> _nativeMessage(
  MethodChannel channel,
  Map<String, bool> state,
) async {
  final reply = Completer<void>();
  TestWidgetsFlutterBinding.ensureInitialized().channelBuffers.push(
    channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('accessibilityChanged', state),
    ),
    (_) => reply.complete(),
  );
  await reply.future;
}

// Widget tests exercise live theme propagation; filesystem/native transport
// contracts are covered above outside Flutter's simulated clock.
class _MemoryAppearance extends CinemaAppearance {
  _MemoryAppearance() : super(observeNativeAccessibility: false);
  bool transparency = false, motion = false;
  @override
  bool get reduceTransparency => transparency;
  @override
  bool get reduceMotion => motion;
  @override
  double get effectiveBackgroundOpacity => transparency ? 1 : backgroundOpacity;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> flush() async {}
  @override
  Future<void> retrySave() async {}
  void accessibility({required bool transparency, required bool motion}) {
    this.transparency = transparency;
    this.motion = motion;
    notifyListeners();
  }
}

class _Probe extends StatefulWidget {
  const _Probe();
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  int count = 0;
  @override
  Widget build(BuildContext context) {
    final theme = CinemaTheme.of(context);
    return Theme(
      data: theme,
      child: Scaffold(
        key: const ValueKey('appearance-probe'),
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Column(
          children: [
            Text('count:$count'),
            Text('motion:${MediaQuery.disableAnimationsOf(context)}'),
            TextButton(
              onPressed: () => setState(() => count++),
              child: const Text('increment'),
            ),
            const CinemaGlass(child: Text('foreground')),
          ],
        ),
      ),
    );
  }
}
