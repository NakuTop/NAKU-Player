import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_tv_native_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/tv-external-subtitles');
  const captions = '''1
00:00:01,000 --> 00:00:04,000
第一句

2
00:00:05,000 --> 00:00:08,000
Second line
''';
  late StreamController<dynamic> events;
  late CinemaTVNativePlayer player;
  setUp(() {
    events = StreamController<dynamic>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => null);
    player = CinemaTVNativePlayer(channel: channel, events: events.stream);
  });
  tearDown(() async {
    await closeCinemaExternalSubtitles(player);
    await player.dispose();
    await events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  Future<void> position(int ms) async {
    events.add({'id': player.id, 'positionMs': ms});
    await Future<void>.delayed(Duration.zero);
  }

  test(
    'Media3 online timed text advances, seeks and expires with real position',
    () async {
      expect(player.platform, isNot(isA<NativePlayer>()));
      await applyCinemaExternalSubtitle(player, captions);
      final state = cinemaExternalSubtitleState(player);
      expect(state.active.value, true);
      expect(state.text.value, isEmpty);
      await position(1500);
      expect(state.text.value, '第一句');
      await position(5500);
      expect(state.text.value, 'Second line');
      await position(9000);
      expect(state.text.value, isEmpty);
      await position(2000);
      expect(state.text.value, '第一句');
    },
  );
  test(
    'Media3 subtitle off and embedded selection clear the external overlay',
    () async {
      await applyCinemaExternalSubtitle(player, captions);
      final state = cinemaExternalSubtitleState(player);
      await position(1500);
      expect(state.text.value, '第一句');
      await player.setSubtitleTrack(SubtitleTrack.no());
      await Future<void>.delayed(Duration.zero);
      expect(state.active.value, false);
      expect(state.text.value, isEmpty);
      await applyCinemaExternalSubtitle(player, captions);
      await position(5500);
      expect(state.text.value, 'Second line');
      await player.setSubtitleTrack(const SubtitleTrack('2:0', '内嵌', 'zh'));
      await Future<void>.delayed(Duration.zero);
      expect(state.active.value, false);
      expect(state.text.value, isEmpty);
    },
  );
  test(
    'Media3 external delay uses playback clock and stops updating after close',
    () async {
      await applyCinemaExternalSubtitle(player, captions);
      final state = cinemaExternalSubtitleState(player);
      state.setDelay(.5);
      await position(1200);
      expect(state.text.value, isEmpty);
      await position(1700);
      expect(state.text.value, '第一句');
      await state.close();
      await position(5600);
      // No late listener may touch disposed ValueNotifiers after cleanup.
    },
  );
  test(
    'closing captions detaches streams before pending writes and shares completion',
    () async {
      await applyCinemaExternalSubtitle(player, captions);
      final state = cinemaExternalSubtitleState(player);
      final saved = Completer<void>();
      var saves = 0;
      addTearDown(() {
        if (!saved.isCompleted) saved.complete();
      });
      state.saveTiming = (_, _) {
        saves++;
        return saved.future;
      };
      state.setDelay(.5);
      final closing = state.close();
      expect(state.close(), same(closing));
      var closed = false;
      unawaited(closing.then((_) => closed = true));
      // Player streams can close while preference storage remains pending.
      await player.dispose().timeout(const Duration(seconds: 1));
      expect(closed, false);
      expect(saves, 1);
      saved.complete();
      await closing;
      expect(closed, true);
    },
  );
}
