import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_navigation_island.dart';

void main() {
  const entries = [
    (0, Icons.movie_outlined, '电影'),
    (1, Icons.tv, '剧集'),
    (2, Icons.animation, '动漫'),
    (3, Icons.bookmark_outline, '收藏'),
    (4, Icons.history, '继续观看'),
    (5, Icons.settings_outlined, '设置'),
  ];
  var current = 0;
  final committed = <int>[];

  Future<void> mount(WidgetTester tester) async {
    current = 0;
    committed.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                return CinemaNavigationIsland<int>(
                  value: current,
                  destinations: entries,
                  keyFor: (value) => ValueKey('destination-$value'),
                  onChanged: (value) => setState(() {
                    current = value;
                    committed.add(value);
                  }),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'mouse thumb drag follows across cells and commits only on release',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(current, 0);
      expect(committed, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current, 4);
      expect(committed, [4]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('short or vertical drag returns to the original destination', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('destination-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(4, 35));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(current, 0);
    expect(committed, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping still opens every destination exactly once', (
    tester,
  ) async {
    await mount(tester);
    for (var i = 1; i < entries.length; i++) {
      await tester.tap(find.byKey(ValueKey('destination-$i')));
      await tester.pumpAndSettle();
      expect(current, i);
    }
    expect(committed, [1, 2, 3, 4, 5]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keyboard navigation preserves bounds and stops when idle', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(current, 1);
    expect(committed, [1]);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox());
  });
}
