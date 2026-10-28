import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_archive.dart';

List<int> zip(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.add(ArchiveFile.string(entry.key, entry.value));
  }
  return ZipEncoder().encode(archive);
}

int central(List<int> bytes) {
  final data = ByteData.sublistView(Uint8List.fromList(bytes));
  for (var i = 0; i <= bytes.length - 46; i++) {
    if (data.getUint32(i, Endian.little) == 0x02014b50) return i;
  }
  throw StateError('fixture central directory missing');
}

void main() {
  test(
    'only safe timed subtitle files are listed and read in memory',
    () async {
      const text = '1\n00:00:01,000 --> 00:00:02,000\n字幕内容\n';
      final bytes = zip({
        'Season 1/Show.S01E03.srt': text,
        '../escape.srt': text,
        '/absolute.srt': text,
        'D:/drive.srt': text,
        'notes.txt': 'not subtitles',
      });
      expect(await CinemaSubtitleArchive.list(bytes), [
        'Season 1/Show.S01E03.srt',
      ]);
      expect(
        utf8.decode(
          await CinemaSubtitleArchive.extract(
            bytes,
            'Season 1/Show.S01E03.srt',
          ),
        ),
        text,
      );
      for (final path in [
        '../escape.srt',
        '/absolute.srt',
        'D:/drive.srt',
        'notes.txt',
      ]) {
        await expectLater(
          CinemaSubtitleArchive.extract(bytes, path),
          throwsFormatException,
        );
      }
    },
  );
  test('CRC corruption and forged uncompressed sizes are rejected', () async {
    final bytes = Uint8List.fromList(
      zip({'example.srt': 'example timed content'}),
    );
    final at = central(bytes), data = ByteData.sublistView(bytes);
    data.setUint32(at + 16, 0x12345678, Endian.little);
    await expectLater(
      CinemaSubtitleArchive.extract(bytes, 'example.srt'),
      throwsFormatException,
    );
    final forged = Uint8List.fromList(
      zip({'example.srt': 'example timed content'}),
    );
    ByteData.sublistView(
      forged,
    ).setUint32(central(forged) + 24, 1, Endian.little);
    await expectLater(
      CinemaSubtitleArchive.extract(forged, 'example.srt'),
      throwsFormatException,
    );
  });
  test(
    'declared decompression and archive count limits are enforced',
    () async {
      final bytes = Uint8List.fromList(zip({'example.srt': 'small'}));
      ByteData.sublistView(bytes).setUint32(
        central(bytes) + 24,
        CinemaSubtitleArchive.maxBytes + 1,
        Endian.little,
      );
      expect(await CinemaSubtitleArchive.list(bytes), isEmpty);
      await expectLater(
        CinemaSubtitleArchive.extract(bytes, 'example.srt'),
        throwsFormatException,
      );
      final many = zip({
        for (var i = 0; i <= CinemaSubtitleArchive.maxEntries; i++)
          '$i.srt': 'x',
      });
      await expectLater(
        CinemaSubtitleArchive.list(many),
        throwsFormatException,
      );
      await expectLater(
        CinemaSubtitleArchive.list(
          Uint8List(CinemaSubtitleArchive.maxBytes + 1),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'symlink entries cannot be selected or expanded while listing',
    () async {
      final bytes = Uint8List.fromList(zip({'link.srt': '../outside'}));
      ByteData.sublistView(
        bytes,
      ).setUint32(central(bytes) + 38, 0xa1ff << 16, Endian.little);
      expect(await CinemaSubtitleArchive.list(bytes), isEmpty);
      await expectLater(
        CinemaSubtitleArchive.extract(bytes, 'link.srt'),
        throwsFormatException,
      );
    },
  );
  test('a lying compressed member cannot grow beyond the output cap', () async {
    final bytes = Uint8List.fromList(
      zip({'large.srt': 'x' * (CinemaSubtitleArchive.maxBytes + 1000)}),
    );
    ByteData.sublistView(
      bytes,
    ).setUint32(central(bytes) + 24, 1, Endian.little);
    await expectLater(
      CinemaSubtitleArchive.extract(bytes, 'large.srt'),
      throwsFormatException,
    );
  });
}
