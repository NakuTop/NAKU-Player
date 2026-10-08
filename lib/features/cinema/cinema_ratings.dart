import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_models.dart';

class RatingIdentity {
  const RatingIdentity({
    this.doubanId = '',
    this.imdbId = '',
    this.rottenTomatoesId = '',
    this.label = '',
    this.wikidataId = '',
    this.confirmed = false,
  });
  final String doubanId, imdbId, rottenTomatoesId, label, wikidataId;
  final bool confirmed;
  void validate() {
    if (doubanId.isNotEmpty &&
        !RegExp(r'^[1-9][0-9]{1,11}$').hasMatch(doubanId)) {
      throw const FormatException('豆瓣 ID 应为条目网址中的数字');
    }
    if (imdbId.isNotEmpty && !RegExp(r'^tt[0-9]{7,10}$').hasMatch(imdbId)) {
      throw const FormatException('IMDb ID 格式为 tt 加 7–10 位数字');
    }
    if (rottenTomatoesId.isNotEmpty &&
        !RegExp(
          r'^(m|tv)/[a-zA-Z0-9_-]+(/s[0-9]{1,3}(/e[0-9]{1,3})?)?$',
        ).hasMatch(rottenTomatoesId)) {
      throw const FormatException('烂番茄条目格式为 m/片名 或 tv/剧名/s01');
    }
  }

  Map<String, dynamic> toJson() => {
    'doubanId': doubanId,
    'imdbId': imdbId,
    'rottenTomatoesId': rottenTomatoesId,
    'label': label,
    'wikidataId': wikidataId,
    'confirmed': confirmed,
  };
  factory RatingIdentity.fromJson(Map<String, dynamic> json) => RatingIdentity(
    doubanId: json['doubanId'] as String? ?? '',
    imdbId: json['imdbId'] as String? ?? '',
    rottenTomatoesId: json['rottenTomatoesId'] as String? ?? '',
    label: json['label'] as String? ?? '',
    wikidataId: json['wikidataId'] as String? ?? '',
    confirmed: json['confirmed'] == true,
  )..validate();
}

class CinemaRating {
  const CinemaRating({
    required this.provider,
    this.value,
    this.scale = 10,
    this.count,
    this.url = '',
    required this.note,
    this.verified = false,
    this.fetchedAt,
  });
  final String provider, url, note;
  final double? value;
  final double scale;
  final int? count;
  final bool verified;
  final DateTime? fetchedAt;
  Map<String, dynamic> toJson() => {
    'provider': provider,
    'value': value,
    'scale': scale,
    'count': count,
    'url': url,
    'note': note,
    'verified': verified,
    'fetchedAt': fetchedAt?.toIso8601String(),
  };
  factory CinemaRating.fromJson(Map<String, dynamic> json) => CinemaRating(
    provider: json['provider'] as String,
    value: (json['value'] as num?)?.toDouble(),
    scale: (json['scale'] as num).toDouble(),
    count: json['count'] as int?,
    url: json['url'] as String,
    note: json['note'] as String,
    verified: json['verified'] == true,
    fetchedAt: DateTime.tryParse(json['fetchedAt']?.toString() ?? ''),
  );
}

class CinemaRatings {
  const CinemaRatings({
    required this.identity,
    required this.ratings,
    required this.message,
  });
  final RatingIdentity identity;
  final List<CinemaRating> ratings;
  final String message;
}

typedef RatingsFetch = Future<List<int>> Function(Uri uri, int maxBytes);

// Top-level isolate entry wrappers avoid capturing repository futures/clients.
Future<(double, int)?> _readImdbInBackground(String path, String id) =>
    Isolate.run(() => CinemaRatingsRepository.readImdbRating(path, id));
Future<void> _validateImdbInBackground(List<int> bytes) => Isolate.run(() {
  final data = utf8.decode(gzip.decode(bytes));
  if (!data.startsWith('tconst\taverageRating\tnumVotes\n')) {
    throw const FormatException('IMDb 数据集格式变化');
  }
});

/// On-demand, exact-ID lookups. Ratings never affect catalogue/playback success.
class CinemaRatingsRepository {
  CinemaRatingsRepository({Directory? directory, RatingsFetch? fetch})
    : _directory = directory,
      _fetch = fetch ?? _networkFetch;
  static final instance = CinemaRatingsRepository();
  Directory? _directory;
  final RatingsFetch _fetch;
  Map<String, dynamic> _bindings = {}, _cache = {}, _mappings = {};
  Future<void>? _loading, _dataset;
  Future<void> _writes = Future.value();
  final Map<String, Future<CinemaRatings>> _pending = {};
  int _bindingRevision = 0;
  final Map<String, CinemaRatings> _memory = {};
  Future<void> _cardQueue = Future.value();
  String? _storageWarning;

  Future<Directory> get _dir async => _directory ??= Directory(
    '${(await getApplicationSupportDirectory()).path}/cinema/ratings',
  );

  Future<void> _ready() => _loading ??= _read();
  Future<void> _read() async {
    final file = File('${(await _dir).path}/ratings-v1.json');
    if (!await file.exists()) return;
    try {
      final data = jsonDecode(await file.readAsString()) as Map;
      if (data['version'] != 1 ||
          data['bindings'] is! Map ||
          data['cache'] is! Map ||
          data['mappings'] is! Map) {
        throw const FormatException('评分文件格式无效');
      }
      _bindings = Map<String, dynamic>.from(data['bindings']);
      _cache = Map<String, dynamic>.from(data['cache']);
      _mappings = Map<String, dynamic>.from(data['mappings']);
    } catch (_) {
      // Keep a malformed file intact; never silently replace user bindings.
      _storageWarning = '评分设置文件无法读取，已保留原文件；本次结果不保存';
    }
  }

  Future<void> _save() async {
    if (_storageWarning != null) return;
    final directory = await _dir;
    final encoded = jsonEncode({
      'version': 1,
      'bindings': _bindings,
      'cache': _cache,
      'mappings': _mappings,
    });
    final operation = _writes.catchError((_) {}).then((_) async {
      await directory.create(recursive: true);
      final temp = File('${directory.path}/ratings-v1.json.tmp');
      await temp.writeAsString(encoded, flush: true);
      await temp.rename('${directory.path}/ratings-v1.json');
    });
    _writes = operation;
    await operation;
  }

  Future<void> setIdentity(CinemaTitle title, RatingIdentity identity) async {
    identity.validate();
    await _ready();
    if (_storageWarning != null) throw StateError(_storageWarning!);
    final previous = _bindings[title.key];
    _bindings[title.key] = identity.toJson();
    _bindingRevision++;
    _memory.clear();
    try {
      await _save();
    } catch (_) {
      if (previous == null) {
        _bindings.remove(title.key);
      } else {
        _bindings[title.key] = previous;
      }
      rethrow;
    }
  }

  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) {
    final revision = _bindingRevision;
    final key = jsonEncode([
      title.key,
      force,
      _bindingRevision,
      title.title,
      title.year,
      title.doubanId,
      title.imdbId,
      title.rottenTomatoesId,
      title.sourceDoubanScore,
    ]);
    return _pending.putIfAbsent(
      key,
      () => _load(title, force)
          .then((result) {
            if (revision == _bindingRevision) {
              _memory[_memoryKey(title)] = result;
            }
            return result;
          })
          .whenComplete(() {
            _pending.remove(key);
          }),
    );
  }

  String _memoryKey(CinemaTitle title) => jsonEncode([
    title.key,
    title.title,
    title.year,
    title.doubanId,
    title.imdbId,
    title.rottenTomatoesId,
    title.sourceDoubanScore,
    _bindingRevision,
  ]);
  CinemaRatings? peek(CinemaTitle title) => _memory[_memoryKey(title)];

  /// Posters queue one lookup at a time. Off-screen/disposed cards can abandon
  /// their queued work; opening details always bypasses this background queue.
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
  }) {
    final operation = _cardQueue.catchError((_) {}).then((_) async {
      while (true) {
        if (isCurrent != null && !isCurrent()) {
          throw StateError('Card no longer displayed');
        }
        final revision = _bindingRevision;
        final result = await load(title);
        // A manual correction in the detail sheet may finish while the old
        // poster request is in flight. Never hand that old association back.
        if (revision == _bindingRevision) return result;
      }
    });
    _cardQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<CinemaRatings> _load(CinemaTitle title, bool force) async {
    await _ready();
    var identity = _bindings[title.key] is Map
        ? RatingIdentity.fromJson(
            Map<String, dynamic>.from(_bindings[title.key]),
          )
        : RatingIdentity(
            doubanId: title.doubanId,
            imdbId: title.imdbId,
            rottenTomatoesId: title.rottenTomatoesId,
          );
    identity.validate();
    var message = identity.confirmed ? '使用你确认的条目 ID' : '条目 ID 由片源提供';
    if (identity.doubanId.isNotEmpty &&
        (identity.imdbId.isEmpty || identity.rottenTomatoesId.isEmpty)) {
      try {
        identity = await _resolve(title, identity, force);
        if (identity.wikidataId.isNotEmpty) {
          message = '按豆瓣 ID 精确关联 Wikidata · 片名与年份已核对';
          if (identity.confirmed) message = '按你确认的豆瓣 ID 关联 Wikidata';
        }
      } catch (error) {
        message = _readable(error);
      }
    }
    final results = await Future.wait([
      _rating('豆瓣', identity.doubanId, force),
      _rating('IMDb', identity.imdbId, force),
      _rating('烂番茄', identity.rottenTomatoesId, force),
    ]);
    // The source's Douban field is explicitly unverified and never enters the
    // shared provider cache. A manual change must not reuse another item's score.
    if (results[0].value == null &&
        title.sourceDoubanScore != null &&
        identity.doubanId == title.doubanId) {
      results[0] = CinemaRating(
        provider: '豆瓣',
        value: title.sourceDoubanScore,
        url: results[0].url,
        note: '片源转述 · 未核验；${results[0].note}',
      );
    }
    try {
      await _save();
    } catch (_) {
      message += ' · 评分缓存保存失败';
    }
    if (_storageWarning != null) message += ' · $_storageWarning';
    return CinemaRatings(
      identity: identity,
      ratings: results,
      message: message,
    );
  }

  Future<RatingIdentity> _resolve(
    CinemaTitle title,
    RatingIdentity original,
    bool force,
  ) async {
    final id = original.doubanId;
    Map<String, dynamic> entity;
    String qid;
    final cached = _mappings[id];
    if (!force && cached is Map && _fresh(cached, const Duration(days: 7))) {
      entity = Map<String, dynamic>.from(cached['entity']);
      qid = cached['qid'] as String;
    } else {
      final query =
          'SELECT DISTINCT ?item WHERE { ?item wdt:P4529 "$id" . } LIMIT 5';
      final data = await _json(
        Uri.https('query.wikidata.org', '/sparql', {
          'query': query,
          'format': 'json',
        }),
      );
      final bindings = (data['results'] as Map?)?['bindings'];
      final ids = <String>{};
      if (bindings is List) {
        for (final row in bindings) {
          final value = row['item']?['value']?.toString() ?? '';
          final q = Uri.tryParse(value)?.pathSegments.lastOrNull ?? '';
          if (RegExp(r'^Q[1-9][0-9]*$').hasMatch(q)) ids.add(q);
        }
      }
      if (ids.length != 1) throw const FormatException('未找到唯一的跨站条目，请手动关联 ID');
      qid = ids.single;
      final details = await _json(
        Uri.https('www.wikidata.org', '/w/api.php', {
          'action': 'wbgetentities',
          'ids': qid,
          'props': 'labels|aliases|claims',
          'languages': 'zh|zh-hans|zh-hant|en',
          'format': 'json',
        }),
      );
      entity = Map<String, dynamic>.from(details['entities'][qid]);
      _mappings[id] = {
        'at': DateTime.now().toIso8601String(),
        'qid': qid,
        'entity': entity,
      };
    }
    return identityFromEntity(title, original, qid, entity);
  }

  static RatingIdentity identityFromEntity(
    CinemaTitle title,
    RatingIdentity original,
    String qid,
    Map<String, dynamic> entity,
  ) {
    List<dynamic> claims(String property) =>
        ((entity['claims'] as Map?)?[property] as List? ?? [])
            .where((c) => c['rank'] != 'deprecated')
            .map((c) => c['mainsnak']?['datavalue']?['value'])
            .where((v) => v != null)
            .toList();
    final douban = claims('P4529').map((e) => e.toString()).toSet();
    if (!douban.contains(original.doubanId)) {
      throw const FormatException('跨站条目的豆瓣 ID 不一致，请检查关联');
    }
    final labels = (entity['labels'] as Map? ?? {}).values
        .map((v) => v['value'].toString())
        .toList();
    final aliases = (entity['aliases'] as Map? ?? {}).values
        .expand((v) => v as List)
        .map((v) => v['value'].toString());
    String normalize(String value) => value
        .toLowerCase()
        .replaceFirst(RegExp(r'\s*[（(](原声版|普通话版|国语版|英语版)[）)]\s*$'), '')
        .replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
    final names = [...labels, ...aliases].map(normalize).toSet();
    final years = claims('P577')
        .whereType<Map>()
        .map(
          (v) => RegExp(
            r'^\+([0-9]{4})-',
          ).firstMatch(v['time']?.toString() ?? '')?.group(1),
        )
        .whereType<String>()
        .toSet();
    // A season cannot silently inherit its parent series' rating: exact name,
    // documented release year and an instance-of claim are required.
    if (!original.confirmed &&
        (!names.contains(normalize(title.title)) ||
            !years.contains(title.year.trim()) ||
            claims('P31').isEmpty)) {
      throw FormatException(
        '关联待确认：${labels.firstOrNull ?? qid} '
        '(${years.join('/')})，请核对片名、年份及季度后关联',
      );
    }
    String unique(String property) {
      final values = claims(property).map((v) => v.toString()).toSet();
      if (values.length > 1) throw const FormatException('跨站 ID 有冲突，请手动关联');
      return values.firstOrNull ?? '';
    }

    final mappedImdb = unique('P345'), mappedRt = unique('P1258');
    final isSeason =
        claims('P31').whereType<Map>().any((v) => v['id'] == 'Q3464665') ||
        RegExp(
          r'第.{1,8}季|season\s*\d',
          caseSensitive: false,
        ).hasMatch(title.title);
    if (isSeason && !original.confirmed) {
      throw const FormatException('季度条目需手动确认，避免将整剧评分当作本季评分');
    }
    if ((original.imdbId.isNotEmpty &&
            mappedImdb.isNotEmpty &&
            original.imdbId != mappedImdb) ||
        (original.rottenTomatoesId.isNotEmpty &&
            mappedRt.isNotEmpty &&
            original.rottenTomatoesId != mappedRt)) {
      throw const FormatException('片源与跨站 ID 不一致；保留原 ID，请手动核对');
    }
    return RatingIdentity(
      doubanId: original.doubanId,
      imdbId: original.imdbId.isEmpty ? mappedImdb : original.imdbId,
      rottenTomatoesId: original.rottenTomatoesId.isEmpty
          ? mappedRt
          : original.rottenTomatoesId,
      label:
          ((entity['labels'] as Map?)?['zh-hans']?['value'] ??
                  labels.firstOrNull ??
                  qid)
              .toString(),
      wikidataId: qid,
      confirmed: original.confirmed,
    )..validate();
  }

  Future<CinemaRating> _rating(String provider, String id, bool force) async {
    final scale = provider == '烂番茄' ? 100.0 : 10.0;
    if (id.isEmpty) {
      return CinemaRating(
        provider: provider,
        scale: scale,
        note: '缺少条目 ID，可手动关联',
      );
    }
    final key = '$provider:$id';
    final cached = _cache[key];
    if (!force &&
        cached is Map &&
        _fresh(
          cached,
          cached['value'] == null
              ? const Duration(minutes: 30)
              : const Duration(hours: 24),
          field: 'fetchedAt',
        )) {
      try {
        return CinemaRating.fromJson(Map<String, dynamic>.from(cached));
      } catch (_) {
        _cache.remove(key);
      }
    }
    final url = switch (provider) {
      '豆瓣' => 'https://movie.douban.com/subject/$id/',
      'IMDb' => 'https://www.imdb.com/title/$id/',
      _ => 'https://www.rottentomatoes.com/$id',
    };
    CinemaRating result;
    try {
      if (provider == 'IMDb') {
        await (_dataset ??= _prepareDataset(
          force: force,
        ).whenComplete(() => _dataset = null));
        final path = '${(await _dir).path}/title.ratings.tsv.gz';
        (double, int)? values;
        try {
          values = await _readImdbInBackground(path, id);
        } catch (_) {
          // One bounded repair for a corrupt/truncated local dataset.
          await (_dataset ??= _prepareDataset(force: true).whenComplete(() {
            _dataset = null;
          }));
          values = await _readImdbInBackground(path, id);
        }
        if (values == null) throw const FormatException('IMDb 数据集暂未收录评分');
        result = CinemaRating(
          provider: provider,
          value: values.$1,
          count: values.$2,
          url: url,
          verified: true,
          note: 'IMDb 官方每日数据 · 个人非商业使用',
          fetchedAt: (await File(path).lastModified()),
        );
      } else {
        final body = utf8.decode(await _fetch(Uri.parse(url), 5 * 1024 * 1024));
        result = parseRatingPage(provider, url, body);
      }
    } catch (error) {
      result = CinemaRating(
        provider: provider,
        scale: scale,
        url: url,
        note: _readable(error),
        fetchedAt: DateTime.now(),
      );
    }
    _cache[key] = result.toJson();
    return result;
  }

  Future<void> _prepareDataset({bool force = false}) async {
    final directory = await _dir;
    await directory.create(recursive: true);
    final file = File('${directory.path}/title.ratings.tsv.gz');
    if (!force &&
        await file.exists() &&
        DateTime.now().difference(await file.lastModified()) <
            const Duration(hours: 24)) {
      return;
    }
    final bytes = await _fetch(
      Uri.parse('https://datasets.imdbws.com/title.ratings.tsv.gz'),
      32 * 1024 * 1024,
    );
    // Validate the entire gzip before replacing the last known complete file.
    await _validateImdbInBackground(bytes);
    final temp = File('${file.path}.tmp');
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
  }

  static (double, int)? readImdbRating(String path, String id) {
    final data = utf8.decode(gzip.decode(File(path).readAsBytesSync()));
    final start = data.indexOf('\n$id\t');
    if (start < 0) return null;
    final end = data.indexOf('\n', start + 1);
    final row = data
        .substring(start + 1, end < 0 ? data.length : end)
        .split('\t');
    final score = double.tryParse(row[1]), count = int.tryParse(row[2]);
    if (score == null ||
        !score.isFinite ||
        score < 0 ||
        score > 10 ||
        count == null ||
        count < 0) {
      return null;
    }
    return (score, count);
  }

  static CinemaRating parseRatingPage(
    String provider,
    String url,
    String body,
  ) {
    final document = html.parse(body);
    Iterable<Map> nodes(Object? value) sync* {
      if (value is List) {
        for (final item in value) {
          yield* nodes(item);
        }
      }
      if (value is Map) {
        yield value;
        if (value['@graph'] != null) yield* nodes(value['@graph']);
      }
    }

    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      Object? json;
      try {
        json = jsonDecode(script.text);
      } catch (_) {
        continue;
      }
      for (final item in nodes(json)) {
        if (![
          'Movie',
          'TVSeries',
          'TVSeason',
          'TVEpisode',
          'CreativeWork',
        ].contains(item['@type'])) {
          continue;
        }
        final rating = item['aggregateRating'];
        if (rating is! Map) continue;
        final pageUrl = Uri.tryParse(
          (item['url'] ?? item['@id'])?.toString() ?? '',
        );
        final expectedUrl = Uri.parse(url);
        if (pageUrl == null ||
            pageUrl.host != expectedUrl.host ||
            pageUrl.path.replaceAll(RegExp(r'/$'), '') !=
                expectedUrl.path.replaceAll(RegExp(r'/$'), '')) {
          continue;
        }
        final scale = provider == '烂番茄' ? 100.0 : 10.0;
        if (provider == '烂番茄' && rating['name'] != 'Tomatometer') continue;
        final best = double.tryParse(rating['bestRating']?.toString() ?? '');
        if (best != scale) continue;
        final value = double.tryParse(rating['ratingValue']?.toString() ?? '');
        if (value == null || !value.isFinite || value < 0 || value > scale) {
          continue;
        }
        return CinemaRating(
          provider: provider,
          value: value,
          scale: scale,
          count: int.tryParse(
            (rating['ratingCount'] ?? rating['reviewCount'])?.toString() ?? '',
          ),
          url: url,
          verified: true,
          fetchedAt: DateTime.now(),
          note: provider == '烂番茄' ? '官网 Tomatometer · 影评人新鲜度' : '豆瓣官网公开条目',
        );
      }
    }
    throw FormatException(provider == '豆瓣' ? '官网未返回评分，可能需要验证' : '官网未返回影评人评分');
  }

  Future<Map<String, dynamic>> _json(Uri uri) async =>
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(await _fetch(uri, 2 * 1024 * 1024))),
      );
  static bool _fresh(Map data, Duration ttl, {String field = 'at'}) {
    final date = DateTime.tryParse(data[field]?.toString() ?? '');
    if (date == null) return false;
    final age = DateTime.now().difference(date);
    return !age.isNegative && age < ttl;
  }

  static String _readable(Object error) {
    if (error is FormatException) return error.message;
    if (error is TimeoutException) return '请求超时，可稍后刷新';
    if (error is HandshakeException) return '安全连接失败，可稍后刷新';
    if (error is HttpException) return error.message;
    return '暂时无法获取，可稍后刷新或手动关联';
  }

  static Future<List<int>> _networkFetch(Uri uri, int maxBytes) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    client.findProxy = Platform.isMacOS
        ? MacOSSystemProxy.findProxy
        : HttpClient.findProxyFromEnvironment;
    Future<List<int>> request() async {
      final req = await client.getUrl(uri);
      req.headers.set(
        'User-Agent',
        'NAKUPlayer/1.0.0 (https://github.com/NakuTop/NAKU-Player)',
      );
      req.headers.set('Accept', 'application/json,text/html,*/*');
      final response = await req.close();
      if (response.statusCode != 200) {
        throw HttpException(
          response.statusCode == 429
              ? '服务限流，请稍后刷新'
              : '服务暂不可用 (HTTP ${response.statusCode})',
        );
      }
      if (response.contentLength > maxBytes) {
        throw const FormatException('评分响应超过大小限制');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const FormatException('评分响应超过大小限制');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    }

    try {
      return await request().timeout(const Duration(seconds: 40));
    } finally {
      client.close(force: true);
    }
  }
}
