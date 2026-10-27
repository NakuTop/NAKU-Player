import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:kazumi/services/player/playback_lifecycle.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naku/desktop-controls-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowControls controls;
  late Map<String, dynamic> native;
  late List<MethodCall> calls;
  late String stored;
  bool saveFails = false, conflict = false;
  String rejectedShortcut = 'command-shift-h';
  Completer<Map<String, dynamic>>? queryResponse;

  setUp(() {
    stored = '{}';
    calls = [];
    native = {'registered': true, 'hidden': false, 'reduceTransparency': false};
    saveFails = conflict = false;
    rejectedShortcut = 'command-shift-h';
    queryResponse = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'state') {
        return queryResponse?.future ?? Map.of(native);
      }
      if (call.method == 'configure') {
        final args = call.arguments as Map;
        if (conflict &&
            args['hotkeyEnabled'] == true &&
            args['shortcut'] == rejectedShortcut) {
          throw PlatformException(code: 'conflict', message: '快捷键已被其他应用占用');
        }
        native['registered'] = args['hotkeyEnabled'];
        native['opacity'] = args['translucent'] == true ? args['opacity'] : 1.0;
        return native;
      }
      return null;
    });
    controls = DesktopWindowControls(
      supported: true,
      channel: channel,
      read: () => stored,
      save: (value) async {
        if (saveFails) throw StateError('disk full');
        stored = value;
      },
    );
  });
  tearDown(() {
    controls.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> visibility(bool value) async {
    native['hidden'] = value;
    final reply = Completer<void>();
    TestWidgetsFlutterBinding.ensureInitialized().channelBuffers.push(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('visibilityChanged', {'hidden': value}),
      ),
      (_) => reply.complete(),
    );
    await reply.future;
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'fresh defaults pause hidden playback while keeping the window opaque',
    () async {
      await controls.initialize();
      expect(controls.preferences.pauseOnHide, isTrue);
      expect(controls.preferences.translucent, isFalse);
      expect(native['opacity'], 1.0);
      expect(controls.registered, isTrue);
      await visibility(true);
      expect(controls.blocksPlayback, isTrue);
      expect(
        stored,
        '{}',
        reason: 'Starting the app must not rewrite preferences.',
      );
    },
  );

  test(
    'explicit saved background playback choice remains off after restart',
    () async {
      stored = '{"pauseOnHide":false}';
      await controls.initialize();
      await visibility(true);
      expect(controls.preferences.pauseOnHide, isFalse);
      expect(controls.blocksPlayback, isFalse);
      expect(DesktopWindowPreferences.decode(stored).pauseOnHide, isFalse);
    },
  );

  test(
    'pause policy covers active film and anime owners without auto-resuming',
    () async {
      await controls.initialize();
      await controls.update(controls.preferences.copyWith(pauseOnHide: false));
      final film = Object(), anime = Object();
      var filmPlaying = true, animePlaying = true, pauses = 0;
      controls.register(film, (hidden) async {
        if (controls.blocksPlayback) {
          filmPlaying = false;
          pauses++;
        }
      });
      controls.register(anime, (hidden) async {
        if (controls.blocksPlayback) {
          animePlaying = false;
          pauses++;
        }
      });
      await visibility(true);
      expect(filmPlaying && animePlaying, isTrue);
      await visibility(false);
      await controls.update(controls.preferences.copyWith(pauseOnHide: true));
      await visibility(true);
      await visibility(true);
      expect(
        pauses,
        2,
        reason: 'Duplicate native hide events must be ignored.',
      );
      expect(controls.blocksPlayback, isTrue);
      await visibility(false);
      expect(controls.blocksPlayback, isFalse);
      expect(
        filmPlaying || animePlaying,
        isFalse,
        reason: 'Show cannot call Play.',
      );
      controls.unregister(film);
      await visibility(true);
      expect(pauses, 3);
    },
  );

  test(
    'a player registered after hide sees the blocking policy immediately',
    () async {
      stored = jsonEncode(
        const DesktopWindowPreferences(pauseOnHide: true).toJson(),
      );
      await controls.initialize();
      await visibility(true);
      var paused = false;
      controls.register(
        Object(),
        (hidden) async => paused = controls.blocksPlayback,
      );
      await Future<void>.delayed(Duration.zero);
      expect(paused, isTrue);
    },
  );

  test(
    'shortcut conflict preserves the saved settings and working old shortcut',
    () async {
      await controls.initialize();
      conflict = true;
      expect(
        await controls.update(
          controls.preferences.copyWith(shortcut: 'command-shift-h'),
        ),
        isFalse,
      );
      expect(controls.preferences.shortcut, 'command-b');
      expect(stored, '{}');
      expect(controls.registered, isTrue);
      expect(controls.error, contains('占用'));
    },
  );

  test(
    'startup conflict still loads the window opacity and can be recovered',
    () async {
      conflict = true;
      rejectedShortcut = 'command-b';
      stored = jsonEncode(
        const DesktopWindowPreferences(
          shortcut: 'command-b',
          translucent: true,
          opacity: .45,
        ).toJson(),
      );
      await controls.initialize();
      expect(controls.registered, isFalse);
      expect(native['opacity'], .45);
      expect(controls.error, contains('占用'));
      expect(
        await controls.update(controls.preferences.copyWith(shortcut: 'f9')),
        isTrue,
      );
      expect(controls.registered, isTrue);
      expect(controls.error, isNull);
    },
  );

  test(
    'failed storage rolls native opacity back instead of losing persistence',
    () async {
      await controls.initialize();
      saveFails = true;
      expect(
        await controls.update(
          controls.preferences.copyWith(translucent: true, opacity: .4),
        ),
        isFalse,
      );
      expect(controls.preferences.translucent, isFalse);
      expect(native['opacity'], 1.0);
      expect(controls.error, isNotNull);
      saveFails = false;
      expect(
        await controls.update(
          controls.preferences.copyWith(translucent: true, opacity: .4),
        ),
        isTrue,
      );
      expect(jsonDecode(stored)['opacity'], .4);
      expect(controls.error, isNull);
    },
  );

  test(
    'an occupied default key does not block opacity/pause edits and can be retried',
    () async {
      conflict = true;
      rejectedShortcut = 'command-b';
      await controls.initialize();
      expect(controls.registered, isFalse);
      expect(
        await controls.update(
          controls.preferences.copyWith(
            translucent: true,
            opacity: .6,
            pauseOnHide: true,
          ),
        ),
        isTrue,
      );
      expect(native['opacity'], .6);
      expect(controls.preferences.pauseOnHide, isTrue);
      expect(controls.preferences.hotkeyEnabled, isTrue);
      expect(controls.registered, isFalse);
      conflict = false;
      expect(
        await controls.update(controls.preferences, retryHotkey: true),
        isTrue,
      );
      expect(controls.registered, isTrue);
      expect(controls.error, isNull);
    },
  );

  test(
    'successful settings survive a restart including disabled hotkey and pause',
    () async {
      await controls.initialize();
      await controls.update(
        const DesktopWindowPreferences(
          hotkeyEnabled: false,
          shortcut: 'f8',
          pauseOnHide: true,
          translucent: true,
          opacity: .55,
        ),
      );
      controls.dispose();
      controls = DesktopWindowControls(
        supported: true,
        channel: channel,
        read: () => stored,
        save: (value) async => stored = value,
      );
      await controls.initialize();
      expect(controls.registered, isFalse);
      expect(controls.preferences.pauseOnHide, isTrue);
      expect(controls.preferences.shortcut, 'f8');
      expect(native['opacity'], .55);
    },
  );

  test(
    'bad values cannot make the window invisible or select an unsafe key',
    () {
      expect(DesktopWindowPreferences.decode('{bad').pauseOnHide, isTrue);
      final prefs = DesktopWindowPreferences.decode(
        '{"opacity":-5,"shortcut":"command-q"}',
      );
      expect(prefs.opacity, .3);
      expect(prefs.shortcut, 'command-b');
      expect(prefs.copyWith(opacity: 8).opacity, 1);
      expect(prefs.copyWith(opacity: double.nan).opacity, .3);
    },
  );

  test(
    'focus/fullscreen is distinct from opt-in hide and ordinary minimizing',
    () async {
      Future<bool> check({
        bool visible = true,
        bool minimized = false,
        bool hidden = false,
        bool pause = false,
      }) => isPlaybackWindowBackgrounded(
        isMacOS: true,
        appHidden: hidden,
        pauseWhenHidden: pause,
        isVisible: () async => visible,
        isMinimized: () async => minimized,
      );
      expect(await check(visible: false), isFalse);
      expect(await check(hidden: true), isFalse);
      expect(await check(hidden: true, pause: true), isTrue);
      expect(await check(visible: false, pause: true), isTrue);
      expect(await check(minimized: true), isTrue);
      expect(await check(pause: true), isFalse);
    },
  );

  test(
    'foreground/manual refresh clears a stale hide without starting playback',
    () async {
      stored = jsonEncode(
        const DesktopWindowPreferences(pauseOnHide: true).toJson(),
      );
      await controls.initialize();
      final restored = <bool>[];
      controls.register(Object(), (hidden) async => restored.add(hidden));
      await visibility(true);
      expect(controls.blocksPlayback, isTrue);
      native['hidden'] = false;
      await controls.refreshVisibility();
      expect(controls.blocksPlayback, isFalse);
      expect(restored, [true, false]);
      expect(calls.where((call) => call.method == 'play'), isEmpty);
    },
  );

  test(
    'a real hidden app remains blocked after a manual state query',
    () async {
      stored = jsonEncode(
        const DesktopWindowPreferences(pauseOnHide: true).toJson(),
      );
      await controls.initialize();
      await visibility(true);
      await controls.refreshVisibility();
      expect(controls.blocksPlayback, isTrue);
    },
  );

  test(
    'late visible query cannot override a newer native Hide, including duplicates',
    () async {
      stored = jsonEncode(
        const DesktopWindowPreferences(pauseOnHide: true).toJson(),
      );
      await controls.initialize();
      await visibility(true);
      queryResponse = Completer<Map<String, dynamic>>();
      final refresh = controls.refreshVisibility();
      await Future<void>.delayed(Duration.zero);
      await visibility(true);
      queryResponse!.complete({...native, 'hidden': false});
      await refresh;
      expect(controls.blocksPlayback, isTrue);
    },
  );
}
