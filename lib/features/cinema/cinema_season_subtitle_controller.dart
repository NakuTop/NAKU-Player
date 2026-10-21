import 'dart:async';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_online_subtitles.dart';
import 'cinema_season_subtitle_preferences.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_sync_preferences.dart';
import 'cinema_subtitle_timing.dart';

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
    this.mediaRelease = '',
    this.canResume,
    CinemaOnlineSubtitles? client,
    CinemaSeasonSubtitleApply? apply,
  }) : preferences = CinemaSeasonSubtitlePreferences(store),
       _client = client,
       _apply = apply ?? applyCinemaExternalSubtitle {
    bindCinemaSubtitleTiming(
      player,
      store,
      mediaIdentity,
      fallbackTiming: (_) => _inheritedTiming,
      onTimingSaved: (content, timing) async {
        if (!_closed && content == _trackedFingerprint) {
          await preferences.updateTiming(seriesIdentity, query.season, timing);
        }
      },
    );
  }

  final Player player;
  final String seriesIdentity, imdbId, mediaRelease;
  final CinemaSubtitleQuery query;
  final bool Function()? canResume;
  final CinemaSeasonSubtitlePreferences preferences;
  CinemaOnlineSubtitles? _client;
  final CinemaSeasonSubtitleApply _apply;
  CinemaSubtitleTiming? _inheritedTiming;
  String? _trackedFingerprint;
  int _revision = 0;
  bool _closed = false, _manual = false, _loaded = false;
  Future<void>? _attempt;
  Future<void> Function()? _resumeAfterSearch;
  final _tried = <String>{};

  void beginManualSelection() {
    _manual = true;
    _revision++;
    _inheritedTiming = null;
    _client?.close();
  }

  bool _current(int revision) => !_closed && !_manual && revision == _revision;

  Future<void> remember(CinemaOnlineSubtitleSelection selection) async {
    if (_closed || query.type != 'series') return;
    final selected = selection.query;
    String canonical(String text) =>
        text.toLowerCase().replaceAll(RegExp(r'[\s._\-:：·]+'), '');
    final sameTitle =
        canonical(selected.title) == canonical(query.title) ||
        (imdbId.isNotEmpty && selection.imdbId == imdbId);
    if (!sameTitle ||
        selected.type != 'series' ||
        selected.season != query.season ||
        selected.episode != query.episode) {
      return;
    }
    final session = cinemaExternalSubtitleState(player);
    if (!selection.applyToSeason) {
      _trackedFingerprint = null;
      await preferences.clear(seriesIdentity, query.season);
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
  }

  Future<void> load({void Function(String message)? onNotice}) async {
    if (_closed || _manual || _loaded || query.type != 'series') return;
    final revision = _revision;
    await preferences.flush();
    if (!_current(revision)) return;
    final profile = preferences.read(seriesIdentity, query.season);
    if (profile == null || !profile.appliesTo(query.episode)) return;
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
              await _loadRows(rows, profile, revision, onNotice);
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
      onNotice?.call('正在自动匹配本集字幕，播放已暂停以保留对白位置');
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
        onNotice?.call('本集暂无可自动加载的同语言字幕，可打开在线搜索重试');
      }
    } catch (_) {
      if (_current(revision) && !_loaded) {
        onNotice?.call('本集自动字幕连接失败，可打开在线搜索重试');
      }
    } finally {
      await resume();
      _resumeAfterSearch = null;
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
        _inheritedTiming =
            preferences.read(seriesIdentity, query.season)?.timing ??
            profile.timing;
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
        _loaded = true;
        _trackedFingerprint = session.fingerprint;
        await _resumeAfterSearch?.call();
        onNotice?.call(
          '本季字幕已自动加载，沿用对齐设置（${session.delay.toStringAsFixed(2)} 秒）',
        );
      } catch (_) {
        // An unavailable candidate must not stop video or other subtitle rows.
      }
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _revision++;
    _client?.close();
    _inheritedTiming = null;
    _trackedFingerprint = null;
  }
}
