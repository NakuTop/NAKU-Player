import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_display_data.dart';

void main() {
  final now = DateTime.utc(2026, 11, 1, 5);
  Map<String, dynamic> flight() => {
    'id': 'owner-flight',
    'airline': '测试航空',
    'origin': {
      'city': '北京',
      'label': 'PEK',
      'lat': 40,
      'lng': 116,
      'timezone': 'Asia/Shanghai',
      'drawable': true,
    },
    'destination': {
      'city': '多伦多',
      'label': 'YYZ',
      'country': '加拿大',
      'lat': 43,
      'lng': -79,
      'timezone': 'America/Toronto',
      'drawable': true,
    },
    'scheduledDeparture': '2026-11-01T06:00:00Z',
    'scheduledArrival': '2026-11-01T20:00:00Z',
    'terminal': 'T3',
    'gate': 'E18',
  };
  Map<String, dynamic> collection(Map f) {
    Map entry(String side, num temperature) => {
      'point': f[side],
      'snapshot': {'temperature': temperature, 'condition': '晴'},
      'updatedAt': now.toIso8601String(),
      'dataStatus': 'live',
    };
    return {
      'checkedAt': now.toIso8601String(),
      'routes': [
        {
          'selectionKey': jsonEncode([f['id'], null, null]),
          'origin': entry('origin', 0),
          'destination': entry('destination', -3.2),
        },
      ],
    };
  }

  test(
    'airport times use the supplied IANA zone and its daylight-saving transition',
    () {
      expect(
        cinemaTVAirportTime('2026-11-01T06:00:00Z', 'Asia/Shanghai'),
        '11/01 14:00 当地',
      );
      expect(
        cinemaTVAirportTime('2026-11-01T05:30:00Z', 'America/Toronto'),
        '11/01 01:30 当地',
      );
      expect(
        cinemaTVAirportTime('2026-11-01T07:30:00Z', 'America/Toronto'),
        '11/01 02:30 当地',
      );
      expect(
        cinemaTVAirportTime('2026-11-01T06:00:00Z', 'Unknown/City'),
        '11/01 06:00 UTC',
      );
      expect(
        cinemaTVAirportTime('2026-11-01T06:00:00', 'Asia/Shanghai'),
        '待确认',
      );
      expect(cinemaTVAirportTime('invalid', null), '待确认');
    },
  );
  test(
    'flight details retain actual times, gate and both airport weather readings',
    () {
      final f = flight(),
          info = cinemaTVFlightInfo(f, weather: collection(f), now: now);
      expect(info.city, '多伦多');
      expect(info.country, '加拿大');
      expect(info.departure, '11/01 14:00 当地');
      expect(info.arrival, '11/01 15:00 当地');
      expect(info.departureWeather, '0° 晴');
      expect(info.arrivalWeather, '-3° 晴');
      expect(info.gate, '航站楼 T3 · 登机口 E18');
      expect(info.countdown, '1 小时 0 分钟后起飞');
      final actual = cinemaTVFlightInfo({
        ...f,
        'actualDeparture': '2026-11-01T06:12:00Z',
        'estimatedDeparture': '2026-11-01T06:05:00Z',
      }, now: now);
      expect(actual.departure, '11/01 14:12 当地');
      expect(actual.departureNote, '实际出发');
      expect(actual.countdown, '已起飞');
    },
  );
  test(
    'weather cannot move between flights, corrected coordinates, demo or expired readings',
    () {
      final f = flight(), weather = collection(f);
      expect(
        cinemaTVFlightInfo(
          {...f, 'id': 'different-flight'},
          weather: weather,
          now: now,
        ).arrivalWeather,
        '天气暂不可用',
      );
      expect(
        cinemaTVFlightInfo(
          {
            ...f,
            'destination': {...f['destination'], 'lat': 44},
          },
          weather: weather,
          now: now,
        ).arrivalWeather,
        '天气暂不可用',
      );
      expect(
        cinemaTVFlightInfo(
          f,
          weather: weather,
          now: now.add(const Duration(minutes: 46)),
        ).arrivalWeather,
        '天气暂不可用',
      );
      expect(
        cinemaTVFlightInfo(
          f,
          weather: weather,
          now: now,
          weatherStale: true,
        ).arrivalWeather,
        '-3° 晴 · 缓存',
      );
      final invalid = collection(f);
      invalid['routes'][0]['destination']['dataStatus'] = 'demo';
      final info = cinemaTVFlightInfo(f, weather: invalid, now: now);
      expect(info.arrivalWeather, '天气暂不可用');
      expect(info.departureWeather, '0° 晴');
    },
  );
}
