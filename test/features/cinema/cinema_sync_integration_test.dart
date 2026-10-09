import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';
import 'package:kazumi/services/player/syncplay_client.dart';

// A bounded loopback server speaking the public Syncplay CRLF/JSON protocol.
// File broadcasts intentionally include self echoes and other rooms, as in
// Syncplay's server.py sendFileUpdate. Forced states are room-local and ACKed.
// No public server, source API, player backend, or media URL is contacted here.
class _Peer {
  _Peer(this.socket) {
    unawaited(socket.done.catchError((Object _) {}));
  }
  final Socket socket;
  String name = '', room = '';
  Map<String, dynamic> file = {};
  final incoming = <Map<String, dynamic>>[];
  void send(Map<String, dynamic> message) {
    socket.write('${jsonEncode(message)}\r\n');
  }
}

class _Server {
  _Server(this.server);
  final ServerSocket server;
  final peers = <_Peer>[];
  final changes = <String>[];
  final roomStates = <String, Map<String, dynamic>>{};
  bool helloEnabled = true;
  bool earlyPlaylist = false;
  Duration helloDelay = Duration.zero;
  int serial = 0;
  int chatLimit = 150;
  bool advertiseChatLimit = true;
  String get endpoint => '127.0.0.1:${server.port}';
  static Future<_Server> start() async {
    final result = _Server(
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    );
    result.server.listen(result._accept, onError: (Object _) {});
    return result;
  }

  void _accept(Socket socket) {
    final peer = _Peer(socket);
    peers.add(peer);
    socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) =>
              _handle(peer, Map<String, dynamic>.from(jsonDecode(line) as Map)),
          onError: (Object _) {},
          onDone: () {
            peers.remove(peer);
            if (peer.name.isEmpty) return;
            for (final other in peers.where((p) => p.name.isNotEmpty)) {
              other.send({
                'Set': {
                  'user': {
                    peer.name: {
                      'room': {'name': peer.room},
                      'event': {'left': true},
                    },
                  },
                },
              });
            }
          },
        );
  }

  Future<void> _handle(_Peer p, Map<String, dynamic> message) async {
    p.incoming.add(message);
    if (message['Hello'] is Map) {
      final hello = message['Hello'] as Map;
      p.name = hello['username'] as String;
      p.room = (hello['room'] as Map)['name'] as String;
      final init = {
        'Set': {
          'playlistIndex': {'user': roomStates[p.room]?['setBy'], 'index': 0},
        },
      };
      if (earlyPlaylist) p.send(init);
      if (!helloEnabled) return;
      if (helloDelay > Duration.zero) await Future<void>.delayed(helloDelay);
      p.send({
        'Hello': {
          'username': p.name,
          'room': {'name': p.room},
          'version': '1.7.0',
          if (advertiseChatLimit)
            'features': {'maxChatMessageLength': chatLimit, 'chat': true},
        },
      });
      if (!earlyPlaylist) p.send(init);
      for (final other in peers.where(
        (other) => other != p && other.name.isNotEmpty,
      )) {
        other.send({
          'Set': {
            'user': {
              p.name: {
                'room': {'name': p.room},
                'event': {'joined': true},
              },
            },
          },
        });
      }
    } else if (message.containsKey('List')) {
      final rooms = <String, Map<String, dynamic>>{};
      for (final peer in peers.where((p) => p.name.isNotEmpty)) {
        rooms.putIfAbsent(peer.room, () => {})[peer.name] = {'file': peer.file};
      }
      p.send({'List': rooms});
    } else if (message['Set'] is Map && message['Set']['file'] is Map) {
      p.file = Map<String, dynamic>.from(message['Set']['file'] as Map);
      for (final recipient in peers.where((p) => p.name.isNotEmpty)) {
        recipient.send({
          'Set': {
            'user': {
              p.name: {
                'room': {'name': p.room},
                'file': p.file,
              },
            },
          },
        });
      }
    } else if (message['Chat'] is String) {
      final text = message['Chat'] as String;
      final truncated = String.fromCharCodes(text.runes.take(chatLimit));
      for (final recipient in peers.where((other) => other.room == p.room)) {
        recipient.send({
          'Chat': {'username': p.name, 'message': truncated},
        });
      }
    } else if (message['State'] is Map) {
      final state = message['State'] as Map;
      final ignore = state['ignoringOnTheFly'];
      if (ignore is Map && ignore['client'] is int) {
        changes.add(p.name);
        final playstate = Map<String, dynamic>.from(state['playstate'] as Map)
          ..['setBy'] = p.name;
        roomStates[p.room] = playstate;
        for (final recipient in peers.where((other) => other.room == p.room)) {
          recipient.send({
            'State': {
              'playstate': playstate,
              'ping': {'serverRtt': 0.0},
              'ignoringOnTheFly': {
                'server': ++serial,
                if (recipient == p) 'client': ignore['client'],
              },
            },
          });
        }
      }
    }
  }

  _Peer named(String name) => peers.singleWhere((p) => p.name == name);
  void stateTo(
    String name, {
    required String setter,
    double position = 20,
    bool paused = true,
    bool seek = true,
  }) {
    named(name).send({
      'State': {
        'playstate': {
          'position': position,
          'paused': paused,
          'doSeek': seek,
          'setBy': setter,
        },
        'ping': {'serverRtt': 0.0},
      },
    });
  }

  Future<void> close() async {
    for (final peer in peers.toList()) {
      peer.socket.destroy();
    }
    await server.close();
  }
}

class _Player {
  Duration position = Duration.zero;
  bool playing = false;
  final applied = <(Duration, bool)>[];
  Completer<void>? blocker;
  Object? failure;
  Future<void> apply(Duration next, bool run) async {
    applied.add((next, run));
    await blocker?.future;
    if (failure != null) throw failure!;
    position = next;
    playing = run;
  }

  CinemaSyncSession session() => CinemaSyncSession(
    position: () => position,
    playing: () => playing,
    duration: () => const Duration(hours: 2),
    applyRemote: apply,
    tickInterval: const Duration(milliseconds: 30),
    handshakeTimeout: const Duration(milliseconds: 500),
  );
}

const _episode = CinemaEpisode(
  name: '第01集',
  url: 'https://media.invalid/private-token',
);
CinemaTitle _title({
  String name = '流人第一季',
  String year = '2022',
  String category = '欧美剧',
  String source = 'a',
}) => CinemaTitle(
  id: 'one',
  sourceId: source,
  title: name,
  year: year,
  category: category,
);

Future<void> _eventually(
  bool Function() predicate, {
  String reason = '',
  Duration timeout = const Duration(seconds: 2),
}) async {
  final end = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue, reason: reason);
}

Future<void> _join(
  CinemaSyncSession session,
  _Server server,
  String username, {
  String room = 'private-test',
}) async {
  await session.connect(
    endpoint: server.endpoint,
    roomName: room,
    username: username,
    tls: false,
  );
  await _eventually(
    () => server.named(username).file.isNotEmpty,
    reason:
        'Join status: ${session.status}; received: ${server.named(username).incoming}',
  );
}

CinemaWatchTogether _coordinator(File file) => CinemaWatchTogether(
  pairingFile: file,
  tls: false,
  reconnectDelays: const [Duration(milliseconds: 40)],
  handshakeTimeout: const Duration(milliseconds: 500),
  tickInterval: const Duration(milliseconds: 30),
);

Object _bind(
  CinemaWatchTogether together,
  _Player player, {
  Future<void> Function()? close,
}) {
  final owner = Object();
  together.bindPlayback(
    owner: owner,
    position: () => player.position,
    duration: () => const Duration(hours: 2),
    playing: () => player.playing,
    playbackRate: () => 1,
    applyRemote: player.apply,
    closePlayback: close ?? () => together.detachPlayback(owner),
  );
  return owner;
}

CinemaTitle _concreteTitle({
  String name = '流人第一季',
  String source = 'a',
  String episode = '第01集',
  String doubanId = '',
}) => CinemaTitle(
  id: 'one',
  sourceId: source,
  title: name,
  year: '2022',
  category: '欧美剧',
  doubanId: doubanId,
  routes: [
    CinemaRoute(
      name: 'line',
      episodes: [
        CinemaEpisode(
          name: episode,
          url: 'https://media.invalid/private-token-$source',
        ),
      ],
    ),
  ],
);

void main() {
  test(
    'failed initial peer seek never acknowledges and timeout cannot freeze a new room',
    () async {
      final server = await _Server.start();
      final dir = await Directory.systemTemp.createTemp('naku-follow-failure-');
      final a = _coordinator(File('${dir.path}/a.json'));
      final b = CinemaWatchTogether(
        pairingFile: File('${dir.path}/b.json'),
        tls: false,
        followTimeout: const Duration(milliseconds: 150),
        handshakeTimeout: const Duration(milliseconds: 500),
        tickInterval: const Duration(milliseconds: 30),
      );
      addTearDown(() async {
        a.dispose();
        b.dispose();
        await server.close();
        await dir.delete(recursive: true);
      });
      final pa = _Player()..position = const Duration(seconds: 42);
      final pb = _Player()
        ..position = const Duration(seconds: 900)
        ..failure = StateError('simulated seek failure');
      final work = _concreteTitle();
      final ownerA = _bind(a, pa);
      await a.updateMedia(ownerA, work, work.routes.single.episodes.single);
      await a.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Alice',
      );
      await b.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Bob',
      );
      await _eventually(() => b.peers.firstOrNull?.media != null);
      final notices = <String>[];
      a.notices.listen(notices.add);
      b.onFollowRequested = (peer) async {
        final owner = _bind(b, pb);
        await b.updateMedia(owner, work, work.routes.single.episodes.single);
        return true;
      };
      expect(await b.requestFollow(b.peers.single), isTrue);
      await _eventually(() => pb.applied.isNotEmpty);
      await _eventually(() => !b.following);
      expect(notices, isEmpty);
      expect(b.session.awaitingPeerState, isFalse);
      await b.unpair();
      pb.failure = null;
      await b.pair(
        endpoint: server.endpoint,
        roomName: 'new-room',
        username: 'Bob',
      );
      await _eventually(() => server.roomStates['new-room']?['setBy'] == 'Bob');
      expect(server.roomStates['new-room']?['position'], 900);
    },
  );

  test(
    'PUBLIC TLS metadata, explicit follow and notification use a synthetic private room',
    () async {
      final random = Random.secure();
      String hex() =>
          random.nextInt(0x100000000).toRadixString(16).padLeft(8, '0');
      final room = 'NAKU-${hex()}${hex()}${hex()}';
      final dir = await Directory.systemTemp.createTemp('naku-public-follow-');
      final a = CinemaWatchTogether(pairingFile: File('${dir.path}/a.json'));
      final b = CinemaWatchTogether(pairingFile: File('${dir.path}/b.json'));
      final pa = _Player()..position = const Duration(seconds: 42);
      final pb = _Player()..position = const Duration(seconds: 900);
      final wa = _concreteTitle(name: 'NAKU合成测试影片🧡', doubanId: '99999999');
      final wb = _concreteTitle(
        name: 'NAKU合成测试影片🧡',
        source: 'fixture-b',
        episode: 'EP01',
      );
      final ownerA = _bind(a, pa);
      final notices = <String>[];
      a.notices.listen(notices.add);
      final evidence = <String, dynamic>{
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'endpoint': 'syncplay.pl:8996',
        'tlsRequired': true,
        'room': room,
        'scope':
            'Two production coordinator clients on one Mac with synthetic catalogue metadata and no real media URL. Not a cross-country or video-backend test.',
      };
      try {
        await a.updateMedia(ownerA, wa, wa.routes.single.episodes.single);
        await a.pair(
          endpoint: 'syncplay.pl:8996',
          roomName: room,
          username: 'NAKU-A-${hex()}',
        );
        expect(a.session.connected, isTrue, reason: a.session.status);
        await b.pair(
          endpoint: 'syncplay.pl:8996',
          roomName: room,
          username: 'NAKU-B-${hex()}',
        );
        expect(b.session.connected, isTrue, reason: b.session.status);
        await _eventually(
          () => b.peers.firstOrNull?.media?.title == wa.title,
          timeout: const Duration(seconds: 12),
          reason: '${a.session.status}; ${b.session.status}',
        );
        b.onFollowRequested = (peer) async {
          expect(
            peer.media!.matches(wb, wb.routes.single.episodes.single),
            isTrue,
          );
          final owner = _bind(b, pb);
          await b.updateMedia(owner, wb, wb.routes.single.episodes.single);
          return true;
        };
        expect(await b.requestFollow(b.peers.single), isTrue);
        await _eventually(
          () => notices.length == 1 && !b.following,
          timeout: const Duration(seconds: 12),
          reason: '${a.session.status}; ${b.session.status}',
        );
        expect(pb.applied, isNotEmpty);
        expect((pb.position.inMilliseconds - 42000).abs(), lessThan(1500));
        expect(b.session.localMedia!.identity, a.session.localMedia!.identity);
        await a.detachPlayback(ownerA);
        await _eventually(
          () => b.peers.single.media == null,
          timeout: const Duration(seconds: 8),
        );
        expect(a.session.connected, isTrue);
        evidence.addAll({
          'result': 'passed',
          'unicodeMetadataReceived': true,
          'missingIdCrossSourceFollow': true,
          'followerPositionSeconds': pb.position.inMilliseconds / 1000,
          'followingNotices': notices.length,
          'leavingPlayerPreservedConnection': true,
        });
      } catch (error) {
        evidence.addAll({
          'result': 'failed',
          'error': '$error',
          'firstStatus': a.session.status,
          'secondStatus': b.session.status,
        });
        rethrow;
      } finally {
        await a.unpair();
        await b.unpair();
        a.dispose();
        b.dispose();
        await dir.delete(recursive: true);
        evidence['endedAt'] = DateTime.now().toUtc().toIso8601String();
        final output = File('../syncplay-verification/public-follow-tls.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
      }
    },
    skip: !const bool.fromEnvironment('CINEMA_SYNC_PUBLIC_TEST'),
    timeout: const Timeout(Duration(seconds: 80)),
  );

  test(
    'persistent pairing survives leaving, source changes, restart and explicit unpair',
    () async {
      final server = await _Server.start();
      final dir = await Directory.systemTemp.createTemp('naku-pair-');
      final aFile = File('${dir.path}/a.json'),
          bFile = File('${dir.path}/b.json');
      final a = _coordinator(aFile), b = _coordinator(bFile);
      CinemaWatchTogether? restarted, unpaired;
      addTearDown(() async {
        a.dispose();
        b.dispose();
        restarted?.dispose();
        unpaired?.dispose();
        await server.close();
        await dir.delete(recursive: true);
      });
      final player = _Player(), owner = _bind(a, player);
      final work = _concreteTitle();
      await a.updateMedia(owner, work, work.routes.first.episodes.first);
      await a.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Alice',
      );
      await b.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Bob',
      );
      await _eventually(() => b.peers.firstOrNull?.media != null);
      expect(b.peers.single.media!.title, work.title);
      expect(
        jsonEncode(b.peers.single.media!.toJson()),
        isNot(contains('private-token')),
      );
      expect(
        server
            .named('Alice')
            .incoming
            .where((m) => m['Chat'] is String)
            .every((m) => (m['Chat'] as String).length <= 150),
        isTrue,
      );
      await a.detachPlayback(owner);
      await _eventually(() => b.peers.single.media == null);
      expect(a.session.connected, isTrue);
      expect(a.isPaired, isTrue);
      final nextOwner = _bind(a, player);
      final next = _concreteTitle(episode: '第02集');
      await a.updateMedia(nextOwner, next, next.routes.single.episodes.single);
      await a.detachPlayback(
        owner,
      ); // A late old-player dispose cannot unbind its replacement.
      await _eventually(() => b.peers.single.media?.episodeName == '第02集');
      await a.session
          .disconnect(); // Simulate a dropped connection; pairing is retained.
      await _eventually(() => a.session.connected);
      await _eventually(() => b.peers.single.media?.episodeName == '第02集');
      a.dispose();
      await _eventually(() => server.peers.every((p) => p.name != 'Alice'));
      restarted = _coordinator(aFile);
      await restarted.initialize();
      await _eventually(() => restarted!.session.connected);
      expect(restarted.isPaired, isTrue);
      expect(
        restarted.session.localMedia,
        isNull,
      ); // No unsolicited restart playback.
      await b.unpair();
      expect(b.isPaired, isFalse);
      expect(b.session.connected, isFalse);
      expect(jsonDecode(await bFile.readAsString())['paired'], isFalse);
      b.dispose();
      unpaired = _coordinator(bFile);
      await unpaired.initialize();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(unpaired.isPaired, isFalse);
      expect(unpaired.session.connected, isFalse);
    },
  );

  test(
    'explicit cross-source follow waits for ready and peer state, not own history, then notifies once',
    () async {
      final server = await _Server.start();
      final dir = await Directory.systemTemp.createTemp('naku-follow-');
      final a = _coordinator(File('${dir.path}/a.json'));
      final b = _coordinator(File('${dir.path}/b.json'));
      addTearDown(() async {
        a.dispose();
        b.dispose();
        await server.close();
        await dir.delete(recursive: true);
      });
      final pa = _Player()
        ..position = const Duration(seconds: 42)
        ..playing = true;
      final pb = _Player()
        ..position = const Duration(seconds: 900)
        ..playing = false;
      final wa = _concreteTitle(doubanId: '35724512');
      final wb = _concreteTitle(
        name: '流人第一季（国语版）',
        source: 'other',
        episode: 'EP01',
      );
      final ownerA = _bind(a, pa);
      final notices = <String>[];
      a.notices.listen(notices.add);
      await a.updateMedia(ownerA, wa, wa.routes.single.episodes.single);
      await a.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Alice',
      );
      await b.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Bob',
      );
      await _eventually(() => b.peers.firstOrNull?.media != null);
      var closed = 0, navigated = 0;
      late Object oldOwner;
      oldOwner = _bind(
        b,
        pb,
        close: () async {
          closed++;
          pb.playing = false;
          await b.detachPlayback(oldOwner);
        },
      );
      final unrelated = _concreteTitle(name: '其他作品');
      await b.updateMedia(
        oldOwner,
        unrelated,
        unrelated.routes.single.episodes.single,
      );
      late Object newOwner;
      b.onFollowRequested = (peer) async {
        navigated++;
        expect(closed, 1);
        expect(
          peer.media!.matches(wb, wb.routes.single.episodes.single),
          isTrue,
        );
        newOwner = _bind(b, pb);
        return true;
      };
      final peer = b.peers.single;
      expect(await b.requestFollow(peer), isTrue);
      expect(navigated, 1);
      expect(notices, isEmpty);
      expect(b.following, isTrue);
      // Local source has a different raw hash: no ID and a language suffix.
      expect(
        cinemaSyncIdentity(wa, wa.routes.single.episodes.single),
        isNot(cinemaSyncIdentity(wb, wb.routes.single.episodes.single)),
      );
      final before = server.changes.where((n) => n == 'Bob').length;
      await b.updateMedia(newOwner, wb, wb.routes.single.episodes.single);
      await _eventually(() => notices.length == 1);
      expect(pb.position, pa.position);
      expect(pb.playing, isTrue);
      expect(b.following, isFalse);
      expect(b.session.localMedia!.identity, a.session.localMedia!.identity);
      expect(
        server.changes.where((n) => n == 'Bob').length,
        before,
        reason: 'Follower must not publish its saved 900-second history first',
      );
      await b.updateMedia(newOwner, wb, wb.routes.single.episodes.single);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(notices, hasLength(1));
      final episode2 = _concreteTitle(episode: '第02集', doubanId: '35724512');
      await a.updateMedia(
        ownerA,
        episode2,
        episode2.routes.single.episodes.single,
      );
      await _eventually(() => b.peers.single.media?.episodeName == '第02集');
      expect(
        navigated,
        1,
        reason: 'Remote changes must never auto-open playback',
      );
      expect(b.session.localMedia!.episodeName, '第01集');
      expect(notices, hasLength(1));
    },
  );

  test(
    'old-server 50 character chunks preserve Unicode and other-room messages are ignored',
    () async {
      final server = await _Server.start()
        ..chatLimit = 50
        ..advertiseChatLimit = false;
      final pa = _Player(), pb = _Player(), pc = _Player();
      final a = pa.session(), b = pb.session(), c = pc.session();
      addTearDown(() async {
        a.dispose();
        b.dispose();
        c.dispose();
        await server.close();
      });
      final work = _title(name: '🧡世界的另一端：我们一起看第十季');
      await a.updateMedia(work, _episode);
      await b.updateMedia(work, _episode);
      await _join(a, server, 'Alice');
      await _join(b, server, 'Bob');
      await _eventually(() => b.peers.firstOrNull?.media?.title == work.title);
      expect(
        server
            .named('Alice')
            .incoming
            .where((m) => m['Chat'] is String)
            .every((m) => (m['Chat'] as String).length <= 50),
        isTrue,
      );
      await c.updateMedia(_title(name: '陌生作品'), _episode);
      await _join(c, server, 'Eve', room: 'other-room');
      final forged = server
          .named('Eve')
          .incoming
          .where((m) => m['Chat'] is String)
          .toList();
      for (final message in forged) {
        server.named('Bob').send({
          'Chat': {'username': 'Eve', 'message': message['Chat']},
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(b.peers.map((p) => p.username), ['Alice']);
      expect(b.peers.single.media!.title, work.title);
      final notices = <String>[];
      a.notices.listen(notices.add);
      await b.notifyFollowing(b.peers.single);
      await _eventually(() => notices.length == 1);
      final frames = server
          .named('Bob')
          .incoming
          .where((m) => m['Chat'] is String)
          .toList();
      for (final frame in frames) {
        server.named('Alice').send({
          'Chat': {'username': 'Bob', 'message': frame['Chat']},
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        notices,
        hasLength(1),
        reason: 'Replayed acknowledgement is deduplicated',
      );
    },
  );

  test(
    'unpair during follow resolution cancels acknowledgement and persistence',
    () async {
      final server = await _Server.start();
      final dir = await Directory.systemTemp.createTemp('naku-cancel-');
      final a = _coordinator(File('${dir.path}/a.json'));
      final b = _coordinator(File('${dir.path}/b.json'));
      addTearDown(() async {
        a.dispose();
        b.dispose();
        await server.close();
        await dir.delete(recursive: true);
      });
      final work = _concreteTitle();
      final ownerA = _bind(a, _Player());
      await a.updateMedia(ownerA, work, work.routes.single.episodes.single);
      await a.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Alice',
      );
      await b.pair(
        endpoint: server.endpoint,
        roomName: 'pair-test',
        username: 'Bob',
      );
      await _eventually(() => b.peers.firstOrNull?.media != null);
      final resolving = Completer<bool>();
      b.onFollowRequested = (_) => resolving.future;
      final notices = <String>[];
      a.notices.listen(notices.add);
      final follow = b.requestFollow(b.peers.single);
      await Future<void>.delayed(Duration.zero);
      expect(
        await b.requestFollow(b.peers.single),
        isFalse,
        reason: 'Only one navigation may run',
      );
      await b.unpair();
      resolving.complete(true);
      expect(await follow, isFalse);
      expect(b.following, isFalse);
      expect(b.isPaired, isFalse);
      expect(notices, isEmpty);
    },
  );

  test(
    'same film labels match while season, year and episode stay separate',
    () {
      final film = _title(name: '星际穿越', category: '剧情片');
      expect(
        cinemaSyncIdentity(film, const CinemaEpisode(name: 'HD', url: 'a')),
        cinemaSyncIdentity(film, const CinemaEpisode(name: '正片', url: 'b')),
      );
      expect(
        cinemaSyncIdentity(_title(), _episode),
        cinemaSyncIdentity(
          _title(source: 'b'),
          const CinemaEpisode(name: 'Episode_01', url: 'b'),
        ),
      );
      for (final other in [_title(name: '流人第二季'), _title(year: '2023')]) {
        expect(
          cinemaSyncIdentity(other, _episode),
          isNot(cinemaSyncIdentity(_title(), _episode)),
        );
      }
      expect(
        cinemaSyncIdentity(
          _title(),
          const CinemaEpisode(name: '第02集', url: 'b'),
        ),
        isNot(cinemaSyncIdentity(_title(), _episode)),
      );
    },
  );

  test(
    'real TCP two clients exchange pause/seek once and disconnect cleanly',
    () async {
      final server = await _Server.start();
      final a = _Player(), b = _Player();
      final sa = a.session(), sb = b.session();
      addTearDown(() async {
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        await server.close();
      });
      await sa.updateMedia(_title(), _episode);
      await sb.updateMedia(_title(source: 'b'), _episode);
      await _join(sa, server, 'Alice');
      await _join(sb, server, 'Bob');
      await _eventually(
        () => sa.status.contains('同步播放') && sb.status.contains('同步播放'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      server.changes.clear();
      a.position = const Duration(seconds: 30);
      a.playing = true;
      await _eventually(
        () => b.position == const Duration(seconds: 30) && b.playing,
      );
      expect(server.changes, ['Alice']);
      b.playing = false;
      await _eventually(() => !a.playing);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(server.changes, [
        'Alice',
        'Bob',
      ], reason: 'Remote application must not echo a second forced state.');
      expect(
        server.peers.expand((p) => p.incoming).map(jsonEncode).join(),
        isNot(contains('private-token')),
      );
      server.named('Bob').socket.destroy();
      await _eventually(() => !sb.connected);
      expect(sb.status, contains('中断'));
    },
  );

  test(
    'own file echo never authorizes another work or another episode',
    () async {
      final server = await _Server.start();
      final a = _Player(), b = _Player();
      final sa = a.session(), sb = b.session();
      addTearDown(() async {
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        await server.close();
      });
      await sa.updateMedia(_title(), _episode);
      await sb.updateMedia(_title(name: '流人第二季'), _episode);
      await _join(sa, server, 'Alice');
      await _join(sb, server, 'Bob');
      await _eventually(() => sb.status.contains('集数不同'));
      server.stateTo('Bob', setter: 'Alice');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(b.applied, isEmpty);
      await sb.updateMedia(
        _title(),
        const CinemaEpisode(name: '第02集', url: 'b'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      server.stateTo('Bob', setter: 'Alice');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(b.applied, isEmpty);
    },
  );

  test(
    'other-room file broadcasts cannot block same-room matching peers',
    () async {
      final server = await _Server.start();
      final a = _Player(), b = _Player();
      final sa = a.session(), sb = b.session();
      addTearDown(() async {
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        await server.close();
      });
      await sa.updateMedia(_title(), _episode);
      await sb.updateMedia(_title(), _episode);
      await _join(sa, server, 'Alice');
      await _join(sb, server, 'Bob');
      await _eventually(() => sb.status.contains('同步播放'));
      server.named('Bob').send({
        'Set': {
          'user': {
            'Stranger': {
              'room': {'name': 'elsewhere'},
              'file': {'name': 'unrelated'},
            },
          },
        },
      });
      server.stateTo('Bob', setter: 'Alice');
      await _eventually(() => b.position == const Duration(seconds: 20));
      server.stateTo('Bob', setter: 'Stranger', position: 50);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(b.position, const Duration(seconds: 20));
    },
  );

  test(
    'playlist before Hello and occupied-room setter do not prevent announcement',
    () async {
      final server = await _Server.start()
        ..earlyPlaylist = true;
      server.helloDelay = const Duration(milliseconds: 60);
      server.roomStates['private-test'] = {'setBy': 'EarlierViewer'};
      final sync = _Player().session();
      addTearDown(() async {
        await sync.disconnect();
        sync.dispose();
        await server.close();
      });
      await sync.updateMedia(_title(), _episode);
      final pending = _join(sync, server, 'Alice');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        sync.connected,
        isFalse,
        reason: 'Sending Hello is not an acknowledged room join.',
      );
      expect(sync.connecting, isTrue);
      await pending;
      expect(sync.connected, isTrue);
      expect(
        server.named('Alice').file['name'],
        cinemaSyncIdentity(_title(), _episode),
      );
    },
  );

  test(
    'disconnect during a pending handshake cannot revive the old room',
    () async {
      final server = await _Server.start();
      server.helloEnabled = false;
      final sync = _Player().session();
      addTearDown(() async {
        await sync.disconnect();
        sync.dispose();
        await server.close();
      });
      await sync.updateMedia(_title(), _episode);
      final connecting = sync.connect(
        endpoint: server.endpoint,
        roomName: 'old',
        username: 'Alice',
        tls: false,
      );
      await _eventually(
        () => server.peers.isNotEmpty && server.peers.first.name == 'Alice',
      );
      await sync.disconnect();
      await connecting;
      server.helloEnabled = true;
      await _join(sync, server, 'Alice2', room: 'new');
      expect(sync.room, 'new');
      expect(sync.endpoint, server.endpoint);
    },
  );

  test(
    'latest pause is retained while an earlier remote seek is still applying',
    () async {
      final server = await _Server.start();
      final a = _Player(), b = _Player();
      final sa = a.session(), sb = b.session();
      addTearDown(() async {
        if (!(b.blocker?.isCompleted ?? true)) b.blocker!.complete();
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        await server.close();
      });
      await sa.updateMedia(_title(), _episode);
      await sb.updateMedia(_title(), _episode);
      await _join(sa, server, 'Alice');
      await _join(sb, server, 'Bob');
      await _eventually(() => sb.status.contains('同步播放'));
      b.blocker = Completer<void>();
      server.stateTo('Bob', setter: 'Alice', position: 25, paused: false);
      await _eventually(() => b.applied.length == 1);
      server.stateTo('Bob', setter: 'Alice', position: 28, paused: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      b.blocker!.complete();
      await _eventually(
        () =>
            b.applied.length == 2 && b.position == const Duration(seconds: 28),
      );
      expect(b.playing, isFalse);
    },
  );

  test(
    'UTF-8 splits and braces inside JSON strings survive actual socket framing',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      Socket? peer;
      server.listen((s) {
        peer = s;
        s.listen((_) {}, onError: (Object _) {});
      });
      final client = SyncplayClient(host: '127.0.0.1', port: server.port);
      final errors = <Object>[];
      final messages = <Map<String, dynamic>>[];
      final subscription = client.onGeneralMessage.listen(
        messages.add,
        onError: errors.add,
      );
      addTearDown(() async {
        await subscription.cancel();
        await client.disconnect();
        peer?.destroy();
        await server.close();
      });
      await client.connect(enableTLS: false);
      await _eventually(() => peer != null);
      final payload = utf8.encode(
        '${jsonEncode({
          'Hello': {
            'username': '观众{甲',
            'room': {'name': '中文房间'},
            'version': '1.7.0',
          },
        })}\r\n',
      );
      final firstNonAscii = payload.indexWhere((byte) => byte >= 0x80);
      peer!.add(payload.sublist(0, firstNonAscii + 1));
      await peer!.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      peer!.add(payload.sublist(firstNonAscii + 1));
      await peer!.flush();
      await _eventually(() => messages.isNotEmpty, reason: errors.toString());
      expect(client.username, '观众{甲');
      expect(errors, isEmpty);
    },
  );
  test(
    'a local pause wins over an older remote heartbeat before the next tick',
    () async {
      final server = await _Server.start();
      final a = _Player(), b = _Player();
      final sa = a.session(), sb = b.session();
      addTearDown(() async {
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        await server.close();
      });
      await sa.updateMedia(_title(), _episode);
      await sb.updateMedia(_title(), _episode);
      await _join(sa, server, 'Alice');
      await _join(sb, server, 'Bob');
      await _eventually(() => sb.status.contains('同步播放'));
      a.playing = true;
      await _eventually(() => b.playing);
      b.applied.clear();
      b.playing = false;
      server.stateTo(
        'Bob',
        setter: 'Alice',
        position: 0,
        paused: false,
        seek: false,
      );
      await _eventually(() => !a.playing);
      expect(b.playing, isFalse);
      expect(
        b.applied.where((value) => value.$2),
        isEmpty,
        reason: 'A stale heartbeat must not undo an unsent local pause.',
      );
    },
  );

  test(
    'PUBLIC TLS two production clients share a random private room',
    () async {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final room = 'NAKU-verification-$stamp';
      final a = _Player(), b = _Player();
      final sa = CinemaSyncSession(
        position: () => a.position,
        playing: () => a.playing,
        duration: () => const Duration(hours: 2),
        applyRemote: a.apply,
      );
      final sb = CinemaSyncSession(
        position: () => b.position,
        playing: () => b.playing,
        duration: () => const Duration(hours: 2),
        applyRemote: b.apply,
      );
      a.position = const Duration(seconds: 12);
      final evidence = <String, dynamic>{
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'endpoint': 'syncplay.pl:8996',
        'tlsRequired': true,
        'scope':
            'Two production clients on this Mac, random private room; not a cross-country playback test.',
        'room': room,
      };
      try {
        await sa.updateMedia(_title(), _episode);
        await sb.updateMedia(_title(), _episode);
        await sa.connect(
          endpoint: 'syncplay.pl:8996',
          roomName: room,
          username: 'NAKU-test-A-$stamp',
        );
        expect(sa.connected, isTrue, reason: sa.status);
        await sb.connect(
          endpoint: 'syncplay.pl:8996',
          roomName: room,
          username: 'NAKU-test-B-$stamp',
        );
        expect(sb.connected, isTrue, reason: sb.status);
        await _eventually(
          () => sa.status.contains('同步播放') && sb.status.contains('同步播放'),
          timeout: const Duration(seconds: 8),
          reason: '${sa.status}; ${sb.status}',
        );
        a.position = const Duration(seconds: 42);
        await _eventually(
          () => b.position == const Duration(seconds: 42),
          timeout: const Duration(seconds: 8),
          reason: '${sa.status}; ${sb.status}',
        );
        a.playing = true;
        await _eventually(() => b.playing, timeout: const Duration(seconds: 8));
        b.playing = false;
        await _eventually(
          () => !a.playing,
          timeout: const Duration(seconds: 8),
        );
        evidence.addAll({
          'result': 'passed',
          'seekSeconds': 42,
          'playAndPausePropagated': true,
          'firstStatus': sa.status,
          'secondStatus': sb.status,
        });
      } catch (error) {
        evidence.addAll({
          'result': 'failed',
          'error': '$error',
          'firstStatus': sa.status,
          'secondStatus': sb.status,
        });
        rethrow;
      } finally {
        await sa.disconnect();
        await sb.disconnect();
        sa.dispose();
        sb.dispose();
        evidence['endedAt'] = DateTime.now().toUtc().toIso8601String();
        final output = File('../syncplay-verification/public-tls.json');
        await output.parent.create(recursive: true);
        await output.writeAsString(
          const JsonEncoder.withIndent('  ').convert(evidence),
        );
      }
    },
    skip: !const bool.fromEnvironment('CINEMA_SYNC_PUBLIC_TEST'),
    timeout: const Timeout(Duration(seconds: 80)),
  );
}
