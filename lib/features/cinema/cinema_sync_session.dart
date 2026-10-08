import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_models.dart';

String cinemaSyncIdentity(CinemaTitle title, CinemaEpisode episode) {
  String normalized(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceFirst(RegExp(r'[（(]?(原声版|普通话版|国语版|英语版)[）)]?$'), '');
  final text = normalized(episode.name);
  final number = RegExp(
    r'^(?:第|ep[._-]?|episode[._-]?)?0*([0-9]+)(?:集|话)?$',
  ).firstMatch(text);
  final isFilm =
      !RegExp('电视剧|连续剧|欧美剧|日韩剧|国产剧|港澳剧|动漫|动画|解说|影评').hasMatch(title.category) &&
      RegExp('片|电影').hasMatch(title.category);
  // A source may call a feature film either 正片 or HD; a lone series episode
  // remains an episode. Keep season, year and title as conservative safeguards.
  final ep = isFilm && title.routes.every((r) => r.episodes.length <= 1)
      ? 'film'
      : number == null
      ? text
      : 'ep${int.parse(number[1]!)}';
  final identity = jsonEncode([
    title.doubanId.trim(),
    normalized(title.title),
    title.year.trim(),
    ep,
  ]);
  return 'NAKU:${sha256.convert(utf8.encode(identity))}';
}

class _Member {
  const _Member(this.room, this.file);
  final String room, file;
}

/// Syncplay transports timing only. Every remote update is checked against the
/// sending member's room and work/episode, never against our own file echo.
class CinemaSyncSession extends ChangeNotifier {
  CinemaSyncSession({
    required this.position,
    required this.playing,
    required this.duration,
    required this.applyRemote,
    double Function()? playbackRate,
    SyncplayClient Function(String, int)? clientFactory,
    this.handshakeTimeout = const Duration(seconds: 15),
    this.tickInterval = const Duration(milliseconds: 250),
  }) : playbackRate = playbackRate ?? (() => 1),
       _factory = clientFactory ?? ((h, p) => SyncplayClient(host: h, port: p));
  final Duration Function() position, duration;
  final bool Function() playing;
  final double Function() playbackRate;
  final Future<void> Function(Duration, bool) applyRemote;
  final SyncplayClient Function(String, int) _factory;
  final Duration handshakeTimeout, tickInterval;
  SyncplayClient? _client;
  Completer<void>? _hello;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _members = <String, _Member>{};
  Timer? _timer;
  String room = '',
      lastRoom = '',
      status = '',
      endpoint = '',
      username = '',
      _identity = '';
  String _requestedRoom = '';
  bool connecting = false, _closed = false, _haveSnapshot = false;
  bool _seeded = false;
  int _generation = 0, _mediaGeneration = 0, _applySerial = 0;
  int? _activeApply;
  Map<String, dynamic>? _pendingRemote;
  Duration? _lastPosition;
  DateTime? _lastSample;
  bool? _lastPlaying;
  bool get connected => room.isNotEmpty;

  Iterable<_Member> get _peers => _members.entries
      .where((e) => e.key != username && e.value.room == room)
      .map((e) => e.value);
  bool get _compatible =>
      connected &&
      _haveSnapshot &&
      _identity.isNotEmpty &&
      _peers.every((m) => m.file == _identity);

  void _notify() {
    if (!_closed) notifyListeners();
  }

  void _updateStatus() {
    if (!connected) return;
    if (!_haveSnapshot ||
        _identity.isEmpty ||
        _peers.any((m) => m.file.isEmpty)) {
      status = '已连接 · 等待房间作品确认';
    } else if (_peers.any((m) => m.file != _identity)) {
      status = '房间作品或集数不同，请双方选择同一集';
    } else if (_peers.isEmpty) {
      status = '已连接 · 等待另一位观众';
    } else {
      status = '已连接 · 同步播放和进度';
    }
    _notify();
  }

  Future<void> connect({
    required String endpoint,
    required String roomName,
    required String username,
    bool tls = true,
  }) async {
    final address = parseSyncPlayEndPoint(endpoint);
    if (address == null || roomName.trim().isEmpty || username.trim().isEmpty) {
      throw const FormatException('请填写有效的服务器、房间和昵称');
    }
    if (_closed) throw StateError('同步窗口已关闭');
    final gen = ++_generation;
    final oldConnection = _detach();
    this.endpoint = endpoint.trim();
    this.username = username.trim();
    _requestedRoom = roomName.trim();
    lastRoom = _requestedRoom;
    connecting = true;
    status = '正在连接';
    _notify();
    await oldConnection;
    if (_closed || gen != _generation) return;
    final client = _client = _factory(address.host, address.port);
    final hello = _hello = Completer<void>();
    // Attach an error handler immediately, before the socket can fail. The
    // awaited branch below still receives the original handshake error.
    unawaited(hello.future.catchError((Object _) {}));
    bool current() =>
        !_closed && gen == _generation && identical(client, _client);
    try {
      _subscriptions.add(
        client.onGeneralMessage.listen(
          (message) {
            if (!current()) return;
            if (message['type'] == 'hello' || message.containsKey('room')) {
              if (message['room'] != _requestedRoom) {
                if (!hello.isCompleted) {
                  hello.completeError(const FormatException('服务器返回了不同房间'));
                }
                return;
              }
              this.username = '${message['username'] ?? username}';
              if (!hello.isCompleted) hello.complete();
            }
          },
          onError: (Object error) {
            if (!current()) return;
            if (!hello.isCompleted) hello.completeError(error);
            status = '同步连接中断：$error';
            unawaited(disconnect(clearStatus: false));
          },
        ),
      );
      _subscriptions.add(
        client.onRoomMessage.listen((message) {
          if (!current()) return;
          final type = message['type'];
          if (type == 'snapshot') {
            _members.clear();
            for (final user in (message['users'] as List? ?? const [])) {
              if (user is Map) _recordMember(user);
            }
            _haveSnapshot = true;
          } else if (type == 'left') {
            _members.remove(message['username']);
          } else if (type == 'joined' || type == 'updated') {
            _recordMember(message);
          }
          // playlistIndex's user means the last room-state setter, not whether
          // the room is empty. It must not authorize remote playback.
          _updateStatus();
          if (_compatible && _peers.isEmpty && !_seeded) {
            unawaited(_publishInitial());
          }
          _drainRemote();
        }),
      );
      _subscriptions.add(
        client.onFileChangedMessage.listen((message) {
          if (!current()) return;
          _recordMember({...message, 'username': message['setBy']});
          _updateStatus();
          _drainRemote();
        }),
      );
      _subscriptions.add(
        client.onPositionChangedMessage.listen((message) {
          if (!current()) return;
          _pendingRemote = message;
          _drainRemote();
        }),
      );
      await client.connect(
        enableTLS: tls || isOfficialSyncPlayEndPoint(address),
      );
      if (!current()) return;
      await client.joinRoom(_requestedRoom, this.username);
      await hello.future.timeout(handshakeTimeout);
      if (!current()) return;
      room = _requestedRoom;
      connecting = false;
      _sample();
      await _announce();
      if (!current()) return;
      await client.requestUserList();
      if (!current()) return;
      _updateStatus();
      _timer = Timer.periodic(tickInterval, (_) => unawaited(_tick()));
    } catch (error) {
      if (!current()) return;
      status = '连接失败：$error';
      await disconnect(clearStatus: false);
      rethrow;
    }
  }

  void _recordMember(Map<dynamic, dynamic> message) {
    final name = '${message['username'] ?? ''}';
    if (name.isEmpty) return;
    final previous = _members[name];
    final memberRoom = message['room']?.toString() ?? previous?.room ?? '';
    final file = message.containsKey('name')
        ? '${message['name'] ?? ''}'
        : previous?.file ?? '';
    _members[name] = _Member(memberRoom, file);
  }

  Future<void> updateMedia(CinemaTitle title, CinemaEpisode episode) async {
    final next = cinemaSyncIdentity(title, episode);
    if (next == _identity) return;
    ++_mediaGeneration;
    _identity = next;
    _pendingRemote = null;
    _sample();
    _updateStatus();
    if (connected) await _announce();
  }

  Future<void> _announce() async {
    final c = _client;
    final gen = _generation;
    if (c == null || !connected || !c.isConnected || _identity.isEmpty) return;
    try {
      await c.setSyncPlayPlaying(
        _identity,
        duration().inMilliseconds / 1000,
        0,
      );
    } catch (_) {
      if (gen != _generation) return;
      status = '暂时无法同步作品信息';
      _notify();
    }
  }

  bool _accepts(Map<String, dynamic> message) {
    final setter = message['setBy'];
    final peer = _members[setter];
    return _compatible &&
        setter != username &&
        peer != null &&
        peer.room == room &&
        peer.file == _identity;
  }

  bool _localSeek() {
    if (_lastPosition == null || _lastSample == null) return false;
    final elapsed = DateTime.now().difference(_lastSample!).inMilliseconds;
    final expected = _lastPlaying == true ? elapsed * playbackRate() : 0;
    return ((position() - _lastPosition!).inMilliseconds - expected).abs() >
        1500;
  }

  bool get _localChange =>
      _lastPlaying != null && (_lastPlaying != playing() || _localSeek());

  void _sample() {
    _lastPosition = position();
    _lastPlaying = playing();
    _lastSample = DateTime.now();
  }

  void _drainRemote() {
    if (_activeApply != null || _pendingRemote == null) return;
    final message = _pendingRemote!;
    if (!_accepts(message)) {
      if (_haveSnapshot) _pendingRemote = null;
      return;
    }
    if (duration() == Duration.zero) return;
    // Publish an observed local action before accepting an older heartbeat.
    // Otherwise a remote ping can undo a pause during the sampling interval.
    if (_localChange) {
      _pendingRemote = null;
      unawaited(_tick());
      return;
    }
    _pendingRemote = null;
    final raw = message['calculatedPositon'] ?? message['position'];
    if (raw is! num || !raw.isFinite || raw < 0 || message['paused'] is! bool) {
      return;
    }
    final target = Duration(milliseconds: (raw * 1000).round());
    if (target > duration() + const Duration(seconds: 5)) return;
    final remotePlaying = message['paused'] != true;
    final drift = (target - position()).inMilliseconds.abs();
    if (drift <= 1500 &&
        playing() == remotePlaying &&
        message['doSeek'] != true) {
      return;
    }
    final gen = _generation, media = _mediaGeneration;
    final token = _activeApply = ++_applySerial;
    unawaited(() async {
      try {
        await applyRemote(
          drift > 1500 || message['doSeek'] == true ? target : position(),
          remotePlaying,
        );
      } catch (_) {
        if (gen == _generation && media == _mediaGeneration) {
          status = '当前线路暂时不能同步进度';
          _notify();
        }
      } finally {
        if (gen == _generation && media == _mediaGeneration) _sample();
        if (_activeApply == token) {
          _activeApply = null;
          _drainRemote();
        }
      }
    }());
  }

  Future<void> _tick() async {
    final c = _client;
    final gen = _generation;
    if (c == null || !c.isConnected || _activeApply != null || !_compatible) {
      return;
    }
    final seek = _localSeek();
    final changed = _lastPlaying != null && _lastPlaying != playing();
    c.setPosition(position().inMilliseconds / 1000);
    c.setPaused(!playing());
    _sample();
    if (seek || changed) {
      try {
        await c.sendSyncPlaySyncRequest(doSeek: seek);
      } catch (_) {
        if (gen != _generation) return;
        status = '同步暂时不可用';
        _notify();
      }
    }
  }

  Future<void> _publishInitial() async {
    final c = _client;
    if (c == null || !c.isConnected || !_compatible || _seeded) return;
    _seeded = true;
    c.setPosition(position().inMilliseconds / 1000);
    c.setPaused(!playing());
    _sample();
    try {
      await c.sendSyncPlaySyncRequest(doSeek: true);
    } catch (_) {
      // A socket error is also reported on the connection stream.
    }
  }

  Future<void> _detach() async {
    _timer?.cancel();
    _timer = null;
    final c = _client;
    _client = null;
    final hello = _hello;
    _hello = null;
    if (hello != null && !hello.isCompleted) {
      hello.completeError(SyncplayConnectionException('连接已取消'));
    }
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    room = '';
    connecting = false;
    _haveSnapshot = false;
    _seeded = false;
    _members.clear();
    _pendingRemote = null;
    _activeApply = null;
    _lastPosition = null;
    _lastSample = null;
    _lastPlaying = null;
    await Future.wait(subscriptions.map((s) => s.cancel()));
    await c?.disconnect();
  }

  Future<void> disconnect({bool clearStatus = true}) async {
    final gen = ++_generation;
    final done = _detach();
    if (clearStatus) status = '';
    _notify();
    await done;
    if (gen == _generation) _notify();
  }

  @override
  void dispose() {
    _closed = true;
    unawaited(disconnect());
    super.dispose();
  }
}
