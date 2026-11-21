import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_poster_lift.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'poster hover and keyboard preserve the grid and original action, reduced=$reduced',
      (tester) async {
        final first = FocusNode(), second = FocusNode();
        addTearDown(first.dispose);
        addTearDown(second.dispose);
        final opened = <int>[];
        const boundary = ValueKey('posters');
        Widget tile(int index, FocusNode focus) => SizedBox(
          key: ValueKey('tile-$index'),
          width: 135,
          height: 200,
          child: InkWell(
            focusNode: focus,
            onTap: () => opened.add(index),
            hoverColor: Colors.transparent,
            focusColor: Colors.transparent,
            child: Column(
              children: [
                Expanded(
                  child: CinemaPosterLift(
                    child: DecoratedBox(
                      key: ValueKey('image-$index'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: const Color(0xff85939b),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Title $index', key: ValueKey('caption-$index')),
              ],
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: reduced),
                  child: Center(
                    child: RepaintBoundary(
                      key: boundary,
                      child: ColoredBox(
                        color: const Color(0xff3f4042),
                        child: Padding(
                          padding: const EdgeInsets.all(30),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              tile(1, first),
                              const SizedBox(width: 35),
                              tile(2, second),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        Rect rect(String key) => tester.getRect(find.byKey(ValueKey(key)));
        final resting = rect('image-1'),
            neighbour = rect('image-2'),
            cell = rect('tile-1'),
            caption = rect('caption-1');
        final capture = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(boundary),
        );
        final sample = capture.globalToLocal(
          Offset(resting.center.dx, resting.bottom + 4),
        );
        Future<int> shadow() async => (await tester.runAsync(() async {
          final image = await capture.toImage();
          try {
            final pixels = (await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            ))!;
            return pixels.getUint8(
              (sample.dy.floor() * image.width + sample.dx.floor()) * 4,
            );
          } finally {
            image.dispose();
          }
        }))!;
        final baseline = await shadow();
        final pointer = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        addTearDown(pointer.removePointer);
        await pointer.addPointer(location: Offset.zero);
        await pointer.moveTo(resting.center);
        await tester.pumpAndSettle();
        final raised = rect('image-1');
        if (reduced) {
          expect(raised, resting);
        } else {
          expect(raised.width, greaterThan(resting.width + 3));
          expect(raised.top, lessThan(resting.top - 4));
        }
        expect(await shadow(), lessThan(baseline - 3));
        expect(rect('tile-1'), cell);
        expect(rect('caption-1'), caption);
        expect(rect('image-2'), neighbour);
        await pointer.moveTo(neighbour.center);
        await tester.pumpAndSettle();
        expect(rect('image-1'), resting);
        if (!reduced) {
          expect(rect('image-2').width, greaterThan(neighbour.width));
        }
        await pointer.down(neighbour.center);
        await pointer.up();
        await tester.pumpAndSettle();
        expect(opened, [2]);
        await pointer.moveTo(Offset.zero);
        first.requestFocus();
        await tester.pumpAndSettle();
        if (!reduced) expect(rect('image-1').width, greaterThan(resting.width));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(opened, [2, 1]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      skip: !Platform.isMacOS,
    );
  }
}
