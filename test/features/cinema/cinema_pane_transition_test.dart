import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_pane_transition.dart';

void main() {
  testWidgets(
    'switching a dense pane does not schedule whole-page motion frames',
    (tester) async {
      var childBuilds = 0;
      Future<void> show(String destination) => tester.pumpWidget(
        MaterialApp(
          home: CinemaPaneTransition(
            destination: destination,
            child: Builder(
              builder: (_) {
                childBuilds++;
                return GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 6,
                  ),
                  itemCount: 240,
                  itemBuilder: (_, index) => Text('$destination $index'),
                );
              },
            ),
          ),
        ),
      );
      await show('电影');
      await show('剧集');
      final buildsBeforeIdle = childBuilds;
      final settledFrames = await tester.pumpAndSettle(
        const Duration(milliseconds: 16),
      );
      debugPrint(
        'Pane switch: $settledFrames settling frames; ${childBuilds - buildsBeforeIdle} additional child builds',
      );
      expect(settledFrames, lessThanOrEqualTo(1));
      expect(childBuilds, buildsBeforeIdle);
    },
  );

  testWidgets(
    'new pane is usable immediately and rapid switches leave one destination',
    (tester) async {
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
    },
  );

  testWidgets(
    'navigation has no page motion with either accessibility preference',
    (tester) async {
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
      await show('电影');
      await show('剧集');
      expect(
        find.descendant(
          of: find.byType(CinemaPaneTransition),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      await show('设置', reduce: true);
      expect(
        find.descendant(
          of: find.byType(CinemaPaneTransition),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );
}
