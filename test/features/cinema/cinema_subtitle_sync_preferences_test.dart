import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_sync_preferences.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

class _Player implements Player {
  @override
  PlatformPlayer? get platform => null;
  @override
  PlayerState get state => const PlayerState(position: Duration(seconds: 90));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _mediaA = 'fixture-media-S10E02';
const _subtitleA = '1\n00:00:01,000 --> 00:00:04,000\nSelf authored line A\n';
const _subtitleB = '1\n00:00:01,000 --> 00:00:04,000\nDifferent subtitle cut\n';
String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
String _key(String media, String subtitle) =>
    '${_digest(media)}:${_digest(subtitle)}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File library;
  late CinemaStore store;
  final sessions = <CinemaExternalSubtitleState>[];

  CinemaExternalSubtitleState select(
    String media,
    String source, {
    double initialOffset = 0,
  }) {
    final player = _Player();
    bindCinemaSubtitleTiming(player, store, media);
    final session = cinemaExternalSubtitleState(player);
    sessions.add(session);
    session.select(
      source,
      r'C:\private\subtitle-fixture.srt',
      '1',
      initialOffset,
    );
    return session;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'naku-subtitle-timing-prefs-test-',
    );
    library = File('${directory.path}/library.json');
    store = CinemaStore(file: library, defaults: const []);
    await store.load();
  });
  tearDown(() async {
    for (final session in sessions) {
      await session.close();
    }
    sessions.clear();
    await store.flush();
    store.dispose();
    for (final file in directory.listSync().whereType<File>()) {
      await file.delete();
    }
    await directory.delete();
  });

  test(
    'the same media and caption content restore calibration after a store reload',
    () async {
      final first = select(_mediaA, _subtitleA);
      const timing = CinemaSubtitleTiming(scale: .96, offsetSeconds: 89.04);
      first.setTiming(timing);
      await first.saveTiming!(first.fingerprint, timing);
      await store.flush();
      store.dispose();
      store = CinemaStore(file: library, defaults: const []);
      await store.load();

      final reopened = select(_mediaA, _subtitleA, initialOffset: -2);
      expect(reopened.timing.value.scale, .96);
      expect(reopened.delay, 89.04);
      expect(reopened.text.value, 'Self authored line A');
      expect(reopened.fingerprint, _digest(_subtitleA));
      final records = store.extras['subtitleTimingV1'] as Map;
      expect(records[_key(_mediaA, _subtitleA)], {
        'scale': .96,
        'offset': 89.04,
      });
    },
  );

  test(
    'a different episode or subtitle cut does not inherit another calibration',
    () async {
      final first = select(_mediaA, _subtitleA);
      await first.saveTiming!(
        first.fingerprint,
        const CinemaSubtitleTiming(offsetSeconds: 89),
      );

      final otherSubtitle = select(_mediaA, _subtitleB, initialOffset: 3);
      final otherMedia = select(
        'fixture-media-S10E03',
        _subtitleA,
        initialOffset: -4,
      );
      expect(otherSubtitle.delay, 3);
      expect(otherMedia.delay, -4);
      expect(otherSubtitle.timing.value.scale, 1);
      expect(otherMedia.timing.value.scale, 1);
      expect(select(_mediaA, _subtitleA).delay, 89);
    },
  );

  test(
    'concurrent saves across media and captions preserve every final update',
    () async {
      const otherMedia = 'fixture-media-S10E03';
      final first = select(_mediaA, _subtitleA);
      final second = select(otherMedia, _subtitleB);
      final saves = <Future<void>>[];
      for (var index = 0; index < 12; index++) {
        final content = _digest('concurrent-caption-$index');
        saves.add(
          first.saveTiming!(
            content,
            CinemaSubtitleTiming(offsetSeconds: index.toDouble()),
          ),
        );
        saves.add(
          second.saveTiming!(
            content,
            CinemaSubtitleTiming(offsetSeconds: -index.toDouble()),
          ),
        );
      }
      saves.add(
        first.saveTiming!(
          _digest('concurrent-caption-0'),
          const CinemaSubtitleTiming(offsetSeconds: 900),
        ),
      );
      saves.add(
        second.saveTiming!(
          _digest('concurrent-caption-0'),
          const CinemaSubtitleTiming(offsetSeconds: -900),
        ),
      );
      await Future.wait(saves);
      await store.flush();
      final records = store.extras['subtitleTimingV1'] as Map;
      expect(records, hasLength(24));
      for (var index = 0; index < 12; index++) {
        final content = _digest('concurrent-caption-$index');
        final expected = index == 0 ? 900 : index;
        expect(records['${_digest(_mediaA)}:$content'], {
          'scale': 1,
          'offset': expected,
        });
        expect(records['${_digest(otherMedia)}:$content'], {
          'scale': 1,
          'offset': -expected,
        });
      }
      final onDisk = jsonDecode(await library.readAsString()) as Map;
      expect(onDisk['subtitleTimingV1'], records);
    },
  );

  test('invalid saved shapes, types and timing ranges are ignored', () async {
    final session = select(_mediaA, _subtitleA);
    for (final value in [
      null,
      'invalid',
      [],
      {'scale': 1},
      {'scale': '1', 'offset': 4},
      {'scale': 1, 'offset': '4'},
      {'scale': .49, 'offset': 4},
      {'scale': 2.01, 'offset': 4},
      {'scale': 1, 'offset': 21600.1},
      {'scale': 1, 'offset': -21600.1},
    ]) {
      await store.setExtra('subtitleTimingV1', {
        _key(_mediaA, _subtitleA): value,
      });
      session.select(_subtitleA, 'fixture.srt', '1', 7);
      expect(session.delay, 7, reason: 'Invalid saved value: $value');
      expect(session.timing.value.scale, 1);
    }
    for (final field in [null, [], 'invalid']) {
      await store.setExtra('subtitleTimingV1', field);
      session.select(_subtitleA, 'fixture.srt', '1', 7);
      expect(session.delay, 7);
      expect(session.timing.value.scale, 1);
    }
  });

  test(
    'saved timing is bounded to 64 entries and refreshing one keeps it recent',
    () async {
      final session = select(_mediaA, _subtitleA);
      for (var index = 0; index < 64; index++) {
        await session.saveTiming!(
          _digest('self-authored-$index'),
          CinemaSubtitleTiming(offsetSeconds: index.toDouble()),
        );
      }
      var records = store.extras['subtitleTimingV1'] as Map;
      expect(records, hasLength(64));
      final firstKey = '${_digest(_mediaA)}:${_digest('self-authored-0')}';
      final secondKey = '${_digest(_mediaA)}:${_digest('self-authored-1')}';
      await session.saveTiming!(
        _digest('self-authored-0'),
        const CinemaSubtitleTiming(offsetSeconds: 88),
      );
      await session.saveTiming!(
        _digest('self-authored-64'),
        const CinemaSubtitleTiming(offsetSeconds: 64),
      );
      records = store.extras['subtitleTimingV1'] as Map;
      expect(records, hasLength(64));
      expect(records[firstKey], {'scale': 1, 'offset': 88});
      expect(records.containsKey(secondKey), false);
      expect(
        records.keys.last,
        '${_digest(_mediaA)}:${_digest('self-authored-64')}',
      );
    },
  );

  test(
    'disk records contain hashes and numbers without private paths or dialogue',
    () async {
      const media =
          'https://private-nas.invalid/media?token=FAKE_DO_NOT_PERSIST&path=/private/episode.mkv';
      const path = r'C:\private\FAKE_SECRET_LOCATION\subtitle.srt';
      const subtitle =
          '1\n00:00:01,000 --> 00:00:04,000\nFAKE_PRIVATE_DIALOGUE\n';
      final player = _Player();
      bindCinemaSubtitleTiming(player, store, media);
      final session = cinemaExternalSubtitleState(player);
      sessions.add(session);
      session.select(subtitle, path, '1', 0);
      await session.saveTiming!(
        session.fingerprint,
        const CinemaSubtitleTiming(offsetSeconds: 89),
      );
      await store.flush();
      final serialized = await library.readAsString();
      for (final secret in [
        media,
        path,
        subtitle,
        'FAKE_DO_NOT_PERSIST',
        'FAKE_SECRET_LOCATION',
        'FAKE_PRIVATE_DIALOGUE',
        'private-nas.invalid',
      ]) {
        expect(serialized.contains(secret), false);
      }
      final records = store.extras['subtitleTimingV1'] as Map;
      expect(
        records.keys.single,
        matches(RegExp(r'^[a-f0-9]{64}:[a-f0-9]{64}$')),
      );
      expect(records.values.single, {'scale': 1, 'offset': 89});
      expect(session.readSavedTiming!(session.fingerprint)?.offsetSeconds, 89);
    },
  );
}
