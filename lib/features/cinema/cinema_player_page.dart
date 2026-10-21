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
import 'cinema_external_subtitles.dart';
import 'cinema_season_subtitle_controller.dart';
import 'cinema_mobile_playback_bar.dart';
import 'cinema_media_cache.dart';
import 'cinema_media_transport.dart';
import 'cinema_route_probe.dart';
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
  _CinemaPlayback? _playback;
  Timer? _historyTimer;
  Timer? _loadTimer;
  int _generation = 0;
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
  double? _beforeForwardRate;
  bool _forwardHeld = false;
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
  int? _nasAudio, _nasSubtitle;
  final _playerFocus = FocusScopeNode(debugLabel: 'NAKU player');
  Timer? _volumeSaveTimer;
  final _volumePersistence = CinemaVolumePersistence();
  bool _pip = false, _pipChanging = false;
  Completer<void>? _pipTransition;
  bool _fullscreen = false, _fullscreenChanging = false;
  // Keep the existing native video output alive across fullscreen/PiP layouts.
  final _videoSurfaceKey = GlobalKey(debugLabel: 'cinema-video-surface');
  bool _tvControlsVisible = true;
  bool _androidPip = false;
  Timer? _tvControlsTimer;
  void _scheduleTVControlsHide() {
    _tvControlsTimer?.cancel();
    _tvControlsTimer = Timer(const Duration(seconds: 8), () {
      if (mounted &&
          NakuDevice.isTV &&
          ModalRoute.of(context)?.isCurrent == true) {
        setState(() => _tvControlsVisible = false);
      }
    });
  }

  KeyEventResult _tvRemoteKey(KeyEvent event) {
    if (!NakuDevice.isTV ||
        event is! KeyDownEvent ||
        ModalRoute.of(context)?.isCurrent != true) {
      return KeyEventResult.ignored;
    }
    if (!_tvControlsVisible &&
        {
          LogicalKeyboardKey.select,
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        }.contains(event.logicalKey)) {
      setState(() => _tvControlsVisible = true);
      _scheduleTVControlsHide();
      return KeyEventResult.handled;
    }
    _scheduleTVControlsHide();
    return KeyEventResult.ignored;
  }

  Completer<void>? _fullscreenTransition;
  final _panelRevision = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    // The route sheet shares this live state, including automatic source changes.
    _panelRevision.value++;
  }

  Future<void> _setFullscreen(bool next) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setEnabledSystemUIMode(
        next ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
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
    if (!Platform.isMacOS) {
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

  Future<void> _showEpisodes() => showModalBottomSheet<void>(
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
      sources: _health.available(widget.store.enabledSources),
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
            widget.store.extras['autoBestRoute'] != false);
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
    if (!Platform.isAndroid && !Platform.isIOS) {
      unawaited(
        DesktopFullscreen.isFullScreen().then((value) {
          if (mounted && !_closing) setState(() => _fullscreen = value);
        }),
      );
    }
    _discovering = _discoverRoutes();
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
    _historyTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_persistProgress());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(
          _playEpisode(
            _routeIndex,
            _episodeIndex,
            resumeAt: widget.initialPositionSeconds,
            initial: true,
          ),
        );
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
    _pendingPlayIntent = playWhenReady ?? _preferences.autoPlay;
    if (_closing || selectedTitle.routes.isEmpty) return;
    final route = selectedTitle.routes[routeIndex];
    final offset =
        resumeAt ??
        _positionForEpisode(routeIndex, episodeIndex, title: selectedTitle);
    final watch = Stopwatch()..start();
    if (!automatic && !initial) _automaticProbePending = false;
    _cancelRouteProbe();
    _warmTimer?.cancel();
    for (final token in _probeTokens) {
      token.cancel('播放选择已变化');
    }
    _probeTokens.clear();
    final old = _playback;
    final generation = ++_generation;
    unawaited(_together.clearPlaybackMedia(_syncOwner));
    _resolver.cancel();
    _loadTimer?.cancel();
    _playback = null;
    if (old != null) {
      old.subtitles?.close();
      _volume = old.player.state.volume;
      unawaited(_persistProgress(old));
      unawaited(old.dispose());
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
    if (!automatic) {
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
        if (_nasReference != episode.url || _nasOptions == null) {
          final options = await _nasPlayback.options(episode.url);
          if (!_isCurrent(generation)) return;
          setState(() {
            _nasOptions = options;
            _nasReference = episode.url;
            _nasResolution = options.defaultProfile;
            _nasAudio = null;
            _nasSubtitle = -1;
          });
        }
        if (_nasResolution != nasOriginalFileProfile) {
          pendingNAS = await _nasPlayback.start(
            episode.url,
            resolution: _nasResolution,
            audio: _nasAudio,
            subtitle: _nasSubtitle,
          );
          if (!_isCurrent(generation)) return;
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
        final resolved = await resolveCinemaMedia(
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
      final subtitlePlaybackRevision = candidate.manualPlaybackRevision;
      candidate.nasSession = pendingNAS;
      candidate.subtitles = CinemaSeasonSubtitleController(
        player: candidate.player,
        client: widget.subtitleClientFactory?.call(),
        store: widget.store,
        seriesIdentity: selectedTitle.key,
        mediaIdentity: '${selectedTitle.key}|${episode.url}',
        query: CinemaSubtitleQuery.parse(
          selectedTitle.title,
          category: selectedTitle.category,
          episodeName: _subtitleEpisodeName,
          fallbackEpisode: episodeIndex + 1,
        ),
        imdbId: selectedTitle.imdbId,
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
          final cached = await _cache.open(
            mediaUrl,
            mediaHeaders,
            hls: mediaFormat == VideoSourceFormat.hls,
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
          _fail(generation, '视频连接超时，请重试或更换线路。');
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
        );
        if (!_isCurrent(generation)) return;
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
      await candidate.player.open(
        Media(
          mediaUrl,
          start: Duration(seconds: offset),
          httpHeaders: mediaHeaders,
        ),
        play:
            (playWhenReady ?? _preferences.autoPlay) &&
            !_backgroundPaused &&
            !_windowControls.blocksPlayback,
      );
      if (!_isCurrent(generation)) return;
      candidate.logStage('open-return');
      if (_windowControls.blocksPlayback) {
        await candidate.player.pause();
        if (!_isCurrent(generation)) return;
      }
      candidate.opened = true;
      _updateReady(candidate, generation);
      unawaited(
        candidate.subtitles!.load(
          onNotice: (message) {
            if (_isCurrent(generation) && identical(_playback, candidate)) {
              setState(() => _playbackNotice = message);
            }
          },
        ),
      );
    } on VideoSourceCancelledException {
      // Cancellation is expected when the user chooses another episode.
    } on VideoSourceTimeoutException {
      _fail(generation, '播放页面解析超时，请重试或更换线路。');
    } on FormatException catch (error) {
      _fail(generation, error.message.toString());
    } catch (_) {
      _fail(generation, '播放失败。片源可能暂时不可用，请重试或更换线路。');
    } finally {
      await pendingNAS?.close();
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
    final play = playback?.ready == true
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
    playback.subtitles?.beginManualSelection();
    await showCinemaTracksSheet(
      context,
      playback.player,
      widget.store,
      title: _title.title,
      imdbId: _title.imdbId,
      liveSubtitles: playback.liveSubtitles,
      category: _title.category,
      episodeName: _subtitleEpisodeName,
      episodeNumber: _episodeIndex + 1,
      onSubtitleApplied: (selection) => _rememberSubtitle(playback, selection),
      nasControls:
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

  String get _subtitleEpisodeName {
    final episode = _episode;
    if (episode == null) return '';
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
        playback.position = position;
        playback.cacheSession?.update(
          position,
          buffering: playback.player.state.buffering || _probingRoutes,
        );
        if (!playback.warmedNext &&
            playback.ready &&
            position.inSeconds > 15 &&
            playback.player.state.buffer.inSeconds - position.inSeconds >= 20) {
          unawaited(_warmNext(playback, generation));
        }
      }),
      playback.player.stream.buffering.listen((value) {
        if (!current()) return;
        if (value) playback.cancelNextWarmup('当前视频正在缓冲，暂停下一集预热');
        playback.cacheSession?.update(
          playback.position,
          buffering: value || _probingRoutes,
        );
      }),
      playback.player.stream.playing.listen((playing) {
        if (!current()) return;
        playback.watchdog.reset();
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
      playback.player.stream.volume.listen((volume) {
        if (!current() || !volume.isFinite || volume == _volume) return;
        _volume = volume.clamp(0, 100).toDouble();
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
            unawaited(_playEpisode(_routeIndex, next, resumeAt: 0));
          }
        }
      }),
      playback.player.stream.error.listen((message) {
        if (!current()) return;
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

  void _updateReady(_CinemaPlayback playback, int generation) {
    if (!_isCurrent(generation) ||
        playback.ready ||
        !playback.opened ||
        (playback.width <= 0 || playback.height <= 0)) {
      return;
    }
    playback.ready = true;
    _health.observe(
      _source,
      ok: true,
      media: true,
      firstFrameMs: playback.firstFrameWatch?.elapsedMilliseconds,
    );
    _warmTimer = Timer(const Duration(seconds: 12), () {
      if (_isCurrent(generation) && !playback.player.state.buffering) {
        unawaited(_probeCurrent(playback, generation));
        if (!playback.warmedNext) {
          unawaited(_warmNext(playback, generation));
        }
      }
    });
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
        _fail(generation, '视频已连续 30 秒没有播放进展，请重试或更换线路。');
      }
    });
    setState(() => _loading = false);
    if (_automaticProbePending) {
      _automaticProbePending = false;
      unawaited(_probeRoutes(automatic: true));
    }
  }

  void _fail(int generation, String message) {
    if (!_isCurrent(generation)) return;
    final selection = _selection;
    if (_playback?.cacheSession != null &&
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
    _health.observe(_source, ok: false, media: true, reason: '视频未能继续');
    if (selection != null && _probeResults.containsKey(selection.key)) {
      setState(
        () => _probeResults[selection.key] = const CinemaMediaProbeResult(
          ok: false,
          elapsedMs: 0,
          reason: '测速后播放失败',
        ),
      );
    }
    unawaited(_advanceAfterFailure(message));
  }

  void _releasePlayback() {
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
    while (_isCurrent(generation) && anchor != null && !_attempts.exhausted) {
      final next = _catalogue
          .matching(anchor)
          .where(
            (candidate) =>
                !_attempts.contains(candidate) &&
                !_health.cooling(candidate.source),
          )
          .firstOrNull;
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
          '（${_attempts.count} 条）。可重试或在播放列表中手动选择片源与集数。';
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
        widget.offlinePaths != null) {
      return;
    }
    final token = CancelToken();
    _probeTokens.add(token);
    final result = await _mediaProbe.measure(
      playback.mediaUrl!,
      playback.mediaHeaders,
      cancel: token,
      hls: playback.mediaFormat == VideoSourceFormat.hls,
    );
    _probeTokens.remove(token);
    if (!_isCurrent(generation) || token.isCancelled) return;
    final key = _selection?.key;
    if (key != null) setState(() => _probeResults[key] = result);
    _health.observe(
      _source,
      ok: result.ok,
      media: true,
      mbps: result.mbps,
      latencyMs: result.firstByteMs,
      reason: result.reason,
    );
  }

  Future<void> _warmNext(_CinemaPlayback playback, int generation) async {
    if (_source.id == cinemaNASSource.id) return;
    if (_probingRoutes ||
        !_isCurrent(generation) ||
        playback.warmedNext ||
        widget.offlinePaths != null ||
        _route == null ||
        playback.player.state.buffering ||
        playback.player.state.buffer - playback.position <
            const Duration(seconds: 20) ||
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
    _probeTokens.add(token);
    try {
      await _cache.warmNext(episode.url, _source.headers, cancel: token);
    } finally {
      _probeTokens.remove(token);
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
    return cinemaBestMeasuredRoute([
      for (final candidate in [
        current,
        ..._catalogue.matching(current).where((c) => c.key != current.key),
      ])
        if (_probeResults[candidate.key] case final result?)
          CinemaRouteMeasurement(candidate, result),
    ]);
  }

  Future<void> _useBestRoute(
    CinemaRouteMeasurement best, {
    bool automatic = false,
  }) async {
    if (_closing || _selection?.key == best.candidate.key) return;
    final position = _positionForEpisode(_routeIndex, _episodeIndex);
    final play = _playback?.opened == true
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
      selectionNotice: automatic ? '已自动选择本次最佳线路，保留播放进度' : '已使用本次推荐线路',
    );
  }

  Future<void> _probeRoutes({bool automatic = false}) async {
    if (_probingRoutes || _selection == null) return;
    final generation = _generation;
    for (final background in _probeTokens) {
      background.cancel('线路测速优先，暂停重复采样和下一集预热');
    }
    _probeTokens.clear();
    final token = _routeProbeToken = CancelToken();
    _probeTokens.add(token);
    setState(() {
      _probingRoutes = true;
      _probingAutomatic = automatic;
      _probeCompleted = _probeTotal = 0;
      _probeStatus = automatic ? '正在自动比较播放线路' : '正在比较播放线路';
      _routeComparisonAnchor = _selection;
      _probeResults.clear();
    });
    _playback?.cacheSession?.update(_playback!.position, buffering: true);
    try {
      // Give in-flight details a brief chance to join without delaying playback
      // for slow catalogue APIs. Web page resolvers are never navigated here.
      if (automatic && _discovering != null) {
        try {
          await _discovering!.timeout(const Duration(milliseconds: 1200));
        } catch (_) {}
      }
      if (!_isCurrent(generation) || token.isCancelled) return;
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
        ..._catalogue.matching(current).where((c) => c.key != current.key),
      ], resolved: resolved);
      setState(() => _probeTotal = targets.length);
      final measurements = await CinemaRouteProbeBatch(_mediaProbe).run(
        targets,
        cancel: token,
        budget: Duration(seconds: automatic ? 10 : 30),
        onResult: (target, result) {
          if (!_isCurrent(generation) || token.isCancelled) return;
          setState(() {
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
      if (!_isCurrent(generation) || token.isCancelled) return;
      final best = cinemaBestMeasuredRoute(measurements);
      setState(() {
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
      _probeTokens.remove(token);
      if (identical(_routeProbeToken, token)) {
        _routeProbeToken = null;
        if (mounted && !_closing) setState(() => _probingRoutes = false);
      }
      if (!_probingRoutes && mounted && !_closing) {
        final playback = _playback;
        playback?.cacheSession?.update(
          playback.position,
          buffering: playback.player.state.buffering,
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

  Future<void> _setRate(double rate) async {
    final playback = _playback;
    if (playback == null) return;
    try {
      await playback.player.setRate(rate);
      if (mounted && identical(playback, _playback)) {
        setState(() => _rate = rate);
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
    if (_closing || _loading || _requiresEpisodeSelection) return;
    final target = _episodeIndex + delta;
    if (target >= 0 && target < (_route?.episodes.length ?? 0)) {
      unawaited(_playEpisode(_routeIndex, target, resumeAt: 0));
    }
  }

  void _changeSpeed(int direction) {
    final choices = direction > 0
        ? defaultPlaySpeedList.where((value) => value > _rate)
        : defaultPlaySpeedList.reversed.where((value) => value < _rate);
    if (choices.isNotEmpty) unawaited(_setRate(choices.first));
  }

  Future<void> _holdForward() async {
    if (_closing || _playback == null) return;
    _forwardHeld = true;
    if (_rate < _preferences.longPressRate) {
      await _setRate(_preferences.longPressRate);
    }
  }

  Future<void> _releaseForward() async {
    final previous = _beforeForwardRate;
    final held = _forwardHeld;
    _beforeForwardRate = null;
    _forwardHeld = false;
    if (_closing || !mounted) return;
    if (held && previous != null) {
      await _setRate(previous);
    } else {
      _seekBy(_preferences.arrowSkipSeconds);
    }
  }

  Map<String, PlayerShortcutAction> get _keyboardActions => {
    'playorpause': _togglePlayback,
    'forward': () {
      _beforeForwardRate = _rate;
      _forwardHeld = false;
    },
    'rewind': () => _seekBy(-_preferences.arrowSkipSeconds),
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
      await playback.player.playOrPause();
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
    _closing = true;
    await _pipTransition?.future;
    if (_fullscreen) await _setFullscreen(false);
    if (_pip) {
      await _restoreWindow();
      _pip = false;
    }
    try {
      await _playback?.player.pause();
    } catch (_) {
      // Disposal below still closes a backend that is already failing.
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
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final revision = ++_lifecycleRevision;
    if (!_fullscreenChanging &&
        _fullscreenTransition == null &&
        !_pipChanging &&
        !_preferences.backgroundPlayback &&
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
    if (!_windowControls.blocksPlayback) return;
    _backgroundPaused = true;
    await _playback?.player.pause();
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
    _warmTimer?.cancel();
    _cancelRouteProbe();
    for (final token in _probeTokens) {
      token.cancel('播放器已关闭');
    }
    _probeTokens.clear();
    if (widget.mediaProbe == null) _mediaProbe.transport.dio.close(force: true);
    _volumeSaveTimer?.cancel();
    unawaited(_saveVolume());
    unawaited(_together.detachPlayback(_syncOwner));
    if (_pip) unawaited(_restoreWindow());
    _closing = true;
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
    canPop: !NakuDevice.isTV || !_fullscreen,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && NakuDevice.isTV && _fullscreen) {
        if (_tvControlsVisible) {
          setState(() => _tvControlsVisible = false);
        } else {
          unawaited(_setFullscreen(false));
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
              'forward': PlayerLongPressShortcutActions(
                onRepeat: _holdForward,
                onRelease: _releaseForward,
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
    if (_fullscreen) {
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

  Widget _mainColumn() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(aspectRatio: 16 / 9, child: _videoSurface()),
      ),
      const SizedBox(height: 12),
      _playbackTools(),
      const SizedBox(height: 20),
      if (widget.offlinePaths == null &&
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

  Widget _fullscreenPlaybackTools(BoxConstraints constraints) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Material(
        color: const Color(0xF2222222),
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 880,
            maxHeight: constraints.maxHeight * .35,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: _playbackTools(overlay: true),
          ),
        ),
      ),
    ),
  );

  Widget _videoSurface() => LayoutBuilder(
    key: _videoSurfaceKey,
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 850;
      final mobile =
          widget.mobileControls ??
          (!NakuDevice.isTV && (Platform.isAndroid || Platform.isIOS));
      final playback = _playback;
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
        // media_kit hides its primary controls while buffering. Keep the same
        // quality/track controls available so a stalled stream can be changed.
        bufferingIndicatorBuilder: (_) => _fullscreen && !_pip
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(),
                  ),
                  const SizedBox(height: 12),
                  _fullscreenPlaybackTools(constraints),
                ],
              )
            : const CircularProgressIndicator(color: Colors.white),
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
                                              _episodeIndex > 0 && !_loading
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
                                          onPressed: _hasNext && !_loading
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
                                          _speedControl(),
                                          if (_fullscreen) ...[
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
                                          IconButton(
                                            constraints:
                                                const BoxConstraints.tightFor(
                                                  width: 36,
                                                  height: 40,
                                                ),
                                            padding: EdgeInsets.zero,
                                            tooltip: _usesNASPlayback
                                                ? '外挂字幕 / 播放器音轨'
                                                : '字幕与音轨',
                                            icon: const Icon(
                                              Icons.closed_caption_outlined,
                                            ),
                                            onPressed: playback == null
                                                ? null
                                                : _showTracks,
                                          ),
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
                                            tooltip: '线路 / 选集',
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
                      ListenableBuilder(
                        listenable: Listenable.merge([
                          widget.store,
                          cinemaExternalSubtitleState(playback.player).active,
                        ]),
                        builder: (context, _) => Video(
                          key: ValueKey(playback),
                          controller: playback.controller,
                          fit: _preferences.aspectRatio.fit,
                          aspectRatio:
                              _preferences.aspectRatio.frameAspectRatio,
                          controls: NakuDevice.isTV || _androidPip
                              ? NoVideoControls
                              : MaterialDesktopVideoControls,
                          subtitleViewConfiguration:
                              CinemaSubtitleAppearance.from(
                                widget.store.extras['subtitleAppearance'],
                              ).configurationFor(
                                visible: !cinemaExternalSubtitleState(
                                  playback.player,
                                ).active.value,
                              ),
                          pauseUponEnteringBackgroundMode: false,
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
            if (playback != null)
              Positioned(
                left: 20,
                right: 20,
                bottom: _pip ? 12 : 74,
                child: IgnorePointer(
                  child: ListenableBuilder(
                    listenable: playback.liveSubtitles,
                    builder: (context, _) => playback.liveSubtitles.text.isEmpty
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
                                    widget.store.extras['subtitleAppearance'],
                                  ).fontSize,
                                ),
                              ),
                            ),
                          ),
                  ),
                ),
              ),
            if (NakuDevice.isTV &&
                _tvControlsVisible &&
                playback != null &&
                !_loading &&
                _error == null)
              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  color: const Color(0xD9000000),
                  padding: const EdgeInsets.fromLTRB(32, 12, 32, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StreamBuilder<Duration>(
                        stream: playback.player.stream.position,
                        initialData: playback.position,
                        builder: (_, snapshot) => Text(
                          '${_title.title} · ${snapshot.data?.toString().split('.').first ?? '0:00:00'}',
                          style: const TextStyle(fontSize: 18),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          IconButton(
                            tooltip: '后退 10 秒',
                            onPressed: () => _seekBy(-10),
                            icon: const Icon(Icons.replay_10, size: 32),
                          ),
                          FilledButton.icon(
                            autofocus: true,
                            onPressed: _togglePlayback,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('播放 / 暂停'),
                          ),
                          IconButton(
                            tooltip: '前进 10 秒',
                            onPressed: () => _seekBy(10),
                            icon: const Icon(Icons.forward_10, size: 32),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _showEpisodes,
                            child: const Text('选集 / 线路'),
                          ),
                          TextButton(
                            onPressed: _showSpeedOptions,
                            child: const Text('倍速'),
                          ),
                          if (_fullscreen)
                            TextButton(
                              onPressed: () => _setFullscreen(false),
                              child: const Text('影片详情'),
                            ),
                          TextButton(
                            onPressed: _toggleFavorite,
                            child: Text(
                              widget.store.isFavorite(_title) ? '已收藏' : '收藏',
                            ),
                          ),
                        ],
                      ),
                      if (_usesNASPlayback) _playbackTools(overlay: true),
                    ],
                  ),
                ),
              ),
            if (_loading || _error != null)
              ColoredBox(
                color: const Color(0xEE0B0C0D),
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_loading)
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
                          _error ?? _phase,
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
                              label: const Text('线路 / 选集'),
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
                        if (_loading)
                          TextButton(
                            onPressed: () {
                              ++_generation;
                              _resolver.cancel();
                              _loadTimer?.cancel();
                              final current = _playback;
                              _playback = null;
                              if (current != null) unawaited(current.dispose());
                              setState(() {
                                _loading = false;
                                _error = '已取消加载';
                              });
                            },
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
        (title.key == _title.key &&
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
        : '\n${recommended ? '本次最佳 · ' : ''}${result.label}';
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
              best.result.label,
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
  late final player =
      createPlayer?.call(preferences.playerConfiguration) ??
      Player(configuration: preferences.playerConfiguration);
  late final controller = VideoController(
    player,
    configuration: preferences.videoConfiguration,
  );
  late final liveSubtitles = CinemaLiveSubtitles(player);
  CinemaSeasonSubtitleController? subtitles;
  String lastStage = 'created';
  bool _controllerDiagnosticsAttached = false;

  void logStage(String stage) {
    lastStage = stage;
    KazumiLogger().i('Cinema playback $generation: $stage', forceLog: true);
  }

  void observeControllerInitialization() {
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
    subtitles?.close();
    cancelNextWarmup('播放已结束，取消下一集预热');
    liveSubtitles.dispose();
    await closeCinemaExternalSubtitles(player);
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
      await closingNAS;
    }
  }
}
