import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_models.dart';
import 'cinema_sync_session.dart';

class _Pairing {
  const _Pairing(this.endpoint, this.room, this.username);
  final String endpoint, room, username;
  Map<String, Object> toJson() => {
    'version': 1,
    'endpoint': endpoint,
    'room': room,
    'username': username,
  };
  static _Pairing parse(Map raw) {
    String read(String key, int limit) {
      final value = raw[key];
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > limit ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('配对信息无效');
      }
      return value.trim();
    }

    final endpoint = read('endpoint', 255);
    if (parseSyncPlayEndPoint(endpoint) == null) {
      throw const FormatException('一起看服务器格式无效');
    }
    return _Pairing(endpoint, read('room', 35), read('username', 16));
  }
}

class _Playback {
  const _Playback({
    required this.owner,
    required this.position,
    required this.duration,
    required this.playing,
    required this.playbackRate,
    required this.applyRemote,
    required this.closePlayback,
  });
  final Object owner;
  final Duration Function() position, duration;
  final bool Function() playing;
  final double Function() playbackRate;
  final Future<void> Function(Duration, bool) applyRemote;
  final Future<void> Function() closePlayback;
}

class _Follow {
  _Follow(this.peer);
  final CinemaPeerActivity peer;
  bool opened = false;
  bool ready = false;
}

/// App-owned room connection. Player ownership is separate from pairing, so
/// leaving a movie never disconnects the couple's room. Incoming messages only
/// update catalogue hints; navigation always requires requestFollow from the UI.
class CinemaWatchTogether extends ChangeNotifier {
  CinemaWatchTogether({
    File? pairingFile,
    SyncplayClient Function(String, int)? clientFactory,
    this.reconnectDelays = const [
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
    this.followTimeout = const Duration(seconds: 90),
    this.tls = true,
    Duration handshakeTimeout = const Duration(seconds: 15),
    Duration tickInterval = const Duration(milliseconds: 250),
  }) : _file = pairingFile {
    session = CinemaSyncSession(
      position: () => _playback?.position() ?? Duration.zero,
      duration: () => _playback?.duration() ?? Duration.zero,
      playing: () => _playback?.playing() ?? false,
      playbackRate: () => _playback?.playbackRate() ?? 1,
      applyRemote: (position, playing) async {
        final player = _playback;
        if (player != null) await player.applyRemote(position, playing);
      },
      clientFactory: clientFactory,
      handshakeTimeout: handshakeTimeout,
      tickInterval: tickInterval,
    );
    session.addListener(_sessionChanged);
    _sessionNotices = session.notices.listen(_notice);
  }
  static final instance = CinemaWatchTogether();
  late final CinemaSyncSession session;
  final List<Duration> reconnectDelays;
  final Duration followTimeout;

  /// False is only for an explicitly injected local test fixture. Never saved.
  final bool tls;
  File? _file;
  Future<void>? _initialization;
  Future<void> _writes = Future.value();
  _Pairing? _pairing;
  _Playback? _playback;
  _Follow? _follow;
  CinemaSyncMedia? _canonical;
  Timer? _retry, _followTimer;
  int _generation = 0, _retryCount = 0;
  bool _closed = false, _attempting = false, _followingNavigation = false;
  final _notices = StreamController<String>.broadcast();
  late final StreamSubscription<String> _sessionNotices;

  Future<bool> Function(CinemaPeerActivity peer)? onFollowRequested;
  bool get isPaired => _pairing != null;
  bool get following => _follow != null || _followingNavigation;
  bool isCurrentFollow(CinemaPeerActivity peer) =>
      !_closed && session.connected && identical(_follow?.peer, peer);
  List<CinemaPeerActivity> get peers => session.peers;
  Stream<String> get notices => _notices.stream;
  String get endpoint => _pairing?.endpoint ?? session.endpoint;
  String get roomName => _pairing?.room ?? session.lastRoom;
  String get username => _pairing?.username ?? session.username;

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _notice(String value) {
    if (!_closed) _notices.add(value);
  }

  Future<void> initialize() => _initialization ??= _initialize();
  Future<void> _initialize() async {
    try {
      _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/watch-together-v1.json',
      );
      if (await _file!.exists()) {
        final raw = jsonDecode(await _file!.readAsString());
        if (raw is Map && raw['version'] == 1 && raw['paired'] != false) {
          _pairing = _Pairing.parse(raw);
        }
      }
    } on FormatException {
      _notice('保存的配对信息无法读取，请重新创建或加入房间。');
    } on FileSystemException {
      _notice('暂时无法读取一起看配对设置。');
    } catch (_) {
      _notice('暂时无法访问一起看配对设置，影片仍可正常播放。');
    }
    if (_closed) return;
    _notify();
    if (isPaired) unawaited(_connect(_generation));
  }

  Future<void> _save(_Pairing? pairing) {
    final contents = jsonEncode(
      pairing?.toJson() ?? {'version': 1, 'paired': false},
    );
    final task = _writes.then((_) async {
      final file = _file ??= File(
        '${(await getApplicationSupportDirectory()).path}/cinema/watch-together-v1.json',
      );
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(contents, flush: true);
      await temp.rename(file.path);
    });
    _writes = task.catchError((Object _) {});
    return task;
  }

  Future<void> pair({
    required String endpoint,
    required String roomName,
    required String username,
  }) async {
    await initialize();
    if (_closed) return;
    final pairing = _Pairing.parse({
      'endpoint': endpoint,
      'room': roomName,
      'username': username,
    });
    final gen = ++_generation;
    _retry?.cancel();
    _retryCount = 0;
    _cancelFollow();
    _canonical = null;
    _pairing = pairing;
    _attempting = false;
    await session.disconnect();
    if (gen != _generation || _closed) return;
    try {
      await _save(pairing);
    } catch (_) {
      if (gen == _generation) {
        _pairing = null;
        _notify();
      }
      rethrow;
    }
    if (gen != _generation || _closed) return;
    _notify();
    await _connect(gen);
  }

  Future<void> _connect(int gen) async {
    final pairing = _pairing;
    if (_closed || gen != _generation || pairing == null || _attempting) return;
    _retry?.cancel();
    _retry = null;
    _attempting = true;
    try {
      await session.connect(
        endpoint: pairing.endpoint,
        roomName: pairing.room,
        username: pairing.username,
        tls: tls,
      );
    } catch (_) {
      // Session carries a useful connection error; keep the saved pairing.
    } finally {
      if (gen == _generation && !_closed) {
        _attempting = false;
        _sessionChanged();
      }
    }
  }

  void _sessionChanged() {
    if (_closed) return;
    if (!session.connected && _follow != null) _cancelFollow();
    if (session.connected) {
      _retryCount = 0;
      _retry?.cancel();
      _retry = null;
    } else if (isPaired &&
        !_attempting &&
        !session.connecting &&
        _retry == null) {
      final delays = reconnectDelays.isEmpty
          ? const [Duration(seconds: 5)]
          : reconnectDelays;
      final delay = delays[_retryCount.clamp(0, delays.length - 1)];
      _retryCount++;
      final gen = _generation;
      _retry = Timer(delay, () {
        _retry = null;
        unawaited(_connect(gen));
      });
    }
    final follow = _follow;
    if (follow != null && follow.ready && follow.opened) {
      unawaited(_finishFollow(follow));
    }
    _notify();
  }

  Future<void> reconnect() async {
    await initialize();
    if (!isPaired || _closed) return;
    final gen = ++_generation;
    _cancelFollow();
    _retry?.cancel();
    _retry = null;
    _attempting = false;
    await session.disconnect();
    await _connect(gen);
  }

  Future<void> unpair() async {
    await initialize();
    final gen = ++_generation;
    _pairing = null;
    _attempting = false;
    _retry?.cancel();
    _retry = null;
    _cancelFollow();
    _canonical = null;
    _notify();
    await session.disconnect();
    if (gen != _generation || _closed) return;
    await _save(null);
  }

  void bindPlayback({
    required Object owner,
    required Duration Function() position,
    required Duration Function() duration,
    required bool Function() playing,
    required double Function() playbackRate,
    required Future<void> Function(Duration, bool) applyRemote,
    required Future<void> Function() closePlayback,
  }) {
    _playback = _Playback(
      owner: owner,
      position: position,
      duration: duration,
      playing: playing,
      playbackRate: playbackRate,
      applyRemote: applyRemote,
      closePlayback: closePlayback,
    );
    unawaited(session.clearMedia());
  }

  Future<void> clearPlaybackMedia(Object owner) async {
    if (!identical(_playback?.owner, owner)) return;
    _follow?.ready = false;
    await session.clearMedia();
  }

  Future<void> detachPlayback(Object owner) async {
    if (!identical(_playback?.owner, owner)) return;
    _playback = null;
    _canonical = null;
    if (_follow?.ready == true) _cancelFollow();
    await session.clearMedia();
  }

  Future<void> updateMedia(
    Object owner,
    CinemaTitle title,
    CinemaEpisode episode,
  ) async {
    if (_closed || !identical(_playback?.owner, owner)) return;
    final follow = _follow;
    final requested = follow?.peer.media;
    if (requested != null && !requested.matches(title, episode)) {
      _cancelFollow();
      _notice('当前选择了不同作品或集数，已取消跟随。');
    }
    if (requested != null && requested.matches(title, episode)) {
      _canonical = requested;
    }
    if (_canonical != null && !_canonical!.matches(title, episode)) {
      _canonical = null;
    }
    await session.updateMedia(title, episode, canonical: _canonical);
    if (_closed ||
        !identical(_playback?.owner, owner) ||
        !identical(follow, _follow)) {
      return;
    }
    if (follow != null &&
        requested != null &&
        requested.matches(title, episode)) {
      follow.ready = true;
      await session.requestPeerState(follow.peer);
      await _finishFollow(follow);
    }
  }

  CinemaPeerActivity? _currentPeer(CinemaPeerActivity peer) => peers
      .where(
        (p) =>
            p.username == peer.username &&
            p.media?.identity == peer.media?.identity,
      )
      .firstOrNull;

  Future<bool> requestFollow(CinemaPeerActivity peer) async {
    final navigate = onFollowRequested;
    if (_closed ||
        following ||
        !session.connected ||
        peer.media == null ||
        _currentPeer(peer) == null ||
        navigate == null) {
      return false;
    }
    final follow = _follow = _Follow(peer);
    _followingNavigation = true;
    final gen = _generation;
    _followTimer = Timer(followTimeout, () {
      if (identical(_follow, follow)) {
        _cancelFollow();
        _notice('跟随播放未就绪，可更换线路后重试。');
      }
    });
    _notify();
    try {
      await _playback?.closePlayback();
      if (_closed ||
          gen != _generation ||
          !identical(_follow, follow) ||
          _currentPeer(peer) == null) {
        return false;
      }
      final opened = await navigate(peer);
      if (_closed || gen != _generation || !identical(_follow, follow)) {
        return false;
      }
      if (!opened) {
        _cancelFollow();
        return false;
      }
      follow.opened = true;
      await _finishFollow(follow);
      return true;
    } catch (_) {
      if (!_closed) _notice('暂时无法跟随对方，请稍后重试。');
      return false;
    } finally {
      _followingNavigation = false;
      if (identical(_follow, follow) && !follow.opened) _cancelFollow();
      _notify();
    }
  }

  Future<void> _finishFollow(_Follow follow) async {
    if (!identical(_follow, follow) ||
        !follow.opened ||
        !follow.ready ||
        session.awaitingPeerState) {
      return;
    }
    if (!session.connected ||
        _currentPeer(follow.peer) == null ||
        session.localMedia?.identity != follow.peer.media?.identity) {
      _cancelFollow();
      _notice('对方已经切换作品，请重新选择跟随。');
      return;
    }
    _cancelFollow();
    try {
      final sent = await session.notifyFollowing(follow.peer);
      if (_closed || !session.connected) return;
      if (!sent) {
        _notice('已同步影片，但跟随通知未发送。');
        return;
      }
      _notice('已同步 ${follow.peer.username} 的播放进度，跟随通知已发送');
    } catch (_) {
      _notice('已打开影片，跟随通知暂未送达；连接恢复后可重试。');
    }
  }

  void _cancelFollow() {
    _follow = null;
    session.cancelExpectedPeerState();
    _followTimer?.cancel();
    _followTimer = null;
    _notify();
  }

  @override
  void dispose() {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _retry?.cancel();
    _followTimer?.cancel();
    _playback = null;
    onFollowRequested = null;
    session.removeListener(_sessionChanged);
    unawaited(_sessionNotices.cancel());
    session.dispose();
    unawaited(_notices.close());
    super.dispose();
  }
}
