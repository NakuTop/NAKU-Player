import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_video_metadata.dart';

Uint8List metadataBox(String type, List<int> body) {
  final bytes = Uint8List(body.length + 8);
  ByteData.sublistView(bytes).setUint32(0, bytes.length);
  bytes.setAll(4, type.codeUnits);
  bytes.setAll(8, body);
  return bytes;
}

Uint8List metadataMp4({
  int width = 1920,
  int height = 1080,
  String codec = 'avc1',
}) {
  final entry = Uint8List(78);
  ByteData.sublistView(entry)
    ..setUint16(24, width)
    ..setUint16(26, height);
  var bytes = metadataBox('stsd', [
    0,
    0,
    0,
    0,
    0,
    0,
    0,
    1,
    ...metadataBox(codec, entry),
  ]);
  for (final type in ['stbl', 'minf', 'mdia', 'trak', 'moov']) {
    bytes = metadataBox(type, bytes);
  }
  return bytes;
}

Uint8List metadataTs() {
  // SPS from the project's self-generated 1280x720 native playback fixture.
  const hex = '6742c01fda014016ec0440000003004000000c03c60ca8';
  final sps = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  final bytes = Uint8List(188 * 3)..fillRange(0, 188 * 3, 255);
  for (var i = 0; i < 3; i++) {
    bytes.setAll(188 * i, [0x47, i == 0 ? 0x41 : 0x01, 0x00, 0x10 | i]);
  }
  bytes.setAll(4, [0, 0, 1, 0xe0, 0, 0, 0x80, 0, 0, 0, 0, 0, 1, ...sps]);
  return bytes;
}

void main() {
  test('MP4 dimensions and codec come from the visual sample entry', () {
    for (final entry in {
      'avc1': 'H.264',
      'hvc1': 'HEVC',
      'av01': 'AV1',
      'vp09': 'VP9',
    }.entries) {
      final value = cinemaVideoMetadata(metadataMp4(codec: entry.key));
      expect(value?.width, 1920);
      expect(value?.height, 1080);
      expect(value?.codec, entry.value);
    }
  });
  test('MP4 tail scanning requires a complete moov structure', () {
    final tail = Uint8List.fromList([
      ...List.filled(1000, 99),
      ...metadataMp4(width: 1280, height: 720),
    ]);
    expect(cinemaVideoMetadata(tail), isNull);
    expect(cinemaVideoMetadata(tail, mp4Tail: true)?.height, 720);
    expect(
      cinemaVideoMetadata(
        Uint8List.sublistView(tail, 0, tail.length - 1),
        mp4Tail: true,
      ),
      isNull,
    );
  });
  test('TS video PES yields cropped H264 dimensions from real SPS', () {
    final value = cinemaVideoMetadata(metadataTs());
    expect(value?.width, 1280);
    expect(value?.height, 720);
    expect(value?.codec, 'H.264');
  });
  test(
    'malformed, oversized and arbitrary data stays unknown without guessing',
    () {
      expect(cinemaVideoMetadata(metadataMp4(height: 0)), isNull);
      expect(cinemaVideoMetadata(metadataMp4(width: 20000)), isNull);
      for (var length = 0; length < 300; length++) {
        expect(
          () => cinemaVideoMetadata(
            Uint8List.fromList(List.generate(length, (i) => (i * 29) % 256)),
          ),
          returnsNormally,
        );
      }
      final bytes = metadataTs();
      bytes[7] = 0x40; // Break the PES start prefix.
      expect(cinemaVideoMetadata(bytes), isNull);
    },
  );
}
