import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
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
    for (final peer in peers) {
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
  Future<void> apply(Duration next, bool run) async {
    applied.add((next, run));
    await blocker?.future;
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

void main() {
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
