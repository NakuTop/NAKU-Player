import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_earth.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const route = <String, dynamic>{
    'originLat': 39.9,
    'originLon': 116.4,
    'destinationLat': 35.7,
    'destinationLon': 139.7,
  };
  test('Earth routes accept real coordinates and strip all unrelated data', () {
    expect(
      cinemaTVEarthRoutes([
        {...route, 'flightNumber': 'private', 'token': 'never-cross-bridge'},
        {...route, 'originLat': double.nan},
        {...route, 'destinationLon': 181},
        {'originLat': 39.9},
      ]),
      [route],
    );
  });
  test(
    'Earth routes bound work and deduplicate without inventing positions',
    () {
      final routes = cinemaTVEarthRoutes([
        route,
        route,
        for (var i = 0; i < 20; i++) {...route, 'destinationLat': i},
      ]);
      expect(routes, hasLength(8));
      expect(routes.every((r) => r.keys.length == 4), true);
    },
  );
  test(
    'only complete real ranged position pairs reach the 2D point renderer',
    () {
      expect(
        cinemaTVEarthRoutes([
          {...route, 'positionLat': 22, 'positionLon': 121},
        ]).single,
        containsPair('positionLat', 22.0),
      );
      for (final invalid in [
        {'positionLat': 22},
        {'positionLat': 22, 'positionLon': double.infinity},
        {'positionLat': -91, 'positionLon': 121},
      ]) {
        expect(
          cinemaTVEarthRoutes([
            {...route, ...invalid},
          ]).single.keys,
          hasLength(4),
        );
      }
    },
  );

  const channel = MethodChannel('test/tv-earth');
  late StreamController<dynamic> events;
  late List<MethodCall> calls;
  late Map<String, dynamic> parameters;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    events = StreamController<dynamic>.broadcast(sync: true);
    calls = [];
    parameters = {};
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() async {
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });
  Widget earth({
    bool active = true,
    List<Map<String, dynamic>> flights = const [route],
    VoidCallback? onFrame,
    VoidCallback? onError,
  }) => MaterialApp(
    home: CinemaTVEarth(
      key: const ValueKey('earth'),
      channel: channel,
      events: events.stream,
      active: active,
      flights: flights,
      onFirstFrame: onFrame,
      onError: onError,
      fallbackBuilder: (_) => const Center(child: Text('startup fallback')),
      nativeViewBuilder: (values) {
        parameters = values;
        return const ColoredBox(
          key: ValueKey('native-earth'),
          color: Colors.black,
        );
      },
    ),
  );

  testWidgets(
    'native viewport fills the entire screen and first real frame removes fallback',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var frames = 0;
      await tester.pumpWidget(earth(onFrame: () => frames++));
      expect(
        tester.getSize(find.byKey(const ValueKey('native-earth'))),
        const Size(1280, 720),
      );
      expect(find.text('startup fallback'), findsOneWidget);
      events.add({'id': parameters['id'] + 1000, 'firstFrame': true});
      await tester.pump();
      expect(find.text('startup fallback'), findsOneWidget);
      events.add({
        'id': parameters['id'],
        'firstFrame': true,
        'textureWidth': 4096,
      });
      await tester.pump();
      expect(find.text('startup fallback'), findsNothing);
      expect(frames, 1);
      events.add({'id': parameters['id'], 'firstFrame': true});
      await tester.pump();
      expect(frames, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('active and real route changes update the same native surface', (
    tester,
  ) async {
    await tester.pumpWidget(earth());
    final id = parameters['id'];
    await tester.pumpWidget(earth(active: false));
    await tester.pump();
    expect(calls.last.method, 'update');
    expect(calls.last.arguments['active'], false);
    expect(calls.last.arguments['id'], id);
    await tester.pumpWidget(
      earth(
        flights: [
          {...route, 'destinationLat': 12.0},
        ],
      ),
    );
    await tester.pump();
    expect(calls.last.arguments['active'], true);
    expect(calls.last.arguments['routes'].single['destinationLat'], 12.0);
    expect(parameters['id'], id);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'background suspends native rendering and resume respects inactive page',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(earth());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(calls.last.arguments['active'], false);
      await tester.pumpWidget(earth(active: false));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(calls.last.arguments['active'], false);
      await tester.pumpWidget(earth());
      await tester.pump();
      expect(calls.last.arguments['active'], true);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'native initialization error restores fallback once and disposal releases the view',
    (tester) async {
      var errors = 0;
      await tester.pumpWidget(earth(onError: () => errors++));
      final id = parameters['id'];
      events.add({'id': id, 'firstFrame': true});
      await tester.pump();
      events.add({'id': id, 'error': true});
      await tester.pump();
      events.add({'id': id, 'error': true});
      await tester.pump();
      expect(find.text('startup fallback'), findsOneWidget);
      expect(errors, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      events.add({'id': id, 'firstFrame': true});
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unsupported platform shows fallback without creating native channels',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaTVEarth(
            channel: channel,
            fallbackBuilder: (_) => const Text('platform fallback'),
          ),
        ),
      );
      expect(find.text('platform fallback'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = null;
      expect(tester.takeException(), isNull);
    },
  );
}
