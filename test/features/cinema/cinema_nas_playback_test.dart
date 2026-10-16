import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_nas_playback.dart';

class NAS extends CinemaNASClient {
  final calls = <(String, Map<String, dynamic>?)>[];
  String url = 'https://nas.example/stream.m3u8?token=private';
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    calls.add((method, args));
    return method == 'startPlayback'
        ? {
            'url': url,
            'taskId': 'task-1',
            'resolution': '854x480',
            'audio': 4354,
            'subtitle': 6145,
          }
        : {};
  }
}

void main() {
  test('remote selects lowest offered profile and LAN selects highest', () {
    final data = {
      'profiles': [
        {'id': '1920x1080', 'label': '1080P'},
        {'id': '854x480', 'label': '480P'},
      ],
    };
    expect(
      CinemaNASPlaybackOptions.fromMap({
        ...data,
        'isRelayOrigin': true,
      }).defaultProfile,
      '854x480',
    );
    expect(CinemaNASPlaybackOptions.fromMap(data).defaultProfile, '1920x1080');
  });
  test(
    'stable identity and actual track IDs reach NAS; close is idempotent',
    () async {
      final nas = NAS();
      final playback = CinemaNASPlaybackClient(client: nas);
      final reference = nasMediaReference(
        namespace: 'a' * 64,
        id: 5,
        library: 2,
        path: '/films/a.mkv',
      );
      final session = await playback.start(
        reference,
        resolution: '854x480',
        audio: 4354,
        subtitle: 6145,
      );
      expect(nas.calls.first.$1, 'autoConnect');
      expect(nas.calls.where((c) => c.$1 == 'startPlayback').single.$2, {
        'namespace': 'a' * 64,
        'id': 5,
        'library': 2,
        'path': '/films/a.mkv',
        'resolution': '854x480',
        'audio': 4354,
        'subtitle': 6145,
      });
      await Future.wait([session.close(), session.close()]);
      expect(nas.calls.where((c) => c.$1 == 'closePlayback').length, 1);
      expect(nas.calls.last.$2, {'namespace': 'a' * 64, 'taskId': 'task-1'});
    },
  );
  test('invalid returned URL closes created task before failing', () async {
    final nas = NAS()..url = 'file:///secret';
    final reference = nasMediaReference(
      namespace: 'a' * 64,
      id: 1,
      library: 1,
      path: '/a.mkv',
    );
    await expectLater(
      CinemaNASPlaybackClient(client: nas).start(reference),
      throwsFormatException,
    );
    expect(nas.calls.last.$1, 'closePlayback');
  });
  test('invalid stable reference never calls native playback', () async {
    final nas = NAS();
    await expectLater(
      CinemaNASPlaybackClient(client: nas).start('https://other.example/movie'),
      throwsFormatException,
    );
    expect(nas.calls, isEmpty);
  });
}
