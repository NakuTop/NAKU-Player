import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:html/parser.dart' as html;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

import 'cinema_models.dart';
import 'cinema_media_identity.dart';
import 'cinema_rating_identity_search.dart';
import 'cinema_rating_lookup.dart';
import 'cinema_douban_access.dart';
import 'cinema_douban_details.dart';
export 'cinema_douban_details.dart';

class RatingIdentity {
  const RatingIdentity({
    this.doubanId = '',
    this.imdbId = '',
    this.rottenTomatoesId = '',
    this.label = '',
    this.wikidataId = '',
    this.confirmed = false,
    this.imdbIsSeries = false,
  });
  final String doubanId, imdbId, rottenTomatoesId, label, wikidataId;
  final bool confirmed, imdbIsSeries;
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
    'imdbIsSeries': imdbIsSeries,
  };
  factory RatingIdentity.fromJson(Map<String, dynamic> json) => RatingIdentity(
    doubanId: json['doubanId'] as String? ?? '',
    imdbId: json['imdbId'] as String? ?? '',
    rottenTomatoesId: json['rottenTomatoesId'] as String? ?? '',
    label: json['label'] as String? ?? '',
    wikidataId: json['wikidataId'] as String? ?? '',
    confirmed: json['confirmed'] == true,
    imdbIsSeries: json['imdbIsSeries'] == true,
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
    this.scope = '',
  });
  final String provider, url, note, scope;
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
    'scope': scope,
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
    scope: json['scope'] as String? ?? '',
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
typedef RatingsCacheWriter =
    Future<void> Function(String path, Map<String, dynamic> snapshot);

class _RatingsSaveWaiter {
  _RatingsSaveWaiter(this.revision);
  final int revision;
  final completion = Completer<void>();
}

// Keep JSON encoding and filesystem work off the UI isolate. This top-level
// entry captures only the serializable snapshot, never repository futures.
Future<void> _writeRatingsCacheInBackground(
  String path,
  Map<String, dynamic> snapshot,
) => Isolate.run(() async {
  final encoded = jsonEncode(snapshot);
  final file = File(path);
  await file.parent.create(recursive: true);
  final temp = File('$path.tmp');
  await temp.writeAsString(encoded, flush: true);
  await temp.rename(path);
});

// Copying megabytes of unchanged claims into an isolate also pauses the UI.
// Reconstruct unchanged entries from disk and send only the compact delta.
Future<bool> _writeRatingsCachePatchInBackground(
  String path,
  Map<String, dynamic> changed,
  Map<String, List<String>> retainedKeys,
) => Isolate.run(() async {
  final file = File(path);
  final data = await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : <String, dynamic>{'version': 1};
  if (data['version'] != 1) throw const FormatException('评分文件格式无效');
  for (final section in retainedKeys.keys) {
    final values = Map<String, dynamic>.from(data[section] as Map? ?? {});
    final updates = changed[section] as Map<String, dynamic>;
    final retained = retainedKeys[section]!.toSet();
    // If the base file was removed externally, request a full snapshot instead
    // of silently dropping unchanged entries still held in memory.
    if (retained.any(
      (key) => !values.containsKey(key) && !updates.containsKey(key),
    )) {
      return false;
    }
    values.removeWhere((key, _) => !retained.contains(key));
    values.addAll(updates);
    data[section] = values;
  }
  final encoded = jsonEncode(data);
  await file.parent.create(recursive: true);
  final temp = File('$path.tmp');
  await temp.writeAsString(encoded, flush: true);
  await temp.rename(path);
  return true;
});

// Top-level isolate entry wrappers avoid capturing repository futures/clients.
Future<(double, int)?> _readImdbInBackground(String path, String id) =>
    Isolate.run(() => CinemaRatingsRepository.readImdbRating(path, id));
Future<void> _validateImdbInBackground(List<int> bytes) => Isolate.run(() {
  final data = utf8.decode(gzip.decode(bytes));
  if (!data.startsWith('tconst\taverageRating\tnumVotes\n')) {
    throw const FormatException('IMDb 数据集格式变化');
  }
});

final _htmlParsingWork = _RatingsWorkPool(2);

Future<CinemaRating> _parseRatingOffscreen(
  String provider,
  String url,
  String body,
) => _htmlParsingWork.run(
  () => Isolate.run(
    () => CinemaRatingsRepository.parseRatingPage(provider, url, body),
  ),
);

Future<(bool, CinemaRating?)> _verifyRtOffscreen(
  String id,
  String body,
  String year,
  String kind,
) => _htmlParsingWork.run(
  () => Isolate.run(() {
    if (!cinemaRtPageMatches(id, body, year: year, kind: kind)) {
      return (false, null);
    }
    try {
      return (
        true,
        CinemaRatingsRepository.parseRatingPage(
          '烂番茄',
          'https://www.rottentomatoes.com/$id',
          body,
        ),
      );
    } catch (_) {
      return (true, null);
    }
  }),
);

Future<Map<String, String>> _searchRtOffscreen(
  String body,
  Set<String> names,
  String year,
  String kind,
  String season,
) => _htmlParsingWork.run(
  () => Isolate.run(
    () => cinemaRtSearchCandidates(
      body,
      names: names,
      year: year,
      kind: kind,
      season: season,
    ),
  ),
);

/// On-demand, exact-ID lookups. Ratings never affect catalogue/playback success.
class CinemaRatingsRepository {
  CinemaRatingsRepository({
    Directory? directory,
    RatingsFetch? fetch,
    RatingsCacheWriter? cacheWriter,
  }) : _directory = directory,
       _rawFetch = fetch ?? fetchOfficial,
       _cacheWriter = cacheWriter;
  static final instance = CinemaRatingsRepository();
  Directory? _directory;
  final RatingsFetch _rawFetch;
  final RatingsCacheWriter? _cacheWriter;
  final _networkWork = _RatingsWorkPool(3);
  final _secondaryNetworkWork = _RatingsWorkPool(2);
  final _primaryWork = _RatingsWorkPool(3);
  final _identityWork = _RatingsWorkPool(2);
  final _imdbWork = _RatingsWorkPool(1);
  final _changes = _RatingsChanges();
  Listenable get changes => _changes;
  int get bindingRevision => _bindingRevision;
  static bool _isSubjectApi(Uri uri) =>
      uri.host == 'm.douban.com' &&
      RegExp(r'^/rexxar/api/v2/(?:movie|tv)/[0-9]+/?$').hasMatch(uri.path);
  Future<List<int>> _fetch(Uri uri, int maxBytes) {
    Future<List<int>> run() => _networkWork.run(() async {
      if (_isSubjectApi(uri) && !CinemaDoubanAccess.canRequestSubject()) {
        throw const HttpException('豆瓣资料接口暂时限流，稍后自动重试；可在官网查看');
      }
      try {
        return await _rawFetch(uri, maxBytes);
      } catch (error) {
        // A transient provider connection must not leave an otherwise exact
        // match empty until the user refreshes. One retry stays inside the
        // existing queue; challenges, rate limits and missing scores never loop.
        final provider = const {
          'm.douban.com',
          'movie.douban.com',
          'www.imdb.com',
          'v3.sg.media-imdb.com',
          'www.rottentomatoes.com',
          'www.wikidata.org',
        }.contains(uri.host);
        final transient =
            error is TimeoutException ||
            error is SocketException ||
            error is HandshakeException ||
            error is HttpException &&
                RegExp(r'HTTP (500|502|503|504)\)').hasMatch(error.message);
        if (!provider || !transient) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (_isSubjectApi(uri) && !CinemaDoubanAccess.canRequestSubject()) {
          rethrow;
        }
        return _rawFetch(uri, maxBytes);
      }
    });
    // Reserve capacity for primary Douban requests. Two slow RT/crosswalk
    // connections cannot occupy all three HTTP slots; the one coalesced IMDb
    // dataset download can also use the reserved slot. Cached IMDb reads never
    // enter either HTTP queue.
    return [
          'm.douban.com',
          'movie.douban.com',
          'datasets.imdbws.com',
        ].contains(uri.host)
        ? run()
        : _secondaryNetworkWork.run(run);
  }

  Map<String, dynamic> _bindings = {}, _cache = {}, _mappings = {};
  Map<String, dynamic> _details = {};
  final _subjectMemory = <String, DoubanSubjectDetails>{};
  final _subjectKinds = <String, String>{};
  final _subjectDiskEntries = <String, dynamic>{};
  final _mobileSubjectPending = <String, Future<DoubanSubjectDetails>>{};
  final _subjectPending = <String, Future<DoubanSubjectDetails>>{};
  final _detailsPending = <String, Future<DoubanSubjectDetails>>{};
  Future<void>? _loading, _dataset;
  DateTime? _datasetFailedAt;
  String _datasetFailure = '';
  Future<void>? _writes;
  final _saveWaiters = <_RatingsSaveWaiter>[];
  int _cacheRevision = 0, _savedCacheRevision = 0;
  Map<String, dynamic> _savedSnapshot = {};
  final Map<String, Future<CinemaRatings>> _pending = {};
  int _bindingRevision = 0;
  final Map<String, CinemaRatings> _memory = {};
  final _profiles = <String, CinemaTitle>{};
  final _profileKeys = <String, Set<String>>{};
  final _providerCompleted = <String, Set<String>>{};
  final _cardPending = <String, Future<CinemaRatings>>{};
  final _cardCompleted = <String, DateTime>{};
  final _cardConsumers = <String, List<bool Function()>>{};
  final _providerPending = <String, Future<CinemaRating>>{};
  final _resolutionPending = <String, Future<RatingIdentity>>{};
  final _completionPending = <String, Future<RatingIdentity>>{};
  final _completionObservers = <String, List<void Function(RatingIdentity)>>{};
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
      if (data['doubanSubjects'] is Map) {
        for (final entry in (data['doubanSubjects'] as Map).entries) {
          try {
            final item = Map<String, dynamic>.from(entry.value);
            final subject = DoubanSubjectDetails.fromJson(
              Map<String, dynamic>.from(item['data']),
            );
            if (subject.doubanId == entry.key) {
              _rememberSubject(
                subject,
                kind: item['kind']?.toString() ?? '',
                restored: true,
              );
            }
          } catch (_) {
            /* Invalid optional metadata does not invalidate bindings. */
          }
        }
      }
      if (data['doubanDetails'] is Map) {
        _details = Map<String, dynamic>.from(data['doubanDetails']);
        while (_details.length > 64) {
          _details.remove(_details.keys.first);
        }
      }
      _savedSnapshot = _cacheSnapshot();
    } catch (_) {
      // Keep a malformed file intact; never silently replace user bindings.
      _storageWarning = '评分设置文件无法读取，已保留原文件；本次结果不保存';
    }
  }

  void _cacheChanged() => _cacheRevision++;

  Map<String, dynamic> _cacheSnapshot() => {
    'version': 1,
    // Entries are immutable after insertion. Copy the outer maps so a later
    // response cannot mutate an already queued snapshot.
    'bindings': Map<String, dynamic>.from(_bindings),
    'cache': Map<String, dynamic>.from(_cache),
    'mappings': Map<String, dynamic>.from(_mappings),
    'doubanDetails': Map<String, dynamic>.from(_details),
    'doubanSubjects': Map<String, dynamic>.from(_subjectDiskEntries),
  };

  Future<void> _save() {
    if (_storageWarning != null) return Future.value();
    if (_savedCacheRevision == _cacheRevision) return Future.value();
    final waiter = _RatingsSaveWaiter(_cacheRevision);
    _saveWaiters.add(waiter);
    _startCacheWrites();
    return waiter.completion.future;
  }

  void _startCacheWrites() {
    if (_writes != null) return;
    late final Future<void> operation;
    operation = _drainCacheWrites()
        .catchError((Object error, StackTrace stack) {
          final failed = List<_RatingsSaveWaiter>.of(_saveWaiters);
          _saveWaiters.clear();
          for (final waiter in failed) {
            waiter.completion.completeError(error, stack);
          }
        })
        .whenComplete(() {
          if (identical(_writes, operation)) {
            _writes = null;
            if (_saveWaiters.isNotEmpty) _startCacheWrites();
          }
        });
    _writes = operation;
  }

  Future<void> _drainCacheWrites() async {
    final directory = await _dir;
    // Concurrent card/provider completions share one writer. A response that
    // arrives during a write is included in the next latest-state snapshot;
    // Each caller waits only for its requested revision. A later write failure
    // must not roll back an earlier identity correction already saved to disk.
    while (_saveWaiters.isNotEmpty) {
      // Briefly combine provider/card completions while preserving the contract
      // that awaited loads and manual corrections have finished persistence.
      await Future<void>.delayed(const Duration(milliseconds: 75));
      final revision = _cacheRevision;
      final snapshot = _cacheSnapshot();
      final path = '${directory.path}/ratings-v1.json';
      final writer = _cacheWriter;
      if (writer != null) {
        await writer(path, snapshot);
      } else {
        final changed = <String, dynamic>{};
        final retained = <String, List<String>>{};
        for (final section in snapshot.keys.where((key) => key != 'version')) {
          final values = snapshot[section] as Map<String, dynamic>;
          final previous = _savedSnapshot[section] as Map? ?? const {};
          changed[section] = <String, dynamic>{
            for (final entry in values.entries)
              if (!identical(previous[entry.key], entry.value))
                entry.key: entry.value,
          };
          retained[section] = values.keys.toList();
        }
        if (!await _writeRatingsCachePatchInBackground(
          path,
          changed,
          retained,
        )) {
          await _writeRatingsCacheInBackground(path, snapshot);
        }
      }
      _savedSnapshot = snapshot;
      _savedCacheRevision = revision;
      final finished = _saveWaiters
          .where((waiter) => waiter.revision <= revision)
          .toList();
      _saveWaiters.removeWhere((waiter) => waiter.revision <= revision);
      for (final waiter in finished) {
        waiter.completion.complete();
      }
    }
  }

  Future<void> setIdentity(CinemaTitle title, RatingIdentity identity) async {
    identity.validate();
    await _ready();
    if (_storageWarning != null) throw StateError(_storageWarning!);
    final previous = _bindings[title.key];
    _bindings[title.key] = identity.toJson();
    _cacheChanged();
    _bindingRevision++;
    _memory.clear();
    _profiles.clear();
    _profileKeys.clear();
    _providerCompleted.clear();
    _cardCompleted.clear();
    try {
      await _save();
    } catch (_) {
      if (previous == null) {
        _bindings.remove(title.key);
      } else {
        _bindings[title.key] = previous;
      }
      _cacheChanged();
      _bindingRevision++;
      _memory.clear();
      _profiles.clear();
      _profileKeys.clear();
      _providerCompleted.clear();
      _cardCompleted.clear();
      _changes.changed();
      rethrow;
    }
    _changes.changed();
  }

  Future<CinemaRatings> load(CinemaTitle title, {bool force = false}) {
    final revision = _bindingRevision;
    final key = jsonEncode([
      title.key,
      force,
      _bindingRevision,
      title.title,
      title.year,
      title.category,
      title.aliases,
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
              _publish(title, result);
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
    title.category,
    title.aliases,
    title.doubanId,
    title.imdbId,
    title.rottenTomatoesId,
    title.sourceDoubanScore,
    _bindingRevision,
  ]);
  CinemaRatings? peek(CinemaTitle title) {
    final stored = _memory[_memoryKey(title)] ?? _compatibleMemory(title);
    if (stored == null) return null;
    // A detail refresh and cards for other sources of the same work share the
    // exact provider cache, even when this card's original title lacked IDs.
    final ratings = [
      for (final rating in stored.ratings)
        _newerProviderRating(stored.identity, rating),
    ];
    if (List.generate(
      ratings.length,
      (i) => identical(ratings[i], stored.ratings[i]),
    ).every((same) => same)) {
      return stored;
    }
    return CinemaRatings(
      identity: stored.identity,
      ratings: ratings,
      message: stored.message,
    );
  }

  CinemaRating _newerProviderRating(RatingIdentity identity, CinemaRating old) {
    final id = switch (old.provider) {
      '豆瓣' => identity.doubanId,
      'IMDb' => identity.imdbId,
      _ => identity.rottenTomatoesId,
    };
    try {
      final raw = _cache['${old.provider}:$id'];
      if (raw is Map) {
        final candidate = CinemaRating.fromJson(Map<String, dynamic>.from(raw));
        if (candidate.verified &&
            candidate.value != null &&
            (!old.verified ||
                old.value == null ||
                old.fetchedAt == null ||
                (candidate.fetchedAt?.isAfter(old.fetchedAt!) ?? false))) {
          return _scopedRating(identity, candidate);
        }
      }
    } catch (_) {
      /* Keep the valid in-memory value. */
    }
    return old;
  }

  /// Raw provider scale (Douban/IMDb: 10; Tomatometer: 100), never a blended
  /// score. Unknown values stay null so callers can place them last when sorting.
  double? scoreFor(CinemaTitle title, String provider) {
    final result = peek(title);
    final rating = result?.ratings
        .where((r) => r.provider == provider)
        .firstOrNull;
    final scale = provider == '烂番茄' ? 100.0 : 10.0;
    final value = rating?.value;
    if (value != null &&
        value.isFinite &&
        value >= 0 &&
        value <= scale &&
        rating?.scale == scale) {
      return value;
    }
    // An explicit corrected identity with no score must not inherit the old
    // source's rating. Only use the source fallback before a lookup exists.
    if (result == null && provider == '豆瓣') {
      final source = title.sourceDoubanScore;
      if (source != null && source.isFinite && source > 0 && source <= 10) {
        return source;
      }
    }
    return null;
  }

  static bool _compatibleProfiles(CinemaTitle a, CinemaTitle b) {
    if (a.key != b.key || a.year.trim() != b.year.trim()) return false;
    if (CinemaRatingIdentitySearch.seasonForLabel(a.title) !=
        CinemaRatingIdentitySearch.seasonForLabel(b.title)) {
      return false;
    }
    String kind(String category) =>
        RegExp(r'连续剧|連續劇|电视剧|電視劇|剧集|劇集|剧$|劇$').hasMatch(category)
        ? 'tv'
        : RegExp(r'电影|電影|片$').hasMatch(category)
        ? 'movie'
        : category;
    if (kind(a.category) != kind(b.category)) return false;
    String normalized(String value) => cinemaMediaBaseTitle(
      value,
    ).toLowerCase().replaceAll(RegExp(r'[\s\p{P}]', unicode: true), '');
    final aNames = [
      a.title,
      ...a.aliases.split(RegExp(r'[/／|,，;；\n]')),
    ].where((v) => v.trim().isNotEmpty).map(normalized).toSet();
    final bNames = [
      b.title,
      ...b.aliases.split(RegExp(r'[/／|,，;；\n]')),
    ].where((v) => v.trim().isNotEmpty).map(normalized).toSet();
    if (aNames.intersection(bNames).isEmpty) return false;
    return !_conflictingIdentity(
      RatingIdentity(
        doubanId: a.doubanId,
        imdbId: a.imdbId,
        rottenTomatoesId: a.rottenTomatoesId,
      ),
      RatingIdentity(
        doubanId: b.doubanId,
        imdbId: b.imdbId,
        rottenTomatoesId: b.rottenTomatoesId,
      ),
    );
  }

  static bool _conflictingIdentity(RatingIdentity a, RatingIdentity b) => [
    (a.doubanId, b.doubanId),
    (a.imdbId, b.imdbId),
    (a.rottenTomatoesId, b.rottenTomatoesId),
  ].any((ids) => ids.$1.isNotEmpty && ids.$2.isNotEmpty && ids.$1 != ids.$2);

  CinemaRatings? _compatibleMemory(CinemaTitle title) {
    for (final key
        in (_profileKeys[title.key] ?? const <String>{}).toList().reversed) {
      final profile = _profiles[key];
      if (profile != null && _compatibleProfiles(title, profile)) {
        final result = _memory[key];
        final explicit = RatingIdentity(
          doubanId: title.doubanId,
          imdbId: title.imdbId,
          rottenTomatoesId: title.rottenTomatoesId,
        );
        if (result != null &&
            !_conflictingIdentity(explicit, result.identity)) {
          return result;
        }
      }
    }
    return null;
  }

  static RatingIdentity _mergeIdentity(
    RatingIdentity fresh,
    RatingIdentity old,
  ) => RatingIdentity(
    doubanId: fresh.doubanId.isEmpty ? old.doubanId : fresh.doubanId,
    imdbId: fresh.imdbId.isEmpty ? old.imdbId : fresh.imdbId,
    rottenTomatoesId: fresh.rottenTomatoesId.isEmpty
        ? old.rottenTomatoesId
        : fresh.rottenTomatoesId,
    label: fresh.label.isEmpty ? old.label : fresh.label,
    wikidataId: fresh.wikidataId.isEmpty ? old.wikidataId : fresh.wikidataId,
    confirmed: fresh.confirmed,
    imdbIsSeries: fresh.imdbId.isEmpty ? old.imdbIsSeries : fresh.imdbIsSeries,
  );

  RatingIdentity _identityFor(CinemaTitle title) {
    if (_bindings[title.key] is Map) {
      return RatingIdentity.fromJson(
        Map<String, dynamic>.from(_bindings[title.key]),
      );
    }
    final explicit = RatingIdentity(
      doubanId: title.doubanId,
      imdbId: title.imdbId,
      rottenTomatoesId: title.rottenTomatoesId,
    );
    final previous = _compatibleMemory(title);
    return previous == null
        ? explicit
        : _mergeIdentity(explicit, previous.identity);
  }

  void _rememberProfile(String key, CinemaTitle title) {
    _profiles.remove(key);
    _profiles[key] = title;
    final keys = _profileKeys.putIfAbsent(title.key, () => {});
    keys.remove(key);
    keys.add(key);
    void evict(String oldest) {
      final previous = _profiles.remove(oldest);
      if (previous != null) {
        final bucket = _profileKeys[previous.key];
        bucket?.remove(oldest);
        if (bucket?.isEmpty == true) _profileKeys.remove(previous.key);
      }
      _memory.remove(oldest);
      _providerCompleted.remove(oldest);
      _cardCompleted.remove(oldest);
    }

    while (keys.length > 8) {
      evict(keys.first);
    }
    while (_profiles.length > 512) {
      evict(_profiles.keys.first);
    }
  }

  void _publish(
    CinemaTitle title,
    CinemaRatings result, {
    Set<String> completed = const {},
  }) {
    final key = _memoryKey(title);
    _rememberProfile(key, title);
    final old = _memory[key] ?? _compatibleMemory(title);
    if (old != null && !_conflictingIdentity(old.identity, result.identity)) {
      final identity = _mergeIdentity(result.identity, old.identity);
      result = CinemaRatings(
        identity: identity,
        message: result.message,
        ratings: [
          for (final rating in result.ratings)
            _newerProviderRating(identity, rating),
        ],
      );
    }
    _memory[key] = result;
    _providerCompleted.putIfAbsent(key, () => {}).addAll(completed);
    // Only profiles of this exact source item, with compatible title/year/kind
    // and no conflicting explicit IDs, may learn IDs discovered by its detail.
    for (final profileKey in _profileKeys[title.key] ?? const <String>{}) {
      final profile = _profiles[profileKey]!;
      if (profileKey == key || !_compatibleProfiles(title, profile)) {
        continue;
      }
      final explicit = RatingIdentity(
        doubanId: profile.doubanId,
        imdbId: profile.imdbId,
        rottenTomatoesId: profile.rottenTomatoesId,
      );
      if (_conflictingIdentity(explicit, result.identity)) continue;
      _memory[profileKey] = result;
      _providerCompleted.putIfAbsent(profileKey, () => {}).addAll(completed);
    }
    _changes.changed();
  }

  /// Sorting can advance once its chosen provider has been attempted. Slower
  /// unrelated providers continue to enrich cards through [changes]. Calling
  /// the virtual card method also keeps injected/offline repositories isolated.
  Future<CinemaRatings> loadForProvider(
    CinemaTitle title,
    String provider, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) {
    if (!['豆瓣', 'IMDb', '烂番茄'].contains(provider)) {
      return Future.error(ArgumentError.value(provider, 'provider'));
    }
    final key = _memoryKey(title);
    final completion = Completer<CinemaRatings>();
    void changed() {
      final cached = peek(title);
      if (!completion.isCompleted &&
          cached != null &&
          (_providerCompleted[key]?.contains(provider) ?? false)) {
        completion.complete(cached);
      }
    }

    changes.addListener(changed);
    Future.sync(
      () =>
          loadForCard(title, isCurrent: isCurrent, resolveTitle: resolveTitle),
    ).then(
      (result) {
        if (!completion.isCompleted) completion.complete(result);
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    changed();
    return completion.future.whenComplete(
      () => changes.removeListener(changed),
    );
  }

  /// Visible posters publish their fast Douban result before bounded background
  /// identity/IMDb/Tomatometer work. Full detail navigation is never required.
  /// A resolver may hydrate an ID-less catalogue item from its source detail.
  Future<CinemaRatings> loadForCard(
    CinemaTitle title, {
    bool Function()? isCurrent,
    Future<CinemaTitle> Function(CinemaTitle)? resolveTitle,
  }) {
    final key = _memoryKey(title);
    final completed = _cardCompleted[key];
    final memory = peek(title);
    if (completed != null &&
        memory != null &&
        DateTime.now().difference(completed) <
            (memory.ratings.any((r) => r.value == null) ||
                    memory.identity.doubanId.isEmpty &&
                        !memory.identity.confirmed &&
                        resolveTitle != null
                ? const Duration(seconds: 30)
                : const Duration(minutes: 30))) {
      return Future.value(memory);
    }
    _cardConsumers.putIfAbsent(key, () => []).add(isCurrent ?? () => true);
    return _cardPending.putIfAbsent(key, () {
      bool current() => _cardConsumers[key]?.any((check) => check()) ?? false;
      Future<CinemaRatings> run() async {
        while (true) {
          final revision = _bindingRevision;
          if (!current()) throw StateError('Card no longer displayed');
          await _ready();
          var effective = title;
          final needsHydration =
              _bindings[title.key] is! Map &&
              title.doubanId.isEmpty &&
              resolveTitle != null;
          final knownSecondary = <String>{
            if (title.imdbId.isNotEmpty) 'IMDb',
            if (title.rottenTomatoesId.isNotEmpty) '烂番茄',
          };
          Future<void>? early;
          if (needsHydration && knownSecondary.isNotEmpty) {
            // A missing Douban ID must not delay existing IMDb/RT IDs behind
            // source discovery. Only those attempted IDs become sort-ready;
            // the not-yet-resolved Douban provider remains pending.
            early =
                Future<void>.sync(() async {
                  if (!current()) return;
                  await _load(
                    title,
                    false,
                    cardOnly: true,
                    onProgress: (result, completed) {
                      if (revision == _bindingRevision) {
                        _publish(
                          title,
                          result,
                          completed: completed.intersection(knownSecondary),
                        );
                      }
                    },
                  );
                }).then<void>(
                  (_) {},
                  onError: (Object error, StackTrace stack) {
                    // The final enriched stage still gets an independent attempt.
                  },
                );
          }
          // Source/discovery resolvers have their own bounded queues. Do not
          // occupy the fast provider queue while one missing ID searches them.
          if (needsHydration) {
            try {
              effective = await resolveTitle(title);
            } catch (_) {
              // Source detail failure must not prevent local/source scores.
            }
          }
          if (!current()) throw StateError('Card no longer displayed');
          final quick = _primaryWork.run(() async {
            if (!current()) throw StateError('Card no longer displayed');
            final result = await _loadCard(effective);
            if (revision == _bindingRevision) {
              _publish(title, result, completed: {'豆瓣'});
            }
            return result;
          });
          final full = Future<CinemaRatings>.sync(() async {
            if (!current()) throw StateError('Card no longer displayed');
            return _load(
              effective,
              false,
              cardOnly: true,
              onProgress: (result, completed) {
                if (revision == _bindingRevision) {
                  _publish(title, result, completed: completed);
                }
              },
            );
          });
          // Both futures are observed even if a card is removed while queued.
          final result = (await Future.wait([quick, full])).last;
          if (early != null) await early;
          // A manual correction can arrive during an old network response.
          if (revision != _bindingRevision) continue;
          _publish(title, result, completed: {'豆瓣', 'IMDb', '烂番茄'});
          _cardCompleted[_memoryKey(title)] = DateTime.now();
          return peek(title) ?? result;
        }
      }

      return run().whenComplete(() {
        _cardPending.remove(key);
        _cardConsumers.remove(key);
      });
    });
  }

  Future<CinemaRatings> _loadCard(CinemaTitle title) async {
    await _ready();
    var identity = _identityFor(title);
    identity.validate();
    // Fast first paint reuses existing crosswalks; background card enrichment
    // resolves missing exact identities separately.
    final mapped = _mappings[identity.doubanId];
    if (mapped is Map && mapped['entity'] is Map && mapped['qid'] is String) {
      try {
        identity = identityFromEntity(
          title,
          identity,
          mapped['qid'],
          Map<String, dynamic>.from(mapped['entity']),
          verifiedSubject: _verifiedSubject(identity.doubanId),
          verifiedSubjectKind: _subjectKinds[identity.doubanId] ?? '',
        );
      } catch (_) {
        /* Keep explicit IDs when a cached crosswalk is ambiguous. */
      }
    }
    var douban = await _rating('豆瓣', identity.doubanId, false, cardOnly: true);
    if (douban.value == null &&
        title.sourceDoubanScore != null &&
        identity.doubanId == title.doubanId) {
      douban = CinemaRating(
        provider: '豆瓣',
        value: title.sourceDoubanScore,
        url: douban.url,
        note: '片源转述 · 未核验；${douban.note}',
      );
    }
    CinemaRating secondary(String provider, String id) {
      final cached = _cache['$provider:$id'];
      try {
        if (cached is Map) {
          return CinemaRating.fromJson(Map<String, dynamic>.from(cached));
        }
      } catch (_) {
        /* A malformed cache remains an explicit missing value. */
      }
      return CinemaRating(
        provider: provider,
        scale: provider == 'IMDb' ? 10 : 100,
        note: id.isEmpty ? '尚未关联确切条目' : '正在后台读取官网评分',
      );
    }

    final result = CinemaRatings(
      identity: identity,
      ratings: [
        douban,
        _scopedRating(identity, secondary('IMDb', identity.imdbId)),
        _scopedRating(identity, secondary('烂番茄', identity.rottenTomatoesId)),
      ],
      message: '已显示可用评分，其他平台在后台补充',
    );
    try {
      await _save();
    } catch (_) {
      /* Live values remain useful without disk cache. */
    }
    return result;
  }

  /// Detail first paint bypasses the poster queue and all secondary providers.
  Future<CinemaRatings> loadQuickRatings(CinemaTitle title) async {
    final revision = _bindingRevision;
    final result = await _loadCard(title);
    if (revision == _bindingRevision) _publish(title, result);
    return result;
  }

  Future<CinemaRatings> _load(
    CinemaTitle title,
    bool force, {
    void Function(CinemaRatings result, Set<String> completed)? onProgress,
    bool cardOnly = false,
  }) async {
    await _ready();
    var identity = _identityFor(title);
    identity.validate();
    var message = identity.confirmed ? '使用你确认的条目 ID' : '条目 ID 由片源提供';
    final results = <String, CinemaRating>{};
    final pending = <String, Future<void>>{};
    CinemaRatings snapshot() => CinemaRatings(
      identity: identity,
      message: message,
      ratings: [
        for (final provider in ['豆瓣', 'IMDb', '烂番茄'])
          _scopedRating(
            identity,
            results[provider] ??
                CinemaRating(
                  provider: provider,
                  scale: provider == '烂番茄' ? 100 : 10,
                  note: '正在后台读取官网评分',
                ),
          ),
      ],
    );
    Future<void> start(String provider, String id) =>
        pending.putIfAbsent(provider, () async {
          var rating = await _rating(
            provider,
            id,
            force,
            cardOnly: cardOnly && provider == '豆瓣',
          );
          if (provider == '豆瓣' &&
              rating.value == null &&
              title.sourceDoubanScore != null &&
              identity.doubanId == title.doubanId) {
            rating = CinemaRating(
              provider: '豆瓣',
              value: title.sourceDoubanScore,
              url: rating.url,
              note: '片源转述 · 未核验；${rating.note}',
            );
          }
          results[provider] = rating;
          onProgress?.call(snapshot(), results.keys.toSet());
        });
    // Already-known provider IDs run immediately; an unrelated missing ID must
    // never hold their scores behind the Wikidata timeout or another provider.
    if (identity.doubanId.isNotEmpty) start('豆瓣', identity.doubanId);
    if (identity.imdbId.isNotEmpty) start('IMDb', identity.imdbId);
    if (identity.rottenTomatoesId.isNotEmpty) {
      start('烂番茄', identity.rottenTomatoesId);
    }
    if ((identity.doubanId.isNotEmpty ||
            RegExp(r'^\d{4}$').hasMatch(title.year.trim()) &&
                (identity.imdbId.isNotEmpty ||
                    identity.rottenTomatoesId.isNotEmpty)) &&
        (identity.doubanId.isEmpty ||
            identity.imdbId.isEmpty ||
            identity.rottenTomatoesId.isEmpty)) {
      try {
        identity = await _identityWork.run(
          () => _completeIdentity(
            title,
            identity,
            force,
            onIdentity: (updated) {
              identity = updated;
              if (identity.doubanId.isNotEmpty) start('豆瓣', identity.doubanId);
              if (identity.imdbId.isNotEmpty) start('IMDb', identity.imdbId);
              if (identity.rottenTomatoesId.isNotEmpty) {
                start('烂番茄', identity.rottenTomatoesId);
              }
            },
          ),
        );
        if (identity.wikidataId.isNotEmpty) {
          message = '跨站条目已核对 · 片名、年份及电影／剧集类型一致';
          if (identity.confirmed) message = '按你确认的豆瓣 ID 关联 Wikidata';
        } else if (identity.imdbId.isNotEmpty ||
            identity.rottenTomatoesId.isNotEmpty) {
          message = '通过官网检索补充条目 · 片名、年份及电影／剧集类型已核对';
        }
      } catch (error) {
        message = _readable(error);
      }
    }
    start('豆瓣', identity.doubanId);
    start('IMDb', identity.imdbId);
    start('烂番茄', identity.rottenTomatoesId);
    await Future.wait(pending.values);
    try {
      await _save();
    } catch (_) {
      message += ' · 评分缓存保存失败';
    }
    if (_storageWarning != null) message += ' · $_storageWarning';
    return snapshot();
  }

  CinemaRating _scopedRating(RatingIdentity identity, CinemaRating rating) {
    final subjectSeason = rating.provider == '豆瓣'
        ? CinemaRatingIdentitySearch.seasonForLabel(
            _verifiedSubject(identity.doubanId)?.title ?? '',
          )
        : '';
    final season = RegExp(
      r'/s([0-9]+)$',
    ).firstMatch(identity.rottenTomatoesId)?.group(1);
    final scope = rating.provider == 'IMDb' && identity.imdbIsSeries
        ? '整剧'
        : rating.provider == '烂番茄' && season != null
        ? '第${int.parse(season)}季'
        : rating.provider == '豆瓣' && subjectSeason.isNotEmpty
        ? '第$subjectSeason季'
        : rating.scope;
    if (scope == rating.scope) return rating;
    return CinemaRating(
      provider: rating.provider,
      value: rating.value,
      scale: rating.scale,
      count: rating.count,
      url: rating.url,
      note: rating.note,
      verified: rating.verified,
      fetchedAt: rating.fetchedAt,
      scope: scope,
    );
  }

  String _mappingKey(RatingIdentity identity) => identity.doubanId.isNotEmpty
      ? identity.doubanId
      : identity.imdbId.isNotEmpty
      ? 'imdb:${identity.imdbId}'
      : 'rt:${identity.rottenTomatoesId}';

  Future<RatingIdentity> _completeIdentity(
    CinemaTitle title,
    RatingIdentity original,
    bool force, {
    void Function(RatingIdentity)? onIdentity,
  }) async {
    final lookupKey =
        'lookup:${jsonEncode([original.toJson(), title.title, title.year, title.category])}';
    final pendingKey = '$lookupKey:$force';
    if (onIdentity != null) {
      _completionObservers.putIfAbsent(pendingKey, () => []).add(onIdentity);
    }
    try {
      return await _completionPending.putIfAbsent(
        pendingKey,
        () =>
            _completeIdentityUncached(
              title,
              original,
              force,
              lookupKey: lookupKey,
              onIdentity: (identity) {
                for (final observer in [...?_completionObservers[pendingKey]]) {
                  observer(identity);
                }
              },
            ).whenComplete(() {
              _completionPending.remove(pendingKey);
            }),
      );
    } finally {
      _completionObservers[pendingKey]?.remove(onIdentity);
      if (_completionObservers[pendingKey]?.isEmpty ?? false) {
        _completionObservers.remove(pendingKey);
      }
    }
  }

  Future<RatingIdentity> _completeIdentityUncached(
    CinemaTitle title,
    RatingIdentity original,
    bool force, {
    required String lookupKey,
    void Function(RatingIdentity)? onIdentity,
  }) async {
    final lookup = _mappings[lookupKey];
    if (!force &&
        lookup is Map &&
        lookup['lookupSchema'] == 1 &&
        _fresh(
          lookup,
          lookup['complete'] == true
              ? const Duration(hours: 24)
              : const Duration(seconds: 30),
        )) {
      try {
        final identity = RatingIdentity.fromJson(
          Map<String, dynamic>.from(lookup['identity']),
        );
        if (!_conflictingIdentity(original, identity)) {
          onIdentity?.call(identity);
          return identity;
        }
      } catch (_) {
        /* Recompute a malformed optional lookup cache. */
      }
    }
    var current = original;
    Object? problem;
    Future<void> accept(RatingIdentity candidate) async {
      if (_conflictingIdentity(current, candidate)) return;
      var updated = _mergeIdentity(candidate, current);
      // A derived RT season path must exist with its own canonical identity and
      // release year before it can replace the empty score slot.
      if (updated.rottenTomatoesId != original.rottenTomatoesId &&
          RegExp(r'/s[0-9]+$').hasMatch(updated.rottenTomatoesId)) {
        // Publish a new IMDb series identity before waiting for RT validation.
        if (updated.imdbId.isNotEmpty && current.imdbId.isEmpty) {
          current = RatingIdentity(
            doubanId: updated.doubanId,
            imdbId: updated.imdbId,
            rottenTomatoesId: current.rottenTomatoesId,
            label: updated.label,
            wikidataId: updated.wikidataId,
            confirmed: updated.confirmed,
            imdbIsSeries: updated.imdbIsSeries,
          );
          onIdentity?.call(current);
        }
        final official = _verifiedSubject(updated.doubanId);
        final year = title.year.trim().isEmpty
            ? official?.year ?? ''
            : title.year.trim();
        if (!await _verifyRtCandidate(updated.rottenTomatoesId, year, 'tv')) {
          updated = RatingIdentity(
            doubanId: updated.doubanId,
            imdbId: updated.imdbId,
            label: updated.label,
            wikidataId: updated.wikidataId,
            confirmed: updated.confirmed,
            imdbIsSeries: updated.imdbIsSeries,
          );
        }
      }
      current = updated;
      onIdentity?.call(current);
    }

    try {
      await accept(await _resolve(title, original, force));
    } catch (error) {
      problem = error;
    }
    if (current.doubanId.isEmpty ||
        current.imdbId.isEmpty ||
        current.rottenTomatoesId.isEmpty) {
      DoubanSubjectDetails? official = _verifiedSubject(current.doubanId);
      if (current.doubanId.isNotEmpty && official == null) {
        try {
          official = await _subject(current.doubanId, force);
        } catch (_) {
          try {
            official = await _mobileSubject(current.doubanId, force);
          } catch (_) {
            /* Keep other providers independent. */
          }
        }
      }
      final kind = _subjectKinds[current.doubanId] ?? '';
      final exactOfficial =
          official != null &&
          official.doubanId == current.doubanId &&
          (title.year.trim().isEmpty || official.year == title.year.trim()) &&
          cinemaOfficialTitleMatches(
            title.title,
            {official.title, official.originalTitle, ...official.aliases},
            kind: kind,
            sourceSeason: CinemaRatingIdentitySearch.seasonForLabel(
              title.title,
            ),
            officialSeason: CinemaRatingIdentitySearch.seasonForLabel(
              official.title,
            ),
            exactId: true,
          );
      final season =
          CinemaRatingIdentitySearch.seasonForLabel(title.title).isNotEmpty
          ? CinemaRatingIdentitySearch.seasonForLabel(title.title)
          : exactOfficial
          ? CinemaRatingIdentitySearch.seasonForLabel(official.originalTitle)
          : '';
      final names = exactOfficial
          ? {official.title, official.originalTitle, ...official.aliases}
                .where((n) => n.trim().isNotEmpty)
                .map((n) => kind == 'tv' ? cinemaRatingSeriesName(n) : n)
                .toSet()
          : <String>{};
      final queries = exactOfficial
          ? [official.originalTitle, official.title]
                .where((n) => n.trim().isNotEmpty)
                .map((n) => kind == 'tv' ? cinemaRatingSeriesName(n) : n)
                .toSet()
                .take(2)
                .toList()
          : <String>[];
      if (exactOfficial &&
          ['movie', 'tv'].contains(kind) &&
          current.wikidataId.isEmpty &&
          (current.imdbId.isEmpty || current.rottenTomatoesId.isEmpty)) {
        try {
          await accept(
            await _officialNameIdentity(
              title,
              current,
              official,
              kind,
              queries,
            ),
          );
        } catch (_) {
          /* Ambiguous or unavailable candidates stay unbound. */
        }
      }
      if (exactOfficial &&
          ['movie', 'tv'].contains(kind) &&
          current.imdbId.isEmpty) {
        var id = official.imdbId;
        // A known later-season year is not the IMDb series premiere year.
        // Without an explicit cross-reference, leave that lookup to the exact
        // Wikidata parent relation rather than searching the wrong year.
        if (id.isEmpty && (season.isEmpty || season == '1')) {
          for (final query in queries) {
            try {
              final data = await _json(
                Uri.https('v3.sg.media-imdb.com', '/suggestion/x/$query.json'),
              );
              id = cinemaImdbSuggestionId(
                data,
                names: names,
                year: official.year,
                kind: kind,
              );
              if (id.isNotEmpty) break;
            } catch (_) {
              /* The second exact official alias is a bounded fallback. */
            }
          }
        }
        if (id.isNotEmpty) {
          await accept(
            RatingIdentity(
              doubanId: current.doubanId,
              imdbId: id,
              rottenTomatoesId: current.rottenTomatoesId,
              label: current.label,
              wikidataId: current.wikidataId,
              confirmed: current.confirmed,
              imdbIsSeries: kind == 'tv',
            ),
          );
        }
      }
      // A season's explicit P179/P361 relation can supply the parent IMDb ID.
      if (season.isNotEmpty && current.imdbId.isEmpty && exactOfficial) {
        try {
          await accept(await _seasonParentIdentity(title, current, official));
        } catch (_) {
          /* Continue independent website lookup. */
        }
      }
      if (current.imdbId.isNotEmpty &&
          (current.rottenTomatoesId.isEmpty || current.doubanId.isEmpty) &&
          !(original.doubanId.isEmpty && original.imdbId.isNotEmpty)) {
        try {
          final qid = await _crosswalkEntityId(
            current.imdbId,
            property: 'P345',
          );
          final entity = await _wikidataEntity(qid);
          await accept(
            identityFromEntity(
              title,
              current,
              qid,
              entity,
              verifiedSubject: official,
              verifiedSubjectKind: kind,
              anchorImdb: true,
            ),
          );
        } catch (_) {
          /* Missing cross-site indexing must not stop official search. */
        }
      }
      if (current.rottenTomatoesId.isEmpty &&
          exactOfficial &&
          ['movie', 'tv'].contains(kind)) {
        final officialYear = official.year;
        for (final query in queries) {
          try {
            final body = utf8.decode(
              await _fetch(
                Uri.https('www.rottentomatoes.com', '/search', {
                  'search': query,
                }),
                3 * 1024 * 1024,
              ),
            );
            final candidates = await _searchRtOffscreen(
              body,
              names,
              official.year,
              kind,
              season,
            );
            if (candidates.isEmpty || candidates.length > 4) continue;
            final verified = await Future.wait(
              candidates.entries.map((candidate) async {
                final id = kind == 'tv' && season.isNotEmpty
                    ? '${candidate.key}/s${season.padLeft(2, '0')}'
                    : candidate.key;
                return await _verifyRtCandidate(id, officialYear, kind)
                    ? (id, candidate)
                    : null;
              }),
            );
            final matches = verified.nonNulls.toList();
            if (matches.length != 1) continue;
            final id = matches.single.$1;
            await accept(
              RatingIdentity(
                doubanId: current.doubanId,
                imdbId: current.imdbId,
                rottenTomatoesId: id,
                label: current.label,
                wikidataId: current.wikidataId,
                confirmed: current.confirmed,
                imdbIsSeries: current.imdbIsSeries,
              ),
            );
            // The verified season and parent premiere resolve same-name TV
            // remakes before using the parent's IMDb series score.
            final parent = matches.single.$2;
            if (kind == 'tv' &&
                season.isNotEmpty &&
                current.imdbId.isEmpty &&
                await _verifyRtCandidate(parent.key, parent.value, 'tv')) {
              for (final parentQuery in queries) {
                try {
                  final suggestion = await _json(
                    Uri.https(
                      'v3.sg.media-imdb.com',
                      '/suggestion/x/$parentQuery.json',
                    ),
                  );
                  final imdb = cinemaImdbSuggestionId(
                    suggestion,
                    names: names,
                    year: parent.value,
                    kind: 'tv',
                  );
                  if (imdb.isEmpty) continue;
                  await accept(
                    RatingIdentity(
                      doubanId: current.doubanId,
                      imdbId: imdb,
                      rottenTomatoesId: current.rottenTomatoesId,
                      label: current.label,
                      wikidataId: current.wikidataId,
                      confirmed: current.confirmed,
                      imdbIsSeries: true,
                    ),
                  );
                  break;
                } catch (_) {
                  /* Preserve the independently verified season. */
                }
              }
            }
            break;
          } catch (_) {
            /* Public website may be temporarily unavailable. */
          }
        }
      }
      if (current.imdbId.isEmpty &&
          exactOfficial &&
          kind == 'tv' &&
          RegExp(
            r'^tv/[a-zA-Z0-9_-]+/s[0-9]+$',
          ).hasMatch(current.rottenTomatoesId)) {
        try {
          final root = current.rottenTomatoesId.replaceFirst(
            RegExp(r'/s[0-9]+$'),
            '',
          );
          final qid = await _crosswalkEntityId(root, property: 'P1258');
          final parent = await _wikidataEntity(qid);
          List<dynamic> claims(String property) =>
              ((parent['claims'] as Map?)?[property] as List? ?? [])
                  .where((c) => c['rank'] != 'deprecated')
                  .map((c) => c['mainsnak']?['datavalue']?['value'])
                  .where((v) => v != null)
                  .toList();
          final isSeries = claims('P31').whereType<Map>().any(
            (v) => ['Q5398426', 'Q1259759', 'Q581714'].contains(v['id']),
          );
          final parentNames = [
            ...(parent['labels'] as Map? ?? {}).values.map(
              (v) => v['value'].toString(),
            ),
            ...(parent['aliases'] as Map? ?? {}).values
                .expand((v) => v as List)
                .map((v) => v['value'].toString()),
          ].map(cinemaRatingName).toSet();
          final imdb = claims('P345').map((v) => v.toString()).toSet();
          if (isSeries &&
              claims('P1258').contains(root) &&
              parentNames
                  .intersection(names.map(cinemaRatingName).toSet())
                  .isNotEmpty &&
              imdb.length == 1) {
            await accept(
              RatingIdentity(
                doubanId: current.doubanId,
                imdbId: imdb.single,
                rottenTomatoesId: current.rottenTomatoesId,
                label: current.label,
                wikidataId: current.wikidataId,
                confirmed: current.confirmed,
                imdbIsSeries: true,
              )..validate(),
            );
          }
        } catch (_) {
          /* Keep the verified season score even without a parent crosswalk. */
        }
      }
    }
    _mappings[lookupKey] = {
      'at': DateTime.now().toIso8601String(),
      'lookupSchema': 1,
      'complete':
          current.doubanId.isNotEmpty &&
          current.imdbId.isNotEmpty &&
          current.rottenTomatoesId.isNotEmpty,
      'identity': current.toJson(),
    };
    // Keep the optional lookup cache bounded independently of entity mappings.
    final lookups = _mappings.keys
        .where((k) => k.startsWith('lookup:'))
        .toList();
    for (final key in lookups.take((lookups.length - 160).clamp(0, 160))) {
      _mappings.remove(key);
    }
    _cacheChanged();
    if (current.toJson().toString() == original.toJson().toString() &&
        problem != null) {
      throw problem;
    }
    return current;
  }

  Future<Map<String, dynamic>> _wikidataEntity(String qid) async {
    final data = await _json(
      Uri.https('www.wikidata.org', '/w/api.php', {
        'action': 'wbgetentities',
        'ids': qid,
        'props': 'labels|aliases|claims',
        'languages': 'zh|zh-hans|zh-hant|en',
        'format': 'json',
      }),
    );
    return Map<String, dynamic>.from(data['entities'][qid]);
  }

  Future<RatingIdentity> _officialNameIdentity(
    CinemaTitle title,
    RatingIdentity original,
    DoubanSubjectDetails official,
    String kind,
    List<String> queries,
  ) async {
    final ids = <String>{};
    for (final query in queries.take(2)) {
      final data = await _json(
        Uri.https('www.wikidata.org', '/w/api.php', {
          'action': 'wbsearchentities',
          'search': query,
          'language': RegExp(r'[\u4e00-\u9fff]').hasMatch(query) ? 'zh' : 'en',
          'uselang': 'zh',
          'type': 'item',
          'limit': '5',
          'format': 'json',
        }),
      );
      ids.addAll(
        (data['search'] as List? ?? [])
            .whereType<Map>()
            .map((r) => r['id']?.toString() ?? '')
            .where((id) => RegExp(r'^Q[1-9][0-9]*$').hasMatch(id)),
      );
    }
    if (ids.isEmpty) return original;
    final data = await _json(
      Uri.https('www.wikidata.org', '/w/api.php', {
        'action': 'wbgetentities',
        'ids': ids.take(10).join('|'),
        'props': 'labels|aliases|claims',
        'languages': 'zh|zh-hans|zh-hant|en',
        'format': 'json',
      }),
    );
    final matches = <(RatingIdentity, Map<String, dynamic>)>[];
    for (final qid in ids.take(10)) {
      try {
        final entity = Map<String, dynamic>.from(data['entities'][qid]);
        final candidate = identityFromEntity(
          title,
          original,
          qid,
          entity,
          verifiedSubject: official,
          verifiedSubjectKind: kind,
          officialNameSearch: true,
        );
        matches.add((candidate, entity));
      } catch (_) {
        /* Reject another year, type, season or conflicting ID. */
      }
    }
    if (matches.length != 1) return original;
    final match = matches.single;
    _mappings[_mappingKey(original)] = {
      'at': DateTime.now().toIso8601String(),
      'qid': match.$1.wikidataId,
      'entity': match.$2,
    };
    _cacheChanged();
    return match.$1;
  }

  Future<bool> _verifyRtCandidate(String id, String year, String kind) async {
    final key = '烂番茄:$id';
    final previous = _cache[key];
    if (previous is Map &&
        previous['identityYear'] == year &&
        _fresh(previous, const Duration(hours: 24), field: 'attemptedAt')) {
      return true;
    }
    try {
      final url = 'https://www.rottentomatoes.com/$id';
      final body = utf8.decode(await _fetch(Uri.parse(url), 5 * 1024 * 1024));
      final parsed = await _verifyRtOffscreen(id, body, year, kind);
      if (!parsed.$1) return false;
      final rating = parsed.$2;
      if (rating != null) {
        _cache[key] = {
          ...rating.toJson(),
          'schema': 2,
          'identityYear': year,
          'attemptedAt': DateTime.now().toIso8601String(),
        };
        _cacheChanged();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<RatingIdentity> _seasonParentIdentity(
    CinemaTitle title,
    RatingIdentity current,
    DoubanSubjectDetails official,
  ) async {
    final mapped = _mappings[_mappingKey(current)];
    if (mapped is! Map || mapped['entity'] is! Map) return current;
    final entity = Map<String, dynamic>.from(mapped['entity']);
    List<dynamic> claims(Map<String, dynamic> e, String property) =>
        ((e['claims'] as Map?)?[property] as List? ?? [])
            .where((c) => c['rank'] != 'deprecated')
            .map((c) => c['mainsnak']?['datavalue']?['value'])
            .where((v) => v != null)
            .toList();
    if (!claims(
      entity,
      'P31',
    ).whereType<Map>().any((v) => v['id'] == 'Q3464665')) {
      return current;
    }
    final parentIds = [...claims(entity, 'P179'), ...claims(entity, 'P361')]
        .whereType<Map>()
        .map((v) => v['id']?.toString() ?? '')
        .where((id) => RegExp(r'^Q[1-9][0-9]*$').hasMatch(id))
        .toSet();
    if (parentIds.length != 1) return current;
    final parent = await _wikidataEntity(parentIds.single);
    if (!claims(parent, 'P31').whereType<Map>().any(
      (v) => ['Q5398426', 'Q1259759', 'Q581714'].contains(v['id']),
    )) {
      return current;
    }
    final officialNames = [
      official.title,
      official.originalTitle,
      ...official.aliases,
    ].map(cinemaRatingSeriesName).map(cinemaRatingName).toSet();
    final parentNames = [
      ...(parent['labels'] as Map? ?? {}).values.map(
        (v) => v['value'].toString(),
      ),
      ...(parent['aliases'] as Map? ?? {}).values
          .expand((v) => v as List)
          .map((v) => v['value'].toString()),
    ].map(cinemaRatingName).toSet();
    if (officialNames.intersection(parentNames).isEmpty) return current;
    final imdb = claims(parent, 'P345').map((v) => v.toString()).toSet();
    final rt = claims(parent, 'P1258')
        .map((v) => v.toString())
        .where((v) => RegExp(r'^tv/[a-zA-Z0-9_-]+$').hasMatch(v))
        .toSet();
    final season =
        CinemaRatingIdentitySearch.seasonForLabel(
          official.originalTitle,
        ).isNotEmpty
        ? CinemaRatingIdentitySearch.seasonForLabel(official.originalTitle)
        : CinemaRatingIdentitySearch.seasonForLabel(title.title);
    return RatingIdentity(
      doubanId: current.doubanId,
      imdbId: current.imdbId.isNotEmpty
          ? current.imdbId
          : imdb.length == 1
          ? imdb.single
          : '',
      rottenTomatoesId: current.rottenTomatoesId.isNotEmpty
          ? current.rottenTomatoesId
          : rt.length == 1
          ? '${rt.single}/s${season.padLeft(2, '0')}'
          : '',
      label: current.label,
      wikidataId: current.wikidataId,
      confirmed: current.confirmed,
      imdbIsSeries: true,
    )..validate();
  }

  Future<RatingIdentity> _resolve(
    CinemaTitle title,
    RatingIdentity original,
    bool force,
  ) {
    final key = jsonEncode([original.toJson(), title.title, title.year, force]);
    return _resolutionPending.putIfAbsent(key, () async {
      try {
        final cached = _mappings[_mappingKey(original)];
        if (!force &&
            cached is Map &&
            cached['failureSchema'] == 4 &&
            _fresh(cached, const Duration(seconds: 30), field: 'failedAt')) {
          throw FormatException(cached['failure']?.toString() ?? '跨站条目暂未关联');
        }
        return await _resolveUncached(title, original, force);
      } catch (error) {
        final existing = _mappings[_mappingKey(original)];
        if (force ||
            existing is! Map ||
            existing['failureSchema'] != 4 ||
            !_fresh(existing, const Duration(seconds: 30), field: 'failedAt')) {
          _mappings[_mappingKey(original)] = {
            if (existing is Map) ...Map<String, dynamic>.from(existing),
            'failedAt': DateTime.now().toIso8601String(),
            'failureSchema': 4,
            'failure': _readable(error),
          };
          _cacheChanged();
        }
        rethrow;
      } finally {
        _resolutionPending.remove(key);
      }
    });
  }

  Future<RatingIdentity> _resolveUncached(
    CinemaTitle title,
    RatingIdentity original,
    bool force,
  ) async {
    final id = _mappingKey(original);
    Map<String, dynamic> entity;
    String qid;
    final cached = _mappings[id];
    if (!force &&
        cached is Map &&
        cached['entity'] is Map &&
        cached['qid'] is String &&
        _fresh(cached, const Duration(hours: 24))) {
      entity = Map<String, dynamic>.from(cached['entity']);
      qid = cached['qid'] as String;
    } else {
      qid = await _crosswalkEntityId(
        original.doubanId.isNotEmpty
            ? original.doubanId
            : original.imdbId.isNotEmpty
            ? original.imdbId
            : original.rottenTomatoesId,
        property: original.doubanId.isNotEmpty
            ? 'P4529'
            : original.imdbId.isNotEmpty
            ? 'P345'
            : 'P1258',
      );
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
      _cacheChanged();
    }
    try {
      return identityFromEntity(
        title,
        original,
        qid,
        entity,
        verifiedSubject: _verifiedSubject(id),
        verifiedSubjectKind: _subjectKinds[id] ?? '',
      );
    } on FormatException {
      // An exact official subject can supply its original name when Wikidata
      // has no Chinese label. Reuse the score lookup/cache; never search names.
      if (original.doubanId.isNotEmpty &&
          (_verifiedSubject(id) == null || (_subjectKinds[id] ?? '').isEmpty)) {
        try {
          try {
            await _subject(id, false);
          } catch (_) {
            // The mobile page is the one bounded public fallback below.
          }
          if ((_subjectKinds[id] ?? '').isEmpty) {
            await _mobileSubject(id, false);
          }
        } catch (_) {
          /* Keep the original strict association failure below. */
        }
      }
      return identityFromEntity(
        title,
        original,
        qid,
        entity,
        verifiedSubject: _verifiedSubject(id),
        verifiedSubjectKind: _subjectKinds[id] ?? '',
      );
    }
  }

  Future<String> _crosswalkEntityId(
    String id, {
    String property = 'P4529',
  }) async {
    Set<String> ids = {};
    try {
      final data = await _json(
        Uri.https('query.wikidata.org', '/sparql', {
          'query':
              'SELECT DISTINCT ?item WHERE { ?item wdt:$property "$id" . } LIMIT 5',
          'format': 'json',
        }),
      );
      final bindings = (data['results'] as Map?)?['bindings'];
      if (bindings is List) {
        for (final row in bindings) {
          final value = row['item']?['value']?.toString() ?? '';
          final q = Uri.tryParse(value)?.pathSegments.lastOrNull ?? '';
          if (RegExp(r'^Q[1-9][0-9]*$').hasMatch(q)) ids.add(q);
        }
      }
    } catch (_) {
      // The independent Action API property index is an exact-ID fallback;
      // no title guesses or scores are borrowed from search snippets.
    }
    if (ids.length > 1) throw const FormatException('跨站 ID 有冲突，请手动关联');
    if (ids.length == 1) return ids.single;
    final data = await _json(
      Uri.https('www.wikidata.org', '/w/api.php', {
        'action': 'query',
        'list': 'search',
        'srnamespace': '0',
        'srsearch': 'haswbstatement:$property=$id',
        'srlimit': '5',
        'format': 'json',
      }),
    );
    final rows = (data['query'] as Map?)?['search'];
    if (rows is List) {
      ids = rows
          .whereType<Map>()
          .map((r) => r['title']?.toString() ?? '')
          .where((q) => RegExp(r'^Q[1-9][0-9]*$').hasMatch(q))
          .toSet();
    }
    if (ids.length != 1) throw const FormatException('未找到唯一的跨站条目，请手动关联 ID');
    // identityFromEntity subsequently rechecks the actual P4529 claim,
    // name, year and type. An index result alone is never accepted.
    return ids.single;
  }

  static RatingIdentity identityFromEntity(
    CinemaTitle title,
    RatingIdentity original,
    String qid,
    Map<String, dynamic> entity, {
    DoubanSubjectDetails? verifiedSubject,
    String verifiedSubjectKind = '',
    bool anchorImdb = false,
    bool officialNameSearch = false,
  }) {
    List<dynamic> claims(String property) =>
        ((entity['claims'] as Map?)?[property] as List? ?? [])
            .where((c) => c['rank'] != 'deprecated')
            .map((c) => c['mainsnak']?['datavalue']?['value'])
            .where((v) => v != null)
            .toList();
    final douban = claims('P4529').map((e) => e.toString()).toSet();
    final imdbClaims = claims('P345').map((e) => e.toString()).toSet();
    final rtClaims = claims('P1258').map((e) => e.toString()).toSet();
    if (officialNameSearch && douban.isEmpty && original.doubanId.isNotEmpty
        ? false
        : anchorImdb
        ? !imdbClaims.contains(original.imdbId) ||
              douban.isNotEmpty &&
                  original.doubanId.isNotEmpty &&
                  !douban.contains(original.doubanId)
        : original.doubanId.isNotEmpty
        ? !douban.contains(original.doubanId)
        : original.imdbId.isNotEmpty
        ? !imdbClaims.contains(original.imdbId)
        : original.rottenTomatoesId.isEmpty ||
              !rtClaims.contains(original.rottenTomatoesId)) {
      throw const FormatException('跨站条目的豆瓣 ID 不一致，请检查关联');
    }
    final labels = (entity['labels'] as Map? ?? {}).values
        .map((v) => v['value'].toString())
        .toList();
    final aliases = (entity['aliases'] as Map? ?? {}).values
        .expand((v) => v as List)
        .map((v) => v['value'].toString());
    String normalize(String value) => cinemaRatingName(value);
    final names = [...labels, ...aliases].map(normalize).toSet();
    final instanceIds = claims(
      'P31',
    ).whereType<Map>().map((v) => v['id']).toSet();
    final entityKind =
        instanceIds.contains('Q11424') || instanceIds.contains('Q202866')
        ? 'movie'
        : instanceIds.intersection({
            'Q5398426',
            'Q3464665',
            'Q1259759',
            'Q581714',
          }).isNotEmpty
        ? 'tv'
        : '';
    final years = [...claims('P577'), if (entityKind == 'tv') ...claims('P580')]
        .whereType<Map>()
        .map(
          (v) => RegExp(
            r'^\+([0-9]{4})-',
          ).firstMatch(v['time']?.toString() ?? '')?.group(1),
        )
        .whereType<String>()
        .toSet();
    final sourceKind = RegExp(r'电影|電影|片$').hasMatch(title.category)
        ? 'movie'
        : RegExp(r'电视剧|连续剧|国产剧|欧美剧|韩剧|日剧|泰剧|港剧|台剧|海外剧').hasMatch(title.category)
        ? 'tv'
        : '';
    final officialNames = verifiedSubject == null
        ? <String>{}
        : {
            verifiedSubject.title,
            verifiedSubject.originalTitle,
            ...verifiedSubject.aliases,
          }.where((name) => name.trim().isNotEmpty).map(normalize).toSet();
    final sameOfficialSubject =
        verifiedSubject != null &&
        verifiedSubject.doubanId == original.doubanId &&
        (title.year.trim().isEmpty ||
            verifiedSubject.year.trim() == title.year.trim()) &&
        cinemaOfficialTitleMatches(
          title.title,
          {
            verifiedSubject.title,
            verifiedSubject.originalTitle,
            ...verifiedSubject.aliases,
          },
          kind: verifiedSubjectKind,
          sourceSeason: CinemaRatingIdentitySearch.seasonForLabel(title.title),
          officialSeason: CinemaRatingIdentitySearch.seasonForLabel(
            verifiedSubject.title,
          ),
          exactId: true,
        );
    final expectedYear = title.year.trim().isNotEmpty
        ? title.year.trim()
        : sameOfficialSubject
        ? verifiedSubject.year.trim()
        : '';
    final aliasMatch =
        sameOfficialSubject &&
        ['movie', 'tv'].contains(verifiedSubjectKind) &&
        entityKind == verifiedSubjectKind &&
        officialNames.intersection(names).isNotEmpty;
    final officialIdAnchor =
        sameOfficialSubject &&
        original.doubanId.isNotEmpty &&
        douban.contains(original.doubanId) &&
        verifiedSubject.originalTitle.isEmpty &&
        entityKind == verifiedSubjectKind &&
        years.contains(expectedYear);
    if (officialNameSearch &&
        !(sameOfficialSubject &&
            entityKind == verifiedSubjectKind &&
            years.contains(expectedYear) &&
            officialNames.intersection(names).isNotEmpty)) {
      throw const FormatException('官网片名检索尚未核对唯一的同名、同年、同类型条目');
    }
    final seasonNumbers =
        [
              title.title,
              if (sameOfficialSubject) verifiedSubject.title,
              if (sameOfficialSubject) verifiedSubject.originalTitle,
            ]
            .map(CinemaRatingIdentitySearch.seasonForLabel)
            .where((n) => n.isNotEmpty)
            .toSet();
    if (seasonNumbers.length > 1 && !original.confirmed) {
      throw const FormatException('季度条目存在季数冲突，请手动核对');
    }
    final targetSeason = seasonNumbers.firstOrNull ?? '';
    final entityIsSeason = instanceIds.contains('Q3464665');
    final seriesNames = [
      ...labels,
      ...aliases,
    ].map(cinemaRatingSeriesName).map(normalize).toSet();
    final exactSeriesForSeason =
        sameOfficialSubject &&
        verifiedSubjectKind == 'tv' &&
        entityKind == 'tv' &&
        !entityIsSeason &&
        ![
          ...labels,
          ...aliases,
        ].any((n) => CinemaRatingIdentitySearch.seasonForLabel(n).isNotEmpty) &&
        (officialIdAnchor && targetSeason == '1' ||
            [
                  verifiedSubject.title,
                  verifiedSubject.originalTitle,
                  ...verifiedSubject.aliases,
                ]
                .map(cinemaRatingSeriesName)
                .map(normalize)
                .toSet()
                .intersection(seriesNames)
                .isNotEmpty);
    final entitySeasons = [...labels, ...aliases]
        .map(CinemaRatingIdentitySearch.seasonForLabel)
        .where((n) => n.isNotEmpty)
        .toSet();
    if (!original.confirmed &&
        (targetSeason.isNotEmpty || entityIsSeason) &&
        !(entityIsSeason &&
                targetSeason.isNotEmpty &&
                entitySeasons.length == 1 &&
                entitySeasons.single == targetSeason ||
            targetSeason.isNotEmpty && exactSeriesForSeason)) {
      throw const FormatException('季度条目需手动确认：尚未核对同一剧集和季数，避免将整剧评分当作本季评分');
    }
    if (!original.confirmed &&
        entityKind.isNotEmpty &&
        ((sourceKind.isNotEmpty && sourceKind != entityKind) ||
            (sameOfficialSubject &&
                verifiedSubjectKind.isNotEmpty &&
                verifiedSubjectKind != entityKind))) {
      throw const FormatException('电影与剧集类型不一致，请手动核对关联');
    }
    // An alias is accepted only from the exact official ID, with matching
    // source title, year and film/series kind. Provider-supplied aliases alone
    // never relax these checks, and a season still cannot inherit its series.
    if (!original.confirmed &&
        ((!names.contains(normalize(title.title)) &&
                !aliasMatch &&
                !officialIdAnchor &&
                !exactSeriesForSeason) ||
            !(years.contains(expectedYear) ||
                years.isEmpty &&
                    sameOfficialSubject &&
                    entityKind == verifiedSubjectKind ||
                targetSeason.isNotEmpty &&
                    exactSeriesForSeason &&
                    years.isNotEmpty &&
                    years.every(
                      (y) => int.parse(y) <= (int.tryParse(expectedYear) ?? 0),
                    )) ||
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

    // IMDb publishes one series score rather than independent season scores.
    // A season entity's arbitrary IMDb ID may name an episode, so obtain the
    // parent series through its explicit relationship instead.
    final mappedImdb = entityIsSeason && !original.confirmed
        ? ''
        : unique('P345');
    var mappedRt = unique('P1258');
    if (entityKind == 'tv' && mappedRt.startsWith('m/') ||
        entityKind == 'movie' && mappedRt.startsWith('tv/')) {
      mappedRt = '';
    }
    if (targetSeason.isNotEmpty && mappedRt.isNotEmpty) {
      final pathSeason = RegExp(r'/s([0-9]+)$').firstMatch(mappedRt)?.group(1);
      if (pathSeason != null &&
          int.parse(pathSeason) != int.parse(targetSeason)) {
        throw const FormatException('烂番茄条目季数不一致，请核对关联');
      }
      if (RegExp(r'^tv/[a-zA-Z0-9_-]+$').hasMatch(mappedRt)) {
        mappedRt = '$mappedRt/s${targetSeason.padLeft(2, '0')}';
      }
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
      doubanId: original.doubanId.isNotEmpty
          ? original.doubanId
          : douban.length == 1
          ? douban.single
          : '',
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
      imdbIsSeries:
          original.imdbIsSeries || entityKind == 'tv' && !entityIsSeason,
    )..validate();
  }

  DoubanSubjectDetails? _verifiedSubject(String id) {
    final memory = _subjectMemory[id];
    if (memory?.fetchedAt != null) {
      final age = DateTime.now().difference(memory!.fetchedAt!);
      if (!age.isNegative && age < const Duration(hours: 24)) return memory;
    }
    final cached = _details[id];
    if (cached is Map) {
      try {
        final subject = DoubanSubjectDetails.fromJson(
          Map<String, dynamic>.from(cached['data']),
        );
        if (subject.doubanId == id &&
            _fresh(
              subject.toJson(),
              const Duration(hours: 24),
              field: 'fetchedAt',
            )) {
          _subjectMemory[id] = subject;
          return subject;
        }
      } catch (_) {
        /* Optional metadata is not an identity guess. */
      }
    }
    return null;
  }

  void _rememberSubject(
    DoubanSubjectDetails subject, {
    String kind = '',
    bool restored = false,
  }) {
    final id = subject.doubanId;
    _subjectMemory.remove(id);
    _subjectMemory[id] = subject;
    if (['movie', 'tv'].contains(kind)) _subjectKinds[id] = kind;
    _subjectDiskEntries[id] = {
      'data': subject.toJson(),
      'kind': _subjectKinds[id] ?? '',
    };
    while (_subjectMemory.length > 80) {
      final oldest = _subjectMemory.keys.first;
      _subjectMemory.remove(oldest);
      _subjectKinds.remove(oldest);
      _subjectDiskEntries.remove(oldest);
    }
    if (!restored) _cacheChanged();
  }

  Future<DoubanSubjectDetails> _mobileSubject(String id, bool force) {
    final key = '$id:$force';
    return _mobileSubjectPending.putIfAbsent(key, () async {
      try {
        final body = utf8.decode(
          await _fetch(
            Uri.https('m.douban.com', '/movie/subject/$id/'),
            2 * 1024 * 1024,
          ),
        );
        final result = parseDoubanSubjectHtml(id, body);
        // Only inspect type after the parser has verified canonical subject ID.
        final document = html.parse(body);
        final label =
            document
                .querySelector('meta[property="og:title"]')
                ?.attributes['content'] ??
            '';
        final kind = RegExp(r'\s-\s*电影$').hasMatch(label)
            ? 'movie'
            : RegExp(r'\s-\s*电视剧$').hasMatch(label)
            ? 'tv'
            : '';
        _rememberSubject(result, kind: kind);
        return result;
      } finally {
        _mobileSubjectPending.remove(key);
      }
    });
  }

  Future<DoubanSubjectDetails> _subject(String id, bool force) {
    final cached = _subjectMemory[id] ?? _verifiedSubject(id);
    if (!force &&
        cached != null &&
        _fresh(
          cached.toJson(),
          cached.score == null || cached.note.contains('榜单')
              ? const Duration(seconds: 30)
              : const Duration(hours: 24),
          field: 'fetchedAt',
        )) {
      return Future.value(cached);
    }
    final key = '$id:$force';
    return _subjectPending.putIfAbsent(key, () async {
      try {
        try {
          final data = await _json(
            Uri.https(
              'm.douban.com',
              '/rexxar/api/v2/${_subjectKinds[id] == 'tv' || CinemaDoubanAccess.feedSubject(id)?.$2['type'] == 'tv' ? 'tv' : 'movie'}/$id',
            ),
          );
          final result = parseDoubanSubjectJson(id, data);
          _rememberSubject(result, kind: data['type']?.toString() ?? '');
          return result;
        } catch (_) {
          final feed = CinemaDoubanAccess.feedSubject(id);
          if (feed == null) rethrow;
          final result = parseDoubanSubjectJson(
            id,
            feed.$2,
          ).copyWith(fetchedAt: feed.$1, note: '豆瓣官网榜单公开条目；详情接口暂不可用');
          _rememberSubject(result, kind: feed.$2['type']?.toString() ?? '');
          return result;
        }
      } finally {
        _subjectPending.remove(key);
      }
    });
  }

  /// Full details and distribution requests are separate from card scoring.
  Future<DoubanSubjectDetails> loadDoubanDetails(
    CinemaTitle title, {
    RatingIdentity? identity,
    bool force = false,
  }) async {
    await _ready();
    final selected =
        identity ??
        (_bindings[title.key] is Map
            ? RatingIdentity.fromJson(
                Map<String, dynamic>.from(_bindings[title.key]),
              )
            : RatingIdentity(doubanId: title.doubanId));
    selected.validate();
    final id = selected.doubanId;
    if (id.isEmpty) {
      return const DoubanSubjectDetails(doubanId: '', note: '尚未关联豆瓣条目');
    }
    final key = '$id:$force';
    return _detailsPending.putIfAbsent(
      key,
      () => _loadDoubanDetails(id, force).whenComplete(() {
        _detailsPending.remove(key);
      }),
    );
  }

  Future<DoubanSubjectDetails> _loadDoubanDetails(String id, bool force) async {
    DoubanSubjectDetails? previous;
    final cached = _details[id];
    if (cached is Map) {
      try {
        previous = DoubanSubjectDetails.fromJson(
          Map<String, dynamic>.from(cached['data']),
        );
        if (previous.doubanId != id) throw const FormatException('详情缓存身份不一致');
        if (!force &&
            (_fresh(
                  cached,
                  cached['partial'] == true
                      ? const Duration(minutes: 30)
                      : const Duration(hours: 24),
                ) ||
                _fresh(
                  cached,
                  const Duration(minutes: 30),
                  field: 'attemptedAt',
                ))) {
          return previous.copyWith(stale: cached['failed'] == true);
        }
      } catch (_) {
        _details.remove(id);
        _cacheChanged();
        previous = null;
      }
    }
    DoubanSubjectDetails? subject, page;
    Map<String, dynamic>? stats;
    final problems = <String>[];
    await Future.wait([
      (() async {
        try {
          subject = await _subject(id, force);
        } catch (error) {
          problems.add('详细资料：${_readable(error)}');
        }
      })(),
      (() async {
        try {
          final body = utf8.decode(
            await _fetch(
              Uri.https('m.douban.com', '/movie/subject/$id/'),
              2 * 1024 * 1024,
            ),
          );
          page = parseDoubanSubjectHtml(id, body);
        } catch (error) {
          problems.add('推荐列表：${_readable(error)}');
        }
      })(),
      (() async {
        try {
          stats = await _json(
            Uri.https('m.douban.com', '/rexxar/api/v2/movie/$id/rating'),
          );
        } catch (error) {
          problems.add('星级分布：${_readable(error)}');
        }
      })(),
    ]);
    final primary = subject ?? page;
    DoubanSubjectDetails result;
    if (primary == null || !primary.hasContent) {
      result = (previous ?? DoubanSubjectDetails(doubanId: id)).copyWith(
        stale: previous?.hasContent ?? false,
        note:
            '${previous?.hasContent == true ? '更新失败，保留上次官网资料。' : ''}${problems.join('；')}',
      );
      _details[id] = {
        'data': result.toJson(),
        'failed': true,
        'attemptedAt': DateTime.now().toIso8601String(),
      };
    } else {
      var shares = page?.stars ?? <DoubanStarShare>[];
      try {
        if (stats != null) shares = parseDoubanStarShares(stats!);
      } catch (error) {
        if (shares.isEmpty) problems.add('星级分布：${_readable(error)}');
      }
      var starsAt = DateTime.now(), recommendationsAt = DateTime.now();
      if (shares.isEmpty &&
          previous?.stars.isNotEmpty == true &&
          problems.any((p) => p.startsWith('星级分布'))) {
        shares = previous!.stars;
        starsAt = previous.starsFetchedAt ?? previous.fetchedAt ?? starsAt;
        problems.add(
          '星级分布沿用 ${starsAt.toLocal().toString().substring(0, 16)} 的官网缓存',
        );
      }
      var recommendations = page?.recommendations ?? <DoubanRecommendation>[];
      if (page == null && previous?.recommendations.isNotEmpty == true) {
        recommendations = previous!.recommendations;
        recommendationsAt =
            previous.recommendationsFetchedAt ??
            previous.fetchedAt ??
            recommendationsAt;
        problems.add(
          '推荐列表沿用 ${recommendationsAt.toLocal().toString().substring(0, 16)} 的官网缓存',
        );
      }
      if (subject == null && previous?.hasContent == true) {
        problems.add('官网资料接口暂不可用，缺失字段沿用已保存的官网资料');
      }
      // Never infer per-star counts from rounded proportions or done_count.
      result = DoubanSubjectDetails(
        doubanId: id,
        title: primary.title,
        year: primary.year,
        originalTitle: primary.originalTitle.isNotEmpty
            ? primary.originalTitle
            : (page?.originalTitle.isNotEmpty == true
                  ? page!.originalTitle
                  : subject == null
                  ? previous?.originalTitle ?? ''
                  : ''),
        imdbId: primary.imdbId.isNotEmpty
            ? primary.imdbId
            : page?.imdbId ?? previous?.imdbId ?? '',
        releaseDates: {
          ...primary.releaseDates,
          ...?page?.releaseDates,
          if (subject == null) ...?previous?.releaseDates,
        }.toList(),
        durations: primary.durations.isNotEmpty
            ? primary.durations
            : (page?.durations.isNotEmpty == true
                  ? page!.durations
                  : subject == null
                  ? previous?.durations ?? const []
                  : const []),
        aliases: primary.aliases.isNotEmpty
            ? primary.aliases
            : (page?.aliases.isNotEmpty == true
                  ? page!.aliases
                  : subject == null
                  ? previous?.aliases ?? const []
                  : const []),
        score: primary.score ?? page?.score,
        ratingCount: primary.ratingCount ?? page?.ratingCount,
        stars: shares,
        recommendations: recommendations,
        fetchedAt:
            (primary.score != null ? primary.fetchedAt : page?.fetchedAt) ??
            primary.fetchedAt,
        starsFetchedAt: shares.isEmpty ? null : starsAt,
        recommendationsFetchedAt: recommendations.isEmpty
            ? null
            : recommendationsAt,
        note: problems.isEmpty ? '豆瓣官网公开资料' : problems.join('；'),
      );
      _details.remove(id);
      _details[id] = {
        'at': DateTime.now().toIso8601String(),
        'partial': problems.isNotEmpty,
        'data': result.toJson(),
      };
      if (result.score != null) {
        final scoreSource = primary.score != null ? primary : page!;
        _cache['豆瓣:$id'] = {
          ..._doubanRating(scoreSource).toJson(),
          'schema': 2,
        };
      }
    }
    while (_details.length > 64) {
      _details.remove(_details.keys.first);
    }
    _cacheChanged();
    try {
      await _save();
    } catch (_) {
      result = result.copyWith(note: '${result.note} · 详情缓存保存失败');
    }
    return result;
  }

  static CinemaRating _doubanRating(DoubanSubjectDetails subject) {
    return CinemaRating(
      provider: '豆瓣',
      value: subject.score,
      count: subject.ratingCount,
      url: subject.url,
      verified: true,
      fetchedAt: subject.fetchedAt,
      note: subject.score == null
          ? '豆瓣官网暂未公布评分'
          : subject.note.contains('榜单')
          ? subject.note
          : '豆瓣官网公开条目',
    );
  }

  Future<CinemaRating> _rating(
    String provider,
    String id,
    bool force, {
    bool cardOnly = false,
  }) {
    final key = '$provider:$id:$force:$cardOnly';
    return _providerPending.putIfAbsent(
      key,
      () => _ratingUncached(provider, id, force, cardOnly: cardOnly)
          .whenComplete(() {
            _providerPending.remove(key);
          }),
    );
  }

  Future<CinemaRating> _ratingUncached(
    String provider,
    String id,
    bool force, {
    bool cardOnly = false,
  }) async {
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
        (provider != '豆瓣' ||
            cached['value'] != null ||
            cached['schema'] == 2) &&
        (cardOnly || cached['cardOnlyFailure'] != true) &&
        (_fresh(
              cached,
              cached['value'] == null
                  ? const Duration(seconds: 30)
                  : const Duration(minutes: 30),
              field: 'attemptedAt',
            ) ||
            _fresh(
              cached,
              cached['value'] == null
                  ? const Duration(seconds: 30)
                  : const Duration(hours: 24),
              field: 'fetchedAt',
            ))) {
      try {
        return CinemaRating.fromJson(Map<String, dynamic>.from(cached));
      } catch (_) {
        _cache.remove(key);
        _cacheChanged();
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
        try {
          final path = '${(await _dir).path}/title.ratings.tsv.gz';
          var warning = '';
          try {
            await (_dataset ??= _prepareDataset(
              force: force,
              retryFailure: force,
            ).whenComplete(() => _dataset = null));
          } catch (error) {
            if (!await File(path).exists()) rethrow;
            // The previous official dataset remains useful offline. Its original
            // timestamp is retained and the read below still validates the gzip.
            warning = ' · 更新失败，使用上次官方数据；${_readable(error)}';
          }
          (double, int)? values;
          try {
            values = await _imdbWork.run(() => _readImdbInBackground(path, id));
          } catch (_) {
            // One bounded repair for a corrupt/truncated local dataset.
            await (_dataset ??=
                _prepareDataset(force: true, retryFailure: force).whenComplete(
                  () {
                    _dataset = null;
                  },
                ));
            values = await _imdbWork.run(() => _readImdbInBackground(path, id));
          }
          if (values == null) throw const FormatException('IMDb 数据集暂未收录评分');
          result = CinemaRating(
            provider: provider,
            value: values.$1,
            count: values.$2,
            url: url,
            verified: true,
            note: 'IMDb 官方每日数据 · 个人非商业使用$warning',
            fetchedAt: (await File(path).lastModified()),
          );
        } catch (datasetError) {
          try {
            final body = utf8.decode(
              await _fetch(Uri.parse(url), 5 * 1024 * 1024),
            );
            result = await _parseRatingOffscreen('IMDb', url, body);
          } catch (_) {
            throw datasetError;
          }
        }
      } else if (provider == '豆瓣') {
        // The official mobile page uses metadata instead of JSON-LD, and its
        // subject_header.js loads this public JSON. No cookies or private keys.
        try {
          result = _doubanRating(await _subject(id, force));
        } catch (_) {
          if (cardOnly) {
            result = _doubanRating(await _mobileSubject(id, force));
          } else {
            try {
              final body = utf8.decode(
                await _fetch(Uri.parse(url), 2 * 1024 * 1024),
              );
              result = await _parseRatingOffscreen(provider, url, body);
            } catch (_) {
              result = _doubanRating(await _mobileSubject(id, force));
            }
          }
        }
      } else {
        final body = utf8.decode(await _fetch(Uri.parse(url), 5 * 1024 * 1024));
        result = await _parseRatingOffscreen(provider, url, body);
      }
    } catch (error) {
      CinemaRating? previous;
      try {
        if (cached is Map) {
          previous = CinemaRating.fromJson(Map<String, dynamic>.from(cached));
        }
      } catch (_) {
        /* Invalid cache entries must not defeat independent providers. */
      }
      result = CinemaRating(
        provider: provider,
        scale: scale,
        url: url,
        value: previous?.verified == true ? previous?.value : null,
        count: previous?.verified == true ? previous?.count : null,
        verified: previous?.verified == true && previous?.value != null,
        note: previous?.verified == true && previous?.value != null
            ? '更新失败，保留上次官网评分；${_readable(error)}'
            : _readable(error),
        fetchedAt: previous?.verified == true && previous?.value != null
            ? previous?.fetchedAt
            : DateTime.now(),
      );
    }
    _cache[key] = {
      ...result.toJson(),
      'schema': 2,
      if (cardOnly && result.value == null) 'cardOnlyFailure': true,
      'attemptedAt': DateTime.now().toIso8601String(),
    };
    _cacheChanged();
    _changes.changed();
    return result;
  }

  Future<void> _prepareDataset({
    bool force = false,
    bool retryFailure = false,
  }) async {
    if (!retryFailure &&
        _datasetFailedAt != null &&
        DateTime.now().difference(_datasetFailedAt!) <
            const Duration(seconds: 30)) {
      throw FormatException(_datasetFailure);
    }
    try {
      await _updateDataset(force: force);
      _datasetFailedAt = null;
    } catch (error) {
      _datasetFailedAt = DateTime.now();
      _datasetFailure = _readable(error);
      rethrow;
    }
  }

  Future<void> _updateDataset({bool force = false}) async {
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
    if (provider == '豆瓣') {
      final id = doubanIdFromUrl(url);
      if (id == null) throw const FormatException('豆瓣条目网址无效');
      return _doubanRating(parseDoubanSubjectHtml(id, body));
    }
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
          note: provider == '烂番茄' ? '官网 Tomatometer · 影评人新鲜度' : 'IMDb 官网公开条目',
        );
      }
    }
    if (provider == '烂番茄') {
      // RT's current scorecard can precede its JSON-LD aggregateRating. Require
      // both the canonical link and the current media object's exact path;
      // audienceScore and recommendations are deliberately ignored.
      final canonical = Uri.tryParse(
        document.querySelector('link[rel="canonical"]')?.attributes['href'] ??
            '',
      );
      final expected = Uri.parse(url);
      final vanityScript = document.querySelector('script[data-json="vanity"]');
      final scoreScript = document.querySelector(
        'script[data-json="mediaScorecard"]',
      );
      if (canonical?.host == expected.host &&
          canonical?.path.replaceFirst(RegExp(r'/$'), '') ==
              expected.path.replaceFirst(RegExp(r'/$'), '') &&
          vanityScript != null &&
          scoreScript != null) {
        try {
          final vanity = jsonDecode(vanityScript.text) as Map;
          final score =
              (jsonDecode(scoreScript.text) as Map)['criticsScore'] as Map;
          final value = double.tryParse(score['score']?.toString() ?? '');
          final count = int.tryParse(
            (score['ratingCount'] ?? score['reviewCount'])?.toString() ?? '',
          );
          if (vanity['href'] == expected.path &&
              [
                'movie',
                'tvSeries',
                'tvSeason',
                'tvEpisode',
              ].contains(vanity['type']) &&
              score['title'] == 'Tomatometer' &&
              value != null &&
              value.isFinite &&
              value >= 0 &&
              value <= 100 &&
              count != null &&
              count > 0) {
            return CinemaRating(
              provider: provider,
              value: value,
              scale: 100,
              count: count,
              url: url,
              verified: true,
              fetchedAt: DateTime.now(),
              note: '官网 Tomatometer · 影评人新鲜度',
            );
          }
        } catch (_) {
          /* Keep an unavailable score explicit. */
        }
      }
    }
    throw FormatException(provider == 'IMDb' ? 'IMDb 官网暂未返回评分' : '官网未返回影评人评分');
  }

  Future<Map<String, dynamic>> _json(Uri uri) async {
    final data = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(await _fetch(uri, 2 * 1024 * 1024))),
    );
    if (_isSubjectApi(uri)) {
      CinemaDoubanAccess.noteResponse(null, data);
      if (!CinemaDoubanAccess.canRequestSubject()) {
        throw const HttpException('豆瓣资料接口暂时限流，稍后自动重试；可在官网查看');
      }
    }
    return data;
  }

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

  @visibleForTesting
  static Future<List<int>> fetchOfficial(Uri uri, int maxBytes) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    client.findProxy = Platform.isMacOS
        ? MacOSSystemProxy.findProxy
        : HttpClient.findProxyFromEnvironment;
    Future<List<int>> request(
      Uri target, {
      bool allowSubjectRedirect = true,
    }) async {
      final req = await client.getUrl(target);
      final douban = ['m.douban.com', 'movie.douban.com'].contains(target.host);
      if (douban) req.followRedirects = false;
      req.headers.set(
        'User-Agent',
        target.host == 'm.douban.com' &&
                target.path.startsWith('/movie/subject/')
            ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1 NAKUPlayer/1.5.0'
            : 'NAKUPlayer/1.5.0 (https://github.com/NakuTop/NAKU-Player)',
      );
      req.headers.set('Accept', 'application/json,text/html,*/*');
      if (_isSubjectApi(target)) {
        final id = target.pathSegments[4];
        req.headers.set('Referer', 'https://m.douban.com/movie/subject/$id/');
      }
      final response = await req.close();
      if (allowSubjectRedirect &&
          [301, 302, 307, 308].contains(response.statusCode)) {
        final redirect = CinemaDoubanAccess.subjectRedirect(
          target,
          response.headers.value(HttpHeaders.locationHeader),
          resource: target.path.endsWith('/rating') ? 'rating' : '',
        );
        if (redirect != null) {
          await response.drain<void>();
          return request(redirect, allowSubjectRedirect: false);
        }
      }
      if (response.statusCode != 200) {
        if (_isSubjectApi(uri) && response.statusCode == 400) {
          final errorBytes = <int>[];
          await for (final chunk in response) {
            if (errorBytes.length + chunk.length > 65536) break;
            errorBytes.addAll(chunk);
          }
          CinemaDoubanAccess.noteResponse(
            400,
            utf8.decode(errorBytes, allowMalformed: true),
          );
          if (!CinemaDoubanAccess.canRequestSubject()) {
            throw const HttpException('豆瓣资料接口暂时限流，稍后自动重试；可在官网查看');
          }
        }
        throw HttpException(
          douban &&
                  [
                    301,
                    302,
                    303,
                    307,
                    308,
                    401,
                    403,
                    418,
                  ].contains(response.statusCode)
              ? '豆瓣暂时限制访问或要求验证，请在官网查看'
              : response.statusCode == 429
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
      return await request(uri).timeout(
        Duration(
          seconds: uri.host == 'datasets.imdbws.com'
              ? 40
              : uri.host == 'query.wikidata.org'
              ? 8
              : 12,
        ),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// A small FIFO gate; a failed request never poisons later work.
class _RatingsWorkPool {
  _RatingsWorkPool(this.limit);
  final int limit;
  int _active = 0;
  final _waiting = <Completer<void>>[];
  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete();
      } else {
        _active--;
      }
    }
  }
}

class _RatingsChanges extends ChangeNotifier {
  void changed() => notifyListeners();
}
