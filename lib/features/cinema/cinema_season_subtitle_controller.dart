import 'dart:async';
import 'package:flutter/foundation.dart';
import 'cinema_subtitle_auto_sync.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_online_subtitles.dart';
import 'cinema_season_subtitle_preferences.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_sync_preferences.dart';
import 'cinema_subtitle_timing.dart';
import 'cinema_media_identity.dart';
import 'cinema_saved_subtitle.dart';
import 'cinema_season_subtitle_prefetch.dart';

typedef CinemaSeasonSubtitleApply =
    Future<void> Function(
      Player player,
      String text, {
      String title,
      String language,
      bool Function()? isCurrent,
    });

/// One playback owns its subtitle requests. Late results can never overwrite a
/// manual selection or load the preceding episode's captions into a new player.
class CinemaSeasonSubtitleController {
  CinemaSeasonSubtitleController({
    required this.player,
    required CinemaStore store,
    required this.seriesIdentity,
    required String mediaIdentity,
    required this.query,
    this.imdbId = '',
    this.year = '',
    this.mediaRelease = '',
    this.canResume,
    this.automateMissing = false,
    this.autoSync,
    this.seasonEpisodes = const [],
    this.prefetchClientFactory,
    CinemaOnlineSubtitles? client,
    CinemaSeasonSubtitleApply? apply,
  }) : preferences = CinemaSeasonSubtitlePreferences(store),
       _saved = CinemaSavedSubtitleStore(store, mediaIdentity),
       _client = client,
       _apply = apply ?? applyCinemaExternalSubtitle {
    bindCinemaSubtitleTiming(
      player,
      store,
      mediaIdentity,
      fallbackTiming: (_) => _inheritedTiming,
      onTimingSaved: (content, timing) async {
        final inherits = !_closed && content == _trackedFingerprint;
        await _saved.updateTiming(content, timing);
        if (inherits) {
          await preferences.updateTiming(seriesIdentity, query.season, timing);
        }
      },
    );
    cinemaExternalSubtitleState(player).disableSavedSelection = disable;
  }

  final bool automateMissing;
  final CinemaSubtitleAutoSync? autoSync;
  final List<CinemaSubtitleQuery> seasonEpisodes;
  final CinemaOnlineSubtitles Function()? prefetchClientFactory;
  CinemaSeasonSubtitlePrefetch get prefetch =>
      CinemaSeasonSubtitlePrefetch.forStore(preferences.store);
  final status = ValueNotifier<String>('自动字幕待检查');
  bool automaticEnabled = true;
  final Player player;
  final String seriesIdentity, imdbId, mediaRelease, year;
  final CinemaSubtitleQuery query;
  final bool Function()? canResume;
  final CinemaSeasonSubtitlePreferences preferences;
  final CinemaSavedSubtitleStore _saved;
  CinemaOnlineSubtitles? _client;
  final CinemaSeasonSubtitleApply _apply;
  CinemaSubtitleTiming? _inheritedTiming;
  String? _trackedFingerprint;
  int _revision = 0;
  bool _closed = false, _manual = false, _loaded = false;
  Future<void>? _attempt;
  Future<void> Function()? _resumeAfterSearch;
  final _tried = <String>{};

  Future<void> disable() async {
    automaticEnabled = false;
    beginManualSelection();
    status.value = '已关闭本视频自动字幕';
    // Hiding this episode's captions must not cancel the season the user
    // already chose to download. The season opt-out has its own cancellation.
    await _saved.disable();
  }

  Future<void> rememberNativeSelection(SubtitleTrack track) async {
    if (track.id == 'no') {
      await disable();
      return;
    }
    beginManualSelection();
    automaticEnabled = false;
    status.value = '已记住手动选择的片源字幕';
    await _saved.save(
      CinemaSavedSubtitle(
        nativeTrack: track.id,
        title: track.title ?? '',
        language: track.language ?? '',
      ),
    );
  }

  Future<void> setAutomaticEnabled(bool enabled) async {
    if (_closed) return;
    if (!enabled) {
      await disable();
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    _manual = false;
    _loaded = false;
    automaticEnabled = true;
    _client = null;
    _tried.clear();
    await _saved.clear();
    await load();
  }

  Future<void> rememberCurrent({bool align = true}) async {
    final inherit = await _primeSeasonFromCurrent();
    await _rememberFile(inheritToSeason: inherit);
    if (inherit) {
      await _cacheCurrentSeason();
      prefetchSeason();
    }
    if (align) _alignFresh();
  }

  /// Imported files and caches from older releases also seed a season search.
  /// Valid dialogue establishes the language; unknown release families are
  /// downloaded without transferring this file's timing to a different cut.
  Future<bool> _primeSeasonFromCurrent() async {
    final session = cinemaExternalSubtitleState(player);
    if (query.type != 'series' ||
        !session.active.value ||
        !cinemaSubtitleEpisodeMatches(
          session.title,
          query.season,
          query.episode,
        )) {
      return false;
    }
    var language = session.language;
    if (const ['', 'und', 'null'].contains(language)) {
      language = RegExp(r'[\u3400-\u9fff]').hasMatch(session.normalizedSubtitle)
          ? 'zh'
          : 'eng';
      session.language = language;
    }
    try {
      await preferences.remember(
        seriesIdentity: seriesIdentity,
        season: query.season,
        fromEpisode: query.episode,
        queryTitle: query.title,
        imdbId: imdbId,
        row: {
          'verified': true,
          'subtitleFileName': session.title,
          'lang': language,
          'provider': '已加载文件',
        },
        timing: session.timing.value,
      );
      _trackedFingerprint = session.fingerprint;
      return true;
    } on FormatException {
      return false;
    }
  }

  void _alignFresh() {
    final session = cinemaExternalSubtitleState(player);
    if (session.delay == 0 && session.timing.value.scale == 1) {
      unawaited(autoSync?.run() ?? Future<void>.value());
    }
  }

  void beginManualSelection() {
    autoSync?.cancel();
    _manual = true;
    _revision++;
    _inheritedTiming = null;
    _client?.close();
  }

  bool _current(int revision) => !_closed && !_manual && revision == _revision;

  Future<void> remember(CinemaOnlineSubtitleSelection selection) async {
    if (_closed) return;
    automaticEnabled = true;
    status.value = '已加载手动选择的字幕';
    final manualSession = cinemaExternalSubtitleState(player);
    manualSession.origin = 'manual';
    manualSession.sourceLabel.value =
        '手动搜索 · ${selection.row['provider'] ?? '在线字幕'}';
    final selected = selection.query;
    String canonical(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'[\s._\-:：·]+'), '');
    final sameTitle =
        canonical(selected.title) == canonical(query.title) ||
        (imdbId.isNotEmpty && selection.imdbId == imdbId);
    final sameEpisode =
        sameTitle &&
        selected.type == query.type &&
        selected.season == query.season &&
        selected.episode == query.episode;
    await _rememberFile(
      inheritToSeason: sameEpisode && selection.applyToSeason,
      seasonPrefetch: sameEpisode && selection.applyToSeason,
    );
    if (query.type != 'series' ||
        !sameTitle ||
        selected.type != 'series' ||
        selected.season != query.season ||
        selected.episode != query.episode) {
      _alignFresh();
      return;
    }
    final session = cinemaExternalSubtitleState(player);
    if (!selection.applyToSeason) {
      _trackedFingerprint = null;
      await preferences.clear(seriesIdentity, query.season);
      prefetch.cancel(seriesIdentity);
      _alignFresh();
      return;
    }
    await preferences.remember(
      seriesIdentity: seriesIdentity,
      season: query.season,
      fromEpisode: query.episode,
      queryTitle: selected.title,
      imdbId: selection.imdbId,
      row: selection.row,
      timing: session.timing.value,
    );
    _trackedFingerprint = session.fingerprint;
    final profile = preferences.read(seriesIdentity, query.season);
    if (profile != null) {
      await prefetch.rememberSource(seriesIdentity, profile, selection.row);
    }
    await _cacheCurrentSeason();
    prefetchSeason();
    _alignFresh();
  }

  void prefetchSeason({bool retry = false}) {
    final profile = preferences.read(seriesIdentity, query.season);
    if (query.type != 'series' || profile == null || seasonEpisodes.isEmpty) {
      return;
    }
    unawaited(
      prefetch
          .start(
            series: seriesIdentity,
            profile: profile,
            episodes: seasonEpisodes,
            currentEpisode: query.episode,
            clientFactory: prefetchClientFactory,
            retry: retry,
          )
          .catchError((Object _) {}),
    );
  }

  Future<void> _cacheCurrentSeason({bool inheritToSeason = true}) async {
    final profile = preferences.read(seriesIdentity, query.season);
    final session = cinemaExternalSubtitleState(player);
    if (profile == null || !session.active.value) return;
    try {
      await prefetch.cache(
        seriesIdentity,
        profile,
        query.episode,
        CinemaSavedSubtitle(
          text: session.normalizedSubtitle,
          origin: session.origin,
          sourceLabel: session.sourceLabel.value,
          workTitle: query.title,
          workType: query.type,
          title: session.title,
          language: session.language,
          timing: session.timing.value,
          inheritToSeason: inheritToSeason,
        ),
      );
    } catch (_) {
      // A background cache failure must not reject the selected subtitle.
      if (!_closed) status.value = '本集字幕已加载，整季缓存暂时无法写入';
    }
  }

  Future<void> load({void Function(String message)? onNotice}) async {
    if (_closed || _manual || _loaded) return;
    final revision = _revision;
    void notice(String message) {
      if (!_closed) status.value = message;
      onNotice?.call(message);
    }

    await preferences.flush();
    await flushCinemaSubtitleTiming(preferences.store);
    if (!_current(revision)) return;
    try {
      var saved = await _saved.read();
      if (saved != null &&
          saved.nativeTrack == null &&
          !saved.disabled &&
          !cinemaSavedSubtitleMatches(saved, query)) {
        saved = null;
        notice('已忽略与本片不符的旧字幕，正在重新检查');
      }
      if (!_current(revision)) return;
      if (saved?.disabled == true) {
        automaticEnabled = false;
        try {
          await player.setSubtitleTrack(SubtitleTrack.no());
        } catch (_) {
          /* A failed backend must never resurrect a disabled cache. */
        }
        notice('已记住本视频关闭字幕');
        _loaded = true;
        return;
      }
      if (saved?.nativeTrack != null) {
        final candidates = player.state.tracks.subtitle.where(
          (track) => !['no', 'auto'].contains(track.id),
        );
        final matches = candidates
            .where(
              (track) =>
                  track.title == saved!.title &&
                  track.language == saved.language,
            )
            .toList();
        final track = saved!.nativeTrack == 'auto'
            ? SubtitleTrack.auto()
            : matches.isNotEmpty
            ? matches.first
            : candidates
                  .where((track) => track.id == saved!.nativeTrack)
                  .firstOrNull;
        if (track != null) {
          await player.setSubtitleTrack(track);
          if (!_current(revision)) return;
          _loaded = true;
          automaticEnabled = false;
          notice('已恢复手动选择的片源字幕');
          return;
        }
      }
      if (saved != null && saved.nativeTrack == null) {
        _inheritedTiming = saved.timing;
        try {
          await _apply(
            player,
            saved.text,
            title: saved.title,
            language: saved.language,
            isCurrent: () => _current(revision),
          );
        } finally {
          _inheritedTiming = null;
        }
        if (!_current(revision)) return;
        final restored = cinemaExternalSubtitleState(player);
        restored.origin = saved.origin;
        restored.sourceLabel.value = saved.sourceLabel;
        _loaded = true;
        if (saved.inheritToSeason) {
          final profile = preferences.read(seriesIdentity, query.season);
          final family =
              profile == null ||
              cinemaSeasonSubtitleFamilyMatches(profile, {
                'subtitleFileName': saved.title,
                'lang': saved.language,
                'verified': true,
                'releaseFormat': profile.releaseFormat,
              });
          _trackedFingerprint = family
              ? cinemaExternalSubtitleState(player).fingerprint
              : null;
          if (!family) await _rememberFile(inheritToSeason: false);
          prefetchSeason();
        } else if (saved.seasonPrefetch && query.type == 'series') {
          if (preferences.read(seriesIdentity, query.season) == null &&
              await _primeSeasonFromCurrent()) {
            await _rememberFile(inheritToSeason: true);
            await _cacheCurrentSeason();
          }
          prefetchSeason();
        }
        notice('已恢复本视频字幕及对齐设置');
        return;
      }
    } catch (_) {
      if (!_current(revision)) return;
      notice('已保存字幕未能恢复，可手动搜索或导入');
    }
    final cachedProfile = query.type == 'series'
        ? preferences.read(seriesIdentity, query.season)
        : null;
    if (query.type == 'series' && cachedProfile != null) {
      prefetchSeason();
      notice('正在读取本季字幕缓存，未完成时优先下载本集…');
      final cached = await prefetch.waitForEpisode(
        seriesIdentity,
        cachedProfile,
        query.episode,
      );
      if (!_current(revision)) return;
      if (cached != null) {
        _inheritedTiming = cached.timing;
        try {
          await _apply(
            player,
            cached.text,
            title: cached.title,
            language: cached.language,
            isCurrent: () => _current(revision),
          );
        } finally {
          _inheritedTiming = null;
        }
        if (!_current(revision)) return;
        final restored = cinemaExternalSubtitleState(player);
        restored.origin = 'automatic';
        restored.sourceLabel.value = '本季字幕缓存 · ${cached.sourceLabel}';
        _loaded = true;
        if (cached.inheritToSeason) {
          _trackedFingerprint = cinemaExternalSubtitleState(player).fingerprint;
        }
        await _rememberFile(inheritToSeason: cached.inheritToSeason);
        notice('已从本季缓存加载字幕及对齐设置');
        prefetchSeason();
        if (!cached.inheritToSeason) _alignFresh();
        return;
      }
    }
    // Built-in tracks take precedence over searching for another file.
    if (automateMissing) {
      final embedded = player.state.tracks.subtitle
          .where(
            (track) =>
                !['auto', 'no'].contains(track.id) &&
                !track.uri &&
                (!const {
                      'hdmv_pgs_subtitle',
                      'dvd_subtitle',
                      'dvb_subtitle',
                      'xsub',
                    }.contains(track.codec) ||
                    (player.platform is NativePlayer &&
                        player.platform!.configuration.libass)),
          )
          .toList();
      if (embedded.isNotEmpty) {
        final chinese = embedded
            .where(
              (track) =>
                  cinemaSubtitleLanguageMatches(track.language ?? '', 'zh') ||
                  RegExp(
                    r'中文|简体|繁体|中字|CHS|CHT',
                    caseSensitive: false,
                  ).hasMatch(track.title ?? ''),
            )
            .toList();
        final selected = chinese.isNotEmpty ? chinese.first : embedded.first;
        await player.setSubtitleTrack(selected);
        if (!_current(revision)) return;
        _loaded = true;
        notice(chinese.isNotEmpty ? '已选用片源内置中文字幕' : '片源已有字幕，保留内置轨道');
        return;
      }
      if (cachedProfile == null) {
        notice('正在检查画面字幕…');
        if (await cinemaHasBurnedChinese(
          player,
          isCurrent: () => _current(revision),
        )) {
          if (!_current(revision)) return;
          _loaded = true;
          notice('画面疑似已有中文字幕，已避免叠加；需要时可手动搜索');
          return;
        }
      }
    }
    if (!_current(revision)) return;
    await preferences.flush();
    if (!_current(revision)) return;
    final profile = query.type == 'series'
        ? preferences.read(seriesIdentity, query.season)
        : null;
    if (profile == null || !profile.appliesTo(query.episode)) {
      if (automateMissing) {
        await _loadMissing(revision, notice);
      } else {
        notice('尚未为本视频选择字幕，可手动搜索或导入');
      }
      return;
    }
    var resumeOwnedPause = player.state.playing;

    Future<void> resume() async {
      if (!resumeOwnedPause) return;
      resumeOwnedPause = false;
      if (_current(revision) &&
          (canResume?.call() ?? true) &&
          !player.state.playing) {
        try {
          await player.play();
        } catch (_) {
          // A closing or failing backend must not leak an async error.
        }
      }
    }

    _resumeAfterSearch = resume;
    final client = _client ??= CinemaOnlineSubtitles();
    Future<void> tryRows(List<Map<String, dynamic>> rows) {
      final previous = _attempt ?? Future<void>.value();
      late Future<void> pending;
      pending = previous
          .catchError((Object _) {})
          .then((_) async {
            if (_current(revision) && !_loaded) {
              await _loadRows(rows, profile, revision, notice);
            }
          })
          .whenComplete(() {
            if (identical(_attempt, pending)) _attempt = null;
          });
      _attempt = pending;
      return pending;
    }

    try {
      if (resumeOwnedPause) await player.pause();
      if (!_current(revision)) return;
      notice('正在自动匹配本集字幕，播放已暂停以保留对白位置');
      final result = await client.aggregate(
        profile.queryTitle,
        'series',
        imdbId: profile.imdbId,
        season: query.season,
        episode: query.episode,
        language: profile.language,
        mediaRelease: mediaRelease,
        onVerified: (rows) => unawaited(
          tryRows(
            rows
                .where((row) => cinemaSeasonSubtitleFamilyMatches(profile, row))
                .toList(),
          ),
        ),
      );
      await tryRows(result.rows);
      if (_current(revision) && !_loaded) {
        notice('本集暂无可自动加载的同语言字幕，可打开在线搜索重试');
      }
    } catch (_) {
      if (_current(revision) && !_loaded) {
        notice('本集自动字幕连接失败，可打开在线搜索重试');
      }
    } finally {
      await resume();
      _resumeAfterSearch = null;
    }
  }

  Future<void> _loadMissing(int revision, void Function(String) notice) async {
    if (query.title.trim().isEmpty) {
      notice('缺少片名，请手动搜索字幕');
      return;
    }
    final client = _client ??= CinemaOnlineSubtitles();
    notice('未检测到字幕，正在搜索中文优先字幕…');
    try {
      final result = await client.aggregate(
        query.title,
        query.type,
        imdbId: imdbId,
        year: year,
        season: query.season,
        episode: query.episode,
        language: 'zh-eng',
        mediaRelease: mediaRelease,
      );
      if (!_current(revision)) return;
      final rows = chooseCinemaAutomaticSubtitles(
        result.rows,
        query: query,
        mediaRelease: mediaRelease,
      );
      for (final row in rows.take(4)) {
        if (!_current(revision)) return;
        try {
          final text = await client.download(
            '${row['url']}',
            archiveEntry: row['archiveEntry'] as String?,
          );
          if (!_current(revision)) return;
          final session = cinemaExternalSubtitleState(player);
          if (session.active.value) return;
          await _apply(
            player,
            text,
            title: '${row['subtitleFileName'] ?? '自动字幕'}',
            language: '${row['lang']}',
            isCurrent: () => _current(revision),
          );
          if (!_current(revision)) return;
          session.origin = 'automatic';
          session.sourceLabel.value = '自动搜索 · ${row['provider'] ?? '在线字幕'}';
          _loaded = true;
          final inherit = query.type == 'series';
          if (inherit) {
            await preferences.remember(
              seriesIdentity: seriesIdentity,
              season: query.season,
              fromEpisode: query.episode,
              queryTitle: query.title,
              imdbId: imdbId,
              row: row,
              timing: session.timing.value,
            );
            final profile = preferences.read(seriesIdentity, query.season);
            if (profile != null) {
              await prefetch.rememberSource(seriesIdentity, profile, row);
            }
            _trackedFingerprint = session.fingerprint;
          }
          await _rememberFile(inheritToSeason: inherit);
          if (inherit) {
            await _cacheCurrentSeason();
            prefetchSeason();
          }
          notice(
            cinemaSubtitleLanguageMatches('${row['lang']}', 'zh')
                ? '已自动加载中文字幕 · ${row['provider'] ?? '在线字幕'}'
                : '暂无匹配中文，已加载英文字幕 · ${row['provider'] ?? '在线字幕'}',
          );
          // Saved/manual timing always wins over a fresh audio estimate.
          if (session.delay == 0 && session.timing.value.scale == 1) {
            unawaited(autoSync?.run() ?? Future<void>.value());
          }
          return;
        } catch (_) {
          /* Try the next verified exact-episode candidate. */
        }
      }
      if (_current(revision)) notice('暂无可用的匹配字幕，可手动搜索或导入');
    } catch (_) {
      if (_current(revision)) notice('自动字幕连接失败，可手动搜索重试');
    }
  }

  Future<void> _loadRows(
    List<Map<String, dynamic>> rows,
    CinemaSeasonSubtitleProfile profile,
    int revision,
    void Function(String)? onNotice,
  ) async {
    final candidates = List<Map<String, dynamic>>.of(rows);
    while (_current(revision) && !_loaded) {
      candidates.removeWhere(
        (row) => _tried.contains('${row['url']}|${row['archiveEntry']}'),
      );
      final row = chooseCinemaSeasonSubtitle(
        profile,
        candidates,
        season: query.season,
        episode: query.episode,
        playbackName: mediaRelease,
      );
      if (row == null) return;
      _tried.add('${row['url']}|${row['archiveEntry']}');
      try {
        final text = await _client!.download(
          '${row['url']}',
          archiveEntry: row['archiveEntry'] as String?,
        );
        if (!_current(revision)) return;
        final session = cinemaExternalSubtitleState(player);
        if (session.active.value) return;
        final family = cinemaSeasonSubtitleFamilyMatches(profile, row);
        _inheritedTiming = family
            ? preferences.read(seriesIdentity, query.season)?.timing ??
                  profile.timing
            : const CinemaSubtitleTiming();
        try {
          await _apply(
            player,
            text,
            title: '${row['subtitleFileName'] ?? '本季自动字幕'}',
            language: '${row['lang']}',
            isCurrent: () => _current(revision),
          );
        } finally {
          _inheritedTiming = null;
        }
        if (!_current(revision)) return;
        session.origin = 'automatic';
        session.sourceLabel.value = '本季自动匹配 · ${row['provider'] ?? '在线字幕'}';
        _loaded = true;
        _trackedFingerprint = family ? session.fingerprint : null;
        final saved = _rememberFile(inheritToSeason: family);
        await _resumeAfterSearch?.call();
        await saved;
        await _cacheCurrentSeason(inheritToSeason: family);
        prefetchSeason();
        if (!family) _alignFresh();
        onNotice?.call(
          family
              ? '本季字幕已自动加载，沿用对齐设置（${session.delay.toStringAsFixed(2)} 秒）'
              : '已加载本集字幕，版本不同，校准独立保存',
        );
      } catch (_) {
        // An unavailable candidate must not stop video or other subtitle rows.
      }
    }
  }

  Future<void> _rememberFile({
    required bool inheritToSeason,
    bool seasonPrefetch = true,
  }) async {
    final session = cinemaExternalSubtitleState(player);
    if (!session.active.value || session.normalizedSubtitle.isEmpty) return;
    await _saved.save(
      CinemaSavedSubtitle(
        text: session.normalizedSubtitle,
        origin: session.origin,
        sourceLabel: session.sourceLabel.value,
        workTitle: query.title,
        workType: query.type,
        title: session.title,
        language: session.language,
        timing: session.timing.value,
        inheritToSeason: inheritToSeason,
        seasonPrefetch: seasonPrefetch,
      ),
    );
  }

  Future<void> flush() async {
    await cinemaExternalSubtitleState(player).flush();
    await _saved.flush();
    await preferences.flush();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    autoSync?.cancel();
    _revision++;
    _client?.close();
    _inheritedTiming = null;
    _trackedFingerprint = null;
  }
}

/// Chinese first; only verified files from the exact episode query are eligible.
List<Map<String, dynamic>> chooseCinemaAutomaticSubtitles(
  List<Map<String, dynamic>> rows, {
  required CinemaSubtitleQuery query,
  String mediaRelease = '',
}) {
  final result = rows.where((row) {
    final language = '${row['lang'] ?? ''}';
    if (row['verified'] != true ||
        row['url'] is! String ||
        !(cinemaSubtitleLanguageMatches(language, 'zh') ||
            cinemaSubtitleLanguageMatches(language, 'eng'))) {
      return false;
    }
    if (!cinemaSubtitleCandidateMatches(row, query)) return false;
    if (query.type == 'series' &&
        !cinemaSubtitleEpisodeMatches(
          '${row['archiveEntry'] ?? row['subtitleFileName'] ?? ''}',
          query.season,
          query.episode,
        )) {
      return false;
    }
    return true;
  }).toList();
  int score(Map<String, dynamic> row) =>
      (cinemaSubtitleLanguageMatches('${row['lang']}', 'zh') ? 100000 : 0) +
      cinemaSubtitleReleaseScore(
            '${row['subtitleFileName']} ${row['releaseFormat']}',
            mediaRelease,
          ) *
          10 +
      (row['bilingual'] == true ? 5 : 0);
  result.sort((a, b) => score(b).compareTo(score(a)));
  return result;
}

/// Old releases could persist unrelated first search hits. Keep the file on
/// disk, but do not restore it as this work's subtitle. Explicit manual choices
/// in the new format remain under the user's control.
bool cinemaSavedSubtitleMatches(
  CinemaSavedSubtitle saved,
  CinemaSubtitleQuery query,
) {
  if (saved.origin == 'manual') return true;
  if (saved.workTitle.isNotEmpty) {
    return cinemaMediaTitleKey(saved.workTitle) ==
            cinemaMediaTitleKey(query.title) &&
        saved.workType == query.type &&
        !(query.type == 'movie' && cinemaExplicitSubtitleEpisode(saved.title));
  }
  return cinemaSubtitleCandidateMatches({
    'subtitleFileName': saved.title,
  }, query);
}
