import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_pane_transition.dart';

void main() {
  testWidgets('new pane is usable during motion and frames do not rebuild it', (
    tester,
  ) async {
    var builds = 0;
    var taps = 0;
    Future<void> show(String destination) => tester.pumpWidget(
      MaterialApp(
        home: CinemaPaneTransition(
          destination: destination,
          child: Builder(
            builder: (context) {
              builds++;
              return Center(
                child: TextButton(
                  onPressed: () => taps++,
                  child: Text(destination),
                ),
              );
            },
          ),
        ),
      ),
    );
    await show('电影');
    await show('剧集');
    expect(find.text('电影'), findsNothing);
    final buildsAtStart = builds;
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('剧集'));
    expect(taps, 1);
    await tester.pump(const Duration(milliseconds: 40));
    expect(builds, buildsAtStart);
    // Rapid navigation replaces the target rather than accumulating old panes.
    await show('收藏');
    expect(find.text('剧集'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('收藏'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduce motion bypasses and interrupts pane animation', (
    tester,
  ) async {
    Future<void> show(String destination, {bool reduce = false}) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(disableAnimations: reduce),
              child: CinemaPaneTransition(
                destination: destination,
                child: Text(destination),
              ),
            ),
          ),
        );
    double offset() => tester
        .widget<Transform>(
          find.descendant(
            of: find.byType(CinemaPaneTransition),
            matching: find.byType(Transform),
          ),
        )
        .transform
        .storage[13];
    await show('电影');
    await show('剧集');
    expect(offset(), greaterThan(0));
    await show('剧集', reduce: true);
    expect(offset(), 0);
    await show('设置', reduce: true);
    expect(offset(), 0);
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
