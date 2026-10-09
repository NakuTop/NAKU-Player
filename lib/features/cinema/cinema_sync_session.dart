import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:kazumi/services/player/syncplay_client.dart';
import 'package:kazumi/services/player/syncplay_endpoint.dart';
import 'cinema_models.dart';
import 'cinema_playback_candidates.dart';

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

/// Public catalogue hints only: never a playable URL, HTTP headers, or tokens.
class CinemaSyncMedia {
  const CinemaSyncMedia({
    required this.identity,
    required this.title,
    required this.year,
    required this.category,
    required this.doubanId,
    required this.episodeName,
  });
  factory CinemaSyncMedia.fromSelection(
    CinemaTitle title,
    CinemaEpisode episode,
  ) => CinemaSyncMedia(
    identity: cinemaSyncIdentity(title, episode),
    title: title.title,
    year: title.year,
    category: title.category,
    doubanId: title.doubanId,
    episodeName: episode.name,
  );
  final String identity, title, year, category, doubanId, episodeName;
  bool matches(CinemaTitle title, CinemaEpisode episode) {
    final anchor = CinemaTitle(
      id: identity,
      sourceId: 'sync-peer',
      title: this.title,
      year: year,
      category: category,
      doubanId: doubanId,
      routes: [
        CinemaRoute(
          name: 'peer',
          episodes: [CinemaEpisode(name: episodeName, url: '')],
        ),
      ],
    );
    const source = CinemaSource(
      id: 'sync-peer',
      name: 'Peer',
      kind: CinemaSourceKind.maccms,
      url: '',
    );
    final current = CinemaPlaybackCandidate(
      title: anchor,
      source: source,
      routeIndex: 0,
      episodeIndex: 0,
    );
    if (!cinemaSamePlaybackWork(anchor, title)) return false;
    for (var r = 0; r < title.routes.length; r++) {
      final index = cinemaMatchPlaybackEpisode(
        current: current,
        target: title,
        routeIndex: r,
      );
      if (index != null) {
        final matched = title.routes[r].episodes[index];
        if (identical(matched, episode) ||
            (matched.name == episode.name && matched.url == episode.url)) {
          return true;
        }
      }
    }
    // Catalogue-only fixtures and callers without routes still get strict
    // identity matching; cross-source adoption always needs a concrete route.
    return cinemaSyncIdentity(title, episode) == identity;
  }

  Map<String, String> toJson() => {
    'identity': identity,
    'title': title,
    'year': year,
    'category': category,
    'doubanId': doubanId,
    'episodeName': episodeName,
  };
  static CinemaSyncMedia? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? field(String key, int limit, {bool required = false}) {
      final value = raw[key];
      if (value is! String ||
          value.length > limit ||
          (required && value.trim().isEmpty) ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        return null;
      }
      return value;
    }

    final identity = field('identity', 69, required: true);
    final title = field('title', 160, required: true);
    final year = field('year', 16), category = field('category', 64);
    final douban = field('doubanId', 24),
        episode = field('episodeName', 80, required: true);
    if (identity == null ||
        !RegExp(r'^NAKU:[a-f0-9]{64}$').hasMatch(identity) ||
        title == null ||
        year == null ||
        category == null ||
        douban == null ||
        episode == null) {
      return null;
    }
    return CinemaSyncMedia(
      identity: identity,
      title: title,
      year: year,
      category: category,
      doubanId: douban,
      episodeName: episode,
    );
  }
}

class CinemaPeerActivity {
  const CinemaPeerActivity({required this.username, this.media});
  final String username;
  final CinemaSyncMedia? media;
}

class _Fragments {
  _Fragments(this.id, this.total) : created = DateTime.now();
  final String id;
  final int total;
  final DateTime created;
  final parts = <int, String>{};
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
  final _peerMedia = <String, CinemaSyncMedia>{};
  final _notices = StreamController<String>.broadcast();
  final _seenNotices = <String>{};
  final _activityRequests = <String, DateTime>{};
  CinemaSyncMedia? _localMedia;
  Future<void> _announceTail = Future.value();
  int _noticeSerial = 0, _messageSerial = 0, _chatLimit = 50;
  bool _chatAvailable = true;
  final _fragments = <String, _Fragments>{};
  Future<void> _messageTail = Future.value();
  static const _messagePrefix = 'NAKU2:';
  Timer? _timer;
  String room = '',
      lastRoom = '',
      status = '',
      endpoint = '',
      username = '',
      _identity = '';
  String _requestedRoom = '';
  bool connecting = false, _closed = false, _haveSnapshot = false;
  bool _seeded = false, _awaitingPeerState = false;
  bool get awaitingPeerState => _awaitingPeerState;
  int _generation = 0, _mediaGeneration = 0, _applySerial = 0;
  int? _activeApply;
  Map<String, dynamic>? _pendingRemote;
  Duration? _lastPosition;
  DateTime? _lastSample;
  bool? _lastPlaying;
  bool get connected => room.isNotEmpty;
  Stream<String> get notices => _notices.stream;
  CinemaSyncMedia? get localMedia => _localMedia;
  List<CinemaPeerActivity> get peers =>
      _members.entries
          .where((e) => e.key != username && e.value.room == room)
          .map(
            (e) => CinemaPeerActivity(
              username: e.key,
              media: _peerMedia[e.key]?.identity == e.value.file
                  ? _peerMedia[e.key]
                  : null,
            ),
          )
          .toList()
        ..sort((a, b) => a.username.compareTo(b.username));

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
    if (!_chatAvailable) {
      status = '已连接 · 服务器未启用聊天，作品跟随不可用';
    } else if (!_haveSnapshot ||
        _identity.isEmpty ||
        _peers.any((m) => m.file.isEmpty)) {
      status = '已连接 · 等待房间作品确认';
    } else if (_peers.any((m) => m.file != _identity)) {
      status = '房间作品或集数不同，请双方选择同一集';
    } else if (_awaitingPeerState) {
      status = '已连接 · 等待对方播放进度';
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
              final features = message['features'];
              if (features is Map) {
                final limit = features['maxChatMessageLength'];
                if (limit is int) _chatLimit = limit.clamp(30, 150);
                _chatAvailable = features['chat'] != false;
              }
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
            _peerMedia.removeWhere((name, _) => _members[name]?.room != room);
            _activityRequests.removeWhere(
              (name, _) => _members[name]?.room != room,
            );
            _fragments.removeWhere((name, _) => _members[name]?.room != room);
            _haveSnapshot = true;
          } else if (type == 'left') {
            _members.remove(message['username']);
            _peerMedia.remove(message['username']);
            _activityRequests.remove(message['username']);
            _fragments.remove(message['username']);
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
        client.onChatMessage.listen((message) {
          if (current()) _receiveActivity(message);
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
      await _sendEnvelope(client, {'type': 'request'});
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

  Future<void> updateMedia(
    CinemaTitle title,
    CinemaEpisode episode, {
    CinemaSyncMedia? canonical,
  }) async {
    if (canonical != null && !canonical.matches(title, episode)) {
      throw const FormatException('一起看作品或集数不匹配');
    }
    final next = canonical?.identity ?? cinemaSyncIdentity(title, episode);
    if (next == _identity) return;
    ++_mediaGeneration;
    _identity = next;
    _awaitingPeerState = canonical != null;
    _localMedia = canonical ?? CinemaSyncMedia.fromSelection(title, episode);
    _pendingRemote = null;
    _sample();
    _updateStatus();
    if (connected) await _announce();
  }

  /// Keep the room connection while telling the partner we are in the library.
  Future<void> clearMedia() async {
    ++_mediaGeneration;
    _identity = '';
    _awaitingPeerState = false;
    _localMedia = null;
    _pendingRemote = null;
    _lastPlaying = null;
    _lastPosition = null;
    _lastSample = null;
    _updateStatus();
    if (connected) await _announce();
  }

  Future<void> _announce() {
    final gen = _generation, media = _mediaGeneration;
    final task = _announceTail.then((_) async {
      final c = _client;
      bool current() =>
          gen == _generation &&
          media == _mediaGeneration &&
          identical(c, _client) &&
          !_closed;
      if (!current() || c == null || !connected || !c.isConnected) return;
      try {
        await c.setSyncPlayPlaying(
          _identity,
          duration().inMilliseconds / 1000,
          0,
        );
        if (!current()) return;
        await _sendActivity(c);
      } catch (_) {
        if (!current()) return;
        status = '暂时无法同步作品信息';
        _notify();
      }
    });
    _announceTail = task.catchError((Object _) {});
    return task;
  }

  Future<bool> _sendActivity(SyncplayClient client) =>
      _sendEnvelope(client, {'type': 'media', 'media': _localMedia?.toJson()});

  // Syncplay truncates chat to the negotiated character limit (150 by default,
  // 50 on older servers). ASCII frames keep even non-BMP titles intact.
  Future<bool> _sendEnvelope(
    SyncplayClient client,
    Map<String, Object?> message,
  ) {
    final gen = _generation;
    final encoded = base64Encode(utf8.encode(jsonEncode(message)));
    if (encoded.length > 4000 || !_chatAvailable) return Future.value(false);
    final task = _messageTail.then((_) async {
      final size = (_chatLimit - 30).clamp(1, 120);
      final total = (encoded.length / size).ceil();
      if (total > 200) return false;
      final id = (++_messageSerial).toRadixString(36);
      for (var index = 0; index < total; index++) {
        if (_closed ||
            gen != _generation ||
            !identical(client, _client) ||
            !connected) {
          return false;
        }
        final end = ((index + 1) * size).clamp(0, encoded.length);
        await client.sendChatMessage(
          '$_messagePrefix$id:$index/$total:${encoded.substring(index * size, end)}',
        );
      }
      return true;
    });
    _messageTail = task.then<void>((_) {}).catchError((Object _) {});
    return task;
  }

  void _receiveActivity(Map<String, dynamic> message) {
    final sender = message['username'], text = message['message'];
    if (sender is! String ||
        sender == username ||
        !connected ||
        _members[sender]?.room != room ||
        text is! String ||
        !text.startsWith(_messagePrefix) ||
        text.length > 150) {
      return;
    }
    try {
      final frame = RegExp(
        r'^NAKU2:([0-9a-z]{1,10}):([0-9]{1,3})/([0-9]{1,3}):([A-Za-z0-9+/=]*)$',
      ).firstMatch(text);
      if (frame == null) return;
      final index = int.parse(frame[2]!), total = int.parse(frame[3]!);
      if (total < 1 || total > 200 || index >= total) return;
      _fragments.removeWhere(
        (_, value) => DateTime.now().difference(value.created).inSeconds > 10,
      );
      var fragments = _fragments[sender];
      if (fragments == null ||
          fragments.id != frame[1] ||
          fragments.total != total) {
        if (_fragments.length >= 32) _fragments.remove(_fragments.keys.first);
        fragments = _Fragments(frame[1]!, total);
        _fragments[sender] = fragments;
      }
      fragments.parts[index] = frame[4]!;
      if (fragments.parts.values.fold<int>(
            0,
            (length, part) => length + part.length,
          ) >
          4000) {
        _fragments.remove(sender);
        return;
      }
      if (fragments.parts.length != total) return;
      _fragments.remove(sender);
      final payload = [
        for (var i = 0; i < total; i++) fragments.parts[i]!,
      ].join();
      final raw = jsonDecode(utf8.decode(base64Decode(payload)));
      if (raw is! Map) return;
      if (raw['type'] == 'request') {
        final last = _activityRequests[sender];
        if (last != null && DateTime.now().difference(last).inSeconds < 2) {
          return;
        }
        _activityRequests[sender] = DateTime.now();
        final c = _client;
        if (c != null) {
          unawaited(_sendActivity(c).catchError((Object _) => false));
        }
      } else if (raw['type'] == 'media') {
        final media = CinemaSyncMedia.fromJson(raw['media']);
        if (raw['media'] == null) {
          _peerMedia.remove(sender);
        } else if (media != null && media.identity == _members[sender]?.file) {
          _peerMedia[sender] = media;
        } else {
          return;
        }
        _notify();
      } else if (raw['type'] == 'stateRequest' &&
          raw['to'] == username &&
          raw['identity'] == _identity &&
          _identity.isNotEmpty &&
          _members[sender]?.file == _identity &&
          !_awaitingPeerState) {
        final c = _client;
        if (c != null && duration() > Duration.zero) {
          c.setPosition(position().inMilliseconds / 1000);
          c.setPaused(!playing());
          _sample();
          unawaited(
            c.sendSyncPlaySyncRequest(doSeek: true).catchError((Object _) {}),
          );
        }
      } else if (raw['type'] == 'following' &&
          raw['to'] == username &&
          raw['identity'] == _identity &&
          _identity.isNotEmpty &&
          _members[sender]?.file == _identity) {
        final nonce = raw['nonce'];
        if (nonce is! String || nonce.length > 100) return;
        final key = '$sender:$nonce';
        if (!_seenNotices.add(key)) return;
        if (_seenNotices.length > 64) _seenNotices.remove(_seenNotices.first);
        _notices.add('$sender 开始跟随你观看「${_localMedia?.title ?? ''}」');
      }
    } catch (_) {
      /* Other clients' chat is never an executable command. */
    }
  }

  void cancelExpectedPeerState() {
    if (!_awaitingPeerState) return;
    ++_mediaGeneration;
    _awaitingPeerState = false;
    _pendingRemote = null;
    _sample();
    _updateStatus();
  }

  Future<void> requestPeerState(CinemaPeerActivity peer) async {
    final c = _client;
    if (c == null ||
        !connected ||
        peer.media?.identity != _identity ||
        _members[peer.username]?.room != room ||
        _members[peer.username]?.file != _identity) {
      return;
    }
    await _sendEnvelope(c, {
      'type': 'stateRequest',
      'to': peer.username,
      'identity': _identity,
    });
  }

  Future<bool> notifyFollowing(CinemaPeerActivity peer) async {
    final c = _client, media = peer.media;
    if (c == null ||
        !connected ||
        media == null ||
        media.identity != _identity ||
        _members[peer.username]?.room != room ||
        _members[peer.username]?.file != _identity) {
      return false;
    }
    return _sendEnvelope(c, {
      'type': 'following',
      'to': peer.username,
      'identity': _identity,
      'nonce': '${DateTime.now().microsecondsSinceEpoch}-${++_noticeSerial}',
    });
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
    if (!_awaitingPeerState && _localChange) {
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
      _awaitingPeerState = false;
      _updateStatus();
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
        if (gen == _generation && media == _mediaGeneration) {
          _awaitingPeerState = false;
          _updateStatus();
        }
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
    if (c == null ||
        !c.isConnected ||
        _activeApply != null ||
        _awaitingPeerState ||
        !_compatible) {
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
    if (c == null ||
        !c.isConnected ||
        !_compatible ||
        _seeded ||
        _awaitingPeerState) {
      return;
    }
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
    _peerMedia.clear();
    _activityRequests.clear();
    _seenNotices.clear();
    _fragments.clear();
    _chatLimit = 50;
    _chatAvailable = true;
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
    unawaited(_notices.close());
    super.dispose();
  }
}
