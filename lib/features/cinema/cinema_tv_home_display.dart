import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cinema_nas_media.dart';
import 'cinema_tv_earth.dart';
import 'cinema_tv_display_data.dart';

class CinemaTVDisplayItem {
  const CinemaTVDisplayItem(this.title, this.body, this.detail, {this.flight});
  final String title, body, detail;
  final CinemaTVFlightInfo? flight;
}

String _text(Object? value, [int maximum = 100]) => value is String
    ? value.trim().substring(0, value.trim().length.clamp(0, maximum))
    : '';

String _point(Object? value) {
  if (value is! Map) return '';
  final city = _text(value['city'], 40);
  return city.isNotEmpty ? city : _text(value['label'], 40);
}

String cinemaTVDisplayTime(Object? value) {
  if (value is! String || value.isEmpty) return '';
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return '';
  final time = parsed.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(time.month)}/${two(time.day)} ${two(time.hour)}:${two(time.minute)} UTC';
}

/// Flights-only projection of the existing authenticated /api/display schema.
/// Parcels, destinations, demo data and private notes never appear on TV.
List<CinemaTVDisplayItem> cinemaTVDisplayItems(
  Map<String, dynamic> snapshot, {
  Map<String, dynamic>? weather,
  DateTime? now,
  bool weatherStale = false,
}) {
  if (snapshot['demo'] != false) return const [];
  final items = <CinemaTVDisplayItem>[];
  final flights = snapshot['flights'];
  if (flights is List) {
    for (final flight in flights.whereType<Map>().take(3)) {
      final number = _text(flight['flightNumber'], 30);
      final origin = _point(flight['origin']);
      final destination = _point(flight['destination']);
      if (number.isEmpty && origin.isEmpty && destination.isEmpty) continue;
      final departure =
          flight['actualDeparture'] ??
          flight['estimatedDeparture'] ??
          flight['scheduledDeparture'];
      final status = _text(flight['status'], 50);
      final dataLabel = _text(flight['dataLabel'], 40);
      items.add(
        CinemaTVDisplayItem(
          [number, status].where((v) => v.isNotEmpty).join(' · '),
          [origin, destination].where((v) => v.isNotEmpty).join(' → '),
          [
            cinemaTVDisplayTime(departure),
            dataLabel,
            if (flight['routePreview'] == true) '航线预览',
          ].where((v) => v.isNotEmpty).join(' · '),
          flight: cinemaTVFlightInfo(
            flight,
            weather: weather,
            now: now ?? DateTime.now(),
            weatherStale: weatherStale,
          ),
        ),
      );
    }
  }
  return items.take(3).toList(growable: false);
}

/// Only verified endpoints supplied by the authenticated flight feed can create
/// route arcs. Missing coordinates never borrow a city or synthetic location.
List<Map<String, dynamic>> cinemaTVDisplayRoutes(
  Map<String, dynamic> snapshot,
) {
  if (snapshot['demo'] != false || snapshot['flights'] is! List) {
    return const [];
  }
  bool coordinate(Object? value, double limit) =>
      value is num && value.isFinite && value >= -limit && value <= limit;
  final routes = <Map<String, dynamic>>[];
  for (final flight in (snapshot['flights'] as List).whereType<Map>()) {
    final origin = flight['origin'], destination = flight['destination'];
    if (origin is! Map ||
        destination is! Map ||
        origin['drawable'] != true ||
        destination['drawable'] != true ||
        !coordinate(origin['lat'], 90) ||
        !coordinate(origin['lng'], 180) ||
        !coordinate(destination['lat'], 90) ||
        !coordinate(destination['lng'], 180)) {
      continue;
    }
    final route = <String, dynamic>{
      'originLat': origin['lat'],
      'originLon': origin['lng'],
      'destinationLat': destination['lat'],
      'destinationLon': destination['lng'],
    };
    if (flight['routePreview'] == true) route['preview'] = 1.0;
    final position = flight['position'];
    if (flight['routePreview'] != true &&
        (flight['positionStatus'] == 'live' ||
            flight['positionStatus'] == 'last-known') &&
        position is Map &&
        coordinate(position['lat'], 90) &&
        coordinate(position['lng'], 180)) {
      route['positionLat'] = position['lat'];
      route['positionLon'] = position['lng'];
    }
    routes.add(route);
    if (routes.length == 8) break;
  }
  return routes;
}

typedef CinemaTVEarthBuilder =
    Widget Function(List<Map<String, dynamic>> flights, bool active);

/// Native rotating Earth and a small, noninteractive flight projection. No
/// WebView, WebGL, in-screen controls or screenshot readback.
class CinemaTVHomeDisplay extends StatefulWidget {
  const CinemaTVHomeDisplay({
    super.key,
    this.client,
    this.onWake,
    this.loadSnapshot,
    this.loadWeather,
    this.now,
    this.earthBuilder,
  });
  final CinemaNASClient? client;
  final VoidCallback? onWake;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? loadSnapshot;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? loadWeather;
  @visibleForTesting
  final DateTime Function()? now;
  @visibleForTesting
  final CinemaTVEarthBuilder? earthBuilder;
  @override
  State<CinemaTVHomeDisplay> createState() => _CinemaTVHomeDisplayState();
}

class _CinemaTVHomeDisplayState extends State<CinemaTVHomeDisplay>
    with WidgetsBindingObserver {
  late final _client = widget.client ?? CinemaNASClient();
  late DateTime _clock = widget.now?.call() ?? DateTime.now();
  Map<String, dynamic>? _snapshot;
  Map<String, dynamic>? _weather;
  String _weatherKey = '';
  DateTime? _weatherNext;
  bool _weatherLoading = false, _weatherStale = false;
  Timer? _minute, _poll;
  bool _foreground = true, _loading = false, _waking = false;
  bool _earthFailed = false;
  int _generation = 0;
  int _weatherGeneration = 0;
  String _status = '正在同步 Home Display';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    if (_foreground) _start();
  }

  void _start() {
    _minute?.cancel();
    _poll?.cancel();
    _clock = widget.now?.call() ?? DateTime.now();
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _foreground) {
        setState(() => _clock = widget.now?.call() ?? DateTime.now());
      }
    });
    _poll = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (!_foreground || _loading || !mounted) return;
    _loading = true;
    final generation = ++_generation;
    try {
      final result =
          await (widget.loadSnapshot?.call() ??
                  _client.call('homeDisplaySnapshot'))
              .timeout(const Duration(seconds: 35));
      if (!mounted || !_foreground || generation != _generation) return;
      final data = result['data'];
      if (result['ok'] == true && data is Map && data['demo'] == false) {
        setState(() {
          _snapshot = Map<String, dynamic>.from(data);
          _status = '';
        });
        unawaited(_refreshWeather(Map<String, dynamic>.from(data)));
      } else {
        final reason = result['reason'];
        final needsNAS =
            reason == 'nas_login_required' ||
            reason == 'nas_session_expired' ||
            reason == 'nas_authentication_failed';
        setState(() {
          if (needsNAS) {
            _snapshot = null;
            _weather = null;
            _weatherKey = '';
            ++_weatherGeneration;
            _weatherLoading = false;
          }
          _status = needsNAS ? '请先在“我的”连接 NAS' : '暂时无法同步 · 稍后自动重试';
        });
      }
    } catch (_) {
      if (mounted && _foreground && generation == _generation) {
        setState(
          () => _status = _snapshot == null ? '暂未连接 · 本地时钟' : '连接暂不可用 · 显示上次同步',
        );
      }
    } finally {
      if (generation == _generation) _loading = false;
    }
  }

  Future<void> _refreshWeather(Map<String, dynamic> snapshot) async {
    final flights = snapshot['flights'];
    if (!_foreground ||
        _weatherLoading ||
        flights is! List ||
        flights.isEmpty) {
      return;
    }
    final key = jsonEncode(
      flights
          .whereType<Map>()
          .take(12)
          .map(
            (flight) => [
              flight['id'],
              for (final side in ['origin', 'destination'])
                if (flight[side] is Map)
                  [
                    for (final field in ['lat', 'lng', 'timezone', 'drawable'])
                      flight[side][field],
                  ]
                else
                  null,
            ],
          )
          .toList(),
    );
    final now = widget.now?.call() ?? DateTime.now();
    if (key == _weatherKey &&
        _weatherNext != null &&
        now.isBefore(_weatherNext!)) {
      return;
    }
    final generation = ++_weatherGeneration;
    _weatherLoading = true;
    _weatherKey = key;
    _weatherNext = now.add(const Duration(minutes: 1));
    try {
      final result =
          await (widget.loadWeather?.call() ??
                  _client.call('homeDisplayWeather'))
              .timeout(const Duration(seconds: 45));
      if (!mounted || !_foreground || generation != _weatherGeneration) return;
      final data = result['data'];
      if (result['ok'] == true && data is Map && data['routes'] is List) {
        setState(() {
          _weather = Map<String, dynamic>.from(data);
          _weatherStale = false;
        });
        // Incomplete city results can retry later without polling the provider
        // on every frame or discarding another city's valid weather.
        final incomplete =
            (data['routes'] as List).isEmpty ||
            (data['routes'] as List).whereType<Map>().any(
              (route) => ['origin', 'destination'].any(
                (side) =>
                    route[side] is Map &&
                    (route[side]['snapshot'] == null ||
                        route[side]['error'] != null),
              ),
            );
        _weatherNext = now.add(Duration(minutes: incomplete ? 5 : 30));
      } else {
        setState(() => _weatherStale = true);
      }
    } catch (_) {
      if (mounted && _foreground && generation == _weatherGeneration) {
        setState(() => _weatherStale = true);
      }
    } finally {
      if (generation == _weatherGeneration) _weatherLoading = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final resumed = state == AppLifecycleState.resumed;
    if (_foreground == resumed) return;
    _foreground = resumed;
    if (resumed) {
      _start();
      setState(() {});
    } else {
      _minute?.cancel();
      _poll?.cancel();
      ++_generation;
      ++_weatherGeneration;
      _loading = false;
      if (_weatherLoading) _weatherNext = null;
      _weatherLoading = false;
      setState(() {});
    }
  }

  void _wake() {
    if (_waking) return;
    _waking = true;
    widget.onWake?.call();
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    ++_generation;
    ++_weatherGeneration;
    _minute?.cancel();
    _poll?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String two(int value) => value.toString().padLeft(2, '0');
    final items = _snapshot == null
        ? const <CinemaTVDisplayItem>[]
        : cinemaTVDisplayItems(
            _snapshot!,
            weather: _weather,
            now: _clock,
            weatherStale: _weatherStale,
          );
    return PopScope<void>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && !_waking) {
          _waking = true;
          widget.onWake?.call();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          autofocus: true,
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent || event is KeyRepeatEvent) {
              _wake();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _wake,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final scale = math
                    .min(size.width / 1280, size.height / 720)
                    .clamp(.1, 1.5);
                final horizontal = 46.0 * scale;
                return SizedBox(
                  key: const ValueKey('tv-home-display-fullscreen'),
                  width: size.width,
                  height: size.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      SizedBox.expand(
                        key: const ValueKey('tv-home-display-earth'),
                        child:
                            widget.earthBuilder?.call(
                              _snapshot == null
                                  ? const []
                                  : cinemaTVDisplayRoutes(_snapshot!),
                              _foreground,
                            ) ??
                            CinemaTVEarth(
                              flights: _snapshot == null
                                  ? const []
                                  : cinemaTVDisplayRoutes(_snapshot!),
                              active: _foreground,
                              onFirstFrame: () {
                                if (mounted && _earthFailed) {
                                  setState(() => _earthFailed = false);
                                }
                              },
                              onError: () {
                                if (mounted && !_earthFailed) {
                                  setState(() => _earthFailed = true);
                                }
                              },
                              fallbackBuilder: (_) => Image.asset(
                                'assets/images/tv_home_display.jpg',
                                fit: BoxFit.cover,
                                cacheWidth: 1920,
                                filterQuality: FilterQuality.low,
                                errorBuilder: (_, _, _) =>
                                    const ColoredBox(color: Colors.black),
                              ),
                            ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          horizontal,
                          38 * scale,
                          horizontal,
                          28 * scale,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'HOME DISPLAY',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 16 * scale,
                                letterSpacing: 3,
                              ),
                            ),
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomLeft,
                                child: SizedBox(
                                  width: math.min(
                                    size.width * .44,
                                    580 * scale,
                                  ),
                                  child: FittedBox(
                                    alignment: Alignment.bottomLeft,
                                    fit: BoxFit.scaleDown,
                                    child: SizedBox(
                                      width: 550 * scale,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            '${two(_clock.hour)}:${two(_clock.minute)}',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 64 * scale,
                                              fontWeight: FontWeight.w300,
                                              height: 1,
                                            ),
                                          ),
                                          SizedBox(height: 10 * scale),
                                          Text(
                                            '${_clock.month}月${_clock.day}日  ${const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][_clock.weekday - 1]}',
                                            style: TextStyle(
                                              color: Colors.white70,
                                              fontSize: 20 * scale,
                                            ),
                                          ),
                                          SizedBox(height: 26 * scale),
                                          if (items.isNotEmpty) ...[
                                            _TVFlightDetails(
                                              item: items.first,
                                              scale: scale,
                                            ),
                                            for (final item in items.skip(1))
                                              Padding(
                                                padding: EdgeInsets.only(
                                                  top: 12 * scale,
                                                ),
                                                child: Row(
                                                  children: [
                                                    SizedBox(
                                                      width: 180 * scale,
                                                      child: Text(
                                                        item.title,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: Colors.white60,
                                                          fontSize: 16 * scale,
                                                        ),
                                                      ),
                                                    ),
                                                    Expanded(
                                                      child: Text(
                                                        item.body,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          color: Colors.white70,
                                                          fontSize: 19 * scale,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                          ] else
                                            Text(
                                              _status.isNotEmpty
                                                  ? _status
                                                  : '暂无待展示的航班',
                                              style: TextStyle(
                                                color: Colors.white60,
                                                fontSize: 18 * scale,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(height: 8 * scale),
                            Text(
                              [
                                if (_earthFailed) '地球渲染暂不可用',
                                if (items.isNotEmpty && _status.isNotEmpty)
                                  _status,
                                if (_snapshot != null)
                                  '同步于 ${cinemaTVDisplayTime(_snapshot!['syncedAt'])}',
                              ].where((value) => value.isNotEmpty).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 13 * scale,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _TVFlightDetails extends StatelessWidget {
  const _TVFlightDetails({required this.item, required this.scale});
  final CinemaTVDisplayItem item;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final info = item.flight!;
    Widget line(
      String value,
      double size, {
      Color color = Colors.white70,
      FontWeight weight = FontWeight.w400,
    }) => Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: size * scale,
        fontWeight: weight,
        height: 1.3,
      ),
    );
    Widget airport(bool departure) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line(
            '${departure ? '出发' : '到达'} · ${departure ? info.departureAirport : info.arrivalAirport}',
            16,
          ),
          SizedBox(height: 5 * scale),
          line(
            departure ? info.departure : info.arrival,
            24,
            color: Colors.white,
            weight: FontWeight.w500,
          ),
          line(
            departure ? info.departureNote : info.arrivalNote,
            14,
            color: Colors.white54,
          ),
          SizedBox(height: 8 * scale),
          line(departure ? info.departureWeather : info.arrivalWeather, 19),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: line(
                info.city,
                48,
                color: Colors.white,
                weight: FontWeight.w500,
              ),
            ),
            if (info.country.isNotEmpty) ...[
              SizedBox(width: 14 * scale),
              Flexible(child: line(info.country, 18)),
            ],
          ],
        ),
        SizedBox(height: 6 * scale),
        line(
          [item.title, info.airline].where((v) => v.isNotEmpty).join(' · '),
          20,
          color: Colors.white,
        ),
        line(item.body, 20),
        SizedBox(height: 18 * scale),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            airport(true),
            SizedBox(width: 18 * scale),
            airport(false),
          ],
        ),
        if (info.gate.isNotEmpty) ...[
          SizedBox(height: 12 * scale),
          line(info.gate, 17),
        ],
        SizedBox(height: 12 * scale),
        line(info.countdown, 18, color: Colors.white),
        if (info.source.isNotEmpty)
          line(info.source, 13, color: Colors.white38),
      ],
    );
  }
}
