import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_mobile_gestures.dart';

void main() {
  testWidgets(
    'phone double taps use three zones, single tap reveals controls, toolbar is independent',
    (tester) async {
      var controls = 0, play = 0, buttons = 0, holds = 0, ends = 0;
      final seeks = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaMobileGestures(
            controlsInsets: const EdgeInsets.only(top: 44, bottom: 90),
            onTap: () => controls++,
            onTogglePlayback: () => play++,
            onSeek: seeks.add,
            onHoldStart: () {
              holds++;
              return true;
            },
            onHoldEnd: () => ends++,
            child: Stack(
              children: [
                const Positioned.fill(child: ColoredBox(color: Colors.black)),
                Align(
                  alignment: Alignment.topLeft,
                  child: IconButton(
                    tooltip: '线路与选集',
                    onPressed: () => buttons++,
                    icon: const Icon(Icons.list),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      Future<void> doubleAt(double x) async {
        await tester.tapAt(Offset(x, 220));
        await tester.pump(const Duration(milliseconds: 80));
        await tester.tapAt(Offset(x, 220));
        await tester.pump(const Duration(milliseconds: 350));
      }

      await doubleAt(60);
      await doubleAt(400);
      await doubleAt(740);
      expect(seeks, [-10, 10]);
      expect(play, 1);
      expect(controls, 0);
      await tester.tapAt(const Offset(400, 220));
      await tester.pump(const Duration(milliseconds: 350));
      expect(controls, 1);
      expect(play, 1);
      await tester.tap(find.byTooltip('线路与选集'));
      await tester.pump();
      expect(buttons, 1);
      final hold = await tester.startGesture(const Offset(400, 220));
      await tester.pump(const Duration(milliseconds: 460));
      expect(holds, 1);
      await hold.cancel();
      await tester.pump();
      expect(ends, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      expect(controls, 1);
    },
  );
  testWidgets('backgrounding and unmount release held speed once', (
    tester,
  ) async {
    var ends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaMobileGestures(
          onTap: () {},
          onTogglePlayback: () {},
          onSeek: (_) {},
          onHoldStart: () => true,
          onHoldEnd: () => ends++,
          child: const ColoredBox(color: Colors.black),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(400, 200));
    await tester.pump(const Duration(milliseconds: 460));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(ends, 1);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());
    expect(ends, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
  test(
    'hold restores rate after a fast release without changing playing state',
    () async {
      final first = Completer<void>();
      final rates = <double>[];
      var playing = false;
      final hold = CinemaMobileHoldRate(
        isPlaying: () => playing,
        readRate: () => 1.25,
        setRate: (value) async {
          rates.add(value);
          if (rates.length == 1) await first.future;
        },
      );
      expect(hold.start(), false);
      playing = true;
      expect(hold.start(), true);
      final release = hold.release();
      playing = false;
      await Future<void>.delayed(Duration.zero);
      expect(rates, [2]);
      first.complete();
      await release;
      expect(rates, [2, 1.25]);
      expect(playing, false);
      await hold.close();
      expect(hold.start(), false);
    },
  );
}
