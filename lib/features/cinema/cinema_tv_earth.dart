import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Only real, finite airport coordinates cross the native rendering bridge.
/// No flight identifiers, account data, synthetic routes or aircraft models.
List<Map<String, double>> cinemaTVEarthRoutes(
  List<Map<String, dynamic>> flights,
) {
  final result = <Map<String, double>>[];
  final seen = <String>{};
  for (final flight in flights) {
    final row = <String, double>{};
    for (final key in const [
      'originLat',
      'originLon',
      'destinationLat',
      'destinationLon',
    ]) {
      final value = flight[key];
      if (value is! num || !value.isFinite) break;
      final number = value.toDouble();
      if (number.abs() > (key.endsWith('Lat') ? 90 : 180)) break;
      row[key] = number;
    }
    if (row.length != 4) continue;
    final positionLat = flight['positionLat'];
    final positionLon = flight['positionLon'];
    if (positionLat is num &&
        positionLat.isFinite &&
        positionLat.abs() <= 90 &&
        positionLon is num &&
        positionLon.isFinite &&
        positionLon.abs() <= 180) {
      row['positionLat'] = positionLat.toDouble();
      row['positionLon'] = positionLon.toDouble();
    }
    final identity = row.values.join(',');
    if (seen.add(identity)) result.add(row);
    if (result.length == 8) break;
  }
  return result;
}

/// Fullscreen native GLES2 Earth: one textured sphere, 24fps on-demand frames.
/// Lifecycle/visibility stop both animation scheduling and the native GL context.
class CinemaTVEarth extends StatefulWidget {
  const CinemaTVEarth({
    super.key,
    this.flights = const [],
    this.active = true,
    this.onFirstFrame,
    this.onError,
    this.fallbackBuilder,
    @visibleForTesting this.channel,
    @visibleForTesting this.events,
    @visibleForTesting this.nativeViewBuilder,
  });
  final List<Map<String, dynamic>> flights;
  final bool active;
  final VoidCallback? onFirstFrame, onError;
  final WidgetBuilder? fallbackBuilder;
  @visibleForTesting
  final MethodChannel? channel;
  @visibleForTesting
  final Stream<dynamic>? events;
  @visibleForTesting
  final Widget Function(Map<String, dynamic> parameters)? nativeViewBuilder;

  @override
  State<CinemaTVEarth> createState() => _CinemaTVEarthState();
}

class _CinemaTVEarthState extends State<CinemaTVEarth>
    with WidgetsBindingObserver {
  static int _nextId = 1;
  static final Stream<dynamic> _nativeEvents = const EventChannel(
    'naku/tv-earth/events',
  ).receiveBroadcastStream().asBroadcastStream();
  late final int _id = _nextId++;
  late final MethodChannel _channel =
      widget.channel ?? const MethodChannel('naku/tv-earth');
  StreamSubscription<dynamic>? _subscription;
  bool _firstFrame = false, _failed = false;
  bool _foreground = true;

  bool get _supported =>
      widget.nativeViewBuilder != null ||
      defaultTargetPlatform == TargetPlatform.android;

  Map<String, dynamic> get _parameters => {
    'id': _id,
    'active': widget.active && _foreground,
    'routes': cinemaTVEarthRoutes(widget.flights),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (!_supported) return;
    _subscription = (widget.events ?? _nativeEvents).listen(
      _onEvent,
      onError: (Object _) => _showError(),
    );
  }

  void _onEvent(dynamic event) {
    if (!mounted || event is! Map || event['id'] != _id) return;
    if (event['error'] == true) {
      _showError();
    } else if (event['firstFrame'] == true && !_firstFrame) {
      setState(() {
        _firstFrame = true;
        _failed = false;
      });
      widget.onFirstFrame?.call();
    }
  }

  void _showError() {
    if (!mounted || _failed) return;
    setState(() => _failed = true);
    widget.onError?.call();
  }

  Future<void> _update() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('update', _parameters);
    } on MissingPluginException {
      _showError();
    } on PlatformException {
      _showError();
    }
  }

  @override
  void didUpdateWidget(CinemaTVEarth oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active ||
        !listEquals(
          cinemaTVEarthRoutes(
            oldWidget.flights,
          ).map((e) => e.toString()).toList(),
          cinemaTVEarthRoutes(widget.flights).map((e) => e.toString()).toList(),
        )) {
      unawaited(_update());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (_foreground == foreground) return;
    _foreground = foreground;
    unawaited(_update());
  }

  Widget _surface() {
    if (!_supported) return const SizedBox.expand();
    final testBuilder = widget.nativeViewBuilder;
    if (testBuilder != null) return testBuilder(_parameters);
    return PlatformViewLink(
      viewType: 'naku/tv-earth',
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (parameters) =>
          PlatformViewsService.initExpensiveAndroidView(
              id: parameters.id,
              viewType: 'naku/tv-earth',
              layoutDirection: TextDirection.ltr,
              creationParams: _parameters,
              creationParamsCodec: const StandardMessageCodec(),
              onFocus: () => parameters.onFocusChanged(true),
            )
            ..addOnPlatformViewCreatedListener((id) {
              parameters.onPlatformViewCreated(id);
              unawaited(_update());
            })
            ..create(),
    );
  }

  @override
  Widget build(BuildContext context) => SizedBox.expand(
    child: Stack(
      fit: StackFit.expand,
      children: [
        _surface(),
        if (!_firstFrame || _failed)
          Positioned.fill(
            child: IgnorePointer(
              child:
                  widget.fallbackBuilder?.call(context) ??
                  const ColoredBox(color: Colors.black),
            ),
          ),
      ],
    ),
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_subscription?.cancel());
    if (_supported) {
      unawaited(
        _channel
            .invokeMethod<void>('dispose', {'id': _id})
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }
}
