import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('display ticks move comments without recreating the painters', (
    tester,
  ) async {
    late DanmakuController<Object> controller;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: DanmakuScreen<Object>(
          option: const DanmakuOption(),
          createdController: (value) => controller = value,
        ),
      ),
    );
    controller.addDanmaku(DanmakuContentItem<Object>('帧率测试'));
    await tester.pump();
    final painters = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((widget) => widget.painter)
        .toList();
    final item = controller.scrollDanmaku.single;
    final initialX = item.xPosition;
    await tester.pump(const Duration(microseconds: 8333));
    final nextX = item.xPosition;
    expect(nextX, lessThan(initialX));
    expect(item.drawTick, closeTo(8.333, .001));
    await tester.pump(const Duration(microseconds: 8333));
    expect(item.xPosition, lessThan(nextX));
    expect(
      tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((widget) => widget.painter),
      orderedEquals(painters),
    );
    controller.pause();
    final pausedX = item.xPosition;
    await tester.pump(const Duration(milliseconds: 250));
    expect(item.xPosition, pausedX);
    controller.clear();
    await tester.pump();
    expect(controller.scrollDanmaku, isEmpty);
  });
}
