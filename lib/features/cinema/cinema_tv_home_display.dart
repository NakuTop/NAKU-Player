import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cinema_nas_media.dart';
import 'cinema_tv_earth.dart';

class CinemaTVDisplayItem {
  const CinemaTVDisplayItem(this.title, this.body, this.detail);
  final String title, body, detail;
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
List<CinemaTVDisplayItem> cinemaTVDisplayItems(Map<String, dynamic> snapshot) {
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
          ].where((v) => v.isNotEmpty).join(' · '),
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
/// WebView, WebGL, decorative models, in-screen controls or screenshot readback.
class CinemaTVHomeDisplay extends StatefulWidget {
  const CinemaTVHomeDisplay({
    super.key,
    this.client,
    this.onWake,
    this.loadSnapshot,
    this.now,
    this.earthBuilder,
  });
  final CinemaNASClient? client;
  final VoidCallback? onWake;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? loadSnapshot;
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
  Timer? _minute, _poll;
  bool _foreground = true, _loading = false, _waking = false;
  bool _earthFailed = false;
  int _generation = 0;
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
      } else {
        final reason = result['reason'];
        final needsNAS =
            reason == 'nas_login_required' ||
            reason == 'nas_session_expired' ||
            reason == 'nas_authentication_failed';
        setState(() {
          if (needsNAS) _snapshot = null;
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
      _loading = false;
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
        : cinemaTVDisplayItems(_snapshot!);
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
                            const Spacer(),
                            Text(
                              '${two(_clock.hour)}:${two(_clock.minute)}',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 96 * scale,
                                fontWeight: FontWeight.w300,
                                height: 1,
                              ),
                            ),
                            SizedBox(height: 12 * scale),
                            Text(
                              '${_clock.month}月${_clock.day}日  ${const ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'][_clock.weekday - 1]}',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 22 * scale,
                              ),
                            ),
                            SizedBox(height: 28 * scale),
                            if (items.isNotEmpty)
                              SizedBox(
                                width: (size.width * .44)
                                    .clamp(280, 720)
                                    .toDouble(),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    for (final item in items)
                                      Padding(
                                        padding: EdgeInsets.only(
                                          bottom: 16 * scale,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.white,
                                                fontSize: 20 * scale,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                            if (item.body.isNotEmpty)
                                              Text(
                                                item.body,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 18 * scale,
                                                ),
                                              ),
                                            if (item.detail.isNotEmpty)
                                              Text(
                                                item.detail,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 14 * scale,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              )
                            else
                              Text(
                                _status.isNotEmpty ? _status : '暂无待展示的航班',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 18 * scale,
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
