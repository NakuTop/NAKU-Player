import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/storage/personal_defaults.dart';

void main() {
  test(
    'personal profile keeps portable typed choices while excluding sensitive settings',
    () {
      final p = PersonalDefaults.decode(
        base64Encode(
          utf8.encode(
            jsonEncode({
              'settings': {
                'opacity': 0.4,
                'speed': 2,
                'names': ['a'],
                'password': 'secret',
                'bangumiAccessToken': 'secret',
                'downloadDirectory': '/private',
                'proxyUrl': '127.0.0.1:7897',
              },
              'sources': [
                {'id': 'source'},
              ],
              'cinema': {
                'trackPreferences': {'subtitleLanguage': 'zh'},
                'autoBestRoute': false,
                'history': ['private'],
              },
            }),
          ),
        ),
      );
      expect(p.value<double>('opacity', 1), 0.4);
      expect(p.value<double>('speed', 1), 2.0);
      expect(p.value<List<String>>('names', []), ['a']);
      expect(p.settings.keys, isNot(contains('password')));
      expect(p.settings.keys, isNot(contains('bangumiAccessToken')));
      expect(p.settings.keys, isNot(contains('downloadDirectory')));
      expect(p.settings.keys, isNot(contains('proxyUrl')));
      expect(p.cinema.keys, isNot(contains('history')));
      expect(p.value('absent', true), true);
    },
  );
  test('absent or invalid optional profile falls back to normal defaults', () {
    expect(PersonalDefaults.decode('').settings, isEmpty);
    expect(PersonalDefaults.decode('bad').value('key', true), true);
    expect(
      PersonalDefaults.decode('').value<String?>('absent', 'fallback'),
      'fallback',
    );
  });
}
