import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_online_subtitles.dart';
import 'cinema_saved_subtitle.dart';
import 'cinema_season_subtitle_preferences.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_timing.dart';

final _services = Expando<CinemaSeasonSubtitlePrefetch>();

/// One background queue per library, independent of the current player. Files
/// are keyed by work/season/episode so rotating URLs and route changes work too.
class CinemaSeasonSubtitlePrefetch extends ChangeNotifier {
  CinemaSeasonSubtitlePrefetch._(this.store);
  factory CinemaSeasonSubtitlePrefetch.forStore(CinemaStore store) =>
      _services[store] ??= CinemaSeasonSubtitlePrefetch._(store);

  final CinemaStore store;
  String _jobKey = '', _series = '';
  CinemaOnlineSubtitles? _client;
  Future<void> _pending = Future.value();
  int _revision = 0, _requestedFrom = 0;
  int ready = 0, failed = 0, completed = 0, total = 0;
  bool busy = false;
  int? activeEpisode;
  List<int> _todo = [];
  Map<int, Completer<void>> _episodeDone = {};
  String get status => total == 0
      ? ''
      : busy
      ? '本季字幕预下载 $completed/$total · 已缓存 $ready 集${activeEpisode == null ? '' : ' · 正在处理第 $activeEpisode 集'}'
      : '本季字幕已缓存 $ready/$total 集${failed > 0 ? ' · $failed 集暂无匹配，可重试' : ''}';
  Future<void> get idle => _pending;
  bool belongsTo(String series) => _series == series;

  /// Keep the public download descriptor in the local caption cache, outside
  /// library exports. No video URL, NAS path or credential is accepted here.
  Future<void> rememberSource(
    String series,
    CinemaSeasonSubtitleProfile profile,
    Map<String, dynamic> selected,
  ) async {
    final url = Uri.tryParse('${selected['url'] ?? ''}');
    if (url == null ||
        url.scheme != 'https' ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.toString().length > 2048 ||
        selected['archiveEntry'] is! String) {
      return;
    }
    final row = <String, dynamic>{
      for (final field in [
        'url',
        'sourceUrl',
        'archiveEntry',
        'subtitleFileName',
        'lang',
        'provider',
        'releaseFormat',
        'bilingual',
      ])
        if (selected[field] is String || selected[field] is bool)
          field: selected[field],
    };
    final file = await _sourceFile(series, profile);
    final text = jsonEncode(row);
    if (text.length > 8192) return;
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
    final sources = await file.parent
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (sources.length > 64) {
      final old = <({File file, DateTime at})>[];
      for (final f in sources) {
        old.add((file: f, at: await f.lastModified()));
      }
      old.sort((a, b) => a.at.compareTo(b.at));
      for (final entry in old.take(sources.length - 64)) {
        if (entry.file.path != file.path) await entry.file.delete();
      }
    }
  }

  Future<File> _sourceFile(
    String series,
    CinemaSeasonSubtitleProfile profile,
  ) async => File(
    '${(await store.subtitleCacheDirectory()).path}/season-sources-v1/${sha256.convert(utf8.encode('$series|${_signature(profile)}'))}.json',
  );

  Future<Map<String, dynamic>?> _source(
    String series,
    CinemaSeasonSubtitleProfile profile,
  ) async {
    try {
      final file = await _sourceFile(series, profile);
      if (!await file.exists() || await file.length() > 8192) return null;
      final row = jsonDecode(await file.readAsString());
      return row is Map ? Map<String, dynamic>.from(row) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<CinemaSavedSubtitle?> waitForEpisode(
    String series,
    CinemaSeasonSubtitleProfile profile,
    int episode, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final cached = await read(series, profile, episode);
    if (cached != null ||
        !busy ||
        !belongsTo(series) ||
        !_jobKey.startsWith('$series|${_signature(profile)}|')) {
      return cached;
    }
    if (_todo.remove(episode)) _todo.insert(0, episode);
    final done = _episodeDone[episode];
    if (done != null) {
      await done.future.timeout(timeout, onTimeout: () {});
    }
    return read(series, profile, episode);
  }

  String _signature(CinemaSeasonSubtitleProfile profile) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            profile.queryTitle.toLowerCase(),
            profile.season,
            profile.language,
            profile.provider,
            profile.releaseFormat,
            profile.bilingual,
            profile.name
                .toLowerCase()
                .replaceAll(
                  RegExp(
                    r's\d+[ ._-]*e\d+|\d+x\d+|第\s*[零一二两三四五六七八九十百\d]+\s*[集话話]|\b(?:episode|e)\s*\d+',
                  ),
                  '',
                )
                .replaceAll(RegExp(r'[\s._-]+'), ''),
          ]),
        ),
      )
      .toString();

  Future<File> _file(
    String series,
    int season,
    int episode,
    String family,
  ) async {
    final key = sha256.convert(utf8.encode('$series|$season|$episode|$family'));
    return File(
      '${(await store.subtitleCacheDirectory()).path}/season-v1/$key.json',
    );
  }

  Future<CinemaSavedSubtitle?> read(
    String series,
    CinemaSeasonSubtitleProfile profile,
    int episode,
  ) async {
    final file = await _file(
      series,
      profile.season,
      episode,
      _signature(profile),
    );
    try {
      if (!await file.exists() ||
          await file.length() > CinemaSavedSubtitleStore.maxFileBytes) {
        return null;
      }
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['family'] != _signature(profile)) return null;
      final saved = CinemaSavedSubtitle.parse(json['subtitle']);
      if (saved == null || saved.disabled || saved.nativeTrack != null) {
        return null;
      }
      return saved.inheritToSeason ? saved.withTiming(profile.timing) : saved;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<void> cache(
    String series,
    CinemaSeasonSubtitleProfile profile,
    int episode,
    CinemaSavedSubtitle subtitle,
  ) async {
    final file = await _file(
      series,
      profile.season,
      episode,
      _signature(profile),
    );
    final bytes = utf8.encode(
      jsonEncode({
        'family': _signature(profile),
        'subtitle': subtitle.toJson(),
      }),
    );
    if (bytes.length > CinemaSavedSubtitleStore.maxFileBytes) {
      throw const FormatException('单集字幕超过缓存大小上限');
    }
    await file.parent.create(recursive: true);
    // Unique temporaries prevent a replacement queue racing an older write.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(file.path);
    final files = <({File file, int size, DateTime modified})>[];
    await for (final entry in file.parent.list(followLinks: false)) {
      if (entry is File &&
          RegExp(r'[a-f0-9]{64}\.json$').hasMatch(entry.path)) {
        final stat = await entry.stat();
        files.add((file: entry, size: stat.size, modified: stat.modified));
      }
    }
    files.sort((a, b) => a.modified.compareTo(b.modified));
    var bytesTotal = files.fold(0, (int a, b) => a + b.size);
    var count = files.length;
    for (final entry in files) {
      if (count <= 512 && bytesTotal <= 128 * 1024 * 1024) break;
      if (entry.file.path == file.path) continue;
      await entry.file.delete();
      bytesTotal -= entry.size;
      count--;
    }
  }

  void cancel(String series) {
    if (_series != series) return;
    ++_revision;
    _client?.close();
    _client = null;
    _jobKey = '';
    busy = false;
    activeEpisode = null;
    for (final done in _episodeDone.values) {
      if (!done.isCompleted) done.complete();
    }
    notifyListeners();
  }

  Future<void> start({
    required String series,
    required CinemaSeasonSubtitleProfile profile,
    required Iterable<CinemaSubtitleQuery> episodes,
    required int currentEpisode,
    CinemaOnlineSubtitles Function()? clientFactory,
    bool retry = false,
  }) {
    final numbers =
        episodes
            .where((q) => q.type == 'series' && q.season == profile.season)
            .map((q) => q.episode)
            .where((n) => n >= 1 && n <= 9999)
            .toSet()
            .toList()
          ..sort();
    if (numbers.isEmpty) return Future.value();
    final key = '$series|${_signature(profile)}|${numbers.join(',')}';
    if (!retry &&
        key == _jobKey &&
        (busy || failed == 0 || _requestedFrom == currentEpisode)) {
      return _pending;
    }
    _client?.close();
    for (final done in _episodeDone.values) {
      if (!done.isCompleted) done.complete();
    }
    final revision = ++_revision;
    _jobKey = key;
    _series = series;
    _requestedFrom = currentEpisode;
    ready = failed = completed = 0;
    total = numbers.length;
    busy = true;
    // Warm the immediately following episodes first, then the earlier ones.
    final ordered = _todo = [
      ...numbers.where((n) => n > currentEpisode),
      ...numbers.where((n) => n <= currentEpisode),
    ];
    final episodeDone = _episodeDone = {
      for (final number in numbers) number: Completer<void>(),
    };
    notifyListeners();
    return _pending = (() async {
      CinemaOnlineSubtitles createClient() =>
          (clientFactory ?? CinemaOnlineSubtitles.new)();
      var client = _client = createClient();
      bool current() => revision == _revision;
      try {
        var seedRows = <Map<String, dynamic>>[];
        try {
          final source = await _source(series, profile);
          if (source != null) {
            seedRows = await client
                .seasonFiles(source)
                .timeout(const Duration(seconds: 25));
          }
        } catch (_) {
          /* The regular catalog search remains available. */
        }
        while (ordered.isNotEmpty) {
          final episode = ordered.removeAt(0);
          if (!current()) return;
          activeEpisode = episode;
          notifyListeners();
          var refreshClient = false;
          try {
            if (await read(series, profile, episode) != null) {
              if (!current()) return;
              ready++;
            } else {
              final packaged = seedRows.where((row) {
                final q = CinemaSubtitleQuery.parse(
                  'Season ${profile.season}',
                  category: 'series',
                  episodeName: '${row['archiveEntry']}',
                  fallbackEpisode: 0,
                );
                return q.season == profile.season && q.episode == episode;
              }).toList();
              final verified = <Map<String, dynamic>>[];
              for (final row in packaged.take(8)) {
                if (!current()) return;
                try {
                  final valid = await client.verifyFile(
                    row,
                    language: profile.language,
                  );
                  if (valid != null) verified.add(valid);
                } catch (_) {
                  /* Try another file or the online catalog. */
                }
              }
              // fromEpisode controls inheritance of older preferences; the
              // background download still checks all episodes of this season.
              final allSeason = CinemaSeasonSubtitleProfile(
                season: profile.season,
                fromEpisode: 1,
                queryTitle: profile.queryTitle,
                language: profile.language,
                name: profile.name,
                provider: profile.provider,
                releaseFormat: profile.releaseFormat,
                bilingual: profile.bilingual,
                timing: profile.timing,
                imdbId: profile.imdbId,
              );
              var rows = verified;
              if (rows.isEmpty) {
                final first = Completer<List<Map<String, dynamic>>>();
                var searchDone = false;
                final full = client
                    .aggregate(
                      profile.queryTitle,
                      'series',
                      imdbId: profile.imdbId,
                      season: profile.season,
                      episode: episode,
                      language: profile.language,
                      mediaRelease: profile.releaseFormat,
                      onVerified: (rows) {
                        if (!first.isCompleted &&
                            chooseCinemaSeasonSubtitle(
                                  allSeason,
                                  rows,
                                  season: profile.season,
                                  episode: episode,
                                ) !=
                                null) {
                          refreshClient = true;
                          first.complete(rows);
                        }
                      },
                    )
                    .then((result) {
                      searchDone = true;
                      return result.rows;
                    });
                // One usable exact-episode file is enough for predownload.
                // Stop other catalog requests rather than waiting for every
                // unavailable provider to time out for every episode.
                try {
                  rows = await Future.any([
                    full,
                    first.future,
                  ]).timeout(const Duration(seconds: 40));
                  refreshClient = !searchDone;
                } on TimeoutException {
                  refreshClient = true;
                  rethrow;
                }
              }
              if (!current()) return;
              final remaining = List<Map<String, dynamic>>.of(rows);
              var found = false;
              for (var attempt = 0; attempt < 3; attempt++) {
                final row = chooseCinemaSeasonSubtitle(
                  allSeason,
                  remaining,
                  season: profile.season,
                  episode: episode,
                );
                if (row == null) break;
                remaining.remove(row);
                try {
                  final text = cinemaSubtitleSrt(
                    await client.download(
                      '${row['url']}',
                      archiveEntry: row['archiveEntry'] as String?,
                    ),
                  );
                  if (!current()) return;
                  final family = cinemaSeasonSubtitleFamilyMatches(
                    profile,
                    row,
                  );
                  await cache(
                    series,
                    profile,
                    episode,
                    CinemaSavedSubtitle(
                      text: text,
                      title:
                          '${row['archiveEntry'] ?? row['subtitleFileName'] ?? '本季字幕'}',
                      language: '${row['lang']}',
                      inheritToSeason: family,
                      timing: family
                          ? profile.timing
                          : const CinemaSubtitleTiming(),
                    ),
                  );
                  if (!current()) return;
                  found = true;
                  ready++;
                  if (seedRows.isEmpty && row['archiveEntry'] is String) {
                    try {
                      await rememberSource(series, profile, row);
                      seedRows = await client
                          .seasonFiles(row)
                          .timeout(const Duration(seconds: 20));
                    } catch (_) {
                      /* A valid single-episode file stays cached. */
                    }
                  }
                  break;
                } catch (_) {
                  if (!current()) return;
                }
              }
              if (!found) failed++;
            }
          } catch (_) {
            if (!current()) return;
            failed++;
          } finally {
            if (refreshClient && current()) {
              client.close();
              client = _client = createClient();
            }
          }
          completed++;
          episodeDone[episode]?.complete();
          notifyListeners();
        }
      } finally {
        client.close();
        if (current()) {
          busy = false;
          activeEpisode = null;
          _client = null;
          notifyListeners();
        }
        for (final done in episodeDone.values) {
          if (!done.isCompleted) done.complete();
        }
      }
    })();
  }
}
