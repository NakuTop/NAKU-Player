import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_scroll_activity.dart';

void main() {
  testWidgets('drag and momentum defer work without rebuilding the viewport', (
    tester,
  ) async {
    final activity = CinemaScrollActivity();
    addTearDown(activity.dispose);
    var viewportBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaScrollNotifications(
          activity: activity,
          child: Builder(
            builder: (context) {
              viewportBuilds++;
              expect(CinemaScrollActivityScope.maybeOf(context), activity);
              return ListView.builder(
                itemExtent: 100,
                itemCount: 200,
                itemBuilder: (_, index) => Text('Work $index'),
              );
            },
          ),
        ),
      ),
    );
    final before = viewportBuilds;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(ListView)),
    );
    await gesture.moveBy(const Offset(0, -240));
    await tester.pump();
    expect(activity.value, isTrue);
    var idle = false;
    activity.whenIdle.then((_) => idle = true);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      idle,
      isFalse,
      reason: 'An active drag must remain busy without new deltas.',
    );
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 121));
    expect(activity.value, isFalse);
    expect(idle, isTrue);
    expect(viewportBuilds, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successive trackpad bursts share one idle notification', (
    tester,
  ) async {
    final activity = CinemaScrollActivity();
    addTearDown(activity.dispose);
    final states = <bool>[];
    activity.addListener(() => states.add(activity.value));
    activity.begin();
    var idle = false;
    activity.whenIdle.then((_) => idle = true);
    activity.end();
    await tester.pump(const Duration(milliseconds: 80));
    activity.begin();
    await tester.pump(const Duration(milliseconds: 80));
    expect(idle, isFalse);
    activity.end();
    await tester.pump(const Duration(milliseconds: 121));
    expect(idle, isTrue);
    expect(states, [true, false]);
  });

  test('disposing the page releases queued enrichment workers', () async {
    final activity = CinemaScrollActivity()..begin();
    final idle = activity.whenIdle;
    activity.dispose();
    await idle;
  });
}
