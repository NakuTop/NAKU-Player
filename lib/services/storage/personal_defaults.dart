import 'dart:convert';

/// Optional private build profile. Stored user choices always take precedence.
class PersonalDefaults {
  PersonalDefaults._(this.settings, this.sources, this.cinema);
  static final current = PersonalDefaults.decode(
    const String.fromEnvironment('NAKU_PERSONAL_DEFAULTS'),
  );
  final Map<String, dynamic> settings, cinema;
  final List<Map<String, dynamic>> sources;
  static final excluded = RegExp(
    r'password|passwd|token|secret|appKey|apiKey|directory|bookmark|webdav|username|account|proxyUrl|proxyEnable',
    caseSensitive: false,
  );
  factory PersonalDefaults.decode(String encoded) {
    try {
      final raw = jsonDecode(utf8.decode(base64Decode(encoded))) as Map;
      final settings = Map<String, dynamic>.from(raw['settings'] as Map? ?? {})
        ..removeWhere((key, _) => excluded.hasMatch(key));
      final sources = (raw['sources'] as List? ?? [])
          .whereType<Map>()
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      final cinema = <String, dynamic>{
        for (final key in ['trackPreferences', 'autoBestRoute'])
          if ((raw['cinema'] as Map? ?? {}).containsKey(key))
            key: raw['cinema'][key],
      };
      return PersonalDefaults._(settings, sources, cinema);
    } catch (_) {
      return PersonalDefaults._({}, [], {});
    }
  }
  T value<T>(String key, T fallback) {
    if (!settings.containsKey(key)) return fallback;
    final value = settings[key];
    if (value is T) return value;
    if (fallback is double && value is num) return value.toDouble() as T;
    if (fallback is List<String> &&
        value is List &&
        value.every((v) => v is String)) {
      return value.cast<String>().toList() as T;
    }
    return fallback;
  }
}
