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
  var visibleEntries = entries;
  late StateSetter update;
  final committed = <int>[];

  Future<void> mount(WidgetTester tester, {int initial = 0}) async {
    current = initial;
    visibleEntries = entries;
    committed.clear();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return CinemaNavigationIsland<int>(
                  value: current,
                  destinations: visibleEntries,
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

  testWidgets(
    'filtering destinations preserves selected IDs and click mapping',
    (tester) async {
      await mount(tester, initial: 3);
      update(
        () => visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('destination-2')), findsNothing);
      expect(
        tester
            .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
            .dx,
        closeTo(
          tester.getCenter(find.byKey(const ValueKey('destination-3'))).dx,
          1,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('destination-5')));
      await tester.pumpAndSettle();
      expect(current, 5);
      expect(committed, [5]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('same-length ID reordering moves the thumb to the selected ID', (
    tester,
  ) async {
    await mount(tester, initial: 4);
    update(() => visibleEntries = [entries[4], ...entries.take(4), entries[5]]);
    await tester.pumpAndSettle();
    expect(current, 4);
    expect(committed, isEmpty);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))).dx,
        1,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('removing an ID during drag cancels remaining move and release', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('destination-0'))),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('destination-4'))),
    );
    await tester.pump();
    update(
      () => visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
    );
    await tester.pump();
    await gesture.moveTo(
      tester.getCenter(find.byKey(const ValueKey('destination-5'))),
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(current, 0);
    expect(committed, isEmpty);
    expect(
      tester
          .getCenter(find.byKey(const ValueKey('cinema-navigation-thumb')))
          .dx,
      closeTo(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))).dx,
        1,
      ),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'external selection during drag cannot be overwritten on release',
    (tester) async {
      await mount(tester);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('destination-0'))),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-4'))),
      );
      await tester.pump();
      update(() => current = 1);
      await tester.pump();
      await gesture.moveTo(
        tester.getCenter(find.byKey(const ValueKey('destination-5'))),
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(current, 1);
      expect(committed, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final direction in [
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowLeft,
  ]) {
    testWidgets(
      'a hidden selected value has no false highlight and $direction chooses an edge',
      (tester) async {
        await mount(tester, initial: 2);
        update(
          () =>
              visibleEntries = entries.where((entry) => entry.$1 != 2).toList(),
        );
        await tester.pumpAndSettle();
        expect(current, 2);
        expect(
          find.byKey(const ValueKey('cinema-navigation-thumb')),
          findsNothing,
        );
        final selection = find.descendant(
          of: find.byType(CinemaNavigationIsland<int>),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.selected == true,
          ),
        );
        expect(selection, findsNothing);
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.sendKeyEvent(direction);
        await tester.pumpAndSettle();
        final expected = direction == LogicalKeyboardKey.arrowRight ? 0 : 5;
        expect(current, expected);
        expect(committed, [expected]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
