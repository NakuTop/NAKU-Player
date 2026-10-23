import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_saved_subtitle.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

const _text = '1\n00:00:01,000 --> 00:00:03,000\nSelf authored caption\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late CinemaStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-saved-caption-');
    store = CinemaStore(
      file: File('${directory.path}/library.json'),
      defaults: const [],
    );
    await store.load();
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'exact caption and calibration survive reload without entering exports',
    () async {
      const identity = 'private-media?token=DO_NOT_SAVE';
      final saved = CinemaSavedSubtitleStore(store, identity);
      await saved.save(
        const CinemaSavedSubtitle(
          text: _text,
          title: 'Chosen cut',
          language: 'zh-eng',
          timing: CinemaSubtitleTiming(scale: .96, offsetSeconds: 6.793222),
        ),
      );
      final reopened = await CinemaSavedSubtitleStore(store, identity).read();
      expect(reopened!.text, _text);
      expect(reopened.title, 'Chosen cut');
      expect(reopened.language, 'zh-eng');
      expect(reopened.timing.scale, .96);
      expect(reopened.timing.offsetSeconds, 6.793222);
      expect(
        await CinemaSavedSubtitleStore(store, 'another episode').read(),
        isNull,
      );
      expect(jsonEncode(await store.exportLibrary()), isNot(contains(_text)));
      final files = await (await store.subtitleCacheDirectory())
          .list()
          .toList();
      expect(files, hasLength(1));
      expect(
        files.single.uri.pathSegments.last,
        matches(RegExp(r'^[a-f0-9]{64}\.json$')),
      );
      expect(
        await File(files.single.path).readAsString(),
        isNot(contains(identity)),
      );
    },
  );

  test(
    'queued calibration updates apply only to their chosen content',
    () async {
      final saved = CinemaSavedSubtitleStore(store, 'same video');
      final value = const CinemaSavedSubtitle(text: _text);
      final first = saved.save(value);
      final update = saved.updateTiming(
        value.fingerprint,
        const CinemaSubtitleTiming(scale: 1.02, offsetSeconds: 12),
      );
      await Future.wait([first, update]);
      expect((await saved.read())!.timing.offsetSeconds, 12);
      await saved.updateTiming(
        'another cut',
        const CinemaSubtitleTiming(offsetSeconds: 99),
      );
      expect((await saved.read())!.timing.offsetSeconds, 12);
      await saved.disable();
      expect((await saved.read())!.disabled, true);
    },
  );

  test(
    'malformed or oversized cache files are ignored for online recovery',
    () async {
      final saved = CinemaSavedSubtitleStore(store, 'corrupt file');
      await saved.save(const CinemaSavedSubtitle(text: _text));
      final file =
          (await (await store.subtitleCacheDirectory()).list().toList()).single
              as File;
      for (final text in [
        '{bad json',
        '{"version":1,"text":12}',
        'x' * (CinemaSavedSubtitleStore.maxFileBytes + 1),
      ]) {
        await file.writeAsString(text);
        expect(await saved.read(), isNull);
      }
    },
  );

  test(
    'caption count remains bounded while the latest video is retained',
    () async {
      for (var i = 0; i <= CinemaSavedSubtitleStore.maxEntries; i++) {
        await CinemaSavedSubtitleStore(
          store,
          'video-$i',
        ).save(const CinemaSavedSubtitle(text: _text));
      }
      final files = await (await store.subtitleCacheDirectory())
          .list()
          .toList();
      expect(files, hasLength(CinemaSavedSubtitleStore.maxEntries));
      expect(
        await CinemaSavedSubtitleStore(
          store,
          'video-${CinemaSavedSubtitleStore.maxEntries}',
        ).read(),
        isNotNull,
      );
    },
  );
}
