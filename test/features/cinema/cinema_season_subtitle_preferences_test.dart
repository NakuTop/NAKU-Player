import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_season_subtitle_preferences.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_timing.dart';

Map<String, dynamic> _row(
  String name, {
  String lang = 'zh',
  String provider = 'Fixture catalog',
  bool verified = true,
  bool bilingual = true,
}) => {
  'subtitleFileName': name,
  'provider': provider,
  'lang': lang,
  'verified': verified,
  'bilingual': bilingual,
  // A URL is transient catalog data and must not be persisted with a profile.
  'url': 'https://fixture.invalid/subtitle?token=DO_NOT_SAVE',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File library;
  late CinemaStore store;
  late CinemaSeasonSubtitlePreferences preferences;
  const identity = 'nas://PRIVATE_HOST/PRIVATE_PATH?token=PRIVATE_TOKEN';
  const selected = 'A.Test.Series.S10E02.1080p.HULU.WEB-DL.NTb.chs.ass';
  const timing = CinemaSubtitleTiming(scale: .96, offsetSeconds: 12.25);

  Future<void> remember({
    String seriesIdentity = identity,
    int season = 10,
    int episode = 2,
    String name = selected,
  }) => preferences.remember(
    seriesIdentity: seriesIdentity,
    season: season,
    fromEpisode: episode,
    queryTitle: 'A Test Series',
    imdbId: 'tt123456',
    row: _row(name),
    timing: timing,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'naku-season-prefs-test-',
    );
    library = File('${directory.path}/library.json');
    store = CinemaStore(file: library, defaults: const []);
    await store.load();
    preferences = CinemaSeasonSubtitlePreferences(store);
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'persists a season profile and calibration across application reload',
    () async {
      await remember();
      await store.flush();
      store.dispose();
      store = CinemaStore(file: library, defaults: const []);
      await store.load();
      preferences = CinemaSeasonSubtitlePreferences(store);

      final profile = preferences.read(identity, 10)!;
      expect(profile.queryTitle, 'A Test Series');
      expect(profile.imdbId, 'tt123456');
      expect(profile.fromEpisode, 2);
      expect(profile.season, 10);
      expect(profile.name, selected);
      expect(profile.language, 'zh');
      expect(profile.provider, 'Fixture catalog');
      expect(profile.bilingual, true);
      expect(profile.timing.scale, .96);
      expect(profile.timing.offsetSeconds, 12.25);
      expect(profile.appliesTo(1), false);
      expect(profile.appliesTo(3), true);
      expect(preferences.read(identity, 11), isNull);
      expect(preferences.read('another-library-work', 10), isNull);
    },
  );

  test(
    'selects the same release family for the next episode, across catalogs',
    () async {
      await remember();
      final profile = preferences.read(identity, 10)!;
      final unrelated = _row('A.Test.Series.S10E03.720p.HDTV.CAKES.chs.ass');
      final matching = _row(
        'A.Test.Series.S10E03.1080p.HULU.WEB-DL.NTb.chs.ass',
        provider: 'Other catalog',
      );
      final wrongLanguage = _row(
        'A.Test.Series.S10E03.1080p.HULU.WEB-DL.NTb.eng.ass',
        lang: 'eng',
      );
      expect(
        chooseCinemaSeasonSubtitle(
          profile,
          [unrelated, wrongLanguage, matching],
          season: 10,
          episode: 3,
        ),
        same(matching),
      );
    },
  );

  test(
    'missing Chinese never falls back to English or an unverified candidate',
    () async {
      await remember();
      final profile = preferences.read(identity, 10)!;
      expect(
        chooseCinemaSeasonSubtitle(
          profile,
          [
            _row('A Test Series S10E03 English', lang: 'eng'),
            _row('A Test Series S10E03 中文', verified: false),
            _row('A Test Series S10E03 未识别', lang: 'und'),
          ],
          season: 10,
          episode: 3,
        ),
        isNull,
      );
      final chinese = _row('A Test Series S10E03 简体', lang: 'chi');
      expect(
        chooseCinemaSeasonSubtitle(profile, [chinese], season: 10, episode: 3),
        same(chinese),
      );
    },
  );

  test(
    'cannot select a subtitle from an earlier episode or another season',
    () async {
      await remember();
      final profile = preferences.read(identity, 10)!;
      final next = _row('A Test Series S10E03 中文');
      expect(
        chooseCinemaSeasonSubtitle(profile, [next], season: 10, episode: 1),
        isNull,
      );
      expect(
        chooseCinemaSeasonSubtitle(profile, [next], season: 11, episode: 3),
        isNull,
      );
      for (final wrong in [
        'A Test Series S10E02 中文',
        'A Test Series S11E03 中文',
        'A Test Series 10x02 中文',
        'A Test Series Season 11 Episode 3 中文',
        'A Test Series S10 E02 中文',
        'A Test Series 第十季 第二集 中文',
        'A Test Series E02 中文',
      ]) {
        expect(
          chooseCinemaSeasonSubtitle(
            profile,
            [_row(wrong)],
            season: 10,
            episode: 3,
          ),
          isNull,
          reason: wrong,
        );
      }
      final correct = _row('A Test Series 第十季 第三集 中文');
      expect(
        chooseCinemaSeasonSubtitle(profile, [correct], season: 10, episode: 3),
        same(correct),
      );
    },
  );

  test(
    'archive entry determines the episode when a catalog title is a season pack',
    () async {
      await remember();
      final wrong = {
        ..._row('A Test Series S10E01-S10E10 全季'),
        'archiveEntry': 'Season10/A.Test.Series.S10E02.chs.ass',
      };
      final correct = {
        ..._row('A Test Series S10E01-S10E10 全季'),
        'archiveEntry': 'Season10/A.Test.Series.S10E03.chs.ass',
      };
      expect(
        chooseCinemaSeasonSubtitle(
          preferences.read(identity, 10)!,
          [wrong, correct],
          season: 10,
          episode: 3,
        ),
        same(correct),
      );
    },
  );

  test(
    'prefers the selected Chinese script and bilingual preference',
    () async {
      await remember(name: 'A Test Series S10E02 chs.ass');
      final simplified = _row('A Test Series S10E03 chs.ass');
      final traditional = _row('A Test Series S10E03 cht.ass');
      final mono = _row('A Test Series S10E03 chs.ass', bilingual: false);
      expect(
        chooseCinemaSeasonSubtitle(
          preferences.read(identity, 10)!,
          [traditional, mono, simplified],
          season: 10,
          episode: 3,
        ),
        same(simplified),
      );
    },
  );

  test(
    'release family ignores episode numbering and archive directories',
    () async {
      await remember(name: 'A_Test_Series_S10E02_HULU_NTb_chs.ass');
      final matching = {
        ..._row('A Test Series Season 10 pack'),
        'archiveEntry': '公开字幕包/A_Test_Series_S10E03_HULU_NTb_chs.ass',
      };
      final other = _row('A_Test_Series_S10E03_HULU_CAKES_chs.ass');
      expect(
        chooseCinemaSeasonSubtitle(
          preferences.read(identity, 10)!,
          [other, matching],
          season: 10,
          episode: 3,
        ),
        same(matching),
      );
    },
  );

  test(
    'high confidence family accepts a next episode across separators',
    () async {
      await remember(name: 'A_Test_Series_S10E02_HULU_NTb_chs.ass');
      final next = _row('a.test.series.S10E03.HULU.NTb.CHS.srt');
      expect(
        cinemaSeasonSubtitleFamilyMatches(
          preferences.read(identity, 10)!,
          next,
        ),
        true,
      );
    },
  );

  test(
    'high confidence family rejects a different release or subtitle group',
    () async {
      await remember();
      final profile = preferences.read(identity, 10)!;
      for (final name in [
        'A.Test.Series.S10E03.1080p.AMZN.WEB-DL.NTb.chs.ass',
        'A.Test.Series.S10E03.1080p.HULU.WEB-DL.CAKES.chs.ass',
        'A.Test.Series.S10E03.chs.ass',
      ]) {
        expect(
          cinemaSeasonSubtitleFamilyMatches(profile, _row(name)),
          false,
          reason: name,
        );
      }
    },
  );

  test(
    'high confidence family rejects another script, language or unverified file',
    () async {
      await remember(name: 'A Test Series S10E02 chs.ass');
      final profile = preferences.read(identity, 10)!;
      for (final row in [
        _row('A Test Series S10E03 cht.ass'),
        _row('A Test Series S10E03 chs.ass', lang: 'eng'),
        _row('A Test Series S10E03 chs.ass', verified: false),
      ]) {
        expect(cinemaSeasonSubtitleFamilyMatches(profile, row), false);
      }
    },
  );

  test('season zero specials remain isolated from the first season', () async {
    await remember(season: 0, name: 'A Test Series S00E02 chs.ass');
    final next = _row('A Test Series S00E03 chs.ass');
    expect(preferences.read(identity, 0), isNotNull);
    expect(preferences.read(identity, 1), isNull);
    expect(
      chooseCinemaSeasonSubtitle(
        preferences.read(identity, 0)!,
        [next],
        season: 0,
        episode: 3,
      ),
      same(next),
    );
  });

  test(
    'concurrent writes across instances preserve every work and final timing',
    () async {
      final other = CinemaSeasonSubtitlePreferences(store);
      final writes = <Future<void>>[];
      for (var index = 0; index < 12; index++) {
        writes.add(remember(seriesIdentity: 'work-$index'));
        writes.add(
          other.updateTiming(
            'work-$index',
            10,
            CinemaSubtitleTiming(offsetSeconds: index.toDouble()),
          ),
        );
      }
      await Future.wait(writes);
      expect((store.extras['seasonSubtitleProfilesV1'] as Map), hasLength(12));
      for (var index = 0; index < 12; index++) {
        expect(
          preferences.read('work-$index', 10)!.timing.offsetSeconds,
          index,
        );
      }
      await other.updateTiming('missing-work', 10, timing);
      expect((store.extras['seasonSubtitleProfilesV1'] as Map), hasLength(12));
      await other.clear('work-0', 10);
      expect(preferences.read('work-0', 10), isNull);
      expect(preferences.read('work-1', 10), isNotNull);
    },
  );

  test('bounded profile history keeps an updated work recent', () async {
    for (var index = 0; index < 64; index++) {
      await remember(seriesIdentity: 'work-$index');
    }
    await preferences.updateTiming('work-0', 10, timing);
    await remember(seriesIdentity: 'work-64');
    expect((store.extras['seasonSubtitleProfilesV1'] as Map), hasLength(64));
    expect(preferences.read('work-0', 10), isNotNull);
    expect(preferences.read('work-1', 10), isNull);
    expect(preferences.read('work-64', 10), isNotNull);
  });

  test(
    'no private work identifier, URL, path or dialogue is persisted',
    () async {
      await preferences.remember(
        seriesIdentity: identity,
        season: 10,
        fromEpisode: 2,
        queryTitle: 'A Test Series',
        row: {
          ..._row('A Test Series S10E02 chs.ass'),
          'archiveEntry': r'C:\PRIVATE_PATH\A.Test.Series.S10E02.chs.ass',
          'dialogue': 'PRIVATE_DIALOGUE',
        },
      );
      await store.flush();
      final encoded = await library.readAsString();
      for (final secret in [
        identity,
        'PRIVATE_HOST',
        'PRIVATE_PATH',
        'PRIVATE_TOKEN',
        'PRIVATE_DIALOGUE',
        'fixture.invalid',
        'DO_NOT_SAVE',
      ]) {
        expect(encoded.contains(secret), false, reason: secret);
      }
      final json = jsonDecode(encoded) as Map;
      final records = json['seasonSubtitleProfilesV1'] as Map;
      expect(records.keys.single, matches(RegExp(r'^[a-f0-9]{64}:10$')));
      expect(
        preferences.read(identity, 10)!.name,
        'A.Test.Series.S10E02.chs.ass',
      );
    },
  );

  test('invalid profiles and out of range timing are rejected', () async {
    await remember();
    final original = store.extras['seasonSubtitleProfilesV1'] as Map;
    final key = original.keys.single as String;
    final valid = Map<String, dynamic>.from(original.values.single as Map);
    for (final change in [
      {'scale': .49},
      {'offset': 21601},
      {'fromEpisode': 0},
      {'season': 11},
      {'queryTitle': 'https://PRIVATE_HOST/title'},
      {'language': 'all'},
      {'language': 'zh-eng'},
      {'name': r'C:\PRIVATE_PATH\subtitle.ass'},
      {'imdbId': 'https://private.invalid'},
    ]) {
      await store.setExtra('seasonSubtitleProfilesV1', {
        key: {...valid, ...change},
      });
      expect(preferences.read(identity, 10), isNull, reason: '$change');
    }
    for (final row in [
      _row('fixture.ass', verified: false),
      _row('fixture.ass', lang: 'all'),
      _row('A Test Series S10E03 fixture.ass'),
    ]) {
      await expectLater(
        preferences.remember(
          seriesIdentity: identity,
          season: 10,
          fromEpisode: 2,
          queryTitle: 'A Test Series',
          row: row,
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      preferences.updateTiming(
        identity,
        10,
        const CinemaSubtitleTiming(offsetSeconds: double.nan),
      ),
      throwsFormatException,
    );
  });
}
