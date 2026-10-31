import 'dart:convert';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

String _text(Object? value, [int maximum = 80]) => value is String
    ? value.trim().substring(0, value.trim().length.clamp(0, maximum))
    : '';

bool _zonesReady = false;

/// An absent/unknown airport zone stays explicitly UTC. Device time cannot
/// stand in for a flight in a different country, including across DST changes.
String cinemaTVAirportTime(Object? value, Object? timezone) {
  final instant = value is String ? DateTime.tryParse(value) : null;
  if (instant == null ||
      !RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(value as String)) {
    return '待确认';
  }
  DateTime time = instant.toUtc();
  var suffix = ' UTC';
  final zone = _text(timezone);
  if (zone.isNotEmpty) {
    if (!_zonesReady) {
      tzdata.initializeTimeZones();
      _zonesReady = true;
    }
    try {
      time = tz.TZDateTime.from(instant, tz.getLocation(zone));
      suffix = ' 当地';
    } catch (_) {
      /* Keep labeled UTC. */
    }
  }
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(time.month)}/${two(time.day)} ${two(time.hour)}:${two(time.minute)}$suffix';
}

class CinemaTVFlightInfo {
  const CinemaTVFlightInfo({
    required this.city,
    required this.country,
    required this.airline,
    required this.departureAirport,
    required this.arrivalAirport,
    required this.departure,
    required this.arrival,
    required this.departureNote,
    required this.arrivalNote,
    required this.departureWeather,
    required this.arrivalWeather,
    required this.gate,
    required this.countdown,
    required this.source,
  });
  final String city, country, airline, departureAirport, arrivalAirport;
  final String departure, arrival, departureNote, arrivalNote;
  final String departureWeather, arrivalWeather, gate, countdown, source;
}

bool _samePoint(Object? a, Object? b) =>
    a is Map &&
    b is Map &&
    a['drawable'] == true &&
    b['drawable'] == true &&
    a['lat'] is num &&
    a['lng'] is num &&
    (a['lat'] as num).isFinite &&
    (a['lng'] as num).isFinite &&
    (a['lat'] as num).abs() <= 90 &&
    (a['lng'] as num).abs() <= 180 &&
    a['lat'] == b['lat'] &&
    a['lng'] == b['lng'] &&
    a['timezone'] == b['timezone'];

Map? _weatherRoute(Map flight, Map<String, dynamic>? collection) {
  final routes = collection?['routes'];
  if (routes is! List ||
      routes.length > 12 ||
      _text(flight['id'], 100).isEmpty) {
    return null;
  }
  for (final route in routes.whereType<Map>()) {
    try {
      final key = jsonDecode(_text(route['selectionKey'], 1000));
      if (key is List && key.length == 3 && key.first == flight['id']) {
        return route;
      }
    } catch (_) {
      /* A malformed identity never borrows another route. */
    }
  }
  return null;
}

String _weather(Object? value, Object? point, DateTime now, bool stale) {
  if (value is! Map ||
      !_samePoint(point, value['point']) ||
      !['live', 'cached'].contains(value['dataStatus'])) {
    return '天气暂不可用';
  }
  final updated = value['updatedAt'] is String
      ? DateTime.tryParse(value['updatedAt'])
      : null;
  final snapshot = value['snapshot'];
  final temperature = snapshot is Map ? snapshot['temperature'] : null;
  final age = updated == null ? null : now.difference(updated);
  if (age == null ||
      age > const Duration(minutes: 45) ||
      age < const Duration(minutes: -5) ||
      temperature is! num ||
      !temperature.isFinite ||
      temperature < -100 ||
      temperature > 80) {
    return '天气暂不可用';
  }
  final condition = _text(snapshot['condition'], 20);
  final cached = stale || value['dataStatus'] == 'cached';
  return '${temperature.round()}°${condition.isEmpty ? '' : ' $condition'}${cached ? ' · 缓存' : ''}';
}

CinemaTVFlightInfo cinemaTVFlightInfo(
  Map flight, {
  Map<String, dynamic>? weather,
  required DateTime now,
  bool weatherStale = false,
}) {
  final from = flight['origin'] is Map ? flight['origin'] as Map : const {};
  final to = flight['destination'] is Map
      ? flight['destination'] as Map
      : const {};
  String airport(Map point) => _text(point['label'], 35).isNotEmpty
      ? _text(point['label'], 35)
      : _text(point['city'], 35);
  String time(Object? value, Map point) =>
      cinemaTVAirportTime(value, point['timezone']);
  final departure =
      flight['actualDeparture'] ??
      flight['estimatedDeparture'] ??
      flight['scheduledDeparture'];
  final arrival =
      flight['actualArrival'] ??
      flight['estimatedArrival'] ??
      flight['scheduledArrival'];
  String note(String kind, String side, Map point) {
    if (flight['actual$side'] != null) return '实际$kind';
    if (flight['estimated$side'] != null) {
      return '预计 · 计划 ${time(flight['scheduled$side'], point)}';
    }
    return '计划$kind';
  }

  var countdown = '时刻待确认';
  final date = departure is String ? DateTime.tryParse(departure) : null;
  if (flight['actualDeparture'] != null) {
    countdown = flight['actualArrival'] != null ? '已到达' : '已起飞';
  } else if (date != null) {
    final minutes = date.difference(now).inMinutes;
    countdown = minutes <= 0
        ? '已到计划起飞时间'
        : minutes >= 1440
        ? '${minutes ~/ 1440} 天 ${(minutes % 1440) ~/ 60} 小时后起飞'
        : minutes >= 60
        ? '${minutes ~/ 60} 小时 ${minutes % 60} 分钟后起飞'
        : '$minutes 分钟后起飞';
  } else if (_text(flight['requestedDepartureDate']).isNotEmpty) {
    countdown = '${_text(flight['requestedDepartureDate'])} · 时刻待确认';
  }
  final route = _weatherRoute(flight, weather);
  return CinemaTVFlightInfo(
    city: _text(to['city'], 40).isNotEmpty
        ? _text(to['city'], 40)
        : airport(to),
    country: _text(to['country'], 40),
    airline: _text(flight['airline'], 60),
    departureAirport: airport(from),
    arrivalAirport: airport(to),
    departure: time(departure, from),
    arrival: time(arrival, to),
    departureNote: note('出发', 'Departure', from),
    arrivalNote: note('到达', 'Arrival', to),
    departureWeather: _weather(route?['origin'], from, now, weatherStale),
    arrivalWeather: _weather(route?['destination'], to, now, weatherStale),
    gate: [
      if (_text(flight['terminal'], 20).isNotEmpty)
        '航站楼 ${_text(flight['terminal'], 20)}',
      if (_text(flight['gate'], 20).isNotEmpty)
        '登机口 ${_text(flight['gate'], 20)}',
    ].join(' · '),
    countdown: countdown,
    source: [
      _text(flight['dataLabel'], 40),
      if (flight['routePreview'] == true) '航线预览',
    ].where((value) => value.isNotEmpty).join(' · '),
  );
}
