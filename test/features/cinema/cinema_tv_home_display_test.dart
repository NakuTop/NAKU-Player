import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_home_display.dart';

Map<String, dynamic> _snapshot() => {
  'ok': true,
  'data': {
    'demo': false,
    'syncedAt': '2026-10-28T12:20:00Z',
    'flights': [
      {
        'id': 'fixture-flight',
        'flightNumber': 'TEST901',
        'status': '计划出发',
        'origin': {'city': '上海', 'label': 'PVG'},
        'destination': {'city': '东京', 'label': 'NRT'},
        'scheduledDeparture': '2026-10-29T03:30:00Z',
        'dataLabel': '计划班表',
        'bookingReference': 'must-never-render',
      },
    ],
    'parcels': [
      {
        'parcelName': '样品',
        'carrier': '测试承运商',
        'status': '运输中',
        'latestEvent': {'location': '上海', 'description': '已离开分拨中心'},
      },
    ],
    'destination': {
      'city': '东京',
      'country': '日本',
      'date': '2026-10-29',
      'dataLabel': '手动更新',
      'note': 'private-note-must-never-render',
    },
  },
};

void main() {
  test(
    'projection preserves actual supplied records, labels, UTC and a maximum of three',
    () {
      final data = _snapshot()['data'] as Map<String, dynamic>;
      final items = cinemaTVDisplayItems(data);
      expect(items.length, 3);
      expect(items.first.title, 'TEST901 · 计划出发');
      expect(items.first.body, '上海 → 东京');
      expect(items.first.detail, '10/29 03:30 UTC · 计划班表');
      expect(items[1].body, '运输中 · 上海');
      expect(items[2].title, '下一站 · 东京');
      expect(cinemaTVDisplayItems({...data, 'demo': true}), isEmpty);
      expect(
        cinemaTVDisplayItems({
          ...data,
          'flights': List.filled(8, (data['flights'] as List).single),
        }).length,
        3,
      );
      expect(cinemaTVDisplayTime('invalid'), isEmpty);
    },
  );

  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(1280, 360),
  ]) {
    testWidgets(
      'native display fills $size without WebView, effect layers or overflow',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: CinemaTVHomeDisplay(
              now: () => DateTime(2026, 10, 28, 14, 20),
              loadSnapshot: () async => _snapshot(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(
            find.byKey(const ValueKey('tv-home-display-fullscreen')),
          ),
          size,
        );
        expect(
          tester.getSize(find.byKey(const ValueKey('tv-home-display-earth'))),
          size,
        );
        expect(find.text('14:20'), findsOneWidget);
        expect(find.text('上海 → 东京'), findsOneWidget);
        expect(find.textContaining('must-never-render'), findsNothing);
        final subtree = find.byType(CinemaTVHomeDisplay);
        for (final type in [
          AndroidView,
          PlatformViewLink,
          Texture,
          BackdropFilter,
          ImageFiltered,
          AnimatedOpacity,
          AnimatedContainer,
          ShaderMask,
        ]) {
          expect(
            find.descendant(of: subtree, matching: find.byType(type)),
            findsNothing,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'clock and snapshot refresh at minute cadence and stop while backgrounded',
    (tester) async {
      var requests = 0;
      var now = DateTime(2026, 10, 28, 14, 20);
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            now: () => now,
            loadSnapshot: () async {
              requests++;
              return _snapshot();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.pump(const Duration(seconds: 59));
      expect(requests, 1);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(requests, 2);
      expect(find.text('14:21'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(minutes: 3));
      await tester.pump(const Duration(minutes: 3));
      expect(requests, 2);
      expect(find.text('14:21'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(requests, 3);
      expect(find.text('14:24'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'offline remains a full local earth clock and never fabricates travel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            now: () => DateTime(2026, 10, 28, 14, 20),
            loadSnapshot: () async => throw const SocketException('offline'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('暂未连接 · 本地时钟'), findsOneWidget);
      expect(find.text('14:20'), findsOneWidget);
      expect(find.textContaining('TEST901'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background completion is ignored; resume fetches a fresh snapshot',
    (tester) async {
      final first = Completer<Map<String, dynamic>>();
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            loadSnapshot: () {
              requests++;
              return requests == 1 ? first.future : Future.value(_snapshot());
            },
          ),
        ),
      );
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      first.complete(_snapshot());
      await tester.pump();
      expect(find.text('上海 → 东京'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.text('上海 → 东京'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('tap wakes once and restores the underlying route', (
    tester,
  ) async {
    var wakes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => Navigator.of(context).push(
                PageRouteBuilder<void>(
                  transitionDuration: Duration.zero,
                  reverseTransitionDuration: Duration.zero,
                  pageBuilder: (_, _, _) => CinemaTVHomeDisplay(
                    onWake: () => wakes++,
                    loadSnapshot: () async => _snapshot(),
                  ),
                ),
              ),
              child: const Text('底层页面'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('底层页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tv-home-display-fullscreen')));
    await tester.pumpAndSettle();
    expect(wakes, 1);
    expect(find.text('底层页面'), findsOneWidget);
    expect(find.byType(CinemaTVHomeDisplay), findsNothing);
  });
}
