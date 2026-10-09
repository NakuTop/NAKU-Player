import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/dialog/exit_confirmation_dialog.dart';
import 'package:kazumi/features/cinema/cinema_window_close_settings.dart';

void main() {
  Future<void> mount(
    WidgetTester tester, {
    required int Function() read,
    required Future<void> Function(int) save,
    double width = 600,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: CinemaWindowCloseSettings(
            readBehavior: read,
            saveBehavior: save,
          ),
        ),
      ),
    ),
  );

  DropdownButton<int> dropdown(WidgetTester tester) =>
      tester.widget(find.byKey(const ValueKey('window-close-behavior')));

  for (final stored in [0, 1, 2]) {
    testWidgets(
      'existing preference $stored remains untouched until selection',
      (tester) async {
        final writes = <int>[];
        await mount(
          tester,
          read: () => stored,
          save: (value) async => writes.add(value),
        );
        expect(dropdown(tester).value, stored);
        expect(writes, isEmpty);
        expect(dropdown(tester).items!.map((item) => item.value), [0, 1, 2]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('changed choice persists and reopening reads the saved choice', (
    tester,
  ) async {
    var saved = 1;
    await mount(
      tester,
      read: () => saved,
      save: (value) async => saved = value,
    );
    await tester.tap(find.byKey(const ValueKey('window-close-behavior')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每次都询问').last);
    await tester.pumpAndSettle();
    expect(saved, 2);
    expect(dropdown(tester).value, 2);
    await tester.pumpWidget(const SizedBox());
    await mount(
      tester,
      read: () => saved,
      save: (value) async => saved = value,
    );
    expect(dropdown(tester).value, 2);
  });

  testWidgets(
    'saving disables another choice and failure retains the old preference',
    (tester) async {
      final saved = Completer<void>();
      final writes = <int>[];
      await mount(
        tester,
        read: () => 1,
        save: (value) {
          writes.add(value);
          return saved.future;
        },
      );
      dropdown(tester).onChanged!(0);
      await tester.pump();
      expect(dropdown(tester).onChanged, isNull);
      expect(dropdown(tester).value, 1);
      saved.completeError(StateError('disk full'));
      await tester.pumpAndSettle();
      expect(writes, [0]);
      expect(dropdown(tester).value, 1);
      expect(find.text('关闭设置未保存，请重试。'), findsOneWidget);
      expect(dropdown(tester).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown stored values fall back to ask without overwriting storage',
    (tester) async {
      final writes = <int>[];
      await mount(
        tester,
        read: () => 99,
        save: (value) async => writes.add(value),
        width: 340,
      );
      expect(dropdown(tester).value, 2);
      expect(writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unavailable storage disables the setting without writing a default',
    (tester) async {
      final writes = <int>[];
      await mount(
        tester,
        read: () => throw StateError('not opened'),
        save: (value) async => writes.add(value),
      );
      expect(dropdown(tester).value, isNull);
      expect(dropdown(tester).onChanged, isNull);
      expect(writes, isEmpty);
      expect(find.text('关闭设置暂时无法读取，请重新打开设置。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the existing ask dialog retains cancel and remember-choice behavior',
    (tester) async {
      ExitDialogResult? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<ExitDialogResult>(
                    context: context,
                    builder: (_) => const ExitConfirmationDialog(),
                  );
                },
                child: const Text('关闭测试'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('关闭测试'));
      await tester.pumpAndSettle();
      expect(find.text('关闭 NAKU播放器？'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await tester.tap(find.text('关闭测试'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出 NAKU播放器'));
      await tester.tap(find.text('记住我的选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '退出'));
      await tester.pumpAndSettle();
      expect(selected?.action, ExitDialogAction.exit);
      expect(selected?.rememberChoice, isTrue);
    },
  );
}
