import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

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
        'airline': '测试航空',
        'terminal': 'T2',
        'gate': 'D18',
        'origin': {
          'city': '上海',
          'label': 'PVG',
          'lat': 31.1443,
          'lng': 121.8083,
          'drawable': true,
          'timezone': 'Asia/Shanghai',
        },
        'destination': {
          'city': '东京',
          'label': 'NRT',
          'lat': 35.7647,
          'lng': 140.3864,
          'drawable': true,
          'country': '日本',
          'timezone': 'Asia/Tokyo',
        },
        'scheduledDeparture': '2026-10-29T03:30:00Z',
        'scheduledArrival': '2026-10-29T06:30:00Z',
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

Map<String, dynamic> _weather(DateTime now) {
  final flight =
      ((_snapshot()['data'] as Map)['flights'] as List).single as Map;
  Map entry(String side, num temperature) => {
    'point': flight[side],
    'dataStatus': 'live',
    'updatedAt': now.toUtc().toIso8601String(),
    'snapshot': {'temperature': temperature, 'condition': '晴'},
  };
  return {
    'ok': true,
    'data': {
      'checkedAt': now.toUtc().toIso8601String(),
      'routes': [
        {
          'selectionKey': jsonEncode([flight['id'], null, null]),
          'origin': entry('origin', 18),
          'destination': entry('destination', 12),
        },
      ],
    },
  };
}

void main() {
  setUpAll(() async {
    if ((Platform.environment['NAKU_TV_UI_OUTPUT'] ?? '').isEmpty) return;
    final font = await rootBundle.load('assets/fonts/MiSans-Regular.ttf');
    for (final family in [
      'Roboto',
      '.AppleSystemUIFont',
      'MI_Sans_Regular',
      'Ahem',
    ]) {
      await (FontLoader(family)..addFont(Future.value(font))).load();
    }
  });
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

  test(
    'explicit route previews reach native renderer without fabricated telemetry',
    () {
      final data = _snapshot()['data'] as Map<String, dynamic>;
      final flight = Map<String, dynamic>.from(
        (data['flights'] as List).single,
      );
      final snapshot = {
        ...data,
        'flights': [
          {
            ...flight,
            'routePreview': true,
            'positionStatus': 'estimated',
            'position': {'lat': 35, 'lng': 130},
          },
        ],
      };
      final route = cinemaTVDisplayRoutes(snapshot).single;
      expect(route['preview'], 1.0);
      expect(route.containsKey('positionLat'), false);
      expect(cinemaTVDisplayItems(snapshot).single.detail, contains('航线预览'));
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
            loadWeather: () async => {
              'ok': true,
              'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
            },
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
            loadWeather: () async => {
              'ok': true,
              'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
            },
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

  testWidgets(
    'flight weather uses its own slow clock and retains only unexpired readings after a failure',
    (tester) async {
      var now = DateTime(2026, 10, 28, 14, 20),
          weatherCalls = 0,
          failing = false;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            earthBuilder: _earth,
            now: () => now,
            loadSnapshot: () async => _snapshot(),
            loadWeather: () async {
              weatherCalls++;
              if (failing) throw const SocketException('offline');
              return _weather(now);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('18° 晴'), findsOneWidget);
      expect(find.text('12° 晴'), findsOneWidget);
      expect(find.text('10/29 11:30 当地'), findsOneWidget);
      expect(find.text('10/29 15:30 当地'), findsOneWidget);
      expect(find.text('航站楼 T2 · 登机口 D18'), findsOneWidget);
      expect(weatherCalls, 1);
      now = now.add(const Duration(minutes: 1));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(weatherCalls, 1);
      failing = true;
      now = now.add(const Duration(minutes: 30));
      await tester.pump(const Duration(minutes: 30));
      await tester.pumpAndSettle();
      expect(weatherCalls, 2);
      expect(find.text('12° 晴 · 缓存'), findsOneWidget);
      now = now.add(const Duration(minutes: 15));
      await tester.pump(const Duration(minutes: 15));
      await tester.pumpAndSettle();
      expect(find.text('12° 晴 · 缓存'), findsNothing);
      expect(find.text('天气暂不可用'), findsNWidgets(2));
      expect(find.text('上海 → 东京'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a suspended weather response is ignored and resumes without waiting for its old deadline',
    (tester) async {
      final delayed = Completer<Map<String, dynamic>>();
      var calls = 0;
      final now = DateTime(2026, 10, 28, 14, 20);
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVHomeDisplay(
            earthBuilder: _earth,
            now: () => now,
            loadSnapshot: () async => _snapshot(),
            loadWeather: () {
              calls++;
              return calls == 1 ? delayed.future : Future.value(_weather(now));
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('12° 晴'), findsOneWidget);
      delayed.complete({
        'ok': true,
        'data': {'routes': []},
      });
      await tester.pumpAndSettle();
      expect(find.text('12° 晴'), findsOneWidget);
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
              loadWeather: () async => {
                'ok': true,
                'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
              },
              earthBuilder: _earth,
              now: () => DateTime(2026, 10, 28, 14, 20),
              loadSnapshot: () async {
                final result = _snapshot();
                final data = result['data'] as Map<String, dynamic>;
                data['flights'] = List.filled(
                  3,
                  (data['flights'] as List).single,
                );
                return result;
              },
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
        final capture =
            Platform.environment['NAKU_TV_UI_OUTPUT'] ??
            const String.fromEnvironment('NAKU_TV_UI_OUTPUT');
        if (capture.isNotEmpty) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byType(RepaintBoundary).first,
            );
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              '$capture/tv-display-text-${size.width.toInt()}x${size.height.toInt()}.png',
            );
            await file.parent.create(recursive: true);
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        expect(find.text('14:20'), findsOneWidget);
        expect(find.text('上海 → 东京'), findsNWidgets(3));
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
            loadWeather: () async => {
              'ok': true,
              'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
            },
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
            loadWeather: () async => {
              'ok': true,
              'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
            },
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
            loadWeather: () async => {
              'ok': true,
              'data': {'routes': [], 'checkedAt': '2026-10-28T12:20:00Z'},
            },
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
                    loadWeather: () async => {
                      'ok': true,
                      'data': {
                        'routes': [],
                        'checkedAt': '2026-10-28T12:20:00Z',
                      },
                    },
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
