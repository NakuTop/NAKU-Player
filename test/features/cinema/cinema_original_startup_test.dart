import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'cinema_video_metadata_test.dart' show metadataMp4;
import 'package:dio/dio.dart' show CancelToken;
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_tv_media_policy.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_match.dart';
import 'package:kazumi/features/cinema/cinema_original_search.dart';
import 'package:kazumi/features/cinema/cinema_video_metadata.dart';

OriginalEdition _edition(String hash, int seeds, {bool chinese = false}) =>
    OriginalEdition(
      hash: hash,
      name: 'Open Film 2025 2160p ${chinese ? "CHS" : "WEB"}',
      seeds: seeds,
      pack: false,
      size: 50 << 20,
      magnet: '',
      subtitleHint: chinese,
    );

class _RangeEngine extends CinemaOriginalEngine {
  _RangeEngine(this.origin);
  final Uri origin;
  final opened = <String>[], closed = <String>[];
  @override
  Future<OriginalStream> open(
    OriginalMatches matches,
    OriginalEdition edition, {
    required CancelToken cancel,
    Duration budget = const Duration(seconds: 15),
  }) async {
    opened.add(edition.hash);
    return OriginalStream(
      origin.resolve(edition.hash),
      const {},
      const OriginalFile(1, 'S01E01.mkv', 65536),
      () async {
        closed.add(edition.hash);
      },
    );
  }
}

void main() {
  test(
    'a Matroska stream primes its remote Cues and Tags without reading the intervening film',
    () async {
      final fileSize = 3 << 20;
      final indexStart = 2 << 20;
      final header = <int>[
        0x1a,
        0x45,
        0xdf,
        0xa3,
        0x80,
        0x18,
        0x53,
        0x80,
        0x67,
        0xff,
      ];
      List<int> seek(List<int> id, int at) => [
        0x4d,
        0xbb,
        0x8d,
        0x53,
        0xab,
        0x84,
        ...id,
        0x53,
        0xac,
        0x83,
        (at >> 16) & 255,
        (at >> 8) & 255,
        at & 255,
      ];
      final head = Uint8List(384 * 1024)
        ..setAll(0, [
          ...header,
          0x11,
          0x4d,
          0x9b,
          0x74,
          0xa0,
          ...seek([0x1c, 0x53, 0xbb, 0x6b], indexStart - header.length),
          ...seek([0x12, 0x54, 0xc3, 0x67], indexStart + 2048 - header.length),
        ]);
      final indexRead = Completer<void>(), ranges = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        final range = r.headers.value('Range')!;
        ranges.add(range);
        final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
        final a = int.parse(match[1]!), b = int.parse(match[2]!);
        r.response
          ..statusCode = 206
          ..headers.set('Content-Range', 'bytes $a-$b/$fileSize');
        if (a == 0) {
          r.response.add(head.sublist(0, 32768));
          await r.response.flush();
          await indexRead.future.timeout(const Duration(seconds: 2));
          r.response.add(head.sublist(32768));
        } else {
          r.response.add(Uint8List(b - a + 1));
          indexRead.complete();
        }
        await r.response.close();
      });
      try {
        final url = Uri.parse('http://127.0.0.1:${server.port}/episode.mkv');
        final lease = OriginalStream(
          url,
          const {},
          OriginalFile(1, 'S01E01.mkv', fileSize),
          () async {},
        );
        await CinemaOriginalEngine().readOriginalHead(
          lease,
          CancelToken(),
          const Duration(seconds: 5),
        );
        expect(ranges, [
          'bytes=0-393215',
          'bytes=$indexStart-${indexStart + 2048 + 128 * 1024 - 1}',
        ]);
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'a widely seeded compact encode with an encoder setting matches only its own episode',
    () {
      final work = OriginalWork(
        names: ['North Road'],
        years: {'2019'},
        season: 1,
        episode: 2,
      );
      const name = 'North Road S01E02 North (2160p x265 10bit S95 Team).mkv';
      final compact = parseOriginalStream(work, {
        'infoHash': 'a' * 40,
        'title': 'North Road Season 1\n👤 54 💾 2.13 GB',
        'behaviorHints': {'filename': name},
      })!;
      expect(
        originalMainFile(work, compact, [
          const OriginalFile(
            1,
            'North Road Season 1 (2160p BD x265 10bit S86 Team)/$name',
            6000,
          ),
          const OriginalFile(
            2,
            'North Road S01E03 (2160p x265 10bit S95 Team).mkv',
            6000,
          ),
        ])?.id,
        1,
      );
      expect(
        originalMainFile(work, compact, [
          const OriginalFile(
            1,
            'North Road Season 2 (2160p BD x265 10bit S86 Team)/$name',
            6000,
          ),
        ]),
        isNull,
      );
      expect(
        originalMainFile(work, compact, [
          const OriginalFile(
            1,
            'North Road Season 1 (2160p x265 10bit S95 E12)/$name',
            6000,
          ),
        ]),
        isNull,
      );
      expect(
        work.matchRelease('North Road S01E02 (2160p x265 S02E03)'),
        isNull,
      );
      expect(
        work.matchRelease('North Road S01E02 S02 (2160p x265 10bit S95 Team)'),
        isNull,
      );
      OriginalEdition edition(
        String hash,
        int seeds,
        int size, {
        bool pack = false,
      }) => OriginalEdition(
        hash: hash,
        name: 'North Road S01E02 2160p CHS',
        seeds: seeds,
        size: size,
        pack: pack,
        magnet: '',
      );
      final primary = edition('large', 55, 10 << 30),
          heavy = edition('otherLarge', 54, 9 << 30),
          season = edition('pack', 55, 1 << 30, pack: true);
      final matches = OriginalMatches(work, [primary, heavy, season, compact]);
      expect(
        CinemaOriginalEngine().alternate((
          matches: matches,
          edition: primary,
        ))?.edition,
        same(compact),
      );
    },
  );
  test('a late but readable node still gets a bounded first frame window', () {
    const remaining = Duration(milliseconds: 1600),
        limit = Duration(seconds: 22);
    expect(originalStartupTimeout(remaining, limit), remaining);
    expect(
      originalStartupTimeout(remaining, limit, decoding: true),
      const Duration(milliseconds: 11600),
    );
    expect(
      originalStartupTimeout(
        const Duration(seconds: -11),
        limit,
        decoding: true,
      ),
      Duration.zero,
    );
  });
  test(
    'unresponsive indexes release the waiting player at its remaining deadline',
    () async {
      final lookup = OriginalLookup();
      var calls = 0;
      expect(
        await lookup.nextAvailable<Object>((matches) {
          calls++;
          return null;
        }, budget: const Duration(milliseconds: 15)),
        isNull,
      );
      expect(calls, 1);
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      lookup.notifyListeners();
      expect(calls, 1);
      lookup.dispose();
    },
  );
  test(
    'a slow indexed seed loses to a readable episode range and releases its lease',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final slow = Completer<void>();
      server.listen((r) async {
        if (r.uri.path == '/slow') await slow.future;
        try {
          expect(r.headers.value('range'), 'bytes=0-65535');
          r.response
            ..statusCode = 206
            ..headers.set('Content-Range', 'bytes 0-65535/65536')
            ..add(List.filled(65536, 7));
          await r.response.close();
        } on IOException {
          /* lost race */
        }
      });
      final engine = _RangeEngine(Uri.parse('http://127.0.0.1:${server.port}'));
      final work = OriginalWork(
        names: ['Show'],
        years: {'2016'},
        season: 1,
        episode: 1,
      );
      final a = _edition('slow', 88), b = _edition('fast', 3);
      final matches = OriginalMatches(work, [a, b]);
      try {
        final winner = await engine.openPlayable(
          (matches: matches, edition: a),
          alternate: (matches: matches, edition: b),
          cancel: CancelToken(),
          hedge: const Duration(milliseconds: 30),
          budget: const Duration(seconds: 2),
        );
        expect(winner.selection.edition, same(b));
        await winner.stream.close();
        slow.complete();
        for (var i = 0; i < 30 && engine.closed.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(engine.closed, unorderedEquals(['slow', 'fast']));
      } finally {
        if (!slow.isCompleted) slow.complete();
        await server.close(force: true);
      }
    },
  );
  test(
    'only an edition delivering playback bytes can finish its index inside the grace period',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final engine = _RangeEngine(Uri.parse('http://127.0.0.1:${server.port}'));
      final work = OriginalWork(names: ['River'], years: {'2020'});
      final gates = <String, Completer<void>>{};
      server.listen((r) async {
        try {
          final key = r.uri.path.substring(1);
          r.response
            ..statusCode = 206
            ..headers.set('Content-Range', 'bytes 0-65535/65536');
          if (key == 'moving') {
            r.response.add(Uint8List(32768));
            await r.response.flush();
          }
          await gates[key]!.future;
          r.response.add(Uint8List(key == 'moving' ? 32768 : 65536));
          await r.response.close();
        } on IOException {}
      });
      try {
        for (final hash in ['moving', 'stalled']) {
          final e = _edition(hash, 8);
          gates[hash] = Completer<void>();
          final opens = engine.openPlayable(
            (matches: OriginalMatches(work, [e]), edition: e),
            budget: const Duration(milliseconds: 180),
            progressGrace: const Duration(milliseconds: 550),
            cancel: CancelToken(),
          );
          final check = hash == 'moving'
              ? opens.then((r) => r.stream.close())
              : expectLater(opens, throwsFormatException);
          await Future<void>.delayed(const Duration(milliseconds: 310));
          gates[hash]!.complete();
          await check;
        }
      } finally {
        for (final g in gates.values) {
          if (!g.isCompleted) g.complete();
        }
        await server.close(force: true);
      }
    },
  );

  test(
    'the measured codec rejects an unlabelled HEVC edition before opening the decoder',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        final data = Uint8List(65536)
          ..setAll(
            0,
            metadataMp4(
              width: 3840,
              height: 2160,
              codec: r.uri.path == '/opaque' ? 'hvc1' : 'avc1',
            ),
          );
        r.response
          ..statusCode = 206
          ..headers.set('Content-Range', 'bytes 0-65535/65536')
          ..add(data);
        await r.response.close();
      });
      final engine = _RangeEngine(Uri.parse('http://127.0.0.1:${server.port}'));
      final tv = CinemaTVMediaEnvironment(
        supported: () => true,
        reader: () async => {
          'decoderCapabilities': [
            {'codec': 'AVC', 'maxWidth': 3840, 'maxHeight': 2160},
          ],
        },
      );
      await tv.refresh();
      final a = _edition('opaque', 85), b = _edition('fallback', 4);
      final matches = OriginalMatches(
        OriginalWork(names: ['Film'], years: {'2020'}),
        [a, b],
      );
      final rejected = <String>[];
      try {
        final winner = await engine.openPlayable(
          (matches: matches, edition: a),
          alternate: (matches: matches, edition: b),
          cancel: CancelToken(),
          acceptsVideo: tv.supportsOriginalVideo,
          onFailure: (s) => rejected.add(s.edition.hash),
        );
        expect(rejected, [a.hash]);
        expect(engine.measured(matches, a)?.codec, 'HEVC');
        expect(engine.measured(matches, b)?.codec, 'H.264');
        expect(winner.selection.edition, same(b));
        await winner.stream.close();
      } finally {
        await server.close(force: true);
      }
    },
  );
  test(
    'old television hardware skips AV1 and DV-only but accepts a HEVC HDR10 hybrid',
    () async {
      final tv = CinemaTVMediaEnvironment(
        supported: () => true,
        reader: () async => {
          'decoderCapabilities': [
            {'codec': 'HEVC', 'maxWidth': 3840, 'maxHeight': 2160},
          ],
          'displayCapabilities': {
            'known': true,
            'dolbyVision': false,
            'hdr10': true,
          },
        },
      );
      await tv.refresh();
      OriginalEdition format(String text) => OriginalEdition(
        hash: text,
        name: 'Season S01 2160p $text',
        size: 1,
        seeds: 12,
        pack: true,
        magnet: '',
      );
      final av1 = format('AV1 CHS'),
          dv = format('HEVC Dolby Vision Profile 5'),
          hevc = format('HEVC DV HDR10');
      final work = OriginalMatches(
        OriginalWork(names: ['Show'], years: {'2016'}, season: 1, episode: 1),
        [dv, av1, hevc],
      );
      expect(
        CinemaOriginalEngine()
            .preferred(work, compatibility: tv.originalCompatibility)
            ?.edition,
        same(hevc),
      );
      expect(tv.originalCompatibility(av1), -1);
      expect(
        CinemaOriginalEngine()
            .preferred(
              work,
              preferredHash: dv.hash,
              compatibility: tv.originalCompatibility,
            )
            ?.edition,
        same(dv),
      );
    },
  );
  test(
    '4K selection uses subtitle evidence then seed count and respects an explicit choice',
    () {
      final engine = CinemaOriginalEngine();
      final low = _edition('few', 4, chinese: true);
      final high = _edition('many', 90, chinese: true);
      final unknown = _edition('unlabelled', 600);
      final matches = OriginalMatches(
        OriginalWork(names: ['Open Film'], years: {'2025'}),
        [unknown, low, high],
      );
      expect(engine.preferred(matches)?.edition, same(high));
      expect(
        engine.preferred(matches, excluding: {'many'})?.edition,
        same(low),
      );
      expect(
        engine.preferred(matches, preferredHash: 'unlabelled')?.edition,
        same(unknown),
      );
      expect(
        engine.preferred(matches, excluding: {'many', 'few'})?.edition,
        same(unknown),
      );
    },
  );

  test(
    'an edition confirmed below 4K is excluded on reopening the same episode',
    () {
      final engine = CinemaOriginalEngine();
      final wrong = _edition('not-4k', 1000, chinese: true);
      final next = _edition('real-4k', 12, chinese: true);
      final matches = OriginalMatches(
        OriginalWork(
          names: ['Open Series'],
          years: {'2025'},
          season: 1,
          episode: 2,
        ),
        [wrong, next],
      );
      engine.record(
        matches,
        wrong,
        const CinemaVideoMetadata(1920, 1080, 'h264'),
      );
      expect(
        engine.preferred(matches, preferredHash: wrong.hash)?.edition,
        same(next),
      );
      expect(engine.preferred(matches, excluding: {next.hash}), isNull);
    },
  );
}
