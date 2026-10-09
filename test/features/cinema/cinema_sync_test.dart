import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/services/player/syncplay_client.dart';

class FakeClient extends SyncplayClient {
  FakeClient() : super(host: 'example.com', port: 8996);
  final general = StreamController<Map<String, dynamic>>.broadcast();
  final rooms = StreamController<Map<String, dynamic>>.broadcast();
  final files = StreamController<Map<String, dynamic>>.broadcast();
  final positions = StreamController<Map<String, dynamic>>.broadcast();
  final chat = StreamController<Map<String, dynamic>>.broadcast();
  final chats = <String>[];
  bool online = false;
  bool? tls;
  String? announced;
  @override
  bool get isConnected => online;
  @override
  Stream<Map<String, dynamic>> get onGeneralMessage => general.stream;
  @override
  Stream<Map<String, dynamic>> get onRoomMessage => rooms.stream;
  @override
  Stream<Map<String, dynamic>> get onFileChangedMessage => files.stream;
  @override
  Stream<Map<String, dynamic>> get onPositionChangedMessage => positions.stream;
  @override
  Stream<Map<String, dynamic>> get onChatMessage => chat.stream;
  @override
  Future<void> sendChatMessage(String message) async {
    chats.add(message);
  }

  @override
  Future<void> connect({required bool enableTLS}) async {
    online = true;
    tls = enableTLS;
  }

  @override
  Future<void> joinRoom(String room, String name) async {
    general.add({'type': 'hello', 'room': room, 'username': name});
  }

  @override
  Future<void> requestUserList() async {
    rooms.add({'type': 'snapshot', 'users': <Object>[]});
  }

  @override
  Future<void> sendSyncPlaySyncRequest({bool? doSeek}) async {}
  @override
  Future<void> setSyncPlayPlaying(String name, double d, int s) async {
    announced = name;
  }

  @override
  Future<void> disconnect() async {
    online = false;
  }
}

const episode = CinemaEpisode(
  name: '第01集',
  url: 'https://example.com/private-signed-url',
);
CinemaTitle title(String name) => CinemaTitle(
  id: '1',
  sourceId: 'a',
  title: name,
  year: '2022',
  category: '欧美剧',
);
void main() {
  test('identity retains season and hides media URL', () {
    final a = cinemaSyncIdentity(title('流人第一季'), episode);
    expect(a, startsWith('NAKU:'));
    expect(a, isNot(contains('https')));
    expect(a, isNot(cinemaSyncIdentity(title('流人第二季'), episode)));
    expect(
      a,
      cinemaSyncIdentity(
        title('流人第一季'),
        const CinemaEpisode(name: 'EP01', url: 'https://other.example/1'),
      ),
    );
  });
  test(
    'mismatched work cannot seek; matched work applies pause and seek; disconnect removes callbacks',
    () async {
      final client = FakeClient();
      final applied = <Duration>[];
      final sync = CinemaSyncSession(
        position: () => Duration.zero,
        playing: () => true,
        duration: () => const Duration(minutes: 50),
        applyRemote: (p, r) async {
          applied.add(p);
        },
        clientFactory: (_, _) => client,
      );
      await sync.updateMedia(title('流人第一季'), episode);
      await sync.connect(
        endpoint: 'syncplay.pl:8996',
        roomName: 'test-only',
        username: 'tester',
        tls: false,
      );
      expect(client.tls, isTrue);
      client.files.add({'name': 'other', 'setBy': 'peer', 'room': 'test-only'});
      await Future<void>.delayed(Duration.zero);
      client.positions.add({'position': 10, 'paused': true, 'setBy': 'peer'});
      await Future<void>.delayed(Duration.zero);
      expect(applied, isEmpty);
      client.files.add({
        'name': cinemaSyncIdentity(title('流人第一季'), episode),
        'setBy': 'peer',
        'room': 'test-only',
      });
      await Future<void>.delayed(Duration.zero);
      client.positions.add({'position': 10, 'paused': true, 'setBy': 'peer'});
      await Future<void>.delayed(Duration.zero);
      expect(applied, [const Duration(seconds: 10)]);
      await sync.disconnect();
      client.positions.add({'position': 20, 'paused': false});
      await Future<void>.delayed(Duration.zero);
      expect(applied.length, 1);
      sync.dispose();
      await client.general.close();
      await client.rooms.close();
      await client.files.close();
      await client.positions.close();
    },
  );
}
