import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/player_keyboard_shortcuts.dart';

void main() {
  late FocusScopeNode scope;
  late FocusNode video;
  late FocusNode button;
  late FocusNode slider;
  late FocusNode selector;
  late FocusNode editor;
  late Map<String, int> calls;
  late int activations;
  late double sliderValue;
  late String language;
  late int repeats;
  late int releases;

  setUp(() {
    scope = FocusScopeNode();
    video = FocusNode();
    button = FocusNode();
    slider = FocusNode();
    selector = FocusNode();
    editor = FocusNode();
    calls = {};
    activations = 0;
    sliderValue = .5;
    language = 'zh';
    repeats = releases = 0;
  });

  tearDown(() {
    scope.dispose();
    video.dispose();
    button.dispose();
    slider.dispose();
    selector.dispose();
    editor.dispose();
  });

  void playerTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  Future<void> mount(WidgetTester tester) async {
    const shortcuts = {
      'play': [' '],
      'forward': ['Arrow Right'],
      'rewind': ['Arrow Left'],
      'up': ['Arrow Up'],
      'down': ['Arrow Down'],
      'activate': ['Enter', 'Numpad Enter'],
      'fullscreen': ['F'],
    };
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusScope(
            node: scope,
            child: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  Focus(
                    focusNode: video,
                    child: const SizedBox(height: 40, child: Text('Video')),
                  ),
                  PlayerKeyboardShortcuts(
                    focusScopeNode: scope,
                    shortcuts: shortcuts,
                    actions: {
                      for (final action in shortcuts.keys)
                        action: () => calls.update(
                          action,
                          (count) => count + 1,
                          ifAbsent: () => 1,
                        ),
                    },
                    longPressActions: {
                      'forward': PlayerLongPressShortcutActions(
                        onRepeat: () => repeats++,
                        onRelease: () => releases++,
                      ),
                    },
                  ),
                  ElevatedButton(
                    focusNode: button,
                    onPressed: () => activations++,
                    child: const Text('Align subtitle'),
                  ),
                  Slider(
                    focusNode: slider,
                    value: sliderValue,
                    onChanged: (value) => setState(() => sliderValue = value),
                  ),
                  DropdownButton<String>(
                    focusNode: selector,
                    value: language,
                    items: const [
                      DropdownMenuItem(value: 'zh', child: Text('Chinese')),
                      DropdownMenuItem(value: 'en', child: Text('English')),
                    ],
                    onChanged: (value) => setState(() => language = value!),
                  ),
                  TextField(focusNode: editor),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    video.requestFocus();
    await tester.pumpAndSettle();
  }

  playerTest('ordinary video focus keeps playback and navigation shortcuts', (
    tester,
  ) async {
    await mount(tester);
    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.keyF,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
    expect(calls, {
      'play': 1,
      'forward': 1,
      'rewind': 1,
      'up': 1,
      'down': 1,
      'activate': 1,
      'fullscreen': 1,
    });
    expect(releases, 1);
    expect(activations, 0);
  });

  playerTest(
    'focused button activates normally and keeps unrelated shortcuts',
    (tester) async {
      await mount(tester);
      button.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(activations, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(activations, 2);
      for (final key in [
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        button.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(key);
      }
      button.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.pump();
      expect(calls, {'fullscreen': 1});
    },
  );

  playerTest(
    'focused slider changes value without seeking or changing volume',
    (tester) async {
      await mount(tester);
      slider.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(sliderValue, greaterThan(.5));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(calls, isEmpty);
      expect(repeats, 0);
      expect(releases, 0);
    },
  );

  playerTest('focused selector opens and selects using its own keyboard keys', (
    tester,
  ) async {
    await mount(tester);
    selector.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('English'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(language, 'en');
    expect(calls, isEmpty);
  });

  playerTest('editing text ignores all player shortcuts', (tester) async {
    await mount(tester);
    editor.requestFocus();
    await tester.pump();
    for (final key in [
      LogicalKeyboardKey.space,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.keyF,
    ]) {
      await tester.sendKeyEvent(key);
    }
    await tester.pump();
    expect(calls, isEmpty);
  });

  playerTest('held shortcut always releases after focus moves to a control', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(calls, {'forward': 1});
    expect(repeats, 1);
    button.requestFocus();
    await tester.pump();
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(releases, 1);
  });
}
