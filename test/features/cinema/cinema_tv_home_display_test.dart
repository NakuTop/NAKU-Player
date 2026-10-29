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
        'origin': {
          'city': '上海',
          'label': 'PVG',
          'lat': 31.1443,
          'lng': 121.8083,
          'drawable': true,
        },
        'destination': {
          'city': '东京',
          'label': 'NRT',
          'lat': 35.7647,
          'lng': 140.3864,
          'drawable': true,
        },
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

Widget _earth(List<Map<String, dynamic>> routes, bool active) =>
    const ColoredBox(
      key: ValueKey('rotating-earth-probe'),
      color: Colors.black,
    );

void main() {
  test(
    'flights-only projection preserves actual labels and UTC, hides parcels and destinations',
    () {
      final data = _snapshot()['data'] as Map<String, dynamic>;
      final items = cinemaTVDisplayItems(data);
      expect(items.length, 1);
      expect(items.first.title, 'TEST901 · 计划出发');
      expect(items.first.body, '上海 → 东京');
      expect(items.first.detail, '10/29 03:30 UTC · 计划班表');
      expect(cinemaTVDisplayItems({...data, 'flights': []}), isEmpty);
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

  test(
    'Earth routes contain only finite verified real endpoint coordinates',
    () {
      final data = _snapshot()['data'] as Map<String, dynamic>;
      expect(cinemaTVDisplayRoutes(data), [
        {
          'originLat': 31.1443,
          'originLon': 121.8083,
          'destinationLat': 35.7647,
          'destinationLon': 140.3864,
        },
      ]);
      final flight = Map<String, dynamic>.from(
        (data['flights'] as List).single,
      );
      final point = Map<String, dynamic>.from(flight['origin']);
      for (final badPoint in [
        {...point, 'drawable': false},
        {...point, 'lat': double.nan},
        {...point, 'lat': 91},
        {...point, 'lng': 181},
        {'city': '上海'},
      ]) {
        expect(
          cinemaTVDisplayRoutes({
            ...data,
            'flights': [
              {...flight, 'origin': badPoint},
            ],
          }),
          isEmpty,
        );
      }
      expect(cinemaTVDisplayRoutes({...data, 'demo': true}), isEmpty);
      expect(
        cinemaTVDisplayRoutes({
          ...data,
          'flights': List.filled(20, flight),
        }).length,
        8,
      );
    },
  );

  test(
    'Earth keeps only actual live or last-known positions without interpolation',
    () {
      final data = _snapshot()['data'] as Map<String, dynamic>;
      final base = Map<String, dynamic>.from((data['flights'] as List).single);
      Map<String, dynamic> positioned({
        String status = 'live',
        bool preview = false,
        Object? lat = 32.5,
        Object? lon = 130.5,
      }) => {
        ...base,
        'positionStatus': status,
        'routePreview': preview,
        'position': {'lat': lat, 'lng': lon},
      };
      for (final status in ['live', 'last-known']) {
        final route = cinemaTVDisplayRoutes({
          ...data,
          'flights': [positioned(status: status)],
        }).single;
        expect(route['positionLat'], 32.5);
        expect(route['positionLon'], 130.5);
      }
      for (final flight in [
        positioned(status: 'estimated'),
        positioned(status: 'unavailable'),
        positioned(preview: true),
        positioned(lat: double.nan),
        positioned(lat: 91),
        positioned(lon: -181),
        positioned(lat: null),
      ]) {
        final route = cinemaTVDisplayRoutes({
          ...data,
          'flights': [flight],
        }).single;
        expect(route.containsKey('positionLat'), isFalse);
        expect(route.containsKey('positionLon'), isFalse);
      }
    },
  );

  testWidgets(
    'Earth background receives verified flight routes and native active state',
    (tester) async {
      List<Map<String, dynamic>> routes = [];
      bool? active;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            earthBuilder: (values, enabled) {
              routes = values;
              active = enabled;
              return _earth(values, enabled);
            },
            loadSnapshot: () async => _snapshot(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(active, isTrue);
      expect(routes, [
        {
          'originLat': 31.1443,
          'originLon': 121.8083,
          'destinationLat': 35.7647,
          'destinationLon': 140.3864,
        },
      ]);
      expect(
        find.byKey(const ValueKey('rotating-earth-probe')),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'native Earth active flag pauses in background and resumes with fresh data',
    (tester) async {
      final activeValues = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            earthBuilder: (routes, active) {
              activeValues.add(active);
              return _earth(routes, active);
            },
            loadSnapshot: () async => _snapshot(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(activeValues.last, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(activeValues.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(activeValues.last, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(activeValues.last, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final size in [
    const Size(960, 540),
    const Size(1280, 720),
    const Size(1280, 360),
  ]) {
    testWidgets(
      'rotating-earth display fills $size with flight-only text and no controls or effects',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: CinemaTVHomeDisplay(
              earthBuilder: _earth,
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
        expect(find.textContaining('测试承运商'), findsNothing);
        expect(find.textContaining('运输中'), findsNothing);
        expect(find.textContaining('下一站'), findsNothing);
        expect(find.textContaining('must-never-render'), findsNothing);
        final subtree = find.byType(CinemaTVHomeDisplay);
        for (final type in [
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
        for (final type in [
          FilledButton,
          TextButton,
          OutlinedButton,
          IconButton,
          ElevatedButton,
        ]) {
          expect(
            find.descendant(of: subtree, matching: find.byType(type)),
            findsNothing,
          );
        }
        expect(
          find.byKey(const ValueKey('rotating-earth-probe')),
          findsOneWidget,
        );
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
            earthBuilder: _earth,
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
    'offline keeps the local rotating earth and never fabricates flights',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            earthBuilder: _earth,
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
            earthBuilder: _earth,
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
                    earthBuilder: _earth,
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
