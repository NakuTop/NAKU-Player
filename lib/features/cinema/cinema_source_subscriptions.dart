import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'cinema_models.dart';
import 'cinema_media_transport.dart';
import 'cinema_store.dart';

String cinemaSourceUrlKey(String url) {
  final uri = requireHttpUrl(url);
  return uri
      .replace(
        queryParameters: {
          for (final e in uri.queryParameters.entries)
            if (!['ac', 'pg', 'wd', 'ids', 't'].contains(e.key)) e.key: e.value,
        },
        fragment: '',
      )
      .toString()
      .replaceFirst(RegExp(r'/\?$'), '/')
      .replaceFirst(RegExp(r'/$'), '');
}

class CinemaSourceImport {
  const CinemaSourceImport(this.sources, this.skipped);
  final List<CinemaSource> sources;
  final int skipped;
}

/// Accepts NAKU/LibreTV JSON and only direct MacCMS TVBox sites. Script/jar
/// engines and executable rules are intentionally not interpreted.
CinemaSourceImport parseCinemaSourceImport(String text) {
  if (utf8.encode(text).length > 2 * 1024 * 1024) {
    throw const FormatException('片源清单超过 2MB');
  }
  final raw = jsonDecode(text);
  Object? entries = raw;
  if (raw is Map) entries = raw['sources'] ?? raw['sites'] ?? raw['vod'];
  if (entries is Map) {
    entries = entries.entries
        .map(
          (e) => e.value is Map
              ? {'name': e.key, ...Map<String, dynamic>.from(e.value as Map)}
              : {'name': e.key, 'url': e.value},
        )
        .toList();
  }
  if (entries is! List || entries.length > 500) {
    throw const FormatException('需要 sources 或 sites 片源列表，最多 500 个');
  }
  var skipped = 0;
  final parsed = <CinemaSource>[], urls = <String>{};
  for (final entry in entries) {
    try {
      if (entry is! Map ||
          (entry['kind'] != null && entry['kind'] != 'maccms') ||
          (entry['type'] != null && entry['type'] != 0 && entry['type'] != 1)) {
        skipped++;
        continue;
      }
      final url = textValue(entry['url'] ?? entry['api']).trim();
      final uri = requireHttpUrl(url);
      if (uri.userInfo.isNotEmpty ||
          !RegExp(
            r'/api(?:\.php)?/|/provide/vod',
            caseSensitive: false,
          ).hasMatch(uri.path)) {
        skipped++;
        continue;
      }
      final key = cinemaSourceUrlKey(url);
      if (!urls.add(key)) {
        skipped++;
        continue;
      }
      final headers = entry['headers'] ?? entry['header'];
      final source = CinemaSource(
        id: 'import-${sha256.convert(utf8.encode(key)).toString().substring(0, 16)}',
        name: textValue(entry['name'] ?? entry['key']).trim(),
        kind: CinemaSourceKind.maccms,
        url: url,
        enabled: entry['enabled'] != false,
        requestHeaders: headers is Map
            ? headers.map(
                (key, value) => MapEntry(key.toString(), value.toString()),
              )
            : const {},
      );
      source.validate();
      parsed.add(source);
    } catch (_) {
      skipped++;
    }
  }
  if (parsed.isEmpty) throw const FormatException('没有可导入的 MacCMS 接口');
  return CinemaSourceImport(parsed, skipped);
}

class CinemaSourceSubscriptions {
  CinemaSourceSubscriptions(this.store, {CinemaMediaTransport? transport})
    : transport = transport ?? CinemaMediaTransport();
  final CinemaStore store;
  final CinemaMediaTransport transport;
  List<Map<String, dynamic>> get subscriptions =>
      jsonMaps(store.extras['subscriptions']);
  Future<int> import(CinemaSourceImport list) async {
    final current = store.sources.map((s) => cinemaSourceUrlKey(s.url)).toSet();
    final additions = <CinemaSource>[];
    for (final source in list.sources) {
      if (current.add(cinemaSourceUrlKey(source.url))) additions.add(source);
    }
    await store.addSources(additions);
    return additions.length;
  }

  Future<int> subscribe(
    String url, {
    String name = '',
    CinemaSourceImport? preloaded,
  }) async {
    final uri = requireHttpUrl(url);
    if (uri.userInfo.isNotEmpty) throw const FormatException('订阅地址不能包含账号密码');
    final parsed =
        preloaded ??
        parseCinemaSourceImport(await transport.text(uri, const {}));
    final added = await import(parsed);
    final list = subscriptions;
    list.removeWhere((item) => item['url'] == uri.toString());
    list.add({
      'url': uri.toString(),
      'name': name.trim().isEmpty ? uri.host : name.trim(),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
      'autoRefresh': true,
      'count': parsed.sources.length,
    });
    await store.setExtra('subscriptions', list);
    return added;
  }

  Future<void> refresh({bool automatic = false}) async {
    for (final sub in subscriptions) {
      final at = DateTime.tryParse('${sub['updatedAt']}');
      if (automatic &&
          (sub['autoRefresh'] == false ||
              (at != null && DateTime.now().difference(at).inHours < 24))) {
        continue;
      }
      try {
        await subscribe('${sub['url']}', name: '${sub['name'] ?? ''}');
      } catch (_) {
        if (!automatic) rethrow;
      }
    }
  }

  Future<void> remove(String url) => store.setExtra(
    'subscriptions',
    subscriptions.where((s) => s['url'] != url).toList(),
  );
  String export() => const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'sources': store.sources
        .where((s) => s.kind == CinemaSourceKind.maccms)
        .map((s) => s.toJson())
        .toList(),
  });
}
