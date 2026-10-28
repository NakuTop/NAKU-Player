import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_player_controls.dart';

void main() {
  testWidgets(
    'remote timeline previews, cancels and explicitly commits without player toggles',
    (tester) async {
      final preview = CinemaTVSeekPreview(), focus = FocusNode();
      final commits = <Duration>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaTVTimeline(
              position: const Duration(seconds: 20),
              duration: const Duration(seconds: 40),
              preview: preview,
              focusNode: focus,
              onCommit: commits.add,
              onActivity: () {},
            ),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(preview.target, const Duration(seconds: 30));
      expect(commits, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(preview.active, false);
      expect(commits, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(preview.target, const Duration(seconds: 40));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(commits, [const Duration(seconds: 40)]);
      expect(preview.active, false);
      await tester.pumpWidget(const SizedBox());
      focus.dispose();
      preview.dispose();
    },
  );
  testWidgets(
    'TV episode list scrolls focus to offscreen episodes with D-pad',
    (tester) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 350,
              child: CinemaTVEpisodePicker(
                labels: [for (var i = 1; i <= 30; i++) '第 $i 集'],
                current: 17,
                onSelected: (value) => selected = value,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(selected, 29);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
