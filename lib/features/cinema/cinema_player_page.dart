import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'cinema_playback_buffer.dart';
import 'cinema_tv_background_policy.dart';
import 'cinema_buffer_status.dart';
import 'cinema_homepod_player_route.dart';
import 'cinema_keyboard_transport.dart';
import 'cinema_subtitle_auto_sync.dart';
import 'cinema_danmaku.dart';
import 'cinema_logvar_client.dart';
import 'cinema_playback_recovery.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:kazumi/services/platform/naku_device.dart';
import 'package:kazumi/services/platform/desktop_fullscreen.dart';
import 'cinema_lan_cast.dart';
import 'package:kazumi/features/cinema/naku_update_service.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';
import 'package:kazumi/services/player/playback_quality.dart';
import 'cinema_quality_sheet.dart';
import 'cinema_tracks_sheet.dart';
import 'cinema_subtitle_appearance.dart';
import 'cinema_online_subtitles.dart';
import 'cinema_live_subtitles.dart';
import 'cinema_tv_native_player.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_season_subtitle_controller.dart';
import 'cinema_mobile_playback_bar.dart';
import 'cinema_media_cache.dart';
import 'cinema_media_transport.dart';
import 'cinema_media_routing.dart';
import 'cinema_route_probe.dart';
import 'cinema_source_priority.dart';
import 'cinema_source_health.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:kazumi/services/player/playback_lifecycle.dart';
import 'dart:async';
import 'dart:io';
import 'cinema_download_sheet.dart';
import 'cinema_media_source.dart';
import 'cinema_nas_media.dart';
import 'cinema_nas_playback.dart';
import 'cinema_rating_identity_search.dart';
import 'cinema_search_discovery.dart';
export 'cinema_media_source.dart' show cinemaUsesDirectMedia;
import 'package:kazumi/services/player/native_playback_setup.dart';
import 'package:kazumi/request/core/network_config.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/storage/storage.dart';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/pages/player/player_keyboard_shortcuts.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/desktop_window_close.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:kazumi/services/player/player_error_mapper.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';
import 'package:kazumi/services/video_source/webview_video_source_service.dart';

import 'cinema_models.dart';
import 'cinema_ratings.dart';
import 'cinema_ratings_panel.dart';
import 'cinema_douban_reviews.dart';
import 'cinema_theme.dart';
import 'cinema_work_sources.dart';
import 'cinema_watch_together.dart';
import 'cinema_sync_sheet.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'package:kazumi/services/shaders/shader_asset_service.dart';
import 'package:kazumi/pages/player/controller/player_super_resolution.dart';
import 'package:kazumi/utils/constants.dart';
import 'package:kazumi/utils/media.dart';
import 'cinema_playback_candidates.dart';
import 'cinema_repository.dart';
import 'cinema_store.dart';
import 'cinema_player_preferences.dart';
import 'cinema_video_gestures.dart';
import 'cinema_player_entrance.dart';
import 'cinema_tv_player_controls.dart';
import 'cinema_tv_media_policy.dart';
import 'cinema_tv_session.dart';
import 'cinema_optical_glass.dart';
import 'cinema_pane_transition.dart';

/// Locate the saved episode in a fresh catalogue without trusting old indexes.
({int routeIndex, int episodeIndex})? cinemaResumeSelection(
  CinemaTitle current,
  CinemaHistory saved,
) {
  if (current.key != saved.title.key ||
      saved.routeIndex < 0 ||
      saved.routeIndex >= saved.title.routes.length) {
    return null;
  }
  final oldRoute = saved.title.routes[saved.routeIndex];
  if (saved.episodeIndex < 0 ||
      saved.episodeIndex >= oldRoute.episodes.length) {
    return null;
  }
  final oldEpisode = oldRoute.episodes[saved.episodeIndex];
  final byUrl = <({int routeIndex, int episodeIndex})>[];
  final byName = <({int routeIndex, int episodeIndex})>[];
  for (var route = 0; route < current.routes.length; route++) {
    for (
      var episode = 0;
      episode < current.routes[route].episodes.length;
      episode++
    ) {
      final candidate = current.routes[route].episodes[episode];
      final selection = (routeIndex: route, episodeIndex: episode);
      if (oldEpisode.url.isNotEmpty && candidate.url == oldEpisode.url) {
        byUrl.add(selection);
      }
      if (oldRoute.name.trim().isNotEmpty &&
          oldEpisode.name.trim().isNotEmpty &&
          current.routes[route].name.trim() == oldRoute.name.trim() &&
          candidate.name.trim() == oldEpisode.name.trim()) {
        byName.add(selection);
      }
    }
  }
  if (byUrl.isNotEmpty) {
    // Identical media can appear in multiple routes; retain the old label
    // where possible, while allowing it to move to another route.
    return byUrl
            .where(
              (selection) =>
                  current.routes[selection.routeIndex].name == oldRoute.name,
            )
            .firstOrNull ??
        byUrl.first;
  }
  // Rotating signed links can change URL. Names are safe only if unambiguous.
  return byName.length == 1 ? byName.single : null;
}

/// Resume only the same source, title and media the user selected.
int cinemaResumePosition(
  CinemaTitle title,
  CinemaHistory? history,
  int routeIndex,
  int episodeIndex,
) {
  if (history == null || history.positionSeconds <= 0) {
    return 0;
  }
  final selection = cinemaResumeSelection(title, history);
  if (selection == null ||
      selection.routeIndex != routeIndex ||
      selection.episodeIndex != episodeIndex) {
    return 0;
  }
  if (history.durationSeconds > 0 &&
      history.positionSeconds >= history.durationSeconds - 8) {
    return 0;
  }
  return history.positionSeconds;
}

/// Route changes may carry a position only to one unambiguous matching episode.
({int episodeIndex, int positionSeconds})? cinemaRouteSwitchSelection({
  required CinemaEpisode currentEpisode,
  required CinemaRoute targetRoute,
  required int positionSeconds,
}) {
  final name = currentEpisode.name.trim();
  if (name.isEmpty) return null;
  final matches = <int>[];
  for (var index = 0; index < targetRoute.episodes.length; index++) {
    if (targetRoute.episodes[index].name.trim() == name) matches.add(index);
  }
  if (matches.length != 1) return null;
  return (
    episodeIndex: matches.single,
    positionSeconds: positionSeconds < 0 ? 0 : positionSeconds,
  );
}

/// Requires sustained lack of progress while playback is requested. Pausing,
/// seeking, resuming, and reaching the end all reset the observation window.
class CinemaPlaybackWatchdog {
  CinemaPlaybackWatchdog({this.timeout = const Duration(seconds: 30)});
  final Duration timeout;
  DateTime? _lastProgressAt;
  Duration? _lastPosition;
  bool _wasPlaying = false;

  void reset() {
    _lastProgressAt = null;
    _lastPosition = null;
    _wasPlaying = false;
  }

  bool sample({
    required DateTime now,
    required Duration position,
    required bool playing,
    required bool completed,
  }) {
    if (!playing || completed || !_wasPlaying || position != _lastPosition) {
      _lastProgressAt = now;
    }
    _lastPosition = position;
    _wasPlaying = playing && !completed;
    return _wasPlaying &&
        _lastProgressAt != null &&
        now.difference(_lastProgressAt!) >= timeout;
  }
}

/// A separate player identity and history namespace from upstream Bangumi.
class CinemaPlayerPage extends StatefulWidget {
  const CinemaPlayerPage({
    super.key,
    required this.title,
    required this.source,
    required this.store,
    this.routeIndex = 0,
    this.episodeIndex = 0,
    this.variants = const [],
    this.repository,
    this.watchTogether,
    this.ratingsRepository,
    this.reviewsRepository,
    this.onRecommendationSelected,
    this.preferences,
    this.windowControls,
    this.createPlayer,
    this.subtitleClientFactory,
    this.nasPlayback,
    this.resolveNASRatings,
    this.videoSurfaceBuilder,
    this.mobileControls,
    this.offlinePaths,
    this.initialPositionSeconds,
    this.mediaProbe,
    this.mediaCache,
    this.autoSelectBestRoute,
    this.backgroundPlaybackClock,
  });

  @visibleForTesting
  final bool? mobileControls;
  final CinemaNASPlaybackClient? nasPlayback;
  @visibleForTesting
  final Future<CinemaTitle> Function(CinemaTitle)? resolveNASRatings;
  final CinemaTitle title;
  final CinemaSource source;

  /// Original episode URLs mapped to verified local files, for offline-only use.
  final Map<String, String>? offlinePaths;
  final CinemaStore store;
  final int routeIndex;
  final int episodeIndex;
  final int? initialPositionSeconds;
  @visibleForTesting
  final CinemaMediaProbe? mediaProbe;
  @visibleForTesting
  final CinemaMediaCache? mediaCache;
  @visibleForTesting
  final bool? autoSelectBestRoute;
  @visibleForTesting
  final Duration Function()? backgroundPlaybackClock;
  final List<CinemaTitle> variants;
  final CinemaRepository? repository;
  final CinemaWatchTogether? watchTogether;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaDoubanReviewsRepository? reviewsRepository;
  final ValueChanged<DoubanRecommendation>? onRecommendationSelected;
  @visibleForTesting
  final CinemaPlayerPreferences? preferences;
  final DesktopWindowControls? windowControls;
  @visibleForTesting
  final Player Function(PlayerConfiguration configuration)? createPlayer;
  @visibleForTesting
  final CinemaOnlineSubtitles Function()? subtitleClientFactory;
  @visibleForTesting
  final Widget Function(BuildContext context, Player player)?
  videoSurfaceBuilder;

  @override
  State<CinemaPlayerPage> createState() => _CinemaPlayerPageState();
}

class _CinemaPlayerPageState extends State<CinemaPlayerPage>
    with WidgetsBindingObserver, WindowListener {
  static Color get _background => CinemaTheme.background;
  static Color get _surface => CinemaTheme.surface;
  static const _line = CinemaTheme.border;
  static const _text = Color(0xFFF3EEE5);
  static const _muted = Color(0xFFA6A39C);
  static const _copper = CinemaTheme.copper;

  final _resolver = WebViewVideoSourceService();
  final _health = CinemaSourceHealth.instance;
  late final _cache = widget.mediaCache ?? CinemaMediaCache.instance;
  final Map<String, CinemaMediaProbeResult> _probeResults = {};
  final Map<String, Future<String>> _tvHlsPolicies = {};
  final _tvHlsRejected = <String>{}, _tvHlsCodecRejected = <String>{};
  String? _tvHlsSelectionKey, _tvHlsLastVariant, _tvHlsPreferred;
  int _tvHlsDowngrades = 0, _tvHlsUpgradeProbes = 0;
  bool _tvHlsUpgrading = false;
  late final _mediaProbe = widget.mediaProbe ?? CinemaMediaProbe();
  CancelToken? _routeProbeToken;
  CinemaPlaybackCandidate? _routeComparisonAnchor;
  int _probeCompleted = 0, _probeTotal = 0;
  bool _automaticProbePending = false, _autoBestRoute = true;
  bool _probingAutomatic = false;
  String? _probeStatus;
  final Set<String> _cacheBypass = {};
  final List<CancelToken> _probeTokens = [];
  bool _probingRoutes = false, _reverseEpisodes = false;
  Timer? _warmTimer;
  final _tvBackgroundPolicy = CinemaTVBackgroundPolicy();
  final _tvBackgroundWatch = Stopwatch()..start();
  final _tvBackgroundTokens = <CancelToken>{};
  bool _tvCurrentProbePending = false;
  Duration get _tvBackgroundNow =>
      widget.backgroundPlaybackClock?.call() ?? _tvBackgroundWatch.elapsed;

  bool _tvBackgroundAllowed(_CinemaPlayback playback) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return _tvBackgroundPolicy.update(
      now: _tvBackgroundNow,
      position: playback.position,
      bufferedUntil: playback.player.state.buffer,
      ready: playback.ready && !_loading && !_closing,
      playing: playback.player.state.playing,
      buffering: playback.player.state.buffering,
      foreground:
          !_backgroundPaused &&
          (lifecycle == null || lifecycle == AppLifecycleState.resumed),
      interacting: _tvSheetOpen || _tvTimeline.active || _tvHeldSeek != null,
      completed: playback.completed,
      rate: _rate,
    );
  }

  void _cancelTVBackground(String reason, {bool reset = false}) {
    if (!NakuDevice.isTV) return;
    if (reset) _tvBackgroundPolicy.reset();
    if (_probingRoutes &&
        _probingAutomatic &&
        _tvBackgroundTokens.contains(_routeProbeToken)) {
      // An interrupted optional comparison can retry after playback recovers.
      _automaticProbePending = _autoBestRoute;
    }
    for (final token in _tvBackgroundTokens.toList()) {
      token.cancel(reason);
    }
    _tvBackgroundTokens.clear();
    _playback?.cancelNextWarmup(reason);
    _playback?.cacheSession?.backgroundPrefetchAllowed = false;
  }

  void _syncTVBackground(_CinemaPlayback playback, int generation) {
    if (!NakuDevice.isTV ||
        !_isCurrent(generation) ||
        !identical(_playback, playback)) {
      return;
    }
    if (!_tvBackgroundAllowed(playback)) {
      _cancelTVBackground('当前播放需要带宽，暂停后台优化');
      return;
    }
    if (_tvBackgroundTokens.isNotEmpty || _probingRoutes) {
      playback.cacheSession?.backgroundPrefetchAllowed = false;
      return;
    }
    if (_automaticProbePending &&
        !_usesNASPlayback &&
        widget.offlinePaths == null) {
      _automaticProbePending = false;
      _tvCurrentProbePending = false; // The route batch includes this stream.
      unawaited(_probeRoutes(automatic: true));
      return;
    }
    if (_tvCurrentProbePending) {
      _tvCurrentProbePending = false;
      unawaited(_probeCurrent(playback, generation));
      return;
    }
    if (_usesNASPlayback) {
      unawaited(_considerTVNASUpgrade(playback, generation));
    } else {
      unawaited(_considerTVHlsUpgrade(playback, generation));
    }
    if (_tvBackgroundTokens.isEmpty &&
        !playback.warmedNext &&
        playback.position.inSeconds > 15) {
      unawaited(_warmNext(playback, generation));
    }
    playback.cacheSession?.backgroundPrefetchAllowed =
        _tvBackgroundTokens.isEmpty;
  }

  void _ownOptionalProbe(CancelToken token) {
    _probeTokens.add(token);
    if (NakuDevice.isTV) {
      _tvBackgroundTokens.add(token);
      _playback?.cacheSession?.backgroundPrefetchAllowed = false;
    }
  }

  void _releaseOptionalProbe(CancelToken token) {
    _probeTokens.remove(token);
    _tvBackgroundTokens.remove(token);
  }

  void _updateProbeDisplay(VoidCallback change) {
    if (NakuDevice.isTV && !_tvControlsVisible) {
      change(); // No hidden probe progress should rebuild a native SurfaceView.
    } else if (mounted && !_closing) {
      setState(change);
    }
  }

  Timer? _nasConnectionTimer;
  bool _checkingNASConnection = false;

  late CinemaTitle _title = widget.title;
  late CinemaSource _source = widget.source;
  late final CinemaPlaybackCatalogue _catalogue = CinemaPlaybackCatalogue(
    title: widget.title,
    source: widget.source,
    variants: widget.variants,
    sources: widget.store.sources,
    repository: widget.repository ?? CinemaRepository(),
  );
  CinemaFailoverAttempts _attempts = CinemaFailoverAttempts();
  final Set<String> _detailAttempts = {};
  CinemaPlaybackCandidate? _failoverAnchor;
  bool _preferredDiscoveryDone = false;
  final _preferredProbeFailures = <String>{};
  final _preferredResolved = <String, CinemaPreferredMedia>{};
  DateTime? _preferredResolvedAt;
  _CinemaPlayback? _playback;
  final _recovery = CinemaPlaybackRecovery();
  Timer? _recoveryTimer;
  Timer? _historyTimer;
  Timer? _loadTimer;
  int _generation = 0;
  Future<void>? _tvDecoderRetirement;
  int _routeIndex = 0;
  int _episodeIndex = 0;
  bool _requiresEpisodeSelection = false;
  ({String titleKey, int routeIndex, int episodeIndex, int positionSeconds})?
  _lastPlaybackProgress;
  bool _loading = true;
  bool _pendingPlayIntent = true;
  bool _queueingDownload = false;
  bool _closing = false;
  String _phase = '正在准备播放';
  String? _error;
  String? _historyError;
  String? _playbackNotice;
  double _rate = 1;
  double _volume = 100;
  double _audibleVolume = 100;
  bool _backgroundPaused = false;
  DesktopWindowControls get _windowControls =>
      widget.windowControls ?? DesktopWindowControls.instance;
  bool _manualPlaybackChanging = false;
  int _lifecycleRevision = 0;
  late final _preferences =
      widget.preferences ?? CinemaPlayerPreferences.read();
  late final _nasPlayback = widget.nasPlayback ?? CinemaNASPlaybackClient();
  late CinemaTitle _ratingsTitle = widget.title;
  CinemaNASPlaybackOptions? _nasOptions;
  String? _nasReference, _nasResolution;
  final _tvNASRejectedProfiles = <String>{};
  int _tvNASDowngrades = 0, _tvNASUpgradeProbes = 0;
  DateTime? _tvNASHealthySince, _tvNASLastProgress, _tvNASQualityChanged;
  bool _tvNASUpgrading = false;
  CinemaMediaProbe? _tvNASMediaProbe;
  CinemaMediaProbe get _nasProbe => _tvNASMediaProbe ??= CinemaMediaProbe(
    transport: CinemaMediaTransport.direct(),
  );
  int? _nasAudio, _nasSubtitle;
  final _playerFocus = FocusScopeNode(debugLabel: 'NAKU player');
  final _cinemaPageScroll = ScrollController();
  final _nativeEntranceKey = GlobalKey<CinemaPlayerEntranceState>();
  bool _exitCrtRequested = false, _allowPlayerPop = false;
  static const _startupSoundChannel = MethodChannel('naku/desktop-controls');
  static int _startupSoundSequence = DateTime.now().microsecondsSinceEpoch;
  int? _audibleEntranceGeneration, _audibleEntranceToken;

  void _playEntranceSound(int generation) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!_isCurrent(generation) ||
        !_usesMacCinemaLayout ||
        _volume <= 0 ||
        _windowControls.blocksPlayback ||
        _backgroundPaused ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed) ||
        _playback?.ready != true ||
        _playback?.firstFrameRendered != true) {
      return;
    }
    _audibleEntranceGeneration = generation;
    final soundToken = ++_startupSoundSequence;
    _audibleEntranceToken = soundToken;
    unawaited(() async {
      try {
        await _startupSoundChannel.invokeMethod<bool>(
          'playCinemaStartupSound',
          {'generation': soundToken, 'volume': (_volume / 100).clamp(0, .25)},
        );
      } catch (_) {
        // Audio decoration must never delay or fail the actual media reveal.
      }
    }());
  }

  void _stopEntranceSound([int? generation]) {
    final audible = _audibleEntranceGeneration;
    if (audible == null || (generation != null && audible != generation)) {
      return;
    }
    _audibleEntranceGeneration = null;
    final soundToken = _audibleEntranceToken;
    _audibleEntranceToken = null;
    unawaited(() async {
      try {
        await _startupSoundChannel.invokeMethod<void>(
          'stopCinemaStartupSound',
          {'generation': soundToken},
        );
      } catch (_) {}
    }());
  }

  bool get _usesMacCinemaLayout =>
      defaultTargetPlatform == TargetPlatform.macOS &&
      !NakuDevice.isTV &&
      widget.mobileControls != true &&
      MediaQuery.sizeOf(context).width >= 980;
  Timer? _volumeSaveTimer;
  final _volumePersistence = CinemaVolumePersistence();
  bool _pip = false, _pipChanging = false;
  Completer<void>? _pipTransition;
  bool _fullscreen = false, _fullscreenChanging = false;
  // Keep the existing native video output alive across fullscreen/PiP layouts.
  final _videoSurfaceKey = GlobalKey(debugLabel: 'cinema-video-surface');
  bool _tvControlsVisible = true;
  bool _tvSheetOpen = false;
  ({int generation, String message, CinemaPlaybackFailure failure})?
  _tvDeferredFailure;
  final _tvTimeline = CinemaTVSeekPreview();
  final _tvTimelineFocus = FocusNode(debugLabel: 'TV timeline');
  final _tvPlayFocus = FocusNode(debugLabel: 'TV play');
  final _tvEpisodeFocus = FocusNode(debugLabel: 'TV episodes');
  final _tvSubtitleFocus = FocusNode(debugLabel: 'TV subtitles');
  final _tvDanmakuFocus = FocusNode(debugLabel: 'TV danmaku');
  Duration? _tvHeldSeek;
  LogicalKeyboardKey? _tvHeldDirection;
  bool _androidPip = false;
  Timer? _tvControlsTimer;
  void _scheduleTVControlsHide() {
    _tvControlsTimer?.cancel();
    if (!NakuDevice.isTV ||
        _tvSheetOpen ||
        _tvTimeline.active ||
        _loading ||
        _error != null ||
        _playback?.player.state.playing != true) {
      return;
    }
    _tvControlsTimer = Timer(const Duration(seconds: 5), () {
      if (mounted &&
          NakuDevice.isTV &&
          ModalRoute.of(context)?.isCurrent == true) {
        setState(() => _tvControlsVisible = false);
        _playerFocus.requestFocus();
      }
    });
  }

  KeyEventResult _tvRemoteKey(KeyEvent event) {
    if (!NakuDevice.isTV ||
        _closing ||
        _tvSheetOpen ||
        ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (_tvHeldDirection == key) {
        final target = _tvHeldSeek;
        _tvHeldDirection = null;
        if (target != null) {
          setState(() => _tvHeldSeek = null);
          _seekTV(target);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_tvControlsVisible) {
      if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
        if (event is KeyDownEvent) unawaited(_togglePlayback());
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight) {
        final playback = _playback;
        if (playback?.ready != true) return KeyEventResult.handled;
        _tvHeldDirection = key;
        final seconds = key == LogicalKeyboardKey.arrowLeft ? -10 : 10;
        if (event is KeyRepeatEvent) {
          setState(
            () => _tvHeldSeek = Duration(
              seconds:
                  ((_tvHeldSeek ?? playback!.position).inSeconds + seconds * 3)
                      .clamp(0, playback!.duration.inSeconds),
            ),
          );
        } else {
          _seekBy(seconds);
        }
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp ||
          key == LogicalKeyboardKey.arrowDown) {
        _showTVControls();
        return KeyEventResult.handled;
      }
    }
    _scheduleTVControlsHide();
    return KeyEventResult.ignored;
  }

  Completer<void>? _fullscreenTransition;
  final _panelRevision = ValueNotifier<int>(0);

  void _syncTVActivity() {
    if (!NakuDevice.isTV) return;
    final playback = _playback;
    CinemaTVPlaybackActivity.instance.setWatching(
      this,
      !_closing &&
          !_backgroundPaused &&
          _error == null &&
          (playback?.completed != true) &&
          ((_loading && _pendingPlayIntent) ||
              (playback != null &&
                  (playback.player.state.playing ||
                      playback.player.state.buffering &&
                          !_tvSheetOpen &&
                          _pendingPlayIntent))),
    );
  }

  void _showTVControls() {
    if (!mounted || _closing) return;
    setState(() => _tvControlsVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tvSheetOpen) _tvPlayFocus.requestFocus();
    });
    _scheduleTVControlsHide();
  }

  void _seekTV(Duration target) {
    final playback = _playback;
    if (playback == null || !playback.ready) return;
    playback.watchdog.reset();
    _cancelTVBackground('用户正在定位播放进度', reset: true);
    unawaited(playback.player.seek(target));
  }

  Future<void> _showTVAction(
    Future<void> Function() open,
    FocusNode restore,
  ) async {
    if (_tvSheetOpen) return;
    _tvSheetOpen = true;
    _cancelTVBackground('正在操作播放面板', reset: true);
    _tvControlsTimer?.cancel();
    try {
      await open();
    } finally {
      _tvSheetOpen = false;
      if (mounted && !_closing) {
        _pendingPlayIntent = _playback?.player.state.playing ?? false;
        setState(() => _tvControlsVisible = true);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_closing) restore.requestFocus();
        });
        _scheduleTVControlsHide();
        final deferred = _tvDeferredFailure;
        _tvDeferredFailure = null;
        if (deferred != null) {
          _fail(
            deferred.generation,
            deferred.message,
            failure: deferred.failure,
          );
        }
      }
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    // The route sheet shares this live state, including automatic source changes.
    _panelRevision.value++;
    _syncTVActivity();
  }

  Future<void> _setFullscreen(bool next) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        next || NakuDevice.isTV
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      );
      if (!NakuDevice.isTV) {
        await SystemChrome.setPreferredOrientations(
          next
              ? [
                  DeviceOrientation.landscapeLeft,
                  DeviceOrientation.landscapeRight,
                ]
              : DeviceOrientation.values,
        );
      }
      if (mounted) setState(() => _fullscreen = next);
      return;
    }
    if (await DesktopFullscreen.isFullScreen() == next) {
      if (mounted && !_closing) setState(() => _fullscreen = next);
      return;
    }
    if (defaultTargetPlatform != TargetPlatform.macOS) {
      await DesktopFullscreen.setFullScreen(next);
      if (mounted && !_closing) setState(() => _fullscreen = next);
      return;
    }
    final transition = Completer<void>();
    _fullscreenTransition = transition;
    await DesktopFullscreen.setFullScreen(next);
    // AppKit returns from toggleFullScreen before its window animation ends.
    // Wait for the actual transition before PiP reads or changes window bounds.
    try {
      await transition.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (await DesktopFullscreen.isFullScreen() != next) rethrow;
    } finally {
      if (identical(_fullscreenTransition, transition)) {
        _fullscreenTransition = null;
      }
    }
    if (mounted && !_closing) setState(() => _fullscreen = next);
  }

  Future<void> _toggleFullscreen() async {
    if (_fullscreenChanging) return;
    _fullscreenChanging = true;
    try {
      if (_pip) await _togglePip();
      await _setFullscreen(!_fullscreen);
    } finally {
      _fullscreenChanging = false;
    }
  }

  void _fullscreenChanged(bool value) {
    final transition = _fullscreenTransition;
    if (transition != null && !transition.isCompleted) transition.complete();
    if (mounted && !_closing && _fullscreen != value) {
      setState(() => _fullscreen = value);
    }
  }

  @override
  void onWindowEnterFullScreen() => _fullscreenChanged(true);

  @override
  void onWindowLeaveFullScreen() => _fullscreenChanged(false);

  Future<void> _showEpisodes() {
    if (NakuDevice.isTV) {
      final episodes = _route?.episodes ?? const <CinemaEpisode>[];
      if (episodes.isEmpty) return Future.value();
      return showDialog<void>(
        context: context,
        builder: (dialog) => Dialog(
          backgroundColor: Colors.transparent,
          alignment: Alignment.centerRight,
          insetPadding: const EdgeInsets.all(24),
          child: SizedBox(
            width: (MediaQuery.sizeOf(dialog).width * .44).clamp(360, 640),
            height: MediaQuery.sizeOf(dialog).height * .86,
            child: CinemaOpticalGlass(
              opacity: .88,
              padding: const EdgeInsets.all(24),
              child: CinemaPaneTransition(
                destination: 'tv-episodes',
                child: CinemaTVEpisodePicker(
                  labels: episodes.map((e) => e.name).toList(),
                  current: _episodeIndex,
                  onSelected: (index) {
                    Navigator.pop(dialog);
                    unawaited(
                      _playEpisode(_routeIndex, index, playWhenReady: true),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
    }
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 820),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * .78,
        child: ValueListenableBuilder<int>(
          valueListenable: _panelRevision,
          builder: (_, _, _) => _episodePanel(),
        ),
      ),
    );
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(_title);
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '收藏未保存，请检查磁盘空间后重试。');
      }
    }
  }

  Rect? _windowBounds;
  bool _windowWasOnTop = false;
  SuperResolutionMode _superResolution = SuperResolutionMode.off;
  final _shaders = ShaderAssetService();
  Future<void>? _shaderReady;
  Future<void>? _discovering;
  late final _together = widget.watchTogether ?? CinemaWatchTogether.instance;
  final _syncOwner = Object();

  void _bindTogether() => _together.bindPlayback(
    owner: _syncOwner,
    closePlayback: _leave,
    position: () => _playback?.position ?? Duration.zero,
    duration: () => _playback?.duration ?? Duration.zero,
    playing: () => _playback?.player.state.playing ?? false,
    buffering: () => _loading || (_playback?.player.state.buffering ?? false),
    ready: () => _playback?.ready ?? false,
    playbackRate: () => _rate,
    applyRemote: (position, playing) async {
      final playback = _playback;
      if (playback == null || !playback.ready) return;
      playback.watchdog.reset();
      if ((playback.position - position).inMilliseconds.abs() > 1500) {
        _cancelTVBackground('同步播放正在定位进度', reset: true);
        await playback.player.seek(position);
      }
      if (!identical(playback, _playback)) return;
      if (playing && !_backgroundPaused && !_windowControls.blocksPlayback) {
        await playback.player.play();
      } else {
        await playback.player.pause();
      }
    },
  );

  Future<void> _discoverRoutes() async {
    if (widget.offlinePaths != null || widget.source.id == cinemaNASSource.id) {
      return;
    }
    await for (final variants in discoverCinemaWorkSources(
      anchor: widget.title,
      known: widget.variants,
      sources: _health
          .available(widget.store.enabledSources)
          .where(
            (source) =>
                !_preferredDiscoveryDone || !cinemaPrefersSource(source),
          ),
      repository: widget.repository ?? CinemaRepository(),
      isCurrent: () => mounted && !_closing,
    )) {
      if (!mounted || _closing) return;
      setState(() => _catalogue.addVariants(variants));
    }
    final unread = _catalogue.unread.toList();
    for (var i = 0; i < unread.length && mounted && !_closing; i += 3) {
      await Future.wait(
        unread.skip(i).take(3).map((v) async {
          try {
            await _catalogue.load(v);
          } catch (_) {}
        }),
      );
      if (mounted && !_closing) setState(() {});
    }
  }

  Future<void> _loadPreferredVariants(
    CinemaPlaybackCandidate anchor,
    int generation,
    CancelToken cancel,
  ) async {
    if (_preferredDiscoveryDone) return;
    final sources = widget.store.enabledSources
        .where(cinemaPrefersSource)
        .toList();
    if (cinemaPrefersSource(widget.source) &&
        !sources.any((s) => s.id == widget.source.id)) {
      sources.add(widget.source);
    }
    if (sources.isEmpty) return;
    final end = DateTime.now().add(const Duration(seconds: 10));
    bool current() => _isCurrent(generation) && !cancel.isCancelled;
    if (!_catalogue.variants.any(
      (v) => cinemaPrefersSource(_catalogue.sourceFor(v)),
    )) {
      try {
        await for (final variants in discoverCinemaWorkSources(
          anchor: anchor.title,
          known: _catalogue.variants,
          sources: sources,
          repository: widget.repository ?? CinemaRepository(),
          isCurrent: current,
          maxDuration: const Duration(seconds: 8),
        )) {
          if (!current()) return;
          _catalogue.addVariants(variants);
        }
      } catch (_) {}
    }
    if (!current()) return;
    final unread = _catalogue.variants
        .where(
          (v) =>
              cinemaPrefersSource(_catalogue.sourceFor(v)) &&
              _catalogue.loaded(v) == null,
        )
        .take(3)
        .toList();
    await Future.wait(
      unread.map((variant) async {
        final remaining = end.difference(DateTime.now());
        if (remaining <= Duration.zero || !current()) return;
        try {
          await Future.any<Object?>([
            _catalogue.load(variant, retry: true).timeout(remaining),
            cancel.whenCancel.then((_) => null),
          ]);
        } catch (_) {}
      }),
    );
    if (current()) _preferredDiscoveryDone = true;
  }

  Future<CinemaPreferredMedia> _resolvePreferred(
    CinemaPlaybackCandidate candidate,
  ) => resolveCinemaMedia(
    source: candidate.source,
    route: candidate.route,
    episode: candidate.episode,
    resolve: (url, legacy) => _resolver.resolve(url, useLegacyParser: legacy),
  );

  Future<void> _startInitialPlayback({int? resumeAt}) async {
    final anchor = _selection;
    final offset =
        resumeAt ??
        widget.initialPositionSeconds ??
        _positionForEpisode(_routeIndex, _episodeIndex);
    final usePriority =
        _autoBestRoute &&
        widget.offlinePaths == null &&
        anchor != null &&
        (cinemaPrefersSource(widget.source) ||
            widget.store.enabledSources.any(cinemaPrefersSource));
    if (!usePriority) {
      _discovering = _discoverRoutes();
      await _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: offset,
        initial: true,
      );
      return;
    }
    final generation = ++_generation, token = _routeProbeToken = CancelToken();
    setState(() {
      _phase = '正在优先检查巨量资源的两个播放端';
      _probingRoutes = _probingAutomatic = true;
      _routeComparisonAnchor = anchor;
    });
    try {
      if (Platform.isMacOS && widget.createPlayer == null) {
        await MacOSSystemProxy.initialize();
        if (!_isCurrent(generation) || token.isCancelled) return;
      }
      await _loadPreferredVariants(anchor, generation, token);
      if (!_isCurrent(generation) || token.isCancelled) return;
      if (NakuDevice.isTV) await CinemaTVMediaEnvironment.instance.refresh();
      if (!_isCurrent(generation) || token.isCancelled) return;
      final measured = await CinemaPreferredRouteProbe(_mediaProbe).run(
        _catalogue.matching(anchor),
        resolve: _resolvePreferred,
        cancel: token,
      );
      if (!_isCurrent(generation) || token.isCancelled) return;
      for (final measurement in measured.measurements) {
        _probeResults[measurement.candidate.key] = measurement.result;
        if (!measurement.usable ||
            NakuDevice.isTV &&
                !CinemaTVMediaEnvironment.instance.supports(
                  measurement.result,
                )) {
          _preferredProbeFailures.add(measurement.candidate.key);
        }
      }
      _preferredResolved.addAll(measured.resolved);
      _preferredResolvedAt = DateTime.now();
      final best = cinemaBestSourcePriorityRoute(
        measured.measurements,
        supported: NakuDevice.isTV
            ? CinemaTVMediaEnvironment.instance.supports
            : null,
      );
      _discovering = _discoverRoutes();
      if (best != null) {
        _automaticProbePending = false;
        final selected = best.candidate;
        await _playEpisode(
          selected.routeIndex,
          selected.episodeIndex,
          title: selected.title,
          source: selected.source,
          resumeAt: offset,
          initial: true,
          selectionNotice: '已选择巨量资源中更快的可用播放端',
        );
      } else if (!cinemaPrefersSource(anchor.source)) {
        await _playEpisode(
          anchor.routeIndex,
          anchor.episodeIndex,
          resumeAt: offset,
          initial: true,
        );
      } else {
        _failoverAnchor = anchor;
        _pendingPlayIntent = NakuDevice.isTV || _preferences.autoPlay;
        _lastPlaybackProgress = (
          titleKey: anchor.title.key,
          routeIndex: anchor.routeIndex,
          episodeIndex: anchor.episodeIndex,
          positionSeconds: offset,
        );
        await _advanceAfterFailure('巨量资源的两个播放端均未能加载');
      }
    } finally {
      if (identical(_routeProbeToken, token)) {
        _routeProbeToken = null;
        if (mounted && !_closing) setState(() => _probingRoutes = false);
      }
      if (mounted && !_closing && _discovering == null) {
        _discovering = _discoverRoutes();
      }
    }
  }

  Future<void> _togglePip() async {
    if (Platform.isAndroid) {
      setState(() => _androidPip = true);
      final entered = await PipUtils.enterAndroidPIPWindow(
        width: _playback?.width ?? 16,
        height: _playback?.height ?? 9,
      );
      if (mounted) setState(() => _androidPip = entered);
      return;
    }
    if (_pipChanging) return;
    _pipChanging = true;
    final transition = Completer<void>();
    _pipTransition = transition;
    try {
      if (!_pip) {
        if (await DesktopFullscreen.isFullScreen()) {
          await _setFullscreen(false);
        }
        _windowBounds = await windowManager.getBounds();
        _windowWasOnTop = await windowManager.isAlwaysOnTop();
        await windowManager.setMinimumSize(const Size(320, 180));
        await PipUtils.enterDesktopPIPWindow(
          width: _playback?.width ?? 16,
          height: _playback?.height ?? 9,
        );
        if (!mounted || _closing) {
          await _restoreWindow();
        } else {
          setState(() => _pip = true);
        }
      } else {
        await _restoreWindow();
        if (mounted) setState(() => _pip = false);
      }
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '暂时无法切换画中画');
      }
    } finally {
      _pipChanging = false;
      if (!transition.isCompleted) transition.complete();
      if (identical(_pipTransition, transition)) _pipTransition = null;
    }
  }

  Future<void> _restoreWindow() async {
    await windowManager.setAlwaysOnTop(_windowWasOnTop);
    await windowManager.setAspectRatio(0);
    await windowManager.setMinimumSize(const Size(800, 600));
    final bounds = _windowBounds;
    if (bounds != null) await windowManager.setBounds(bounds);
  }

  Future<void> _applyShader(
    SuperResolutionMode mode, {
    bool save = true,
  }) async {
    final playback = _playback;
    if (playback == null || !playback.ready) return;
    try {
      final native = playback.player.platform;
      if (native is! NativePlayer) throw StateError('Native player required');
      if (mode != SuperResolutionMode.off) {
        await (_shaderReady ??= _shaders.copyShadersToExternalDirectory());
      }
      if (!mounted || !identical(playback, _playback)) return;
      if (mode == SuperResolutionMode.off) {
        await native.command(['change-list', 'glsl-shaders', 'clr', '']);
      } else {
        final files = mode == SuperResolutionMode.efficiency
            ? mpvAnime4KShadersLite
            : mpvAnime4KShaders;
        for (final name in files) {
          if (!File('${_shaders.shadersDirectory.path}/$name').existsSync()) {
            throw StateError('Shader missing');
          }
        }
        await native.command([
          'change-list',
          'glsl-shaders',
          'set',
          buildShadersAbsolutePath(_shaders.shadersDirectory.path, files),
        ]);
      }
      if (mounted && identical(playback, _playback) && save) {
        setState(() => _superResolution = mode);
      }
    } catch (_) {
      if (mounted && identical(playback, _playback)) {
        setState(() => _superResolution = SuperResolutionMode.off);
        KazumiDialog.showToast(
          context: context,
          message: '当前渲染器无法启用超分辨率，已保留原始画面。',
        );
      }
    }
  }

  CinemaRoute? get _route =>
      _title.routes.isEmpty ? null : _title.routes[_routeIndex];
  CinemaEpisode? get _episode =>
      _requiresEpisodeSelection || _route == null || _route!.episodes.isEmpty
      ? null
      : _route!.episodes[_episodeIndex];
  bool get _hasNext =>
      !_requiresEpisodeSelection &&
      _route != null &&
      _episodeIndex + 1 < _route!.episodes.length;

  final _updatePlaybackLease = NakuPlaybackUpdateLease();

  @override
  void initState() {
    super.initState();
    _fullscreen = NakuDevice.isTV;
    if (Platform.isAndroid) {
      unawaited(
        PipUtils.setAndroidPIPInPlayerPage(true, supportsDanmaku: false),
      );
      const MethodChannel('com.predidit.kazumi/pip').setMethodCallHandler((
        call,
      ) async {
        if (!mounted) return;
        if (call.method == 'onModeChanged') {
          setState(
            () =>
                _androidPip = (call.arguments as Map?)?['isInPipMode'] == true,
          );
        }
        if (call.method == 'onAction') {
          final action = (call.arguments as Map?)?['action'];
          if (action == 'play_pause') await _togglePlayback();
          if (action == 'forward') _seekBy(10);
        }
      });
    }
    if (NakuDevice.isTV) {
      FocusManager.instance.addEarlyKeyEventHandler(_tvRemoteKey);
      _tvTimeline.addListener(() {
        if (_tvTimeline.active) _cancelTVBackground('正在预览播放进度', reset: true);
        _scheduleTVControlsHide();
      });
      _scheduleTVControlsHide();
    }
    unawaited(_updatePlaybackLease.start());
    _nasConnectionTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_checkNASConnection()),
    );
    unawaited(_resolveNASRatingIdentity());
    _rate = _preferences.rate;
    _volume = _preferences.initialVolume;
    _audibleVolume = _preferences.volume > 0 ? _preferences.volume : 100;
    _superResolution = _preferences.superResolution;
    _reverseEpisodes = widget.store.extras['reverseEpisodes'] == true;
    _autoBestRoute =
        _source.id != cinemaNASSource.id &&
        (widget.autoSelectBestRoute ??
            (NakuDevice.isTV || widget.store.extras['autoBestRoute'] != false));
    _automaticProbePending = _autoBestRoute && widget.offlinePaths == null;
    final cachePrefs = widget.store.extras['mediaCache'];
    if (cachePrefs is Map) {
      unawaited(_cache.configure(CinemaCachePreferences.parse(cachePrefs)));
    }

    DesktopExitTasks.instance.register(this, _saveBeforeApplicationExit);
    _windowControls.register(this, _windowVisibilityChanged);
    _bindTogether();
    unawaited(_together.initialize());
    WidgetsBinding.instance.addObserver(this);
    if (!Platform.isAndroid && !Platform.isIOS) windowManager.addListener(this);
    if (!Platform.isAndroid && !Platform.isIOS && !NakuDevice.isTV) {
      unawaited(
        DesktopFullscreen.isFullScreen().then((value) {
          if (mounted && !_closing) setState(() => _fullscreen = value);
        }),
      );
    }
    if (widget.title.routes.isEmpty) {
      _loading = false;
      _error = '这个片源没有返回可播放的线路，请返回并更换片源。';
      return;
    }
    _routeIndex = widget.routeIndex.clamp(0, widget.title.routes.length - 1);
    final episodes = _route!.episodes;
    _episodeIndex = episodes.isEmpty
        ? 0
        : widget.episodeIndex.clamp(0, episodes.length - 1);
    _historyTimer = Timer.periodic(
      Duration(seconds: NakuDevice.isTV ? 15 : 8),
      (_) {
        unawaited(_persistProgress());
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_startInitialPlayback());
      }
    });
  }

  bool _isCurrent(int generation) =>
      mounted && !_closing && generation == _generation;

  Future<void> _persistProgress([_CinemaPlayback? playback]) async {
    final current = playback ?? _playback;
    if (current == null || !current.ready) return;
    _lastPlaybackProgress = (
      titleKey: current.title.key,
      routeIndex: current.routeIndex,
      episodeIndex: current.episodeIndex,
      positionSeconds: current.completed ? 0 : current.position.inSeconds,
    );
    if (_preferences.privateMode) return;
    final progress = (
      position: current.position.inSeconds,
      duration: current.duration.inSeconds,
      completed: current.completed,
    );
    if (current.persistedProgress == progress) return;
    try {
      await widget.store.recordProgress(
        title: current.title,
        routeIndex: current.routeIndex,
        episodeIndex: current.episodeIndex,
        positionSeconds: progress.position,
        durationSeconds: progress.duration,
      );
      current.persistedProgress = progress;
      if (mounted && _historyError != null) {
        setState(() => _historyError = null);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _historyError = '本次进度未保存，请检查可用磁盘空间。');
      }
    }
  }

  Future<void> _playEpisode(
    int routeIndex,
    int episodeIndex, {
    int? resumeAt,
    CinemaTitle? title,
    CinemaSource? source,
    bool automatic = false,
    bool initial = false,
    bool? playWhenReady,
    String? selectionNotice,
  }) async {
    final selectedTitle = title ?? _title;
    final selectedSource = source ?? _source;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _pendingPlayIntent =
        playWhenReady ??
        (automatic
            ? _pendingPlayIntent
            : NakuDevice.isTV && initial
            ? true
            : _preferences.autoPlay);
    if (_closing || selectedTitle.routes.isEmpty) return;
    final route = selectedTitle.routes[routeIndex];
    final offset =
        resumeAt ??
        _positionForEpisode(routeIndex, episodeIndex, title: selectedTitle);
    final watch = Stopwatch()..start();
    if (!automatic && !initial) _automaticProbePending = false;
    if (!automatic && !initial) _preferredProbeFailures.clear();
    _cancelTVBackground('播放选择已变化', reset: true);
    _tvCurrentProbePending = false;
    _cancelRouteProbe();
    _tvHlsPolicies.clear();
    _warmTimer?.cancel();
    for (final token in _probeTokens) {
      token.cancel('播放选择已变化');
    }
    _probeTokens.clear();
    final old = _playback;
    _stopEntranceSound();
    final generation = ++_generation;
    unawaited(_together.clearPlaybackMedia(_syncOwner));
    _resolver.cancel();
    _loadTimer?.cancel();
    _playback = null;
    if (old != null) {
      old.subtitles?.close();
      _volume = old.player.state.volume;
      unawaited(_persistProgress(old));
      final disposal = old.dispose();
      if (old.player is CinemaTVNativePlayer) {
        final previous = _tvDecoderRetirement;
        _tvDecoderRetirement = () async {
          try {
            await previous;
            await disposal;
          } catch (_) {
            // A failed old decoder must not retain ownership of the next one.
          }
        }();
      } else {
        unawaited(disposal);
      }
    }
    setState(() {
      _title = selectedTitle;
      _source = selectedSource;
      _routeIndex = routeIndex;
      _episodeIndex = route.episodes.isEmpty ? 0 : episodeIndex;
      _requiresEpisodeSelection = false;
      _loading = true;
      _error = null;
      _playbackNotice = null;
      _probeStatus = selectionNotice;
      _phase =
          selectionNotice ??
          (automatic
              ? '自动换源 · ${selectedSource.name} / ${route.name}'
              : '正在连接片源');
    });
    if (_cinemaPageScroll.hasClients) _cinemaPageScroll.jumpTo(0);
    if (route.episodes.isEmpty) {
      _fail(generation, '这条线路没有集数，请选择另一条线路。');
      return;
    }
    final episode = route.episodes[episodeIndex];
    final selection = CinemaPlaybackCandidate(
      title: selectedTitle,
      source: selectedSource,
      routeIndex: routeIndex,
      episodeIndex: episodeIndex,
    );
    if (_tvHlsSelectionKey != selection.key) {
      _tvHlsRejected.clear();
      _tvHlsCodecRejected.clear();
      _tvHlsDowngrades = 0;
      _tvHlsUpgradeProbes = 0;
      _tvHlsSelectionKey = selection.key;
      _tvHlsPreferred = null;
    }
    _tvHlsLastVariant = null;
    _tvDeferredFailure = null;
    _tvTimeline.cancel();
    _tvHeldSeek = null;
    _tvHeldDirection = null;
    if (!automatic) {
      _recovery.reset();
      _attempts = CinemaFailoverAttempts();
      _detailAttempts.clear();
      _failoverAnchor = selection;
    }
    _attempts.claim(selection);
    unawaited(_together.prepareMedia(_syncOwner, selectedTitle, episode));
    // Retain the intended position even if this route fails before becoming
    // ready. A subsequent route change can still continue the same episode.
    _lastPlaybackProgress = (
      titleKey: selectedTitle.key,
      routeIndex: routeIndex,
      episodeIndex: episodeIndex,
      positionSeconds: offset,
    );

    CinemaNASPlaybackSession? pendingNAS;
    try {
      if (Platform.isMacOS &&
          widget.createPlayer == null &&
          widget.offlinePaths == null &&
          !isNASMediaReference(episode.url)) {
        await MacOSSystemProxy.initialize();
        if (!_isCurrent(generation)) return;
      }
      final localFile = widget.offlinePaths?[episode.url];
      if (widget.offlinePaths != null &&
          (localFile == null || !await File(localFile).exists())) {
        throw const FormatException('本地视频不存在，请重新下载');
      }
      var mediaUrl = localFile == null
          ? episode.url
          : File(localFile).uri.toString();
      var mediaFormat = VideoSourceFormat.auto;
      Map<String, String> mediaHeaders = const {};
      final nas = localFile == null && isNASMediaReference(episode.url);
      if (nas) {
        setState(() => _phase = '正在准备 NAS 播放流');
        if (NakuDevice.isTV) await CinemaTVMediaEnvironment.instance.refresh();
        if (!_isCurrent(generation)) return;
        if (_nasReference != episode.url || _nasOptions == null) {
          final options = await _nasPlayback.options(episode.url);
          if (!_isCurrent(generation)) return;
          setState(() {
            _nasOptions = options;
            _nasReference = episode.url;
            _tvNASRejectedProfiles.clear();
            _tvNASDowngrades = 0;
            _tvNASUpgradeProbes = 0;
            _tvNASHealthySince = null;
            _tvNASLastProgress = null;
            _tvNASQualityChanged = null;
            _nasResolution = NakuDevice.isTV
                ? nasOriginalFileProfile
                : options.defaultProfile;
            _nasAudio = null;
            _nasSubtitle = -1;
          });
        }
        if (NakuDevice.isTV && _nasResolution == null) {
          throw const FormatException('NAS 未提供这台电视可解码的播放档位。');
        }
        if (_nasResolution != nasOriginalFileProfile) {
          pendingNAS = NakuDevice.isTV
              ? await _startTVNAS(episode.url, generation)
              : await _nasPlayback.start(
                  episode.url,
                  resolution: _nasResolution,
                  audio: _nasAudio,
                  subtitle: _nasSubtitle,
                );
          if (!_isCurrent(generation)) return;
          if (pendingNAS == null) return;
          mediaUrl = pendingNAS.url;
          mediaHeaders = pendingNAS.headers;
          mediaFormat = VideoSourceFormat.hls;
          _nasAudio = pendingNAS.audio;
          _nasSubtitle = pendingNAS.subtitle;
        }
      }
      if (localFile == null &&
          (!nas || _nasResolution == nasOriginalFileProfile)) {
        if (!cinemaUsesDirectMedia(selectedSource, route, episode)) {
          setState(() => _phase = '正在解析播放页面');
        }
        if (_preferredResolvedAt != null &&
            DateTime.now().difference(_preferredResolvedAt!) >
                const Duration(seconds: 30)) {
          _preferredResolved.clear();
        }
        final resolved =
            _preferredResolved.remove(selection.key) ??
            await resolveCinemaMedia(
              source: selectedSource,
              route: route,
              episode: episode,
              resolve: (url, legacy) => _resolver.resolve(
                url,
                useLegacyParser: legacy,
                offset: offset,
                timeout: const Duration(seconds: 25),
              ),
            );
        if (!_isCurrent(generation)) return;
        mediaUrl = resolved.url;
        mediaFormat = resolved.format;
        mediaHeaders = resolved.headers;
      }
      if (!_isCurrent(generation)) return;
      // Each selection owns a player. A late response from an old selection
      // cannot seek, stop, or reopen the player's newer selection.
      final candidate = _CinemaPlayback(
        selectedTitle,
        routeIndex,
        episodeIndex,
        generation,
        _preferences,
        widget.createPlayer,
      );
      candidate.keyboardTransport = CinemaKeyboardTransport(
        player: candidate.player,
        skipSeconds: _preferences.arrowSkipSeconds,
        forwardRate: _preferences.longPressRate,
        onSeek: candidate.watchdog.reset,
        canResume: () =>
            !_closing &&
            identical(_playback, candidate) &&
            !_backgroundPaused &&
            !_windowControls.blocksPlayback &&
            (_preferences.backgroundPlayback ||
                !const {
                  AppLifecycleState.hidden,
                  AppLifecycleState.paused,
                  AppLifecycleState.detached,
                }.contains(WidgetsBinding.instance.lifecycleState)),
        setTemporaryRate: (rate) async {
          if (identical(_playback, candidate)) {
            await _setRate(rate, temporary: true);
          } else {
            await candidate.player.setRate(rate);
          }
        },
      );
      final subtitlePlaybackRevision = candidate.manualPlaybackRevision;
      candidate.nasSession = pendingNAS;
      if (widget.createPlayer == null) {
        candidate.danmaku = CinemaDanmakuController(
          candidate.player,
          widget.store,
          '${selectedTitle.key}|${episode.url}',
          autoQuery: CinemaLogvarQuery.parse(
            selectedTitle.title,
            category: selectedTitle.category,
            episodeName: _subtitleNameForEpisode(episode),
            fallbackEpisode: episodeIndex + 1,
            year: selectedTitle.year,
          ),
        );
        candidate.subtitleAutoSync = CinemaSubtitleAutoSync(
          candidate.player,
          media: () => candidate.mediaUrl ?? '',
          sampleSeconds:
              widget.store.extras['subtitleSyncSampleSeconds'] is num &&
                  (widget.store.extras['subtitleSyncSampleSeconds'] as num)
                      .isFinite
              ? (widget.store.extras['subtitleSyncSampleSeconds'] as num)
                    .round()
                    .clamp(5, 20)
              : 5,
          onSampleSecondsChanged: (value) =>
              widget.store.setExtra('subtitleSyncSampleSeconds', value),
          headers: () => candidate.mediaHeaders,
        );
      }
      candidate.subtitles = CinemaSeasonSubtitleController(
        player: candidate.player,
        autoSync: candidate.subtitleAutoSync,
        client: widget.subtitleClientFactory?.call(),
        prefetchClientFactory: widget.subtitleClientFactory,
        seasonEpisodes: [
          for (var index = 0; index < route.episodes.length; index++)
            CinemaSubtitleQuery.parse(
              selectedTitle.title,
              category: selectedTitle.category,
              episodeName: _subtitleNameForEpisode(route.episodes[index]),
              fallbackEpisode: index + 1,
            ),
        ],
        store: widget.store,
        // The work opened by the user owns the season, across route changes.
        seriesIdentity: widget.title.key,
        mediaIdentity: '${selectedTitle.key}|${episode.url}',
        query: CinemaSubtitleQuery.parse(
          selectedTitle.title,
          category: selectedTitle.category,
          episodeName: _subtitleEpisodeName,
          fallbackEpisode: episodeIndex + 1,
        ),
        imdbId: selectedTitle.imdbId,
        year: selectedTitle.year,
        mediaRelease: _subtitleEpisodeName,
        canResume: () =>
            _isCurrent(generation) &&
            identical(_playback, candidate) &&
            !_backgroundPaused &&
            !_windowControls.blocksPlayback &&
            candidate.manualPlaybackRevision == subtitlePlaybackRevision,
      );
      pendingNAS = null;
      _playback = candidate;
      candidate.mediaUrl = mediaUrl;
      candidate.mediaHeaders = mediaHeaders;
      candidate.mediaFormat = mediaFormat;
      candidate.firstFrameWatch = watch;
      if (localFile == null &&
          !nas &&
          !_cacheBypass.contains(selection.key) &&
          widget.createPlayer == null) {
        try {
          final upstreamHeaders = Map<String, String>.unmodifiable(
            mediaHeaders,
          );
          final cached = await _cache.open(
            mediaUrl,
            upstreamHeaders,
            hls: mediaFormat == VideoSourceFormat.hls,
            titleKey: _preferences.privateMode ? null : candidate.title.key,
            backgroundPrefetchAllowed: !NakuDevice.isTV,
            manifestPolicy: NakuDevice.isTV
                ? (text, base) => _tvHlsPolicies.putIfAbsent(
                    '$base\n$text',
                    () => _chooseTVHlsManifest(
                      text,
                      base,
                      upstreamHeaders,
                      generation,
                    ),
                  )
                : null,
          );
          if (!_isCurrent(generation)) {
            await cached?.session.close();
            return;
          }
          if (cached != null) {
            candidate.cacheSession = cached.session;
            mediaUrl = cached.url;
            mediaHeaders = const {};
            mediaFormat = VideoSourceFormat.hls;
          }
        } catch (_) {
          /* Original URL remains usable if cache setup fails. */
        }
      }

      if (candidate.player is CinemaTVNativePlayer) {
        await _tvDecoderRetirement;
        if (!_isCurrent(generation)) return;
      }
      candidate.logStage('player-created');
      _listenTo(candidate, generation);
      setState(
        () => _phase = offset > 0
            ? '正在恢复到 ${_time(Duration(seconds: offset))}'
            : '正在加载视频',
      );
      _loadTimer = Timer(const Duration(seconds: 35), () {
        if (_isCurrent(generation) && !candidate.ready) {
          candidate.logStage('timeout(lastStage=${candidate.lastStage})');
          _fail(
            generation,
            '视频连接超时，请重试或更换线路。',
            failure: CinemaPlaybackFailure.transientNetwork,
          );
        }
      });
      await candidate.player.setVolume(_volume);
      if (!_isCurrent(generation)) return;
      candidate.logStage('volume-ready');
      await candidate.player.setRate(_rate);
      if (!_isCurrent(generation)) return;
      candidate.logStage('rate-ready');
      if (candidate.player.platform is NativePlayer) {
        final native = candidate.player.platform as NativePlayer;
        await configureNativePlayback(
          native,
          Uri.parse(mediaUrl),
          isCurrent: () => _isCurrent(generation),
          diskCache: false,
          bufferBytes: _preferences.bufferSize,
          playbackRate: _rate,
          automaticRoute: !nas && localFile == null,
          mediaHeaders: mediaHeaders,
        );
        if (!_isCurrent(generation)) return;
        if (NakuDevice.isTV && nas) await native.setProperty('http-proxy', '');
        // Probe each input independently. Forcing HLS globally also forces
        // external SRT/ASS inputs through the HLS demuxer and rejects them.
        try {
          await PlaybackQualityPreferences.read().apply(native);
        } catch (_) {
          _playbackNotice = '部分画质增强无法应用，已保留原始播放';
        }
        if (!_isCurrent(generation)) return;
        await applyCinemaTrackPreferences(candidate.player, widget.store);
        candidate.logStage('native-config-ready');
      }
      candidate.logStage('open-start');
      if (candidate.player case final CinemaTVNativePlayer television) {
        television.mediaMimeType = mediaFormat == VideoSourceFormat.hls
            ? 'application/x-mpegURL'
            : null;
        television.httpProxy = nas || localFile != null
            ? null
            : (await CinemaMediaRouter.instance.select(
                Uri.parse(mediaUrl),
                mediaHeaders,
              )).proxy;
        if (!_isCurrent(generation)) return;
      }
      await candidate.homepodAudioRoute.prepareForOpen();
      if (!_isCurrent(generation)) return;
      await candidate.player.open(
        Media(
          mediaUrl,
          start: Duration(seconds: offset),
          httpHeaders: mediaHeaders,
        ),
        play:
            (NakuDevice.isTV
                ? _pendingPlayIntent
                : playWhenReady ?? _preferences.autoPlay) &&
            !_backgroundPaused &&
            !_windowControls.blocksPlayback,
      );
      if (!_isCurrent(generation)) return;
      candidate.logStage('open-return');
      candidate.homepodAudioRoute.logPlaybackState();
      if (_windowControls.blocksPlayback) {
        await candidate.player.pause();
        if (!_isCurrent(generation)) return;
      }
      candidate.opened = true;
      _updateReady(candidate, generation);
    } on VideoSourceCancelledException {
      // Cancellation is expected when the user chooses another episode.
    } on VideoSourceTimeoutException {
      _fail(
        generation,
        '播放页面解析超时，请重试或更换线路。',
        failure: CinemaPlaybackFailure.transientNetwork,
      );
    } on FormatException catch (error) {
      _fail(
        generation,
        error.message.toString(),
        failure: cinemaPlaybackException(error),
      );
    } catch (error) {
      _fail(
        generation,
        '播放失败。片源可能暂时不可用，请重试或更换线路。',
        failure: cinemaPlaybackException(error),
      );
    } finally {
      await pendingNAS?.close();
    }
  }

  List<String> get _tvNASProfiles {
    final size = CinemaTVMediaEnvironment.instance.maximumSize;
    return _nasOptions?.tvProfiles(
          maxWidth: size.width,
          maxHeight: size.height,
        ) ??
        const [];
  }

  Future<String> _chooseTVHlsManifest(
    String text,
    Uri base,
    Map<String, String> headers,
    int generation,
  ) async {
    final variants = cinemaHlsVariants(text, base);
    if (variants.isEmpty) return text;
    final environment = CinemaTVMediaEnvironment.instance;
    await environment.refresh();
    if (!_isCurrent(generation)) throw const FormatException('播放选择已更新');
    final candidates = variants
        .where(
          (variant) =>
              !_tvHlsRejected.contains(variant.uri.toString()) &&
              environment.supports(
                CinemaMediaProbeResult(
                  ok: true,
                  elapsedMs: 0,
                  width: variant.width,
                  height: variant.height,
                  codec: variant.codec,
                ),
              ),
        )
        .toList();
    if (candidates.isEmpty) throw const FormatException('没有这台电视可解码的 HLS 画质');
    candidates.sort((a, b) {
      final pa = (a.width ?? 0) * (a.height ?? 0),
          pb = (b.width ?? 0) * (b.height ?? 0);
      return pa == pb ? b.bitrate.compareTo(a.bitrate) : pb.compareTo(pa);
    });
    CinemaHlsVariant? selected;
    if (_tvHlsPreferred != null) {
      selected = candidates
          .where((candidate) => candidate.uri.toString() == _tvHlsPreferred)
          .firstOrNull;
      if (selected != null) _tvHlsPreferred = null;
    }
    final token = CancelToken();
    _probeTokens.add(token);
    try {
      for (final candidate
          in selected == null
              ? candidates.take(2)
              : const <CinemaHlsVariant>[]) {
        final sample = await _mediaProbe.measure(
          candidate.uri.toString(),
          headers,
          hls: true,
          cancel: token,
          timeout: const Duration(seconds: 6),
        );
        if (!_isCurrent(generation) || token.isCancelled) {
          throw const FormatException('播放选择已更新');
        }
        if (!sample.ok ||
            !environment.supports(sample) ||
            sample.mbps == null) {
          continue;
        }
        final sustainable = candidates.where(
          (v) =>
              v.bitrate <= 0 ||
              sample.mbps! * 1000000 >= v.bitrate * 1.3 * _rate,
        );
        selected = sustainable.firstOrNull ?? candidates.last;
        break;
      }
      selected ??= candidates.last;
      _tvHlsLastVariant = selected.uri.toString();
      return cinemaTVSelectHlsVariant(text, base, selected.uri);
    } finally {
      _probeTokens.remove(token);
    }
  }

  bool _downgradeTVHLS(CinemaPlaybackFailure failure) {
    if (!NakuDevice.isTV ||
        _tvSheetOpen ||
        _usesNASPlayback ||
        _tvHlsLastVariant == null ||
        _tvHlsDowngrades >= 3 ||
        {
          CinemaPlaybackFailure.accessDenied,
          CinemaPlaybackFailure.unavailable,
        }.contains(failure)) {
      return false;
    }
    final variant = _tvHlsLastVariant!;
    if (!_tvHlsRejected.add(variant)) return false;
    if (failure == CinemaPlaybackFailure.decoder ||
        failure == CinemaPlaybackFailure.format) {
      _tvHlsCodecRejected.add(variant);
    }
    _tvHlsDowngrades++;
    _tvNASHealthySince = null;
    unawaited(
      _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: _positionForEpisode(_routeIndex, _episodeIndex),
        automatic: true,
        playWhenReady: _pendingPlayIntent,
        selectionNotice: '正在自动调整播放画质，保留进度',
      ),
    );
    return true;
  }

  Future<void> _considerTVHlsUpgrade(
    _CinemaPlayback playback,
    int generation,
  ) async {
    if (!NakuDevice.isTV ||
        !_tvBackgroundAllowed(playback) ||
        _tvSheetOpen ||
        _usesNASPlayback ||
        _tvHlsUpgrading ||
        _tvHlsUpgradeProbes >= 2 ||
        _tvHlsRejected.isEmpty ||
        _tvHlsLastVariant == null ||
        _tvNASHealthySince == null ||
        DateTime.now().difference(_tvNASHealthySince!).inSeconds < 120 ||
        playback.mediaFormat != VideoSourceFormat.hls ||
        playback.mediaUrl == null) {
      return;
    }
    _tvHlsUpgrading = true;
    _tvHlsUpgradeProbes++;
    _tvNASHealthySince = null;
    final token = CancelToken();
    _ownOptionalProbe(token);
    try {
      final document = await _mediaProbe.transport.document(
        Uri.parse(playback.mediaUrl!),
        playback.mediaHeaders,
        cancel: token,
      );
      final variants = cinemaHlsVariants(document.text, document.uri);
      final current = variants
          .where((v) => v.uri.toString() == _tvHlsLastVariant)
          .firstOrNull;
      if (current == null) return;
      final higher =
          variants
              .where(
                (v) =>
                    v.bitrate > current.bitrate &&
                    !_tvHlsCodecRejected.contains(v.uri.toString()) &&
                    CinemaTVMediaEnvironment.instance.supports(
                      CinemaMediaProbeResult(
                        ok: true,
                        elapsedMs: 0,
                        width: v.width,
                        height: v.height,
                        codec: v.codec,
                      ),
                    ),
              )
              .toList()
            ..sort((a, b) => a.bitrate.compareTo(b.bitrate));
      if (higher.isEmpty) return;
      final candidate = higher.first;
      final sample = await _mediaProbe.measure(
        candidate.uri.toString(),
        playback.mediaHeaders,
        hls: true,
        cancel: token,
        timeout: const Duration(seconds: 6),
      );
      if (!_isCurrent(generation) ||
          !identical(_playback, playback) ||
          token.isCancelled ||
          !_tvBackgroundAllowed(playback) ||
          !playback.player.state.playing ||
          !sample.ok ||
          !CinemaTVMediaEnvironment.instance.supports(sample) ||
          candidate.bitrate <= 0 ||
          (sample.mbps ?? 0) * 1000000 < candidate.bitrate * 1.6) {
        return;
      }
      _tvHlsRejected.remove(candidate.uri.toString());
      _tvHlsPreferred = candidate.uri.toString();
      await _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: playback.position.inSeconds,
        automatic: true,
        playWhenReady: playback.player.state.playing,
        selectionNotice: '已确认更高画质可流畅播放，正在自动优化',
      );
    } catch (_) {
      // Background comparisons are optional and cannot fail active playback.
    } finally {
      _releaseOptionalProbe(token);
      if (token.isCancelled &&
          _isCurrent(generation) &&
          _tvHlsUpgradeProbes > 0) {
        _tvHlsUpgradeProbes--;
      }
      _tvHlsUpgrading = false;
    }
  }

  String? _lowerTVNASProfile() {
    final profiles = _tvNASProfiles;
    if (_nasResolution == nasOriginalFileProfile) {
      return profiles
          .where((p) => !_tvNASRejectedProfiles.contains(p))
          .firstOrNull;
    }
    final at = profiles.indexOf(_nasResolution ?? '');
    if (at < 0) return null;
    return profiles
        .skip(at + 1)
        .where((p) => !_tvNASRejectedProfiles.contains(p))
        .firstOrNull;
  }

  Future<CinemaNASPlaybackSession?> _startTVNAS(
    String reference,
    int generation,
  ) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final session = await _nasPlayback.start(
        reference,
        resolution: _nasResolution,
        audio: _nasAudio,
        subtitle: _nasSubtitle,
      );
      if (!_isCurrent(generation)) {
        await session.close();
        return null;
      }
      final token = CancelToken();
      _probeTokens.add(token);
      CinemaMediaProbeResult? result;
      try {
        result = await _nasProbe.measure(
          session.url,
          session.headers,
          hls: true,
          cancel: token,
          timeout: const Duration(seconds: 6),
        );
      } finally {
        _probeTokens.remove(token);
      }
      if (!_isCurrent(generation) || token.isCancelled) {
        await session.close();
        return null;
      }
      final unsupported =
          result.ok && !CinemaTVMediaEnvironment.instance.supports(result);
      final bitrate = result.bitrate ?? session.bitrate;
      final insufficient =
          result.ok &&
          bitrate > 0 &&
          result.mbps != null &&
          result.mbps! * 1000000 < bitrate * 1.3;
      if (unsupported) _tvNASRejectedProfiles.add(_nasResolution!);
      final lower = _lowerTVNASProfile();
      if ((unsupported || insufficient) &&
          lower != null &&
          attempt < 2 &&
          _tvNASDowngrades < 3) {
        await session.close();
        _tvNASDowngrades++;
        _tvNASQualityChanged = DateTime.now();
        setState(() {
          _nasResolution = lower;
          _phase = '正在自动选择更稳定的 NAS 画质';
        });
        continue;
      }
      if (unsupported) {
        await session.close();
        throw const FormatException('当前 NAS 视频编码超出这台电视的解码能力。');
      }
      return session;
    }
    return null;
  }

  bool _downgradeTVNAS(int generation, CinemaPlaybackFailure failure) {
    if (!NakuDevice.isTV ||
        _tvSheetOpen ||
        !_usesNASPlayback ||
        _tvNASDowngrades >= 3 ||
        {
          CinemaPlaybackFailure.accessDenied,
          CinemaPlaybackFailure.unavailable,
        }.contains(failure)) {
      return false;
    }
    if (failure == CinemaPlaybackFailure.decoder ||
        failure == CinemaPlaybackFailure.format) {
      _tvNASRejectedProfiles.add(_nasResolution ?? '');
    }
    final next = _lowerTVNASProfile();
    if (next == null) return false;
    final at = _positionForEpisode(_routeIndex, _episodeIndex);
    _tvNASDowngrades++;
    _tvNASHealthySince = null;
    _tvNASQualityChanged = DateTime.now();
    _nasResolution = next;
    unawaited(
      _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: at,
        automatic: true,
        playWhenReady: _pendingPlayIntent,
        selectionNotice: '正在自动优化 NAS 播放，保留进度',
      ),
    );
    return true;
  }

  Future<void> _considerTVNASUpgrade(
    _CinemaPlayback playback,
    int generation,
  ) async {
    if (!NakuDevice.isTV ||
        !_tvBackgroundAllowed(playback) ||
        _tvSheetOpen ||
        !_usesNASPlayback ||
        _tvNASUpgrading ||
        _tvNASUpgradeProbes >= 2 ||
        _tvNASHealthySince == null ||
        DateTime.now().difference(_tvNASHealthySince!).inSeconds < 120 ||
        _nasReference == null) {
      return;
    }
    final profiles = _tvNASProfiles;
    final at = profiles.indexOf(_nasResolution ?? '');
    if (at <= 0) return;
    final higher = profiles
        .take(at)
        .where((p) => !_tvNASRejectedProfiles.contains(p))
        .lastOrNull;
    if (higher == null ||
        _tvNASQualityChanged != null &&
            DateTime.now().difference(_tvNASQualityChanged!).inSeconds < 120) {
      return;
    }
    _tvNASUpgrading = true;
    _tvNASUpgradeProbes++;
    _tvNASHealthySince = null;
    CinemaNASPlaybackSession? probe;
    final token = CancelToken();
    _ownOptionalProbe(token);
    try {
      probe = await _nasPlayback.start(
        _nasReference!,
        resolution: higher,
        audio: _nasAudio,
        subtitle: _nasSubtitle,
      );
      if (!_isCurrent(generation) ||
          !identical(_playback, playback) ||
          token.isCancelled ||
          !_tvBackgroundAllowed(playback)) {
        return;
      }
      final result = await _nasProbe.measure(
        probe.url,
        probe.headers,
        hls: true,
        cancel: token,
        timeout: const Duration(seconds: 6),
      );
      final bitrate = result.bitrate ?? probe.bitrate;
      if (!_isCurrent(generation) ||
          !identical(_playback, playback) ||
          token.isCancelled ||
          !_tvBackgroundAllowed(playback) ||
          !playback.player.state.playing ||
          !result.ok ||
          !CinemaTVMediaEnvironment.instance.supports(result) ||
          bitrate <= 0 ||
          (result.mbps ?? 0) * 1000000 < bitrate * 1.6) {
        return;
      }
      await probe.close();
      probe = null;
      _nasResolution = higher;
      _tvNASQualityChanged = DateTime.now();
      await _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: playback.position.inSeconds,
        automatic: true,
        playWhenReady: playback.player.state.playing,
        selectionNotice: '已确认更高画质可稳定播放，正在自动优化',
      );
    } catch (_) {
      // A background quality check never interrupts a working stream.
    } finally {
      _releaseOptionalProbe(token);
      await probe?.close();
      if (token.isCancelled &&
          _isCurrent(generation) &&
          _tvNASUpgradeProbes > 0) {
        _tvNASUpgradeProbes--;
      }
      _tvNASUpgrading = false;
    }
  }

  Future<void> _resolveNASRatingIdentity() async {
    final original = widget.title;
    if (original.sourceId != cinemaNASSource.id ||
        original.doubanId.isNotEmpty ||
        widget.offlinePaths != null ||
        (widget.ratingsRepository != null &&
            widget.resolveNASRatings == null)) {
      return;
    }
    try {
      final resolve =
          widget.resolveNASRatings ??
          CinemaRatingIdentitySearch(
            search: CinemaSearchDiscoveryRepository().searchForIdentity,
          ).resolve;
      final resolved = await resolve(original);
      if (!mounted ||
          _closing ||
          resolved.key != original.key ||
          resolved.doubanId.isEmpty) {
        return;
      }
      setState(() => _ratingsTitle = resolved);
    } catch (_) {
      // An ambiguous or unavailable public match retains manual association.
    }
  }

  Future<void> _checkNASConnection() async {
    final playback = _playback, reference = _nasReference;
    if (!mounted ||
        _closing ||
        _loading ||
        _checkingNASConnection ||
        playback == null ||
        reference == null) {
      return;
    }
    _checkingNASConnection = true;
    final generation = _generation;
    try {
      final result = await _nasPlayback.client.call('autoConnect', {
        'namespace': parseNASMediaReference(reference)['nas'],
      });
      if (_isCurrent(generation) &&
          identical(playback, _playback) &&
          result['changed'] == true) {
        await _applyNASPlaybackChoice(
          CinemaNASPlaybackSelection(
            _nasResolution ?? _nasOptions!.defaultProfile,
            _nasAudio,
            _nasSubtitle,
          ),
        );
      }
    } catch (_) {
      // A failed probe cannot tear down a stream that is still playing.
    } finally {
      _checkingNASConnection = false;
    }
  }

  Future<void> _applyNASPlaybackChoice(
    CinemaNASPlaybackSelection choice,
  ) async {
    final playback = _playback;
    if (!_usesNASPlayback ||
        _closing ||
        _nasOptions == null ||
        !_nasOptions!.supportsProfile(choice.resolution)) {
      return;
    }
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    final play = NakuDevice.isTV && playback?.player is CinemaTVNativePlayer
        ? _pendingPlayIntent
        : playback?.ready == true &&
              (!NakuDevice.isTV || !playback!.player.state.buffering)
        ? playback!.player.state.playing
        : _pendingPlayIntent;
    _nasResolution = choice.resolution;
    _nasAudio = choice.audio;
    _nasSubtitle = choice.subtitle;
    await _playEpisode(
      _routeIndex,
      _episodeIndex,
      resumeAt: position,
      playWhenReady: play,
    );
  }

  Future<void> _showTracks() async {
    final playback = _playback;
    if (playback == null) return;
    await showCinemaTracksSheet(
      context,
      playback.player,
      widget.store,
      title: _title.title,
      imdbId: _title.imdbId,
      liveSubtitles: playback.liveSubtitles,
      automation: playback.subtitles,
      autoSync: playback.subtitleAutoSync,
      category: _title.category,
      episodeName: _subtitleEpisodeName,
      episodeNumber: _episodeIndex + 1,
      onSubtitleApplied: (selection) => _rememberSubtitle(playback, selection),
      nasControls:
          !NakuDevice.isTV &&
              _usesNASPlayback &&
              _nasOptions != null &&
              _nasResolution != nasOriginalFileProfile
          ? CinemaNASInlinePlaybackControls(
              options: _nasOptions!,
              resolution: _nasResolution ?? _nasOptions!.defaultProfile,
              audio: _nasAudio,
              subtitle: _nasSubtitle,
              onApply: (choice) {
                Navigator.pop(context);
                unawaited(_applyNASPlaybackChoice(choice));
              },
            )
          : null,
    );
  }

  Future<void> _rememberSubtitle(
    _CinemaPlayback playback,
    CinemaOnlineSubtitleSelection selection,
  ) async {
    if (!mounted || _closing || !identical(_playback, playback)) return;
    await playback.subtitles?.remember(selection);
  }

  Future<void> _showOnlineSubtitles() async {
    final playback = _playback;
    if (playback == null) return;
    playback.subtitles?.beginManualSelection();
    await showCinemaOnlineSubtitles(
      context,
      playback.player,
      title: _title.title,
      imdbId: _title.imdbId,
      category: _title.category,
      episodeName: _subtitleEpisodeName,
      episodeNumber: _episodeIndex + 1,
      onApplied: (selection) => _rememberSubtitle(playback, selection),
    );
  }

  Future<void> _showDanmaku() async {
    final controller = _playback?.danmaku;
    if (controller != null) {
      await showCinemaDanmakuSheet(context, controller, title: _title.title);
    }
  }

  Future<void> _showQuality() async {
    final playback = _playback;
    if (!_usesNASPlayback || _nasOptions == null) {
      if (playback == null) return;
      return showCinemaQualitySheet(context, playback.player);
    }
    final reference = _nasReference;
    final choice = await showCinemaNASPlaybackSheet(
      context,
      options: _nasOptions!,
      resolution: _nasResolution ?? _nasOptions!.defaultProfile,
      audio: _nasAudio,
      subtitle: _nasSubtitle,
      bitrate: playback?.nasSession?.bitrate ?? 0,
      onPlayerTracks: playback == null ? null : () => unawaited(_showTracks()),
      onPlayerQuality: playback == null
          ? null
          : () => unawaited(showCinemaQualitySheet(context, playback.player)),
    );
    if (choice != null &&
        mounted &&
        _usesNASPlayback &&
        reference == _nasReference) {
      await _applyNASPlaybackChoice(choice);
    }
  }

  Future<void> _showMobilePlaybackTools() async {
    final actions = <String, VoidCallback>{
      '清晰度与播放设置': () => unawaited(_showQuality()),
      '字幕与音轨': () => unawaited(_showTracks()),
      if (_playback != null) '在线搜索字幕': () => unawaited(_showOnlineSubtitles()),
      '弹幕': () => unawaited(_showDanmaku()),
      '播放倍速': _showSpeedOptions,
      '线路 / 选集': _showEpisodes,
      if (_hasNext) '下一集': () => _changeEpisode(1),
      if (_episodeIndex > 0) '上一集': () => _changeEpisode(-1),
      '画中画': () => unawaited(_togglePip()),
      if (NakuDevice.canDownload && widget.offlinePaths == null)
        '下载选集': _downloadCurrent,
    };
    final action = await showModalBottomSheet<VoidCallback>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('播放工具')),
              for (final entry in actions.entries)
                ListTile(
                  title: Text(entry.key),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(ctx, entry.value),
                ),
            ],
          ),
        ),
      ),
    );
    if (mounted && !_closing) action?.call();
  }

  Widget _playbackTools({bool overlay = false}) {
    final playback = _playback;
    Widget action(String text, IconData icon, VoidCallback? onPressed) =>
        TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: overlay ? Colors.white : const Color(0xFFCCCCCC),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            minimumSize: const Size(0, 40),
            textStyle: const TextStyle(fontSize: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          onPressed: onPressed,
          icon: Icon(icon, size: 20),
          label: Text(text),
        );
    final tracks = action(
      _usesNASPlayback ? '外挂字幕 / 播放器音轨' : '字幕与音轨',
      Icons.closed_caption_outlined,
      playback == null ? null : _showTracks,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (overlay)
          Wrap(
            spacing: 4,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_usesNASPlayback && _nasOptions != null)
                CinemaNASInlinePlaybackControls(
                  key: ValueKey(
                    'nas-inline:$_nasReference:${overlay ? 'overlay' : 'detail'}',
                  ),
                  onPlayerTracks: _showTracks,
                  options: _nasOptions!,
                  resolution: _nasResolution ?? _nasOptions!.defaultProfile,
                  audio: _nasAudio,
                  subtitle: _nasSubtitle,
                  bitrate: playback?.nasSession?.bitrate ?? 0,
                  enabled: !_closing,
                  onApply: (choice) =>
                      unawaited(_applyNASPlaybackChoice(choice)),
                ),
              action('倍速', Icons.speed, _showSpeedOptions),
              tracks,
              action(
                '弹幕',
                Icons.comment_outlined,
                playback?.danmaku == null ? null : _showDanmaku,
              ),
              if (!NakuDevice.isTV)
                action('画中画', Icons.picture_in_picture_alt, _togglePip),
              if (!overlay)
                action(
                  _fullscreen ? '退出全屏' : '全屏',
                  Icons.fullscreen,
                  _toggleFullscreen,
                ),
              action('线路 / 选集', Icons.playlist_play, _showEpisodes),
            ],
          ),
        if (!overlay) ...[
          if (_usesNASPlayback && _nasOptions != null)
            CinemaNASInlinePlaybackControls(
              options: _nasOptions!,
              resolution: _nasResolution ?? _nasOptions!.defaultProfile,
              audio: _nasAudio,
              subtitle: _nasSubtitle,
              enabled: !_closing,
              onPlayerTracks: _showTracks,
              onApply: (choice) => unawaited(_applyNASPlaybackChoice(choice)),
            ),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              tracks,
              action(
                '弹幕',
                Icons.comment_outlined,
                playback?.danmaku == null ? null : _showDanmaku,
              ),
              if (Platform.isAndroid && !NakuDevice.isTV)
                action(
                  '发送到电视',
                  Icons.cast,
                  () => showCinemaCast(
                    context,
                    title: _title,
                    source: _source,
                    road: _routeIndex,
                    episode: _episodeIndex,
                    position: _playback?.position.inSeconds ?? 0,
                  ),
                ),
              action(
                widget.store.isFavorite(_title) ? '已收藏' : '收藏',
                Icons.bookmark_border,
                _toggleFavorite,
              ),
              if (NakuDevice.canDownload && widget.offlinePaths == null)
                action('下载选集', Icons.download_rounded, _downloadCurrent),
              action(
                '保存截图',
                Icons.photo_camera_outlined,
                playback == null ? null : _screenshot,
              ),
              action(
                '在线搜索字幕',
                Icons.search,
                playback == null ? null : _showOnlineSubtitles,
              ),
              action(
                _usesNASPlayback ? '清晰度与 NAS 播放设置' : '画质信息与处理',
                Icons.tune,
                playback == null && !_usesNASPlayback ? null : _showQuality,
              ),
              action('超分辨率', Icons.auto_awesome, _showSuperResolutionOptions),
              action(
                'NAS 用户配对',
                Icons.people_outline,
                () => showCinemaSyncSheet(context, coordinator: _together),
              ),
              if (widget.offlinePaths == null && !_usesNASPlayback)
                action('播放线路测速', Icons.network_check, () {
                  _showEpisodes();
                  _probeRoutes();
                }),
              if (_canRetryDirect)
                action('启用视频直连并重试', Icons.network_check, _retryDirect),
            ],
          ),
        ],
      ],
    );
  }

  Widget _macPlaybackOptions() {
    final playback = _playback;
    final actions = <String, VoidCallback?>{
      '保存截图': playback == null ? null : _screenshot,
      '在线搜索字幕': playback == null ? null : _showOnlineSubtitles,
      _usesNASPlayback ? '清晰度与 NAS 播放设置' : '画质信息与处理':
          playback == null && !_usesNASPlayback ? null : _showQuality,
      '超分辨率': _showSuperResolutionOptions,
      'NAS 用户配对': () => showCinemaSyncSheet(context, coordinator: _together),
      if (NakuDevice.canDownload && widget.offlinePaths == null)
        '下载选集': _downloadCurrent,
      if (widget.offlinePaths == null && !_usesNASPlayback)
        '播放线路测速': () {
          _showEpisodes();
          _probeRoutes();
        },
      if (_canRetryDirect) '启用视频直连并重试': _retryDirect,
    };
    return PopupMenuButton<String>(
      key: const ValueKey('cinema-mac-playback-options'),
      tooltip: '播放选项',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (action) => actions[action]?.call(),
      itemBuilder: (_) => [
        for (final action in actions.entries)
          PopupMenuItem(
            value: action.key,
            enabled: action.value != null,
            child: Text(action.key),
          ),
      ],
    );
  }

  String get _subtitleEpisodeName {
    final episode = _episode;
    if (episode == null) return '';
    return _subtitleNameForEpisode(episode);
  }

  String _subtitleNameForEpisode(CinemaEpisode episode) {
    final filename = isNASMediaReference(episode.url)
        ? (parseNASMediaReference(episode.url)['path'] ?? '')
              .split('/')
              .last
              .split('\\')
              .last
        : '';
    return '${episode.name} $filename'.trim();
  }

  bool get _usesNASPlayback =>
      widget.offlinePaths == null &&
      _nasReference != null &&
      _nasReference ==
          _title.routes[_routeIndex].episodes
              .elementAtOrNull(_episodeIndex)
              ?.url;

  void _listenTo(_CinemaPlayback playback, int generation) {
    bool current() => _isCurrent(generation) && identical(_playback, playback);
    void observeFailure(String message) {
      if (!current() || playback.completed) return;
      final kind = playbackFailureKind(message);
      if (kind == null) return;
      if (playback.ready && !playback.player.state.buffering) return;
      final at = playback.position;
      playback.fatalErrorTimer ??= Timer(
        Duration(seconds: kind == PlaybackFailureKind.network ? 6 : 3),
        () {
          playback.fatalErrorTimer = null;
          if (current() &&
              !playback.completed &&
              playback.position <= at &&
              (!playback.ready || playback.player.state.buffering)) {
            playback.logStage('failed(kind=${kind.name})');
            _fail(
              generation,
              kind == PlaybackFailureKind.network
                  ? '视频网络连接失败，请重试、更换线路或在网络设置调整视频连接。'
                  : '当前视频无法打开，正在尝试其他线路。',
              failure: cinemaPlaybackFailure(message),
            );
          }
        },
      );
    }

    playback.subscriptions.addAll([
      playback.player.stream.log.listen((event) => observeFailure(event.text)),
      playback.player.stream.position.listen((position) {
        if (!current()) return;
        if (position > playback.position &&
            _playbackNotice != null &&
            playback.ready) {
          setState(() => _playbackNotice = null);
        }
        if (position > playback.position &&
            !playback.player.state.buffering &&
            _selection != null) {
          _recovery.progress(_selection!.key);
          if (_recoveryTimer != null) {
            _recoveryTimer?.cancel();
            _recoveryTimer = null;
            setState(() {
              _loading = false;
              _playbackNotice = null;
            });
          }
        }
        playback.position = position;
        if (NakuDevice.isTV &&
            playback.ready &&
            playback.player.state.playing &&
            !playback.player.state.buffering) {
          final now = DateTime.now();
          if (_tvNASLastProgress == null ||
              now.difference(_tvNASLastProgress!).inSeconds > 3) {
            _tvNASHealthySince = now;
          }
          _tvNASHealthySince ??= now;
          _tvNASLastProgress = now;
        }
        playback.cacheSession?.update(
          position,
          buffering:
              playback.player.state.buffering ||
              (!NakuDevice.isTV && _probingRoutes),
          rate: _rate,
        );
        if (NakuDevice.isTV) {
          _syncTVBackground(playback, generation);
        } else if (!playback.warmedNext &&
            playback.ready &&
            position.inSeconds > 15 &&
            CinemaPlaybackBufferPolicy(
              _rate,
            ).mayWarmNext(position, playback.player.state.buffer)) {
          unawaited(_warmNext(playback, generation));
        }
      }),
      playback.player.stream.buffering.listen((value) {
        if (!current()) return;
        if (value) playback.cancelNextWarmup('当前视频正在缓冲，暂停下一集预热');
        playback.cacheSession?.update(
          playback.position,
          buffering: value || (!NakuDevice.isTV && _probingRoutes),
          rate: _rate,
        );
        if (value) _tvNASHealthySince = null;
        _syncTVBackground(playback, generation);
        _syncTVActivity();
      }),
      playback.player.stream.playing.listen((playing) {
        if (!current()) return;
        playback.watchdog.reset();
        _syncTVActivity();
        if (NakuDevice.isTV) {
          if (!playing) {
            _tvNASHealthySince = null;
            unawaited(_persistProgress(playback));
          }
          _syncTVBackground(playback, generation);
          _scheduleTVControlsHide();
        }
        if (Platform.isAndroid && !NakuDevice.isTV) {
          unawaited(
            PipUtils.updateAndroidPIPActions(
              playing: playing,
              danmakuEnabled: false,
              width: playback.width,
              height: playback.height,
            ),
          );
        }
      }),
      playback.player.stream.buffer.listen((_) {
        if (current() && NakuDevice.isTV) {
          _syncTVBackground(playback, generation);
        }
      }),
      playback.player.stream.volume.listen((volume) {
        if (!current() || !volume.isFinite || volume == _volume) return;
        _volume = volume.clamp(0, 100).toDouble();
        if (_volume <= 0) _stopEntranceSound();
        if (_volume > 0) _audibleVolume = _volume;
        _volumePersistence.update(_volume);
        _volumeSaveTimer?.cancel();
        _volumeSaveTimer = Timer(const Duration(milliseconds: 300), () {
          unawaited(_saveVolume());
        });
      }),
      playback.player.stream.duration.listen((duration) {
        if (!current()) return;
        playback.duration = duration;
        _updateReady(playback, generation);
      }),
      playback.player.stream.width.listen((width) {
        if (!current()) return;
        if (playback.width == (width ?? 0)) return;
        setState(() => playback.width = width ?? 0);
        _updateReady(playback, generation);
      }),
      playback.player.stream.height.listen((height) {
        if (!current()) return;
        if (playback.height == (height ?? 0)) return;
        setState(() => playback.height = height ?? 0);
        _updateReady(playback, generation);
      }),
      playback.player.stream.completed.listen((completed) {
        if (!current()) return;
        if (playback.completed == completed) return;
        final newlyCompleted = completed && !playback.completed;
        setState(() => playback.completed = completed);
        if (completed) unawaited(_persistProgress(playback));
        if (newlyCompleted) {
          final next = _preferences.nextEpisode(
            index: _episodeIndex,
            count: _route?.episodes.length ?? 0,
            following: _together.following,
          );
          if (next != null) {
            unawaited(
              _playEpisode(
                _routeIndex,
                next,
                resumeAt: 0,
                playWhenReady: _pendingPlayIntent,
              ),
            );
          }
        }
      }),
      playback.player.stream.error.listen((message) {
        if (!current()) return;
        if (playback.player is CinemaTVNativePlayer) {
          final code = int.tryParse(
            RegExp(r'（(\d+)）').firstMatch(message)?[1] ?? '',
          );
          _fail(
            generation,
            '当前视频无法在电视上正常解码或连接，正在检查可用播放方式。',
            failure: code != null && code >= 4000 && code < 5000
                ? CinemaPlaybackFailure.decoder
                : code != null && code >= 3000 && code < 4000
                ? CinemaPlaybackFailure.format
                : code != null && code >= 2000 && code < 3000
                ? CinemaPlaybackFailure.transientNetwork
                : CinemaPlaybackFailure.unknown,
          );
          return;
        }
        observeFailure(message);
        // libmpv emits decoder fallback and transient TCP errors here too.
        // Keep playback running; a log line alone does not prove termination.
        final explanation = PlayerErrorMapper.toActionableMessage(
          message,
          isBuffering: playback.player.state.buffering,
        );
        // Native messages can contain signed URLs; persist categories only.
        if (_preferences.showPlayerError) {
          setState(
            () => _playbackNotice = explanation ?? '播放器报告异常；若无法继续，可重试或更换线路。',
          );
        }
      }),
    ]);
  }

  void _observeNativeFirstFrame(_CinemaPlayback playback) {
    if (playback.firstFrameObserved) return;
    playback.firstFrameObserved = true;
    if (widget.videoSurfaceBuilder != null) {
      // An injected test surface has no native texture/controller to signal.
      playback.firstFrameRendered = true;
      return;
    }
    unawaited(
      (playback.player is CinemaTVNativePlayer
              ? (playback.player as CinemaTVNativePlayer)
                    .waitUntilFirstFrameRendered
              : playback.controller.waitUntilFirstFrameRendered)
          .then<void>(
            (_) {
              if (!_isCurrent(playback.generation) ||
                  !identical(_playback, playback)) {
                return;
              }
              playback.firstFrameTimer?.cancel();
              setState(() => playback.firstFrameRendered = true);
              playback.logStage('first-frame-rendered');
            },
            onError: (Object error, StackTrace _) {
              if (_isCurrent(playback.generation) &&
                  identical(_playback, playback)) {
                _fail(playback.generation, '视频画面未能初始化，请重试或更换线路。');
              }
            },
          ),
    );
  }

  void _updateReady(_CinemaPlayback playback, int generation) {
    if (!_isCurrent(generation) ||
        playback.ready ||
        !playback.opened ||
        (playback.width <= 0 || playback.height <= 0)) {
      return;
    }
    playback.ready = true;
    if ((_usesMacCinemaLayout || NakuDevice.isTV) &&
        widget.videoSurfaceBuilder == null &&
        !playback.firstFrameRendered) {
      playback.firstFrameTimer = Timer(const Duration(seconds: 30), () {
        if (_isCurrent(generation) &&
            identical(_playback, playback) &&
            !playback.firstFrameRendered) {
          _fail(generation, '视频已有媒体信息，但未能显示首帧，请重试或更换线路。');
        }
      });
    }
    playback.bufferMonitor.start();
    unawaited(playback.danmaku?.loadAutomatic());
    // A cached caption is available immediately, before MPV's asynchronous
    // open has necessarily loaded a video. Add it only once the video exists.
    unawaited(
      playback.subtitles!.load(
        onNotice: (message) {
          if (_isCurrent(generation) && identical(_playback, playback)) {
            setState(() => _playbackNotice = message);
          }
        },
      ),
    );
    _health.observe(
      _source,
      ok: true,
      media: true,
      firstFrameMs: playback.firstFrameWatch?.elapsedMilliseconds,
    );
    if (NakuDevice.isTV) {
      _tvCurrentProbePending = true;
    } else {
      _warmTimer = Timer(const Duration(seconds: 12), () {
        if (_isCurrent(generation) && !playback.player.state.buffering) {
          unawaited(_probeCurrent(playback, generation));
          if (!playback.warmedNext) unawaited(_warmNext(playback, generation));
        }
      });
    }
    if (_episode != null) {
      unawaited(_together.updateMedia(_syncOwner, _title, _episode!));
    }
    if (_superResolution != SuperResolutionMode.off) {
      unawaited(_applyShader(_superResolution, save: false));
    }
    playback.logStage(
      'video-ready(width=${playback.width},height=${playback.height})',
    );
    _loadTimer?.cancel();
    playback.watchdogTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!_isCurrent(generation) || _error != null) return;
      final state = playback.player.state;
      if (playback.watchdog.sample(
        now: DateTime.now(),
        position: playback.position,
        playing: state.playing,
        completed: playback.completed,
      )) {
        _fail(
          generation,
          '视频已连续 30 秒没有播放进展，请重试或更换线路。',
          failure: CinemaPlaybackFailure.transientNetwork,
        );
      }
    });
    setState(() => _loading = false);
    _scheduleTVControlsHide();
    if (NakuDevice.isTV) {
      _syncTVBackground(playback, generation);
    } else if (_automaticProbePending) {
      _automaticProbePending = false;
      unawaited(_probeRoutes(automatic: true));
    }
  }

  void _fail(
    int generation,
    String message, {
    CinemaPlaybackFailure failure = CinemaPlaybackFailure.unknown,
  }) {
    if (!_isCurrent(generation) || _recoveryTimer != null) return;
    _cancelTVBackground('当前播放正在恢复', reset: true);
    if (NakuDevice.isTV && _tvSheetOpen) {
      _tvDeferredFailure = (
        generation: generation,
        message: message,
        failure: failure,
      );
      return;
    }
    final selection = _selection;
    if (NakuDevice.isTV) {
      _mediaProbe.invalidate();
      final uri = Uri.tryParse(_playback?.mediaUrl ?? '');
      if (uri != null && uri.hasAuthority) {
        _mediaProbe.transport.router?.invalidate(uri);
      }
    }
    if (!NakuDevice.isTV &&
        _playback?.cacheSession != null &&
        failure != CinemaPlaybackFailure.accessDenied &&
        failure != CinemaPlaybackFailure.unavailable &&
        selection != null &&
        _cacheBypass.add(selection.key)) {
      unawaited(
        _playEpisode(
          _routeIndex,
          _episodeIndex,
          resumeAt: _positionForEpisode(_routeIndex, _episodeIndex),
          automatic: true,
        ),
      );
      return;
    }
    final delay = selection == null || widget.offlinePaths != null
        ? null
        : _recovery.retry(selection.key, failure);
    if (delay != null) {
      final at = _positionForEpisode(_routeIndex, _episodeIndex);
      final playback = _playback;
      if (playback?.ready == true &&
          !(NakuDevice.isTV && playback!.player is CinemaTVNativePlayer)) {
        if (!NakuDevice.isTV || !playback!.player.state.buffering) {
          _pendingPlayIntent = playback!.player.state.playing;
        }
      }
      // Media3 enters IDLE and reports playing=false on a terminal error.
      // The explicit user play/pause intent, rather than IDLE, owns recovery.
      setState(() {
        _loading = true;
        _phase = '网络连接中断，${delay.inMilliseconds / 1000} 秒后重试当前集';
        _playbackNotice = _phase;
      });
      _recoveryTimer = Timer(delay, () {
        _recoveryTimer = null;
        if (!_isCurrent(generation)) return;
        unawaited(
          _playEpisode(
            _routeIndex,
            _episodeIndex,
            resumeAt: at,
            automatic: true,
            playWhenReady:
                _pendingPlayIntent && !_windowControls.blocksPlayback,
          ),
        );
      });
      return;
    }
    _health.observe(_source, ok: false, media: true, reason: '视频未能继续');
    if (_downgradeTVHLS(failure) || _downgradeTVNAS(generation, failure)) {
      return;
    }
    if (selection != null && _probeResults.containsKey(selection.key)) {
      setState(
        () => _probeResults[selection.key] = const CinemaMediaProbeResult(
          ok: false,
          elapsedMs: 0,
          reason: '测速后播放失败',
        ),
      );
    }
    if (selection != null && cinemaPreferredEndpoint(selection)) {
      _preferredProbeFailures.add(selection.key);
    }
    unawaited(_advanceAfterFailure(message));
  }

  void _releasePlayback() {
    _cancelTVBackground('当前播放已释放', reset: true);
    _stopEntranceSound();
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _resolver.cancel();
    _loadTimer?.cancel();
    final old = _playback;
    unawaited(_together.clearPlaybackMedia(_syncOwner));
    _playback = null;
    if (old != null) {
      _volume = old.player.state.volume;
      unawaited(_persistProgress(old));
      unawaited(old.dispose());
    }
  }

  Future<void> _advanceAfterFailure(String message) async {
    if (widget.offlinePaths != null) {
      _releasePlayback();
      setState(() {
        _loading = false;
        _error = message;
      });
      return;
    }
    final generation = ++_generation;
    final anchor = _failoverAnchor;
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    _releasePlayback();
    setState(() {
      _loading = true;
      _error = null;
      _playbackNotice = null;
      _phase = '当前线路未能继续，正在查找同集的其他线路';
    });
    if (anchor != null && !_preferredDiscoveryDone) {
      final token = _routeProbeToken = CancelToken();
      try {
        await _loadPreferredVariants(anchor, generation, token);
      } finally {
        if (identical(_routeProbeToken, token)) _routeProbeToken = null;
      }
      if (!_isCurrent(generation) || token.isCancelled) return;
    }
    while (_isCurrent(generation) && anchor != null && !_attempts.exhausted) {
      final matching = _catalogue
          .matching(anchor)
          .where(
            (candidate) =>
                !_attempts.contains(candidate) &&
                !_preferredProbeFailures.contains(candidate.key) &&
                (cinemaPrefersSource(candidate.source) ||
                    !_health.cooling(candidate.source)),
          )
          .toList();
      final preferred = cinemaPreferredEndpoints(matching);
      final next = preferred.firstOrNull ?? matching.firstOrNull;
      if (next != null) {
        await _playEpisode(
          next.routeIndex,
          next.episodeIndex,
          title: next.title,
          source: next.source,
          resumeAt: position,
          automatic: true,
        );
        return;
      }
      final unread = _catalogue.unread
          .where((item) => !_detailAttempts.contains(item.key))
          .firstOrNull;
      if (unread == null && _discovering != null) {
        setState(() => _phase = '正在等待其他片源的线路');
        final pending = _discovering;
        _discovering = null;
        await pending;
        if (!_isCurrent(generation)) return;
        continue;
      }
      if (unread == null || _detailAttempts.length >= 8) break;
      _detailAttempts.add(unread.key);
      setState(
        () => _phase = '自动换源 · 正在读取${_catalogue.sourceFor(unread).name}线路',
      );
      try {
        final pending = _catalogue.load(unread);
        setState(() {});
        await pending;
      } catch (_) {
        // One source's detail error must not abort the finite candidate scan.
      }
      if (!_isCurrent(generation)) return;
      setState(() {});
    }
    if (!_isCurrent(generation)) return;
    setState(() {
      _loading = false;
      final limited = _attempts.exhausted || _detailAttempts.length >= 8;
      _error =
          '$message\n${limited ? '已达本轮自动尝试上限' : '已尝试所有能确认同集的可用线路'}'
          '（${_attempts.count} 条）。${NakuDevice.isTV ? '可重新自动查找或返回片库。' : '可重试或在播放列表中手动选择片源与集数。'}';
    });
  }

  CinemaPlaybackCandidate? get _selection => _episode == null
      ? null
      : CinemaPlaybackCandidate(
          title: _title,
          source: _source,
          routeIndex: _routeIndex,
          episodeIndex: _episodeIndex,
        );

  Future<void> _loadAndSwitchVariant(CinemaTitle variant) async {
    _automaticProbePending = false;
    _cancelRouteProbe();
    final current = _selection;
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    final generation = ++_generation;
    _releasePlayback();
    setState(() {
      _loading = true;
      _error = null;
      _phase = '正在读取${_catalogue.sourceFor(variant).name}线路';
    });
    try {
      final pending = _catalogue.load(variant, retry: true);
      setState(() {});
      final detail = await pending;
      if (!_isCurrent(generation)) return;
      for (var route = 0; route < detail.routes.length; route++) {
        final episode = current == null
            ? null
            : cinemaMatchPlaybackEpisode(
                current: current,
                target: detail,
                routeIndex: route,
              );
        if (episode != null) {
          await _playEpisode(
            route,
            episode,
            title: detail,
            source: _catalogue.sourceFor(detail),
            resumeAt: position,
          );
          return;
        }
      }
      _selectForManual(detail, 0);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _error = '暂未读取到此片源线路，可点击该片源重试或选择其他片源。';
      });
    }
  }

  void _selectForManual(CinemaTitle title, int routeIndex) {
    _automaticProbePending = false;
    _cancelRouteProbe();
    ++_generation;
    _releasePlayback();
    setState(() {
      _title = title;
      _source = _catalogue.sourceFor(title);
      _routeIndex = routeIndex;
      _episodeIndex = 0;
      _requiresEpisodeSelection = true;
      _loading = false;
      _playbackNotice = null;
      _error = title.routes.isEmpty
          ? '此片源暂无线路，请选择其他片源。'
          : '无法确认这条线路的对应集数，请在播放列表中手动选择。';
    });
  }

  Future<void> _probeCurrent(_CinemaPlayback playback, int generation) async {
    if (_probingRoutes ||
        playback.mediaUrl == null ||
        !playback.mediaUrl!.startsWith('http') ||
        widget.offlinePaths != null ||
        (NakuDevice.isTV && !_tvBackgroundAllowed(playback))) {
      return;
    }
    final token = CancelToken();
    _ownOptionalProbe(token);
    try {
      final result =
          await (NakuDevice.isTV && _usesNASPlayback ? _nasProbe : _mediaProbe)
              .measure(
                playback.mediaUrl!,
                playback.mediaHeaders,
                cancel: token,
                hls: playback.mediaFormat == VideoSourceFormat.hls,
              );
      if (!_isCurrent(generation) ||
          token.isCancelled ||
          (NakuDevice.isTV && !_tvBackgroundAllowed(playback))) {
        return;
      }
      final key = _selection?.key;
      if (key != null) _updateProbeDisplay(() => _probeResults[key] = result);
      _health.observe(
        _source,
        ok: result.ok,
        media: true,
        mbps: result.mbps,
        latencyMs: result.firstByteMs,
        reason: result.reason,
      );
    } catch (_) {
      // Optional diagnostics must not fail the current media route.
    } finally {
      _releaseOptionalProbe(token);
    }
  }

  Future<void> _warmNext(_CinemaPlayback playback, int generation) async {
    if (_source.id == cinemaNASSource.id) return;
    if (NakuDevice.isTV && !_tvBackgroundAllowed(playback)) return;
    if (_probingRoutes ||
        !_isCurrent(generation) ||
        playback.warmedNext ||
        widget.offlinePaths != null ||
        _route == null ||
        playback.player.state.buffering ||
        !CinemaPlaybackBufferPolicy(
          _rate,
        ).mayWarmNext(playback.position, playback.player.state.buffer) ||
        _episodeIndex + 1 >= _route!.episodes.length) {
      return;
    }
    final episode = _route!.episodes[_episodeIndex + 1];
    // Only already-resolved direct streams are warmed; a background resolver
    // must not open webviews or execute the next episode's page during playback.
    if (!cinemaUsesDirectMedia(_source, _route!, episode)) return;
    final token = CancelToken();
    playback.nextWarmup = token;
    playback.warmedNext = true;
    _ownOptionalProbe(token);
    try {
      await _cache.warmNext(
        episode.url,
        _source.headers,
        cancel: token,
        titleKey: _preferences.privateMode ? null : playback.title.key,
      );
    } finally {
      _releaseOptionalProbe(token);
      // A cancelled request may finish after playback has resumed or changed.
      // It only owns this playback's token, never another episode's warmup.
      if (identical(playback.nextWarmup, token)) {
        playback.nextWarmup = null;
        if (token.isCancelled) playback.warmedNext = false;
      }
    }
  }

  void _cancelRouteProbe() {
    _routeProbeToken?.cancel('播放选择已变化');
    _routeProbeToken = null;
    _probingRoutes = false;
  }

  CinemaRouteMeasurement? get _bestMeasuredRoute {
    final current = _selection;
    final anchor = _routeComparisonAnchor;
    if (current == null ||
        anchor == null ||
        widget.offlinePaths != null ||
        cinemaMatchPlaybackEpisode(
              current: current,
              target: anchor.title,
              routeIndex: anchor.routeIndex,
            ) !=
            anchor.episodeIndex) {
      return null;
    }
    final measurements = [
      for (final candidate in [
        current,
        ..._catalogue.matching(current).where((c) => c.key != current.key),
      ])
        if (_probeResults[candidate.key] case final result?)
          CinemaRouteMeasurement(candidate, result, playbackRate: _rate),
    ];
    return _bestSourcePriority(measurements);
  }

  CinemaRouteMeasurement? _bestSourcePriority(
    Iterable<CinemaRouteMeasurement> values,
  ) => cinemaBestSourcePriorityRoute(
    values,
    supported: NakuDevice.isTV
        ? CinemaTVMediaEnvironment.instance.supports
        : null,
    fallback: NakuDevice.isTV
        ? (items) => cinemaBestMeasuredTVRoute(
            items,
            supported: CinemaTVMediaEnvironment.instance.supports,
          )
        : null,
  );

  Future<void> _useBestRoute(
    CinemaRouteMeasurement best, {
    bool automatic = false,
  }) async {
    if (_closing || _selection?.key == best.candidate.key) return;
    if (NakuDevice.isTV && _tvSheetOpen) return;
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    final play = NakuDevice.isTV && _playback?.player.state.buffering == true
        ? _pendingPlayIntent
        : _playback?.opened == true
        ? (_together.session.waitingForBuffer
              ? _together.session.intendedPlaying
              : _playback!.player.state.playing)
        : _preferences.autoPlay;
    final candidate = best.candidate;
    await _playEpisode(
      candidate.routeIndex,
      candidate.episodeIndex,
      title: candidate.title,
      source: candidate.source,
      resumeAt: position,
      playWhenReady: play,
      automatic: automatic,
      selectionNotice: automatic ? '已自动选择本次最佳线路，保留播放进度' : '已使用本次推荐线路',
    );
  }

  Future<void> _probeRoutes({bool automatic = false}) async {
    if (_probingRoutes || _selection == null) return;
    if (NakuDevice.isTV &&
        (_playback == null || !_tvBackgroundAllowed(_playback!))) {
      if (automatic) _automaticProbePending = _autoBestRoute;
      return;
    }
    if (!automatic) _mediaProbe.invalidate();
    if (!automatic) _preferredProbeFailures.clear();
    final generation = _generation;
    for (final background in _probeTokens) {
      background.cancel('线路测速优先，暂停重复采样和下一集预热');
    }
    _probeTokens.clear();
    final token = _routeProbeToken = CancelToken();
    _ownOptionalProbe(token);
    _updateProbeDisplay(() {
      _probingRoutes = true;
      _probingAutomatic = automatic;
      _probeCompleted = _probeTotal = 0;
      _probeStatus = automatic ? '正在自动比较播放线路' : '正在比较播放线路';
      _routeComparisonAnchor = _selection;
      _probeResults.clear();
    });
    if (NakuDevice.isTV) {
      _playback?.cacheSession?.backgroundPrefetchAllowed = false;
    } else {
      _playback?.cacheSession?.update(_playback!.position, buffering: true);
    }
    try {
      // Give in-flight details a brief chance to join without delaying playback
      // for slow catalogue APIs. Web page resolvers are never navigated here.
      if (automatic && _discovering != null) {
        try {
          await _discovering!.timeout(const Duration(milliseconds: 1200));
        } catch (_) {}
      }
      if (!_isCurrent(generation) ||
          token.isCancelled ||
          (NakuDevice.isTV &&
              (_playback == null || !_tvBackgroundAllowed(_playback!)))) {
        return;
      }
      final current = _selection!;
      final playback = _playback;
      final resolved =
          <String, ({String url, Map<String, String> headers, bool hls})>{};
      if (playback?.mediaUrl != null) {
        final path =
            Uri.tryParse(playback!.mediaUrl!)?.path.toLowerCase() ?? '';
        resolved[current.key] = (
          url: playback.mediaUrl!,
          headers: playback.mediaHeaders,
          hls:
              playback.mediaFormat == VideoSourceFormat.hls ||
              !path.endsWith('.mp4') &&
                  cinemaUsesDirectMedia(
                    current.source,
                    current.route,
                    current.episode,
                  ) &&
                  RegExp(
                    r'm3u8|\bhls\b',
                    caseSensitive: false,
                  ).hasMatch(current.route.name),
        );
      }
      final targets = CinemaRouteProbeBatch.plan([
        current,
        ..._catalogue
            .matching(current)
            .where(
              (c) =>
                  c.key != current.key &&
                  !_preferredProbeFailures.contains(c.key),
            ),
      ], resolved: resolved);
      _updateProbeDisplay(() => _probeTotal = targets.length);
      final budget = Duration(seconds: automatic ? 10 : 30);
      final watch = Stopwatch()..start();
      Future<List<CinemaRouteMeasurement>> measure(
        List<CinemaRouteProbeTarget> subset,
      ) => CinemaRouteProbeBatch(_mediaProbe).run(
        subset,
        cancel: token,
        budget: budget - watch.elapsed,
        onResult: (target, result) {
          if (!_isCurrent(generation) ||
              token.isCancelled ||
              (NakuDevice.isTV &&
                  (_playback == null || !_tvBackgroundAllowed(_playback!)))) {
            return;
          }
          _updateProbeDisplay(() {
            _probeCompleted++;
            for (final candidate in target.candidates) {
              _probeResults[candidate.key] = result;
            }
          });
          final seen = <String>{};
          for (final candidate in target.candidates) {
            if (seen.add(candidate.source.id)) {
              _health.observe(
                candidate.source,
                ok: result.ok,
                media: true,
                mbps: result.mbps,
                latencyMs: result.firstByteMs,
                reason: result.reason,
              );
            }
          }
        },
      );
      final preferred = targets
          .where((t) => t.candidates.any(cinemaPreferredEndpoint))
          .toList();
      final measurements = await measure(preferred);
      if (_bestSourcePriority(measurements) == null &&
          _isCurrent(generation) &&
          !token.isCancelled &&
          watch.elapsed < budget) {
        measurements.addAll(
          await measure(targets.where((t) => !preferred.contains(t)).toList()),
        );
      }
      if (!_isCurrent(generation) ||
          token.isCancelled ||
          (NakuDevice.isTV &&
              (_playback == null || !_tvBackgroundAllowed(_playback!)))) {
        return;
      }
      final best = _bestSourcePriority(measurements);
      _updateProbeDisplay(() {
        _probeTotal = _probeCompleted;
        _probingRoutes = false;
        _probeStatus = best == null
            ? '本次未测得可用线路，保留当前播放'
            : automatic
            ? '已使用本次最佳线路'
            : '本次测速完成，可使用推荐线路';
      });
      if (automatic && best != null && _selection?.key != best.candidate.key) {
        await _useBestRoute(best, automatic: true);
      }
    } finally {
      _releaseOptionalProbe(token);
      if (identical(_routeProbeToken, token)) {
        _routeProbeToken = null;
        if (mounted && !_closing) {
          _updateProbeDisplay(() => _probingRoutes = false);
        }
      }
      if (!_probingRoutes && mounted && !_closing) {
        final playback = _playback;
        playback?.cacheSession?.update(
          playback.position,
          buffering: playback.player.state.buffering,
          rate: _rate,
        );
      }
    }
  }

  Future<void> _screenshot() async {
    final playback = _playback;
    if (playback == null || !playback.ready) return;
    playback.manualPlaybackRevision++;
    try {
      final bytes = await playback.player.screenshot(format: 'image/png');
      if (bytes == null || !mounted) return;
      final name = _title.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      final file = await FilePicker.platform.saveFile(
        dialogTitle: '保存播放截图',
        fileName: '$name-${playback.position.inSeconds}s.png',
        type: FileType.custom,
        allowedExtensions: const ['png'],
        bytes: bytes,
      );
      if (file != null && mounted) {
        KazumiDialog.showToast(context: context, message: '截图已保存');
      }
    } catch (_) {
      if (mounted) {
        KazumiDialog.showToast(context: context, message: '当前视频暂时无法截图');
      }
    }
  }

  Future<void> _downloadCurrent() async {
    if (_queueingDownload || widget.offlinePaths != null) return;
    setState(() => _queueingDownload = true);
    try {
      await showCinemaDownloadSheet(
        context,
        title: _title,
        source: _source,
        routeIndex: _routeIndex,
        episodeIndex: _episodeIndex,
      );
    } finally {
      if (mounted) setState(() => _queueingDownload = false);
    }
  }

  Future<void> _retryDirect() async {
    await GStorage.putSetting(SettingsKeys.mediaDirectConnection, true);
    DioFactory.resetDownloadClient();
    if (mounted && !_closing) {
      await _playEpisode(
        _routeIndex,
        _episodeIndex,
        resumeAt: _positionForEpisode(_routeIndex, _episodeIndex),
      );
    }
  }

  Future<void> _setRate(double rate, {bool temporary = false}) async {
    final playback = _playback;
    if (playback == null) return;
    try {
      _cancelTVBackground('播放速度已变化', reset: true);
      await playback.player.setRate(rate);
      if (mounted && identical(playback, _playback)) {
        if (!temporary) setState(() => _rate = rate);
        final policy = CinemaPlaybackBufferPolicy(rate);
        if (!policy.mayWarmNext(
          playback.position,
          playback.player.state.buffer,
        )) {
          playback.cancelNextWarmup('倍速提高，优先缓存当前集');
        }
        playback.cacheSession?.update(
          playback.position,
          buffering: playback.player.state.buffering,
          rate: rate,
        );
        final native = playback.player.platform;
        if (native is NativePlayer) {
          try {
            for (final entry
                in policy.nativeProperties(_preferences.bufferSize).entries) {
              if (!mounted || !identical(playback, _playback)) return;
              await native.setProperty(entry.key, entry.value);
            }
          } catch (_) {
            KazumiLogger().w('Cinema: optional rate cache policy unavailable');
          }
        }
      }
    } catch (_) {
      if (mounted && identical(playback, _playback)) {
        KazumiDialog.showToast(
          context: context,
          message: '暂时无法更改倍速，请在视频加载后重试。',
        );
      }
    }
  }

  Future<void> _saveVolume() async {
    _volumeSaveTimer?.cancel();
    try {
      await _volumePersistence.flush();
    } catch (_) {
      // An unavailable settings store must not stop playback or block exit.
      KazumiLogger().w('Cinema: could not save remembered volume');
    }
  }

  Future<void> _setVolume(double volume) async {
    final player = _playback?.player;
    if (player == null || _closing) return;
    await player.setVolume(volume.clamp(0, 100).toDouble());
  }

  void _changeEpisode(int delta) {
    if (_closing ||
        (_loading && _recoveryTimer == null) ||
        _requiresEpisodeSelection) {
      return;
    }
    final target = _episodeIndex + delta;
    if (target >= 0 && target < (_route?.episodes.length ?? 0)) {
      unawaited(
        _playEpisode(
          _routeIndex,
          target,
          resumeAt: 0,
          playWhenReady: _pendingPlayIntent,
        ),
      );
    }
  }

  void _changeSpeed(int direction) {
    final choices = direction > 0
        ? defaultPlaySpeedList.where((value) => value > _rate)
        : defaultPlaySpeedList.reversed.where((value) => value < _rate);
    if (choices.isNotEmpty) unawaited(_setRate(choices.first));
  }

  Map<String, PlayerShortcutAction> get _keyboardActions => {
    'playorpause': _togglePlayback,
    'forward': () {
      if (_playback?.ready == true) {
        return _playback?.keyboardTransport?.press(1);
      }
    },
    'rewind': () {
      if (_playback?.ready == true) {
        return _playback?.keyboardTransport?.press(-1);
      }
    },
    'next': () => _changeEpisode(1),
    'prev': () => _changeEpisode(-1),
    'volumeup': () => _setVolume(_volume + 10),
    'volumedown': () => _setVolume(_volume - 10),
    'togglemute': () => _setVolume(_volume > 0 ? 0 : _audibleVolume),
    'fullscreen': _toggleFullscreen,
    'exitfullscreen': () async {
      if (_fullscreen) await _toggleFullscreen();
    },
    'skip': () => _seekBy(_preferences.buttonSkipSeconds),
    'speed1': () => _setRate(1),
    'speed2': () => _setRate(2),
    'speed3': () => _setRate(3),
    'speedup': () => _changeSpeed(1),
    'speeddown': () => _changeSpeed(-1),
    'episodes': _showEpisodes,
    'pip': _togglePip,
    'together': () => showCinemaSyncSheet(context, coordinator: _together),
    'favorite': _toggleFavorite,
    'screenshot': _screenshot,
  };

  Future<void> _togglePlayback() async {
    final playback = _playback;
    if (playback == null || _closing || _loading || _manualPlaybackChanging) {
      return;
    }
    _manualPlaybackChanging = true;
    try {
      await _windowControls.refreshVisibility();
      if (!mounted ||
          _closing ||
          !identical(playback, _playback) ||
          _windowControls.blocksPlayback) {
        return;
      }
      _backgroundPaused = false;
      playback.manualPlaybackRevision++;
      final intendedPlaying = !playback.player.state.playing;
      if (NakuDevice.isTV) _pendingPlayIntent = intendedPlaying;
      await playback.player.playOrPause();
      if (identical(playback, _playback)) {
        _pendingPlayIntent = intendedPlaying;
        _syncTVActivity();
        if (NakuDevice.isTV) {
          if (!intendedPlaying) {
            _showTVControls();
          } else {
            _scheduleTVControlsHide();
          }
        }
      }
    } finally {
      _manualPlaybackChanging = false;
    }
  }

  Widget _playPauseButton() {
    final player = _playback?.player;
    if (player == null) return const SizedBox.shrink();
    return StreamBuilder<bool>(
      key: ValueKey(player),
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (_, snapshot) => IconButton(
        tooltip: snapshot.data == true ? '暂停' : '播放',
        onPressed: _togglePlayback,
        color: Colors.white,
        icon: TweenAnimationBuilder<double>(
          tween: Tween(end: snapshot.data == true ? 1 : 0),
          duration: _preferences.disableAnimations
              ? Duration.zero
              : const Duration(milliseconds: 200),
          builder: (_, value, _) => AnimatedIcon(
            icon: AnimatedIcons.play_pause,
            progress: AlwaysStoppedAnimation(value),
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  Future<void>? _leaving;
  Future<void> _leave() => _leaving ??= _leaveOnce();

  Future<void> _saveBeforeApplicationExit() async {
    if (!mounted) return;
    _closing = true;
    _syncTVActivity();
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    ++_generation;
    _historyTimer?.cancel();
    _loadTimer?.cancel();
    _resolver.cancel();
    final playback = _playback;
    // Save the final local progress before process termination. A window hide
    // does not invoke this hook or disturb the current route/playback session.
    try {
      await _saveVolume();
      await _persistProgress(playback);
      await widget.store.flush();
    } finally {
      _playback = null;
      try {
        await _together.detachPlayback(_syncOwner);
      } finally {
        if (playback != null) await playback.dispose();
      }
    }
  }

  Future<void> _leaveOnce() async {
    if (_closing) return;
    final animateExit =
        _usesMacCinemaLayout &&
        !_pip &&
        !_loading &&
        _error == null &&
        _playback?.ready == true &&
        _playback?.firstFrameRendered == true;
    _stopEntranceSound();
    _exitCrtRequested = true;
    _closing = true;
    _recoveryTimer?.cancel();
    _syncTVActivity();
    _recoveryTimer = null;
    // Silence the existing backend first, retaining its final video texture for
    // the CRT contraction. The backend is disposed by the same cleanup below.
    try {
      await _playback?.player.pause();
    } catch (_) {
      // Disposal below still closes a backend that is already failing.
    }
    if (_usesMacCinemaLayout) {
      await _nativeEntranceKey.currentState?.closeForExit(animate: animateExit);
    }
    await _pipTransition?.future;
    if (_fullscreen) await _setFullscreen(false);
    if (_pip) {
      await _restoreWindow();
      _pip = false;
    }
    await _together.detachPlayback(_syncOwner);
    _resolver.cancel();
    await _saveVolume();
    await _persistProgress();
    try {
      await widget.store.flush();
    } catch (_) {}
    // Close the old backend before Home resolves/pushes a follow target.
    final old = _playback;
    _playback = null;
    if (old != null) await old.dispose();
    if (mounted) {
      if (_usesMacCinemaLayout || NakuDevice.isTV) {
        setState(() => _allowPlayerPop = true);
        await WidgetsBinding.instance.endOfFrame;
      }
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopEntranceSound();
      _cancelTVBackground('应用已离开前台', reset: true);
    }
    final revision = ++_lifecycleRevision;
    if (!_fullscreenChanging &&
        _fullscreenTransition == null &&
        !_pipChanging &&
        (NakuDevice.isTV || !_preferences.backgroundPlayback) &&
        (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused) &&
        !_pip &&
        !_androidPip) {
      unawaited(_pauseInBackground(revision));
    } else if (state == AppLifecycleState.resumed) {
      _backgroundPaused = false;
    }
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistProgress());
    }
  }

  Future<void> _windowVisibilityChanged(bool hidden) async {
    if (!mounted || _closing) return;
    if (!hidden) {
      _backgroundPaused = false;
      return;
    }
    _stopEntranceSound();
    if (!_windowControls.blocksPlayback) return;
    _backgroundPaused = true;
    await _playback?.player.pause();
    _syncTVActivity();
    await _persistProgress();
  }

  Future<void> _pauseInBackground(int revision) async {
    if (!await isPlaybackWindowBackgrounded() ||
        !mounted ||
        _closing ||
        revision != _lifecycleRevision ||
        _fullscreenChanging ||
        _fullscreenTransition != null ||
        _pipChanging) {
      return;
    }
    _backgroundPaused = true;
    await _playback?.player.pause();
  }

  @override
  void dispose() {
    CinemaTVPlaybackActivity.instance.release(this);
    _stopEntranceSound();
    _tvControlsTimer?.cancel();
    FocusManager.instance.removeEarlyKeyEventHandler(_tvRemoteKey);
    if (Platform.isAndroid) {
      const MethodChannel('com.predidit.kazumi/pip').setMethodCallHandler(null);
      unawaited(PipUtils.setAndroidPIPInPlayerPage(false));
      if (!NakuDevice.isTV) {
        unawaited(
          SystemChrome.setPreferredOrientations(DeviceOrientation.values),
        );
      }
    }
    _nasConnectionTimer?.cancel();
    unawaited(_updatePlaybackLease.close());
    DesktopExitTasks.instance.unregister(this);
    _windowControls.unregister(this);
    WidgetsBinding.instance.removeObserver(this);
    if (!Platform.isAndroid && !Platform.isIOS) {
      windowManager.removeListener(this);
    }
    _panelRevision.dispose();
    _playerFocus.dispose();
    _tvTimeline.dispose();
    for (final node in [
      _tvTimelineFocus,
      _tvPlayFocus,
      _tvEpisodeFocus,
      _tvSubtitleFocus,
      _tvDanmakuFocus,
    ]) {
      node.dispose();
    }
    _cinemaPageScroll.dispose();
    _warmTimer?.cancel();
    _cancelTVBackground('播放器已关闭', reset: true);
    _cancelRouteProbe();
    for (final token in _probeTokens) {
      token.cancel('播放器已关闭');
    }
    _probeTokens.clear();
    if (widget.mediaProbe == null) _mediaProbe.transport.dio.close(force: true);
    _tvNASMediaProbe?.transport.dio.close(force: true);
    _volumeSaveTimer?.cancel();
    unawaited(_saveVolume());
    unawaited(_together.detachPlayback(_syncOwner));
    if (_pip) unawaited(_restoreWindow());
    _closing = true;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    ++_generation;
    _historyTimer?.cancel();
    _loadTimer?.cancel();
    final playback = _playback;
    _playback = null;
    if (playback != null) {
      unawaited(_persistProgress(playback));
      unawaited(playback.dispose());
    }
    _resolver.cancel();
    unawaited(_resolver.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _usesMacCinemaLayout
        ? _allowPlayerPop
        : NakuDevice.isTV
        ? _allowPlayerPop
        : true,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _usesMacCinemaLayout && !_allowPlayerPop) {
        unawaited(_leave());
        return;
      }
      if (!didPop && NakuDevice.isTV && _fullscreen) {
        if (_tvTimeline.active) {
          _tvTimeline.cancel();
        } else if (_tvControlsVisible && !_loading && _error == null) {
          setState(() => _tvControlsVisible = false);
          _playerFocus.requestFocus();
        } else {
          setState(() => _allowPlayerPop = true);
          unawaited(_leave());
        }
      }
    },
    child: FocusScope(
      node: _playerFocus,
      autofocus: true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildPlayer(context),
          if (_playback?.keyboardTransport case final transport?)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: ListenableBuilder(
                  listenable: transport,
                  builder: (context, _) => transport.label.isEmpty
                      ? const SizedBox.shrink()
                      : Center(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black87,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Text(
                                transport.label,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
          PlayerKeyboardShortcuts(
            focusScopeNode: _playerFocus,
            shortcuts: NakuDevice.isTV
                ? const {
                    'playorpause': ['Media Play Pause'],
                    'forward': ['Media Fast Forward'],
                    'rewind': ['Media Rewind'],
                  }
                : _preferences.shortcuts,
            actions: _keyboardActions,
            longPressActions: {
              for (final direction in const {
                'forward': 1,
                'rewind': -1,
              }.entries)
                if (_playback?.keyboardTransport case final transport?)
                  direction.key: PlayerLongPressShortcutActions(
                    holdDelay: const Duration(milliseconds: 400),
                    onRepeat: () => transport.hold(direction.value),
                    onRelease: transport.release,
                    onCancel: () => transport.release(cancel: true),
                  ),
            },
            isBlocked: () =>
                _closing ||
                HardwareKeyboard.instance.isMetaPressed ||
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isAltPressed,
          ),
        ],
      ),
    ),
  );

  Widget _buildPlayer(BuildContext context) {
    if (_androidPip) {
      return Scaffold(backgroundColor: Colors.black, body: _videoSurface());
    }
    if (_fullscreen || NakuDevice.isTV) {
      return Theme(
        data: CinemaTheme.of(context),
        child: Scaffold(backgroundColor: Colors.black, body: _videoSurface()),
      );
    }
    if (_pip) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            _videoSurface(),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton.filledTonal(
                tooltip: '退出画中画',
                onPressed: _togglePip,
                icon: const Icon(Icons.picture_in_picture_alt),
              ),
            ),
          ],
        ),
      );
    }
    if (_usesMacCinemaLayout) return _macCinemaPlayer();
    return Theme(
      data: CinemaTheme.of(context),
      child: Scaffold(
        backgroundColor: _background,
        appBar: AppBar(
          backgroundColor: _background,
          leading: IconButton(
            tooltip: '返回片库',
            onPressed: _leave,
            icon: const Icon(Icons.arrow_back_rounded),
          ),
          titleSpacing: 4,
          title: Row(
            children: [
              const Text(
                'NAKU播放器',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 19,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(width: 16),
              Container(width: 1, height: 18, color: _line),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  widget.title.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, color: _muted),
                ),
              ),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 980;
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 18, 28, 28),
                        child: _mainColumn(),
                      ),
                    ),
                    Container(width: 1, color: _line),
                    SizedBox(
                      width: 310,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: CinemaGlass(child: _episodePanel()),
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  _mainColumn(),
                  const SizedBox(height: 24),
                  _episodePanel(embedded: true),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// The first viewport is the cinema. Metadata stays below it in the same
  /// scroll view; selecting a route still uses the existing bottom sheet.
  Widget _macCinemaPlayer() => Theme(
    data: CinemaTheme.of(context),
    child: Scaffold(
      key: const ValueKey('cinema-mac-immersive-page'),
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(
          key: const ValueKey('cinema-mac-page-scroll'),
          controller: _cinemaPageScroll,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                key: const ValueKey('cinema-mac-player-viewport'),
                height: box.maxHeight,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _videoSurface(),
                    if (_loading ||
                        _error != null ||
                        (_playback?.ready == true &&
                            _playback?.firstFrameRendered != true))
                      Positioned(
                        top: MediaQuery.paddingOf(context).top + 12,
                        left: 16,
                        child: IconButton.filledTonal(
                          tooltip: '返回片库',
                          onPressed: _leave,
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      ),
                    if (!_closing &&
                        _error == null &&
                        (_loading ||
                            (_playback?.ready == true &&
                                _playback?.firstFrameRendered != true)))
                      Positioned(
                        top: MediaQuery.paddingOf(context).top + 12,
                        right: 16,
                        child: IconButton(
                          tooltip: '取消加载',
                          onPressed: _cancelLoading,
                          color: Colors.white70,
                          icon: const Icon(Icons.close_rounded, size: 20),
                        ),
                      ),
                  ],
                ),
              ),
              ColoredBox(
                color: const Color(0xFF09090B),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(48, 28, 48, 48),
                  child: _mainColumn(includeVideo: false),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _mainColumn({bool includeVideo = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (includeVideo) ...[
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: AspectRatio(aspectRatio: 16 / 9, child: _videoSurface()),
        ),
        const SizedBox(height: 12),
      ],
      if (includeVideo)
        _playbackTools()
      else
        TextButton.icon(
          key: const ValueKey('cinema-mac-work-chooser'),
          onPressed: _showEpisodes,
          icon: const Icon(Icons.playlist_play_rounded, size: 20),
          label: const Text('选集与片源'),
        ),
      const SizedBox(height: 20),
      if (includeVideo &&
          widget.offlinePaths == null &&
          (_probingRoutes ||
              _probeStatus != null ||
              _bestMeasuredRoute != null)) ...[
        _routeRecommendation(),
        const SizedBox(height: 16),
      ],
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _title.title,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '${_source.name}  /  ${_episode?.name ?? '暂无集数'}',
                  style: const TextStyle(color: _muted, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (widget.offlinePaths != null) _tag('离线播放'),
          if (_title.year.isNotEmpty) _tag(_title.year),
          if (_title.category.isNotEmpty) _tag(_title.category),
          if (_title.remarks.isNotEmpty) _tag('片源标注 · ${_title.remarks}'),
          if ((_playback?.width ?? 0) > 0 && (_playback?.height ?? 0) > 0)
            _tag(
              '媒体尺寸 · ${_playback!.width} × ${_playback!.height}',
              accent: true,
            ),
        ],
      ),
      if (_playback?.completed == true) ...[
        const SizedBox(height: 16),
        Text(
          _hasNext ? '本集已结束，可以继续下一集。' : '播放已结束。',
          style: const TextStyle(color: _copper),
        ),
      ],
      if (_historyError != null) ...[
        const SizedBox(height: 14),
        Text(
          _historyError!,
          style: const TextStyle(color: Color(0xFFFFBB94), fontSize: 12),
        ),
      ],
      if (_playbackNotice != null && _error == null) ...[
        const SizedBox(height: 14),
        Row(
          children: [
            const Icon(Icons.info_outline_rounded, size: 17, color: _copper),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _playbackNotice!,
                style: const TextStyle(color: _muted, fontSize: 12),
              ),
            ),
            TextButton(
              onPressed: () => _playEpisode(
                _routeIndex,
                _episodeIndex,
                resumeAt: _playback?.ready == true
                    ? _playback!.position.inSeconds
                    : null,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ],
      if (_title.description.isNotEmpty) ...[
        const SizedBox(height: 26),
        const Divider(color: _line),
        const SizedBox(height: 14),
        const Text(
          '关于本片',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 9),
        SelectableText(
          _title.description,
          style: const TextStyle(color: _muted, fontSize: 13, height: 1.8),
        ),
      ],
      const SizedBox(height: 24),
      if (!widget.title.isDirectMedia && widget.offlinePaths == null)
        CinemaRatingsPanel(
          key: ValueKey('playing-work-details:${widget.title.key}'),
          // Playback routes belong to the same verified work. Keep its metadata
          // anchor stable while changing source or episode, including ID-less ones.
          title: _ratingsTitle,
          sourceName: widget.source.name,
          repository: widget.ratingsRepository,
          reviewsRepository: widget.reviewsRepository,
          onRecommendationSelected: widget.onRecommendationSelected == null
              ? null
              : (recommendation) async {
                  final onSelected = widget.onRecommendationSelected!;
                  await _leave();
                  onSelected(recommendation);
                },
        ),
    ],
  );

  Widget _tvControlOverlay(_CinemaPlayback playback) => CinemaTVControlSurface(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _title.title,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 24),
            Text(
              _probingRoutes ? '正在自动优选' : '自动播放优化',
              style: const TextStyle(fontSize: 16, color: _muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (_episode != null)
          Text(
            _episode!.name,
            style: const TextStyle(fontSize: 16, color: _muted),
          ),
        const SizedBox(height: 8),
        StreamBuilder<Duration>(
          stream: playback.player.stream.position,
          initialData: playback.position,
          builder: (_, position) => CinemaTVTimeline(
            position: position.data ?? playback.position,
            duration: playback.duration,
            preview: _tvTimeline,
            focusNode: _tvTimelineFocus,
            onCommit: _seekTV,
            onActivity: _scheduleTVControlsHide,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            StreamBuilder<bool>(
              stream: playback.player.stream.playing,
              initialData: playback.player.state.playing,
              builder: (_, playing) => FilledButton.icon(
                focusNode: _tvPlayFocus,
                autofocus: true,
                onPressed: _togglePlayback,
                style: _tvButtonStyle(primary: true),
                icon: Icon(
                  playing.data == true
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 26,
                ),
                label: Text(
                  playing.data == true ? '暂停' : '播放',
                  style: const TextStyle(fontSize: 19),
                ),
              ),
            ),
            if ((_route?.episodes.length ?? 0) > 1) ...[
              const SizedBox(width: 14),
              OutlinedButton.icon(
                focusNode: _tvEpisodeFocus,
                style: _tvButtonStyle(),
                onPressed: () => _showTVAction(_showEpisodes, _tvEpisodeFocus),
                icon: const Icon(Icons.playlist_play_rounded, size: 25),
                label: const Text('选集', style: TextStyle(fontSize: 19)),
              ),
            ],
            const Spacer(),
            OutlinedButton.icon(
              focusNode: _tvSubtitleFocus,
              style: _tvButtonStyle(),
              onPressed: () => _showTVAction(_showTracks, _tvSubtitleFocus),
              icon: const Icon(Icons.subtitles_outlined, size: 24),
              label: const Text('字幕', style: TextStyle(fontSize: 19)),
            ),
            const SizedBox(width: 14),
            OutlinedButton.icon(
              focusNode: _tvDanmakuFocus,
              style: _tvButtonStyle(),
              onPressed: playback.danmaku == null
                  ? null
                  : () => _showTVAction(_showDanmaku, _tvDanmakuFocus),
              icon: const Icon(Icons.comment_outlined, size: 23),
              label: const Text('弹幕', style: TextStyle(fontSize: 19)),
            ),
          ],
        ),
      ],
    ),
  );
  ButtonStyle _tvButtonStyle({bool primary = false}) => ButtonStyle(
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: 20, vertical: 14),
    ),
    minimumSize: const WidgetStatePropertyAll(Size(100, 52)),
    side: WidgetStateProperty.resolveWith(
      (states) => BorderSide(
        color: states.contains(WidgetState.focused)
            ? Colors.white
            : primary
            ? Colors.transparent
            : _line,
        width: states.contains(WidgetState.focused) ? 3 : 1,
      ),
    ),
  );
  Widget _tvLoadOrError() => ColoredBox(
    color: const Color(0xB009090B),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: CinemaOpticalGlass(
            opacity: .76,
            padding: const EdgeInsets.all(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_error == null)
                  const Icon(
                    Icons.hourglass_top_rounded,
                    color: _copper,
                    size: 38,
                  )
                else
                  const Icon(
                    Icons.error_outline_rounded,
                    color: _copper,
                    size: 38,
                  ),
                const SizedBox(height: 22),
                Text(
                  _error ?? (_loading ? _phase : '正在等待视频首帧'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 21, height: 1.5),
                ),
                const SizedBox(height: 22),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_error != null && _episode != null)
                      FilledButton.icon(
                        autofocus: true,
                        style: _tvButtonStyle(primary: true),
                        onPressed: _retryTVAutomatically,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text(
                          '重新自动查找',
                          style: TextStyle(fontSize: 19),
                        ),
                      ),
                    if (_error != null && _episode != null)
                      const SizedBox(width: 16),
                    OutlinedButton(
                      style: _tvButtonStyle(),
                      autofocus: _loading || _episode == null,
                      onPressed: _leave,
                      child: const Text('返回', style: TextStyle(fontSize: 19)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  void _retryTVAutomatically() {
    _attempts = CinemaFailoverAttempts();
    _detailAttempts.clear();
    _recovery.reset();
    _mediaProbe.invalidate();
    _cacheBypass.clear();
    _preferredProbeFailures.clear();
    _preferredResolved.clear();
    _preferredDiscoveryDone = false;
    _tvNASRejectedProfiles.clear();
    _tvHlsRejected.clear();
    _tvHlsCodecRejected.clear();
    _tvHlsDowngrades = 0;
    _tvHlsUpgradeProbes = 0;
    _tvNASDowngrades = 0;
    _tvNASUpgradeProbes = 0;
    _automaticProbePending = _source.id != cinemaNASSource.id;
    unawaited(
      _startInitialPlayback(
        resumeAt: _positionForEpisode(_routeIndex, _episodeIndex),
      ),
    );
  }

  Widget _videoSurface() => LayoutBuilder(
    key: _videoSurfaceKey,
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 850;
      final nativeCinema = (_usesMacCinemaLayout || NakuDevice.isTV) && !_pip;
      final mobile =
          widget.mobileControls ??
          (!NakuDevice.isTV && (Platform.isAndroid || Platform.isIOS));
      final playback = _playback;
      final entranceGeneration = _generation;
      if (nativeCinema && playback != null) _observeNativeFirstFrame(playback);
      final waitingForFirstFrame =
          nativeCinema &&
          playback?.ready == true &&
          playback?.firstFrameRendered != true;
      if (widget.videoSurfaceBuilder == null) {
        playback?.observeControllerInitialization();
      }
      final controlsTheme = MaterialDesktopVideoControlsThemeData(
        visibleOnMount: true,
        toggleFullscreenOnDoublePress: false,
        playAndPauseOnTap: false,
        keyboardShortcuts: const {},
        controlsHoverDuration: _preferences.controlsHoverDuration,
        controlsTransitionDuration: _preferences.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 150),
        seekBarTransitionDuration: _preferences.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 300),
        seekBarThumbTransitionDuration: _preferences.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 150),
        volumeBarTransitionDuration: _preferences.disableAnimations
            ? Duration.zero
            : const Duration(milliseconds: 150),
        buttonBarHeight: _pip ? 48 : 72,
        automaticallyImplySkipNextButton: false,
        automaticallyImplySkipPreviousButton: false,
        seekBarPositionColor: const Color(0xFF3388FF),
        seekBarThumbColor: const Color(0xFF3388FF),
        volumeBarActiveColor: const Color(0xFF3388FF),
        primaryButtonBar: const [],
        bufferingIndicatorBuilder:
            nativeCinema && (_loading || waitingForFirstFrame)
            ? (_) => const SizedBox.shrink()
            : (_) => const SizedBox.square(
                key: ValueKey('cinema-buffering-indicator'),
                dimension: 24,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2.5,
                ),
              ),
        topButtonBar: _pip
            ? const []
            : [
                IconButton(
                  tooltip: '返回',
                  onPressed: _leave,
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
                Expanded(
                  child: Text(
                    '${_title.title} · ${_episode?.name ?? ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, color: Colors.white),
                  ),
                ),
                if (mobile)
                  IconButton(
                    tooltip: '播放工具',
                    onPressed: _showMobilePlaybackTools,
                    icon: const Icon(Icons.more_vert),
                  ),
                IconButton(
                  tooltip: widget.store.isFavorite(_title) ? '已收藏' : '收藏',
                  onPressed: _toggleFavorite,
                  icon: Icon(
                    widget.store.isFavorite(_title)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                  ),
                ),
              ],
        bottomButtonBar: mobile && !_pip
            ? [
                Expanded(
                  child: StreamBuilder<bool>(
                    stream: playback?.player.stream.playing,
                    initialData: playback?.player.state.playing ?? false,
                    builder: (context, playing) => StreamBuilder<Duration>(
                      stream: playback?.player.stream.position,
                      initialData: playback?.position ?? Duration.zero,
                      builder: (context, position) => CinemaMobilePlaybackBar(
                        playing: playing.data ?? false,
                        fullscreen: _fullscreen,
                        position: _time(position.data ?? Duration.zero),
                        duration: _time(playback?.duration ?? Duration.zero),
                        onBackward: playback == null
                            ? null
                            : () => _seekBy(-_preferences.buttonSkipSeconds),
                        onPlay: playback == null
                            ? null
                            : () => unawaited(_togglePlayback()),
                        onForward: playback == null
                            ? null
                            : () => _seekBy(_preferences.buttonSkipSeconds),
                        onQuality: playback == null && !_usesNASPlayback
                            ? null
                            : () => unawaited(_showQuality()),
                        onTracks: playback == null
                            ? null
                            : () => unawaited(_showTracks()),
                        onFullscreen: () => unawaited(_toggleFullscreen()),
                      ),
                    ),
                  ),
                ),
              ]
            : [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!_pip && playback != null)
                        StreamBuilder<Duration>(
                          stream: playback.player.stream.position,
                          initialData: playback.position,
                          builder: (context, snapshot) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                Text(
                                  _time(snapshot.data ?? Duration.zero),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFBBBBBB),
                                  ),
                                ),
                                const Spacer(),
                                CinemaBufferStatus(
                                  monitor: playback.bufferMonitor,
                                  capacity: _preferences.bufferSize,
                                  rate: _rate,
                                  routeLabel: () =>
                                      playback.cacheSession?.networkRoute ?? '',
                                ),
                                const Spacer(),
                                Text(
                                  _time(playback.duration),
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFFBBBBBB),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      SizedBox(
                        height: 44,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxWidth: (constraints.maxWidth * .45).clamp(
                                    0,
                                    260,
                                  ),
                                ),
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (!_pip)
                                        IconButton(
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 40,
                                              ),
                                          padding: EdgeInsets.zero,
                                          tooltip: '上一集',
                                          icon: const Icon(
                                            Icons.skip_previous_rounded,
                                          ),
                                          onPressed:
                                              _episodeIndex > 0 &&
                                                  (!_loading ||
                                                      _recoveryTimer != null)
                                              ? () => _changeEpisode(-1)
                                              : null,
                                        ),
                                      if (!_pip)
                                        IconButton(
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 40,
                                              ),
                                          padding: EdgeInsets.zero,
                                          tooltip:
                                              '后退 ${_preferences.buttonSkipSeconds} 秒',
                                          icon: const Icon(
                                            Icons.replay_10_rounded,
                                          ),
                                          onPressed: playback == null
                                              ? null
                                              : () => _seekBy(
                                                  -_preferences
                                                      .buttonSkipSeconds,
                                                ),
                                        ),
                                      _playPauseButton(),
                                      if (!_pip)
                                        IconButton(
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 40,
                                              ),
                                          padding: EdgeInsets.zero,
                                          tooltip:
                                              '快进 ${_preferences.buttonSkipSeconds} 秒',
                                          icon: const Icon(
                                            Icons.forward_10_rounded,
                                          ),
                                          onPressed: playback == null
                                              ? null
                                              : () => _seekBy(
                                                  _preferences
                                                      .buttonSkipSeconds,
                                                ),
                                        ),
                                      if (!_pip)
                                        IconButton(
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 40,
                                              ),
                                          padding: EdgeInsets.zero,
                                          tooltip: '下一集',
                                          icon: const Icon(
                                            Icons.skip_next_rounded,
                                          ),
                                          onPressed:
                                              _hasNext &&
                                                  (!_loading ||
                                                      _recoveryTimer != null)
                                              ? () => _changeEpisode(1)
                                              : null,
                                        ),
                                      if (!_pip) ...[
                                        const SizedBox(width: 24),
                                        if (wide &&
                                            widget.videoSurfaceBuilder == null)
                                          const MaterialDesktopVolumeButton(),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (!_pip) ...[
                                          IconButton(
                                            tooltip: _usesNASPlayback
                                                ? '外挂字幕 / 播放器音轨'
                                                : '字幕与音轨',
                                            onPressed: playback == null
                                                ? null
                                                : _showTracks,
                                            icon: const Icon(
                                              Icons.subtitles_outlined,
                                              size: 20,
                                            ),
                                          ),
                                          if (_usesNASPlayback &&
                                              _nasOptions != null)
                                            CinemaNASInlinePlaybackControls(
                                              key: ValueKey(
                                                'nas-bottom:$_nasReference',
                                              ),
                                              onPlayerTracks: _showTracks,
                                              options: _nasOptions!,
                                              resolution:
                                                  _nasResolution ??
                                                  _nasOptions!.defaultProfile,
                                              audio: _nasAudio,
                                              subtitle: _nasSubtitle,
                                              enabled: !_closing,
                                              bitrate:
                                                  playback
                                                      ?.nasSession
                                                      ?.bitrate ??
                                                  0,
                                              onApply: (choice) => unawaited(
                                                _applyNASPlaybackChoice(choice),
                                              ),
                                            ),
                                          IconButton(
                                            tooltip: '弹幕',
                                            onPressed: playback?.danmaku == null
                                                ? null
                                                : _showDanmaku,
                                            icon: const Icon(
                                              Icons.comment_outlined,
                                              size: 20,
                                            ),
                                          ),
                                          _speedControl(),
                                          if (_fullscreen && !nativeCinema) ...[
                                            IconButton(
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 40,
                                                  ),
                                              padding: EdgeInsets.zero,
                                              tooltip: '保存截图',
                                              onPressed: playback == null
                                                  ? null
                                                  : _screenshot,
                                              icon: const Icon(
                                                Icons.photo_camera_outlined,
                                                size: 22,
                                              ),
                                            ),
                                            IconButton(
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 40,
                                                  ),
                                              padding: EdgeInsets.zero,
                                              tooltip: '画质信息与处理',
                                              onPressed:
                                                  playback == null &&
                                                      !_usesNASPlayback
                                                  ? null
                                                  : _showQuality,
                                              icon: const Icon(
                                                Icons.tune_rounded,
                                                size: 22,
                                              ),
                                            ),
                                            IconButton(
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 40,
                                                  ),
                                              padding: EdgeInsets.zero,
                                              tooltip: '超分辨率',
                                              onPressed:
                                                  _showSuperResolutionOptions,
                                              icon: const Icon(
                                                Icons.auto_awesome_outlined,
                                                size: 22,
                                              ),
                                            ),
                                            IconButton(
                                              constraints:
                                                  const BoxConstraints.tightFor(
                                                    width: 36,
                                                    height: 40,
                                                  ),
                                              padding: EdgeInsets.zero,
                                              tooltip: 'NAS 用户配对',
                                              onPressed: () =>
                                                  showCinemaSyncSheet(
                                                    context,
                                                    coordinator: _together,
                                                  ),
                                              icon: const Icon(
                                                Icons.people_outline,
                                                size: 22,
                                              ),
                                            ),
                                            if (NakuDevice.canDownload &&
                                                widget.offlinePaths == null)
                                              IconButton(
                                                constraints:
                                                    const BoxConstraints.tightFor(
                                                      width: 36,
                                                      height: 40,
                                                    ),
                                                padding: EdgeInsets.zero,
                                                tooltip: '下载选集',
                                                onPressed: _downloadCurrent,
                                                icon: const Icon(
                                                  Icons.download_rounded,
                                                  size: 22,
                                                ),
                                              ),
                                          ],
                                          if (nativeCinema)
                                            _macPlaybackOptions(),
                                          IconButton(
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 36,
                                                  height: 40,
                                                ),
                                            padding: EdgeInsets.zero,
                                            tooltip: '画中画',
                                            onPressed: _togglePip,
                                            icon: const Icon(
                                              Icons
                                                  .picture_in_picture_alt_outlined,
                                            ),
                                          ),
                                          IconButton(
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 36,
                                                  height: 40,
                                                ),
                                            padding: EdgeInsets.zero,
                                            tooltip: nativeCinema
                                                ? '选集与片源'
                                                : '线路 / 选集',
                                            onPressed: _showEpisodes,
                                            icon: const Icon(
                                              Icons.playlist_play_rounded,
                                            ),
                                          ),
                                        ],
                                        IconButton(
                                          constraints:
                                              const BoxConstraints.tightFor(
                                                width: 36,
                                                height: 40,
                                              ),
                                          padding: EdgeInsets.zero,
                                          tooltip: _fullscreen ? '退出全屏' : '全屏',
                                          onPressed: _toggleFullscreen,
                                          icon: Icon(
                                            _fullscreen
                                                ? Icons.fullscreen_exit_rounded
                                                : Icons.fullscreen_rounded,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
      );
      return ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CinemaPlayerEntrance(
              key: _nativeEntranceKey,
              generation: _generation,
              // These are observed milestones, not a simulated download
              // percentage. An unknown network wait keeps its current lamp.
              loadStage: playback == null
                  ? CinemaPlayerLoadStage.connecting
                  : playback.ready
                  ? CinemaPlayerLoadStage.waitingForFrame
                  : CinemaPlayerLoadStage.opening,
              // The existing generation-safe gate requires open plus real video
              // dimensions. No timer or poster load can admit the lamp reveal.
              ready:
                  !_loading &&
                  playback?.ready == true &&
                  playback?.firstFrameRendered == true &&
                  (playback?.width ?? 0) > 0 &&
                  (playback?.height ?? 0) > 0,
              hasError: _error != null || (_closing && !_exitCrtRequested),
              enabled: nativeCinema && !NakuDevice.isTV,
              onReveal: () => _playEntranceSound(entranceGeneration),
              onCancel: () => _stopEntranceSound(entranceGeneration),
              reduceMotion:
                  _preferences.disableAnimations ||
                  MediaQuery.disableAnimationsOf(context),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (playback != null)
                    CinemaVideoGestures(
                      controlsInsets: EdgeInsets.only(
                        top: _pip ? 0 : 52,
                        bottom: _pip ? 48 : 108,
                      ),
                      onTogglePlayback: () {
                        if (!_loading && !_closing) {
                          unawaited(_togglePlayback());
                        }
                      },
                      onToggleFullscreen: () => unawaited(_toggleFullscreen()),
                      child: MaterialDesktopVideoControlsTheme(
                        normal: controlsTheme,
                        fullscreen: controlsTheme,
                        child:
                            widget.videoSurfaceBuilder?.call(
                              context,
                              playback.player,
                            ) ??
                            (playback.player is CinemaTVNativePlayer
                                ? CinemaTVNativeVideo(
                                    key: ValueKey(playback),
                                    player:
                                        playback.player as CinemaTVNativePlayer,
                                  )
                                : ListenableBuilder(
                                    listenable: Listenable.merge([
                                      widget.store,
                                      cinemaExternalSubtitleState(
                                        playback.player,
                                      ).active,
                                    ]),
                                    builder: (context, _) => Video(
                                      key: ValueKey(playback),
                                      controller: playback.controller,
                                      fit: _preferences.aspectRatio.fit,
                                      aspectRatio: _preferences
                                          .aspectRatio
                                          .frameAspectRatio,
                                      controls: NakuDevice.isTV || _androidPip
                                          ? NoVideoControls
                                          : MaterialDesktopVideoControls,
                                      subtitleViewConfiguration:
                                          CinemaSubtitleAppearance.from(
                                            widget
                                                .store
                                                .extras['subtitleAppearance'],
                                          ).configurationFor(
                                            visible:
                                                !cinemaExternalSubtitleState(
                                                  playback.player,
                                                ).active.value,
                                          ),
                                      pauseUponEnteringBackgroundMode: false,
                                    ),
                                  )),
                      ),
                    ),
                  if (nativeCinema)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Offstage(
                          offstage: playback?.firstFrameRendered == true,
                          child: _title.poster.isEmpty
                              ? const SizedBox.shrink()
                              : Opacity(
                                  opacity: .54,
                                  child: CachedNetworkImage(
                                    key: ValueKey(
                                      'cinema-opening-poster:${_title.key}',
                                    ),
                                    imageUrl: _title.poster,
                                    memCacheWidth: 1280,
                                    fit: BoxFit.cover,
                                    fadeInDuration: Duration.zero,
                                    errorWidget: (_, _, _) =>
                                        const SizedBox.shrink(),
                                  ),
                                ),
                        ),
                      ),
                    ),
                  if (playback != null)
                    Positioned.fill(
                      child: ListenableBuilder(
                        listenable: widget.store,
                        builder: (context, _) => CinemaExternalSubtitleOverlay(
                          player: playback.player,
                          appearance: CinemaSubtitleAppearance.from(
                            widget.store.extras['subtitleAppearance'],
                          ),
                        ),
                      ),
                    ),
                  if (playback?.danmaku case final danmaku?)
                    Positioned.fill(
                      child: CinemaDanmakuOverlay(controller: danmaku),
                    ),
                  if (playback != null)
                    Positioned(
                      left: 20,
                      right: 20,
                      bottom: _pip ? 12 : 74,
                      child: IgnorePointer(
                        child: ListenableBuilder(
                          listenable: playback.liveSubtitles,
                          builder: (context, _) =>
                              playback.liveSubtitles.text.isEmpty
                              ? const SizedBox.shrink()
                              : Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 7,
                                    ),
                                    color: const Color(0xB3000000),
                                    child: Text(
                                      playback.liveSubtitles.text,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: CinemaSubtitleAppearance.from(
                                          widget
                                              .store
                                              .extras['subtitleAppearance'],
                                        ).fontSize,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (NakuDevice.isTV &&
                _tvControlsVisible &&
                playback != null &&
                !_loading &&
                _error == null)
              Align(
                alignment: Alignment.bottomCenter,
                child: _tvControlOverlay(playback),
              ),
            if (NakuDevice.isTV && _tvHeldSeek != null)
              Center(
                child: CinemaOpticalGlass(
                  opacity: .8,
                  padding: const EdgeInsets.all(18),
                  child: Text(
                    CinemaTVTimeline.time(_tvHeldSeek!),
                    style: const TextStyle(fontSize: 30),
                  ),
                ),
              ),
            if (_error != null ||
                ((NakuDevice.isTV || !nativeCinema) &&
                    (_loading || waitingForFirstFrame)))
              if (NakuDevice.isTV)
                _tvLoadOrError()
              else
                ColoredBox(
                  color: nativeCinema && _error == null
                      ? Colors.transparent
                      : const Color(0xEE0B0C0D),
                  child: Align(
                    alignment: nativeCinema
                        ? const Alignment(0, .56)
                        : Alignment.center,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_loading || waitingForFirstFrame)
                            const SizedBox(
                              width: 28,
                              height: 28,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: _copper,
                              ),
                            )
                          else
                            const Icon(
                              Icons.error_outline_rounded,
                              color: _copper,
                              size: 30,
                            ),
                          const SizedBox(height: 16),
                          Text(
                            _error ??
                                (waitingForFirstFrame ? '正在等待视频首帧' : _phase),
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: _text, fontSize: 14),
                          ),
                          const SizedBox(height: 16),
                          if (_usesNASPlayback && _nasOptions != null)
                            CinemaNASInlinePlaybackControls(
                              options: _nasOptions!,
                              resolution:
                                  _nasResolution ?? _nasOptions!.defaultProfile,
                              audio: _nasAudio,
                              subtitle: _nasSubtitle,
                              enabled: !_closing,
                              onPlayerTracks: playback == null
                                  ? null
                                  : _showTracks,
                              onApply: (choice) =>
                                  unawaited(_applyNASPlaybackChoice(choice)),
                            ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _showEpisodes,
                                icon: const Icon(Icons.playlist_play),
                                label: Text(nativeCinema ? '选集与片源' : '线路 / 选集'),
                              ),
                              if (_canRetryDirect)
                                OutlinedButton.icon(
                                  onPressed: _retryDirect,
                                  icon: const Icon(Icons.network_check_rounded),
                                  label: const Text('启用视频直连并重试'),
                                ),
                              if (_fullscreen)
                                OutlinedButton.icon(
                                  onPressed: _toggleFullscreen,
                                  icon: const Icon(Icons.fullscreen_exit),
                                  label: const Text('退出全屏'),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          if (_loading || waitingForFirstFrame)
                            TextButton(
                              onPressed: _cancelLoading,
                              child: const Text('取消'),
                            )
                          else if (_episode != null)
                            Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              alignment: WrapAlignment.center,
                              children: [
                                FilledButton.tonalIcon(
                                  onPressed: () => _playEpisode(
                                    _routeIndex,
                                    _episodeIndex,
                                    resumeAt: playback?.ready == true
                                        ? playback!.position.inSeconds
                                        : null,
                                  ),
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('重试'),
                                ),
                                if (_title.routes.length > 1)
                                  OutlinedButton(
                                    onPressed: _tryNextRoute,
                                    child: const Text('更换线路'),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
          ],
        ),
      );
    },
  );

  bool get _canRetryDirect {
    final url = Uri.tryParse(_playback?.mediaUrl ?? _episode?.url ?? '');
    return widget.offlinePaths == null &&
        url != null &&
        NetworkConfig.forMedia().proxyForUri(url) != null;
  }

  void _cancelLoading() {
    if (_closing || (!_loading && _playback?.firstFrameRendered == true)) {
      return;
    }
    ++_generation;
    _cancelRouteProbe();
    _resolver.cancel();
    _loadTimer?.cancel();
    final current = _playback;
    _playback = null;
    if (current != null) {
      unawaited(current.player.pause().catchError((_) {}));
      unawaited(current.dispose());
    }
    setState(() {
      _loading = false;
      _error = '已取消加载';
    });
  }

  Future<void> _showSpeedOptions() async {
    final selected = await showDialog<double>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('倍速'),
        children: [
          for (final rate in defaultPlaySpeedList)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, rate),
              child: Text('$rate×'),
            ),
        ],
      ),
    );
    if (mounted && selected != null) await _setRate(selected);
  }

  Future<void> _showSuperResolutionOptions() async {
    final selected = await showDialog<SuperResolutionMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('超分辨率'),
        children: [
          for (final mode in SuperResolutionMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, mode),
              child: Text(
                mode == SuperResolutionMode.off
                    ? '关闭超分辨率'
                    : 'Anime4K · ${mode.label}',
              ),
            ),
        ],
      ),
    );
    if (mounted && selected != null) await _applyShader(selected);
  }

  Widget _speedControl() => PopupMenuButton<double>(
    tooltip: '倍速',
    onSelected: _setRate,
    enabled: _playback != null && !_loading,
    itemBuilder: (_) => [
      for (final rate in defaultPlaySpeedList)
        CheckedPopupMenuItem(
          value: rate,
          checked: _rate == rate,
          child: Text('$rate×'),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Text(_rate == 1 ? '倍速' : '$_rate×'),
    ),
  );

  void _seekBy(int seconds) {
    final playback = _playback;
    if (playback == null || !playback.ready) return;
    final target = (playback.position.inSeconds + seconds).clamp(
      0,
      playback.duration.inSeconds,
    );
    playback.watchdog.reset();
    _cancelTVBackground('用户正在定位播放进度', reset: true);
    unawaited(playback.player.seek(Duration(seconds: target)));
  }

  void _tryNextRoute() {
    _attempts = CinemaFailoverAttempts();
    _detailAttempts.clear();
    _failoverAnchor = _selection;
    if (_selection != null) _attempts.claim(_selection!);
    unawaited(_advanceAfterFailure('手动换线未找到可接续的线路。'));
  }

  void _switchLoadedRoute(CinemaTitle title, int route) {
    if (_closing) return;
    _automaticProbePending = false;
    if (_probingRoutes) {
      _cancelRouteProbe();
      setState(() => _probeStatus = '已手动选择，取消自动切换');
    }
    if (_closing ||
        (_playback != null &&
            title.key == _title.key &&
            route == _routeIndex &&
            !_requiresEpisodeSelection)) {
      return;
    }
    final current = _selection;
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    final episode = current == null
        ? null
        : cinemaMatchPlaybackEpisode(
            current: current,
            target: title,
            routeIndex: route,
          );
    if (episode == null) {
      _selectForManual(title, route);
      return;
    }
    unawaited(
      _playEpisode(
        route,
        episode,
        title: title,
        source: _catalogue.sourceFor(title),
        resumeAt: position,
      ),
    );
  }

  int _positionForEpisode(
    int routeIndex,
    int episodeIndex, {
    CinemaTitle? title,
  }) {
    final selected = title ?? _title;
    final playback = _playback;
    if (playback != null &&
        playback.ready &&
        playback.title.key == selected.key &&
        playback.routeIndex == routeIndex &&
        playback.episodeIndex == episodeIndex) {
      return playback.completed ? 0 : playback.position.inSeconds;
    }
    final saved = _lastPlaybackProgress;
    if (saved != null &&
        saved.titleKey == selected.key &&
        saved.routeIndex == routeIndex &&
        saved.episodeIndex == episodeIndex) {
      return saved.positionSeconds;
    }
    return cinemaResumePosition(
      selected,
      _preferences.resume ? widget.store.historyFor(selected) : null,
      routeIndex,
      episodeIndex,
    );
  }

  String _routeProbeLabel(
    CinemaTitle title,
    int route, {
    bool recommended = false,
  }) {
    final selection = _selection;
    if (selection == null) return '';
    final index = cinemaMatchPlaybackEpisode(
      current: selection,
      target: title,
      routeIndex: route,
    );
    if (index == null) return '';
    final result = _probeResults['${title.key}::$route::$index'];
    return result == null
        ? ''
        : '\n${recommended ? '本次最佳 · ' : ''}${result.labelForRate(_rate)}';
  }

  Widget _routeRecommendation({bool compact = false}) {
    final best = _bestMeasuredRoute;
    return Container(
      key: ValueKey(
        compact ? 'route-recommendation-panel' : 'route-recommendation-main',
      ),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _copper.withValues(alpha: .09),
        border: Border.all(color: _copper.withValues(alpha: .55)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_probingRoutes)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: _copper,
                  ),
                )
              else
                Icon(
                  best == null ? Icons.speed : Icons.workspace_premium,
                  size: 21,
                  color: _copper,
                ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  _probingRoutes
                      ? '正在寻找最优线路'
                      : best != null
                      ? '本次最佳线路'
                      : '测速结果',
                  style: const TextStyle(
                    color: _copper,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_probeTotal > 0)
                Text(
                  '$_probeCompleted/$_probeTotal',
                  style: const TextStyle(color: _text, fontSize: 12),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_probingRoutes && best != null) ...[
            Text(
              '${best.candidate.source.name} · ${best.candidate.route.name}',
              style: const TextStyle(color: _text, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              '${best.result.mbps!.toStringAsFixed(1)} Mbps',
              style: TextStyle(
                color: _copper,
                fontSize: compact ? 22 : 28,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              best.result.labelForRate(_rate),
              style: const TextStyle(color: _text, fontSize: 12),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            _probeStatus ?? '按实测速度和码率余量推荐',
            style: const TextStyle(color: _muted, fontSize: 12, height: 1.5),
          ),
          if (!_probingRoutes &&
              best != null &&
              _selection?.key != best.candidate.key)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton.icon(
                onPressed: () => _useBestRoute(best),
                icon: const Icon(Icons.bolt, size: 18),
                label: const Text('使用推荐线路'),
              ),
            ),
        ],
      ),
    );
  }

  bool _isSelectedEpisode(int index) =>
      !_requiresEpisodeSelection && index == _episodeIndex;

  Widget _episodePanel({bool embedded = false}) {
    final route = _route;
    final best = _probingRoutes ? null : _bestMeasuredRoute;
    final currentEpisodeKey = GlobalKey();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text(
              '播放列表',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            IconButton(
              tooltip: '定位当前集',
              icon: const Icon(Icons.my_location, size: 19),
              onPressed: () {
                final current = currentEpisodeKey.currentContext;
                if (current != null) {
                  Scrollable.ensureVisible(
                    current,
                    duration: _preferences.disableAnimations
                        ? Duration.zero
                        : const Duration(milliseconds: 180),
                    alignment: .35,
                  );
                }
              },
            ),
            IconButton(
              tooltip: _reverseEpisodes ? '选集正序' : '选集倒序',
              icon: const Icon(Icons.swap_vert),
              onPressed: () {
                setState(() => _reverseEpisodes = !_reverseEpisodes);
                unawaited(
                  widget.store.setExtra('reverseEpisodes', _reverseEpisodes),
                );
              },
            ),
            Text(
              '${route?.episodes.length ?? 0} 集',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Text('播放线路', style: TextStyle(color: _muted, fontSize: 12)),
            const Spacer(),
            if (NakuDevice.canDownload && widget.offlinePaths == null)
              TextButton.icon(
                onPressed: _probingRoutes ? null : _probeRoutes,
                icon: const Icon(Icons.speed, size: 18),
                label: Text(
                  _probingRoutes ? '测速 $_probeCompleted/$_probeTotal' : '重新测速',
                ),
              ),
          ],
        ),
        if (widget.offlinePaths == null) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('打开影片时自动选线', style: TextStyle(fontSize: 12)),
            subtitle: const Text(
              '保留播放进度；手动选择会取消自动切换',
              style: TextStyle(fontSize: 11),
            ),
            value: _autoBestRoute,
            onChanged: (value) {
              setState(() {
                _autoBestRoute = value;
                _automaticProbePending = false;
                if (!value && _probingAutomatic) {
                  _cancelRouteProbe();
                  _probeStatus = '已关闭自动选线，保留当前线路';
                }
              });
              unawaited(widget.store.setExtra('autoBestRoute', value));
              if (value && _playback?.ready == true) {
                unawaited(_probeRoutes(automatic: true));
              }
            },
          ),
          if (_probingRoutes || _probeStatus != null || best != null) ...[
            _routeRecommendation(compact: true),
            const SizedBox(height: 12),
          ],
        ],
        const Text(
          '仅比较同一作品和集数；推荐基于本次实际视频读取，未解析的网页线路需先播放。',
          style: TextStyle(color: _muted, fontSize: 11),
        ),
        const SizedBox(height: 10),
        for (final variant in _catalogue.variants) ...[
          if (_catalogue.loaded(variant) case final detail?)
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (var i = 0; i < detail.routes.length; i++)
                  ChoiceChip(
                    key: ValueKey('playback-route:${detail.key}:$i'),
                    label: Text(
                      '${_catalogue.sourceFor(detail).name} · ${detail.routes[i].name}${_routeProbeLabel(detail, i, recommended: best?.candidate.title.key == detail.key && best?.candidate.routeIndex == i)}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _title.key == detail.key && _routeIndex == i,
                    avatar:
                        best?.candidate.title.key == detail.key &&
                            best?.candidate.routeIndex == i
                        ? const Icon(
                            Icons.workspace_premium,
                            color: _copper,
                            size: 18,
                          )
                        : null,
                    side:
                        best?.candidate.title.key == detail.key &&
                            best?.candidate.routeIndex == i
                        ? const BorderSide(color: _copper, width: 1.5)
                        : null,
                    onSelected: (_) => _switchLoadedRoute(detail, i),
                    selectedColor: _copper.withValues(alpha: .25),
                  ),
                if (detail.routes.isEmpty)
                  Text(
                    '${_catalogue.sourceFor(detail).name}：暂无线路',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
              ],
            )
          else
            OutlinedButton(
              onPressed: _catalogue.isLoading(variant)
                  ? null
                  : () => _loadAndSwitchVariant(variant),
              child: Text(
                '${_catalogue.sourceFor(variant).name} · ${_catalogue.isLoading(variant)
                    ? '读取中'
                    : _catalogue.errors.containsKey(variant.key)
                    ? '重试读取'
                    : '读取线路'}',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 20),
        if (route == null || route.episodes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Text('暂时没有集数', style: TextStyle(color: _muted)),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final index in List.generate(
                route.episodes.length,
                (i) => _reverseEpisodes ? route.episodes.length - 1 - i : i,
              ))
                SizedBox(
                  width: embedded ? 130 : 118,
                  child: OutlinedButton(
                    key: _isSelectedEpisode(index) ? currentEpisodeKey : null,
                    onPressed: () => _playEpisode(_routeIndex, index),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 14,
                      ),
                      backgroundColor: _isSelectedEpisode(index)
                          ? _copper.withValues(alpha: 0.12)
                          : _surface,
                      foregroundColor: _isSelectedEpisode(index)
                          ? _copper
                          : _text,
                      side: BorderSide(
                        color: _isSelectedEpisode(index) ? _copper : _line,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(7),
                      ),
                    ),
                    child: Text(
                      route.episodes[index].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 26),
        Text(
          _preferences.privateMode ? '隐身模式已开启，本次不会保存观看记录。' : '播放进度会自动保存在这台电脑。',
          style: const TextStyle(color: _muted, fontSize: 11, height: 1.7),
        ),
      ],
    );
    return embedded
        ? content
        : SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(22, 24, 22, 24),
            child: content,
          );
  }

  Widget _tag(String label, {bool accent = false}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: accent ? _copper.withValues(alpha: 0.1) : _surface,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: _line),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: accent ? _copper : _muted),
    ),
  );

  static String _time(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }
}

class _CinemaPlayback {
  _CinemaPlayback(
    this.title,
    this.routeIndex,
    this.episodeIndex,
    this.generation,
    this.preferences,
    this.createPlayer,
  );
  final CinemaTitle title;
  final int routeIndex;
  final int episodeIndex;
  final int generation;
  final CinemaPlayerPreferences preferences;
  final Player Function(PlayerConfiguration configuration)? createPlayer;
  late final Player player = _createPlayer();
  late final CinemaHomePodPlayerRoute homepodAudioRoute;

  Player _createPlayer() {
    final created =
        createPlayer?.call(preferences.playerConfiguration) ??
        (Platform.isAndroid && NakuDevice.isTV
            ? CinemaTVNativePlayer(
                configuration: preferences.playerConfiguration,
              )
            : Player(configuration: preferences.playerConfiguration));
    homepodAudioRoute = CinemaHomePodPlayerRoute(created);
    return created;
  }

  late final controller = VideoController(
    player,
    configuration: preferences.videoConfiguration,
  );
  late final liveSubtitles = CinemaLiveSubtitles(player);
  late final bufferMonitor = CinemaBufferMonitor(player);
  CinemaKeyboardTransport? keyboardTransport;
  CinemaSeasonSubtitleController? subtitles;
  CinemaSubtitleAutoSync? subtitleAutoSync;
  CinemaDanmakuController? danmaku;
  String lastStage = 'created';
  bool _controllerDiagnosticsAttached = false;

  void logStage(String stage) {
    lastStage = stage;
    KazumiLogger().i('Cinema playback $generation: $stage', forceLog: true);
  }

  void observeControllerInitialization() {
    if (player is CinemaTVNativePlayer) return;
    if (_controllerDiagnosticsAttached) return;
    _controllerDiagnosticsAttached = true;
    // Observe when the video surface first needs the lazy controller, without
    // moving its creation earlier in the playback lifecycle.
    unawaited(
      controller.platform.future.then<void>(
        (_) => logStage('controller-ready'),
        onError: (Object error, StackTrace _) {
          // Exception messages may contain media paths or URLs.
          logStage('controller-error(type=${error.runtimeType})');
        },
      ),
    );
  }

  final subscriptions = <StreamSubscription<dynamic>>[];
  Timer? fatalErrorTimer;
  final watchdog = CinemaPlaybackWatchdog();
  Timer? watchdogTimer;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  int width = 0;
  int height = 0;
  bool opened = false;
  bool firstFrameObserved = false, firstFrameRendered = false;
  Timer? firstFrameTimer;
  int manualPlaybackRevision = 0;
  String? mediaUrl;
  Map<String, String> mediaHeaders = const {};
  VideoSourceFormat mediaFormat = VideoSourceFormat.auto;
  CinemaCacheSession? cacheSession;
  CinemaNASPlaybackSession? nasSession;
  Stopwatch? firstFrameWatch;
  bool warmedNext = false;
  CancelToken? nextWarmup;

  void cancelNextWarmup(String reason) {
    final token = nextWarmup;
    if (token == null) return;
    nextWarmup = null;
    warmedNext = false;
    token.cancel(reason);
  }

  bool ready = false;
  bool completed = false;
  ({int position, int duration, bool completed})? persistedProgress;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    firstFrameTimer?.cancel();
    // Reading player also initializes its route binding if creation was lazy.
    final disposingPlayer = player;
    await homepodAudioRoute.dispose();
    if (disposingPlayer is CinemaTVNativePlayer) {
      try {
        await player.stop();
      } catch (_) {
        // Release below still closes a terminal MediaCodec error.
      }
    }
    await keyboardTransport?.close();
    try {
      await subtitles?.flush();
    } catch (_) {
      KazumiLogger().w('Cinema: subtitle preferences could not be saved');
    }
    subtitles?.close();
    subtitleAutoSync?.dispose();
    await danmaku?.close();
    cancelNextWarmup('播放已结束，取消下一集预热');
    liveSubtitles.dispose();
    bufferMonitor.dispose();
    // External close detaches its listeners synchronously. Persistence and
    // cancellation completion must not delay decoder or NAS task release.
    final closingExternal = closeCinemaExternalSubtitles(player);
    // Keep early errors observed while still awaiting/reporting them below.
    closingExternal.ignore();
    final closingNAS = nasSession?.close();
    try {
      await cacheSession?.close();
      watchdogTimer?.cancel();
      fatalErrorTimer?.cancel();
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
      await player.dispose();
    } finally {
      try {
        await closingExternal;
      } finally {
        await closingNAS;
      }
    }
  }
}
