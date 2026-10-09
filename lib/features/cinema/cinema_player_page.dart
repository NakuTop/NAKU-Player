import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/services/platform/desktop_window_close.dart';
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

bool cinemaUsesDirectMedia(
  CinemaSource source,
  CinemaRoute route,
  CinemaEpisode episode,
) =>
    episode.isDirect ||
    (source.kind == CinemaSourceKind.maccms &&
        RegExp(
          r'm3u8|\bmp4\b|\bhls\b|\bdirect\b',
          caseSensitive: false,
        ).hasMatch(route.name));

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
  });

  final CinemaTitle title;
  final CinemaSource source;
  final CinemaStore store;
  final int routeIndex;
  final int episodeIndex;
  final List<CinemaTitle> variants;
  final CinemaRepository? repository;
  final CinemaWatchTogether? watchTogether;
  final CinemaRatingsRepository? ratingsRepository;
  final CinemaDoubanReviewsRepository? reviewsRepository;
  final ValueChanged<DoubanRecommendation>? onRecommendationSelected;

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
  bool _closing = false;
  String _phase = '正在准备播放';
  String? _error;
  String? _historyError;
  String? _playbackNotice;
  double _rate = 1;
  double _volume = 100;
  bool _pip = false, _pipChanging = false;
  Completer<void>? _pipTransition;
  bool _fullscreen = false, _fullscreenChanging = false;
  Completer<void>? _fullscreenTransition;
  final _panelRevision = ValueNotifier<int>(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    // The route sheet shares this live state, including automatic source changes.
    _panelRevision.value++;
  }

  Future<void> _setFullscreen(bool next) async {
    if (await windowManager.isFullScreen() == next) {
      if (mounted && !_closing) setState(() => _fullscreen = next);
      return;
    }
    final transition = Completer<void>();
    _fullscreenTransition = transition;
    await windowManager.setFullScreen(next);
    // AppKit returns from toggleFullScreen before its window animation ends.
    // Wait for the actual transition before PiP reads or changes window bounds.
    try {
      await transition.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      if (await windowManager.isFullScreen() != next) rethrow;
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('收藏未保存，请检查磁盘空间后重试。')));
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
    playbackRate: () => _rate,
    applyRemote: (position, playing) async {
      final playback = _playback;
      if (playback == null || !playback.ready) return;
      playback.watchdog.reset();
      await playback.player.seek(position);
      if (!identical(playback, _playback)) return;
      if (playing) {
        await playback.player.play();
      } else {
        await playback.player.pause();
      }
    },
  );

  Future<void> _discoverRoutes() async {
    await for (final variants in discoverCinemaWorkSources(
      anchor: widget.title,
      known: widget.variants,
      sources: widget.store.enabledSources,
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
    if (_pipChanging) return;
    _pipChanging = true;
    final transition = Completer<void>();
    _pipTransition = transition;
    try {
      if (!_pip) {
        if (await windowManager.isFullScreen()) {
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法切换画中画')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前渲染器无法启用超分辨率，已保留原始画面。')));
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

  @override
  void initState() {
    super.initState();
    DesktopExitTasks.instance.register(this, _saveBeforeApplicationExit);
    _bindTogether();
    unawaited(_together.initialize());
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    unawaited(
      windowManager.isFullScreen().then((value) {
        if (mounted && !_closing) setState(() => _fullscreen = value);
      }),
    );
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
      if (mounted) unawaited(_playEpisode(_routeIndex, _episodeIndex));
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
    try {
      await widget.store.recordProgress(
        title: current.title,
        routeIndex: current.routeIndex,
        episodeIndex: current.episodeIndex,
        positionSeconds: current.position.inSeconds,
        durationSeconds: current.duration.inSeconds,
      );
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
  }) async {
    final selectedTitle = title ?? _title;
    final selectedSource = source ?? _source;
    if (_closing || selectedTitle.routes.isEmpty) return;
    final route = selectedTitle.routes[routeIndex];
    final offset =
        resumeAt ??
        _positionForEpisode(routeIndex, episodeIndex, title: selectedTitle);
    final old = _playback;
    final generation = ++_generation;
    unawaited(_together.clearPlaybackMedia(_syncOwner));
    _resolver.cancel();
    _loadTimer?.cancel();
    _playback = null;
    if (old != null) {
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
      _phase = automatic
          ? '自动换源 · ${selectedSource.name} / ${route.name}'
          : '正在连接片源';
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
    // Retain the intended position even if this route fails before becoming
    // ready. A subsequent route change can still continue the same episode.
    _lastPlaybackProgress = (
      titleKey: selectedTitle.key,
      routeIndex: routeIndex,
      episodeIndex: episodeIndex,
      positionSeconds: offset,
    );

    try {
      var mediaUrl = requireHttpUrl(episode.url).toString();
      if (!cinemaUsesDirectMedia(selectedSource, route, episode)) {
        setState(() => _phase = '正在解析播放页面');
        final resolved = await _resolver
            .resolve(
              mediaUrl,
              useLegacyParser: selectedSource.rule?['useLegacyParser'] == true,
              offset: offset,
              timeout: const Duration(seconds: 25),
            )
            .timeout(
              const Duration(seconds: 35),
              onTimeout: () {
                if (_isCurrent(generation)) _resolver.cancel();
                throw const VideoSourceTimeoutException(Duration(seconds: 35));
              },
            );
        if (!_isCurrent(generation)) return;
        mediaUrl = requireHttpUrl(resolved.url).toString();
      }
      if (!_isCurrent(generation)) return;
      // Each selection owns a player. A late response from an old selection
      // cannot seek, stop, or reopen the player's newer selection.
      final candidate = _CinemaPlayback(
        selectedTitle,
        routeIndex,
        episodeIndex,
        generation,
      );
      _playback = candidate;
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
      if (Platform.isMacOS && candidate.player.platform is NativePlayer) {
        final native = candidate.player.platform as NativePlayer;
        await native.setProperty('tls-verify', 'yes');
        if (!_isCurrent(generation)) return;
        await native.setProperty('tls-ca-file', '/etc/ssl/cert.pem');
        if (!_isCurrent(generation)) return;
        await native.setProperty(
          'http-proxy',
          MacOSSystemProxy.proxyFor(Uri.parse(mediaUrl))?.toString() ?? '',
        );
        if (!_isCurrent(generation)) return;
        candidate.logStage('native-config-ready');
      }
      candidate.logStage('open-start');
      await candidate.player.open(
        Media(
          mediaUrl,
          start: Duration(seconds: offset),
          httpHeaders: selectedSource.headers,
        ),
      );
      if (!_isCurrent(generation)) return;
      candidate.logStage('open-return');
      candidate.opened = true;
      _updateReady(candidate, generation);
    } on VideoSourceCancelledException {
      // Cancellation is expected when the user chooses another episode.
    } on VideoSourceTimeoutException {
      _fail(generation, '播放页面解析超时，请重试或更换线路。');
    } on FormatException catch (error) {
      _fail(generation, error.message.toString());
    } catch (_) {
      _fail(generation, '播放失败。片源可能暂时不可用，请重试或更换线路。');
    }
  }

  void _listenTo(_CinemaPlayback playback, int generation) {
    bool current() => _isCurrent(generation) && identical(_playback, playback);
    playback.subscriptions.addAll([
      playback.player.stream.position.listen((position) {
        if (!current()) return;
        if (position > playback.position &&
            _playbackNotice != null &&
            playback.ready) {
          setState(() => _playbackNotice = null);
        }
        playback.position = position;
      }),
      playback.player.stream.playing.listen((_) {
        if (current()) playback.watchdog.reset();
      }),
      playback.player.stream.duration.listen((duration) {
        if (!current()) return;
        playback.duration = duration;
        _updateReady(playback, generation);
      }),
      playback.player.stream.width.listen((width) {
        if (!current()) return;
        setState(() => playback.width = width ?? 0);
        _updateReady(playback, generation);
      }),
      playback.player.stream.height.listen((height) {
        if (!current()) return;
        setState(() => playback.height = height ?? 0);
        _updateReady(playback, generation);
      }),
      playback.player.stream.completed.listen((completed) {
        if (!current()) return;
        setState(() => playback.completed = completed);
        if (completed) unawaited(_persistProgress(playback));
      }),
      playback.player.stream.error.listen((message) {
        if (!current()) return;
        final fatal = RegExp(
          r'Failed to recognize file format|Failed to open|Nothing to play|No video or audio streams selected',
          caseSensitive: false,
        ).hasMatch(message);
        if (fatal && !playback.completed) {
          final at = playback.position;
          playback.fatalErrorTimer?.cancel();
          playback.fatalErrorTimer = Timer(const Duration(seconds: 3), () {
            if (current() && !playback.completed && playback.position <= at) {
              _fail(generation, '当前视频无法打开，正在尝试其他线路。');
            }
          });
        }
        // libmpv emits decoder fallback and transient TCP errors here too.
        // Keep playback running; a log line alone does not prove termination.
        final explanation = PlayerErrorMapper.toActionableMessage(
          message,
          isBuffering: playback.player.state.buffering,
        );
        debugPrint('Cinema playback notice: $message');
        setState(
          () => _playbackNotice = explanation ?? '播放器报告异常；若无法继续，可重试或更换线路。',
        );
      }),
    ]);
  }

  void _updateReady(_CinemaPlayback playback, int generation) {
    if (!_isCurrent(generation) ||
        playback.ready ||
        !playback.opened ||
        (playback.duration == Duration.zero && playback.width == 0)) {
      return;
    }
    playback.ready = true;
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
  }

  void _fail(int generation, String message) {
    if (!_isCurrent(generation)) return;
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
          .where((candidate) => !_attempts.contains(candidate))
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂时无法更改倍速，请在视频加载后重试。')));
      }
    }
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
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_persistProgress());
    }
  }

  @override
  void dispose() {
    DesktopExitTasks.instance.unregister(this);
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _panelRevision.dispose();
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
  Widget build(BuildContext context) {
    if (_fullscreen) {
      return Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent ||
              HardwareKeyboard.instance.isMetaPressed ||
              HardwareKeyboard.instance.isControlPressed) {
            return KeyEventResult.ignored;
          }
          final actions = <LogicalKeyboardKey, VoidCallback>{
            LogicalKeyboardKey.escape: _toggleFullscreen,
            LogicalKeyboardKey.keyF: _toggleFullscreen,
            LogicalKeyboardKey.keyE: _showEpisodes,
            LogicalKeyboardKey.keyP: _togglePip,
            LogicalKeyboardKey.keyW: () =>
                showCinemaSyncSheet(context, coordinator: _together),
            LogicalKeyboardKey.keyB: _toggleFavorite,
            LogicalKeyboardKey.space: () {
              _playback?.player.playOrPause();
            },
            LogicalKeyboardKey.arrowLeft: () => _seekBy(-10),
            LogicalKeyboardKey.arrowRight: () => _seekBy(10),
          };
          final action = actions[event.logicalKey];
          if (action == null) return KeyEventResult.ignored;
          action();
          return KeyEventResult.handled;
        },
        child: Theme(
          data: CinemaTheme.of(context),
          child: Scaffold(backgroundColor: Colors.black, body: _videoSurface()),
        ),
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
      const SizedBox(height: 20),
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
          const SizedBox(width: 12),
          if (_hasNext)
            FilledButton.tonalIcon(
              onPressed: () => _playEpisode(_routeIndex, _episodeIndex + 1),
              icon: const Icon(Icons.skip_next_rounded, size: 20),
              label: const Text('下一集'),
            ),
        ],
      ),
      const SizedBox(height: 16),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (_title.year.isNotEmpty) _tag(_title.year),
          if (_title.category.isNotEmpty) _tag(_title.category),
          if (_title.remarks.isNotEmpty) _tag('片源标注 · ${_title.remarks}'),
          if ((_playback?.width ?? 0) > 0 && (_playback?.height ?? 0) > 0)
            _tag(
              '媒体尺寸 · ${_playback!.width} × ${_playback!.height}',
              accent: true,
            ),
          OutlinedButton.icon(
            onPressed: _togglePip,
            icon: const Icon(Icons.picture_in_picture_alt, size: 17),
            label: const Text('画中画'),
          ),
          PopupMenuButton<SuperResolutionMode>(
            tooltip: '超分辨率',
            enabled: _playback?.ready == true,
            onSelected: _applyShader,
            itemBuilder: (_) => [
              for (final mode in SuperResolutionMode.values)
                CheckedPopupMenuItem(
                  value: mode,
                  checked: _superResolution == mode,
                  child: Text(
                    mode == SuperResolutionMode.off
                        ? '关闭超分辨率'
                        : 'Anime4K · ${mode.label}',
                  ),
                ),
            ],
            child: _tag('超分辨率 · ${_superResolution.label} ▾'),
          ),
          OutlinedButton.icon(
            onPressed: () =>
                showCinemaSyncSheet(context, coordinator: _together),
            icon: const Icon(Icons.group_outlined, size: 17),
            label: const Text('一起看'),
          ),
          OutlinedButton.icon(
            onPressed: _toggleFavorite,
            icon: Icon(
              widget.store.isFavorite(_title)
                  ? Icons.bookmark
                  : Icons.bookmark_border,
              size: 17,
            ),
            label: Text(widget.store.isFavorite(_title) ? '已收藏' : '收藏'),
          ),
          OutlinedButton.icon(
            onPressed: _showEpisodes,
            icon: const Icon(Icons.playlist_play, size: 18),
            label: const Text('线路 / 选集'),
          ),
          PopupMenuButton<double>(
            tooltip: '播放倍速',
            onSelected: _setRate,
            enabled: _playback != null && !_loading,
            itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                .map(
                  (rate) => CheckedPopupMenuItem<double>(
                    value: rate,
                    checked: rate == _rate,
                    child: Text('$rate×'),
                  ),
                )
                .toList(),
            child: _tag('倍速 $_rate×  ▾'),
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
      CinemaRatingsPanel(
        key: ValueKey('playing-work-details:${widget.title.key}'),
        // Playback routes belong to the same verified work. Keep its metadata
        // anchor stable while changing source or episode, including ID-less ones.
        title: widget.title,
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

  Widget _videoSurface() {
    final playback = _playback;
    playback?.observeControllerInitialization();
    final controlsTheme = MaterialDesktopVideoControlsThemeData(
      visibleOnMount: true,
      toggleFullscreenOnDoublePress: false,
      keyboardShortcuts: {
        const SingleActivator(LogicalKeyboardKey.space): () {
          playback?.player.playOrPause();
        },
        const SingleActivator(LogicalKeyboardKey.keyF): _toggleFullscreen,
        const SingleActivator(LogicalKeyboardKey.keyE): _showEpisodes,
        const SingleActivator(LogicalKeyboardKey.keyP): _togglePip,
        const SingleActivator(LogicalKeyboardKey.keyW): () =>
            showCinemaSyncSheet(context, coordinator: _together),
        const SingleActivator(LogicalKeyboardKey.keyB): _toggleFavorite,

        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_fullscreen) _toggleFullscreen();
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekBy(-10),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekBy(10),
      },
      buttonBarHeight: _pip ? 48 : 72,
      automaticallyImplySkipNextButton: false,
      automaticallyImplySkipPreviousButton: false,
      seekBarPositionColor: _copper,
      seekBarThumbColor: _copper,
      volumeBarActiveColor: _copper,
      topButtonBar: _pip
          ? const []
          : [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: CinemaGlass(
                    radius: 16,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        if (_fullscreen) ...[
                          Expanded(
                            child: Text(
                              '${_title.title} · ${_episode?.name ?? ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                        ] else
                          const Spacer(),
                        _videoAction(
                          '画中画',
                          Icons.picture_in_picture_alt,
                          _togglePip,
                        ),
                        PopupMenuButton<SuperResolutionMode>(
                          tooltip: '超分辨率',
                          enabled: playback?.ready == true,
                          onSelected: _applyShader,
                          itemBuilder: (_) => [
                            for (final mode in SuperResolutionMode.values)
                              CheckedPopupMenuItem(
                                value: mode,
                                checked: mode == _superResolution,
                                child: Text(
                                  mode == SuperResolutionMode.off
                                      ? '关闭超分辨率'
                                      : 'Anime4K · ${mode.label}',
                                ),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 12,
                            ),
                            child: Text(
                              '超分 · ${_superResolution.label}',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ),
                        _videoAction(
                          '一起看',
                          Icons.group_outlined,
                          () => showCinemaSyncSheet(
                            context,
                            coordinator: _together,
                          ),
                        ),
                        _videoAction(
                          widget.store.isFavorite(_title) ? '已收藏' : '收藏',
                          widget.store.isFavorite(_title)
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                          _toggleFavorite,
                        ),
                        _videoAction(
                          '线路 / 选集',
                          Icons.playlist_play,
                          _showEpisodes,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
      bottomButtonBar: [
        const MaterialDesktopPlayOrPauseButton(),
        const MaterialDesktopVolumeButton(),
        const MaterialDesktopPositionIndicator(),
        const Spacer(),
        IconButton(
          tooltip: _fullscreen ? '退出全屏' : '全屏',
          onPressed: _toggleFullscreen,
          icon: Icon(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
        ),
      ],
    );
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (playback != null)
            MaterialDesktopVideoControlsTheme(
              normal: controlsTheme,
              fullscreen: controlsTheme,
              child: Video(
                key: ValueKey(playback),
                controller: playback.controller,
                controls: MaterialDesktopVideoControls,
                pauseUponEnteringBackgroundMode: false,
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
                              icon: const Icon(Icons.refresh_rounded, size: 18),
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
  }

  Widget _videoAction(String label, IconData icon, VoidCallback action) =>
      !_fullscreen
      ? IconButton(
          tooltip: label,
          onPressed: action,
          icon: Icon(icon, size: 19),
        )
      : Tooltip(
          message: label,
          child: TextButton.icon(
            onPressed: action,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size(40, 40),
              padding: const EdgeInsets.symmetric(horizontal: 9),
            ),
            icon: Icon(icon, size: 18),
            label: Text(label, style: const TextStyle(fontSize: 12)),
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
      widget.store.historyFor(selected),
      routeIndex,
      episodeIndex,
    );
  }

  bool _isSelectedEpisode(int index) =>
      !_requiresEpisodeSelection && index == _episodeIndex;

  Widget _episodePanel({bool embedded = false}) {
    final route = _route;
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
            Text(
              '${route?.episodes.length ?? 0} 集',
              style: const TextStyle(color: _muted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 20),
        const Text('播放线路', style: TextStyle(color: _muted, fontSize: 12)),
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
                      '${_catalogue.sourceFor(detail).name} · ${detail.routes[i].name}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _title.key == detail.key && _routeIndex == i,
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
              for (var index = 0; index < route.episodes.length; index++)
                SizedBox(
                  width: embedded ? 130 : 118,
                  child: OutlinedButton(
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
        const Text(
          '播放进度会自动保存在这台电脑。',
          style: TextStyle(color: _muted, fontSize: 11, height: 1.7),
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
  );
  final CinemaTitle title;
  final int routeIndex;
  final int episodeIndex;
  final int generation;
  final player = Player(
    configuration: const PlayerConfiguration(
      title: 'NAKU播放器',
      osc: false,
      bufferSize: 64 * 1024 * 1024,
    ),
  );
  late final controller = VideoController(player);
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
  bool ready = false;
  bool completed = false;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();
  Future<void> _dispose() async {
    watchdogTimer?.cancel();
    fatalErrorTimer?.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
    await player.dispose();
  }
}
