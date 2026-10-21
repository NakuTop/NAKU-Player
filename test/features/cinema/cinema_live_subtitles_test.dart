import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_tracks_sheet.dart';
import 'package:kazumi/features/cinema/cinema_live_subtitles.dart';

class _Streams implements PlayerStream {
  @override
  Stream<Tracks> get tracks => const Stream.empty();
  @override
  Stream<Track> get track => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player implements Player {
  @override
  PlayerState get state => const PlayerState();
  @override
  PlayerStream get stream => _Streams();
  @override
  PlatformPlayer? get platform => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'streaming window keeps recent context without accumulating stale audio',
    () {
      final window = CinemaLiveAudioWindow();
      window.push(Uint8List.fromList(List.filled(96000, 1)));
      final latest = window.push(Uint8List.fromList(List.filled(96000, 2)));
      expect(latest.length, 128000);
      expect(latest.last, 2);
      expect(latest.first, 1);
      window.clear();
      expect(window.push(Uint8List.fromList([3, 4])), [3, 4]);
    },
  );
  testWidgets(
    'tracks replace external audio import with real-time original subtitle controls',
    (tester) async {
      final player = _Player();
      final live = CinemaLiveSubtitles(player);
      final store = CinemaStore(defaults: const []);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CinemaTracksPanel(
              player: player,
              store: store,
              liveSubtitles: live,
            ),
          ),
        ),
      );
      expect(find.text('外部音轨'), findsNothing);
      await tester.ensureVisible(find.text('实时生成字幕'));
      await tester.tap(find.text('实时生成字幕'));
      await tester.pumpAndSettle();
      expect(find.text('开启实时原文字幕'), findsOneWidget);
      expect(find.text('音频语言'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      live.dispose();
      store.dispose();
    },
  );
  test(
    'capture PCM is wrapped in 16k mono PCM wave without copying header data into samples',
    () {
      final pcm = Uint8List.fromList([0, 1, 2, 3]);
      final wave = cinemaPcmWave(pcm);
      final header = ByteData.sublistView(wave);
      expect(String.fromCharCodes(wave.take(4)), 'RIFF');
      expect(header.getUint32(24, Endian.little), 16000);
      expect(header.getUint16(22, Endian.little), 1);
      expect(header.getUint16(34, Endian.little), 16);
      expect(header.getUint32(40, Endian.little), pcm.length);
      expect(wave.skip(44), pcm);
    },
  );
  test('silence is not sent for speech recognition', () {
    expect(cinemaPcmHasSpeech(Uint8List(160000)), false);
    expect(
      cinemaPcmHasSpeech(
        Uint8List.fromList(List.generate(32000, (i) => i.isEven ? 0 : 32)),
      ),
      true,
    );
  });
}
