import 'dart:typed_data';

/// Only dimensions read from a video header, never inferred from titles/bitrate.
class CinemaVideoMetadata {
  const CinemaVideoMetadata(this.width, this.height, this.codec);
  final int width, height;
  final String codec;
}

CinemaVideoMetadata? cinemaVideoMetadata(
  Uint8List bytes, {
  bool mp4Tail = false,
}) {
  if (bytes.length < 8) return null;
  try {
    final direct = _mp4(bytes);
    if (direct != null) return direct;
    if (mp4Tail) {
      final data = ByteData.sublistView(bytes);
      for (var at = 4; at + 4 <= bytes.length; at++) {
        if (bytes[at] != 0x6d ||
            bytes[at + 1] != 0x6f ||
            bytes[at + 2] != 0x6f ||
            bytes[at + 3] != 0x76) {
          continue;
        }
        final size = data.getUint32(at - 4);
        if (size >= 8 && size <= bytes.length - at + 4) {
          final found = _mp4(
            Uint8List.sublistView(bytes, at - 4, at - 4 + size),
          );
          if (found != null) return found;
        }
      }
    }
    return _transportStream(bytes);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

CinemaVideoMetadata? _mp4(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  String tag(int offset) =>
      String.fromCharCodes(bytes.sublist(offset, offset + 4));
  CinemaVideoMetadata? boxes(
    int start,
    int end,
    int depth, {
    bool samples = false,
  }) {
    if (depth > 8) return null;
    for (
      var offset = start, count = 0;
      offset + 8 <= end && count < 4096;
      count++
    ) {
      var size = data.getUint32(offset);
      var header = 8;
      if (size == 1) {
        if (offset + 16 > end) return null;
        size = data.getUint64(offset + 8);
        header = 16;
      } else if (size == 0) {
        size = end - offset;
      }
      if (size < header || size > end - offset) return null;
      final type = tag(offset + 4);
      if (samples && size >= 36) {
        final codec = switch (type) {
          'avc1' || 'avc3' => 'H.264',
          'hvc1' || 'hev1' => 'HEVC',
          'av01' => 'AV1',
          'vp09' => 'VP9',
          _ => '',
        };
        final width = data.getUint16(offset + 32);
        final height = data.getUint16(offset + 34);
        if (codec.isNotEmpty && _validSize(width, height)) {
          return CinemaVideoMetadata(width, height, codec);
        }
      }
      final child = offset + header;
      final nested = switch (type) {
        'moov' ||
        'trak' ||
        'mdia' ||
        'minf' ||
        'stbl' => boxes(child, offset + size, depth + 1),
        'stsd' when child + 8 <= offset + size => boxes(
          child + 8,
          offset + size,
          depth + 1,
          samples: true,
        ),
        _ => null,
      };
      if (nested != null) return nested;
      offset += size;
    }
    return null;
  }

  return boxes(0, bytes.length, 0);
}

bool _validSize(int width, int height) =>
    width > 0 && height > 0 && width <= 16384 && height <= 16384;

CinemaVideoMetadata? _transportStream(Uint8List bytes) {
  var sync = -1;
  for (var offset = 0; offset < 188 && offset + 376 < bytes.length; offset++) {
    if (bytes[offset] == 0x47 &&
        bytes[offset + 188] == 0x47 &&
        bytes[offset + 376] == 0x47) {
      sync = offset;
      break;
    }
  }
  if (sync < 0) return null;
  final streams = <int, BytesBuilder>{};
  for (var offset = sync; offset + 188 <= bytes.length; offset += 188) {
    if (bytes[offset] != 0x47 ||
        bytes[offset + 1] & 0x80 != 0 ||
        bytes[offset + 3] & 0xc0 != 0) {
      continue;
    }
    final pid = ((bytes[offset + 1] & 0x1f) << 8) | bytes[offset + 2];
    final control = (bytes[offset + 3] >> 4) & 3;
    if (control == 0 || control == 2) continue;
    var payload = offset + 4;
    if (control == 3) payload += 1 + bytes[payload];
    if (payload >= offset + 188) continue;
    if (bytes[offset + 1] & 0x40 != 0) {
      if (payload + 9 > offset + 188 ||
          bytes[payload] != 0 ||
          bytes[payload + 1] != 0 ||
          bytes[payload + 2] != 1 ||
          bytes[payload + 3] < 0xe0 ||
          bytes[payload + 3] > 0xef) {
        continue;
      }
      payload += 9 + bytes[payload + 8];
      if (payload >= offset + 188) continue;
      if (streams.length >= 32 && !streams.containsKey(pid)) continue;
      streams.putIfAbsent(pid, () => BytesBuilder(copy: false));
    }
    streams[pid]?.add(Uint8List.sublistView(bytes, payload, offset + 188));
  }
  for (final stream in streams.values) {
    final elementary = stream.takeBytes();
    for (var offset = 0; offset + 5 < elementary.length; offset++) {
      if (elementary[offset] != 0 || elementary[offset + 1] != 0) continue;
      final prefix = elementary[offset + 2] == 1
          ? 3
          : elementary[offset + 2] == 0 && elementary[offset + 3] == 1
          ? 4
          : 0;
      if (prefix == 0 || elementary[offset + prefix] & 0x1f != 7) continue;
      final result = _h264(
        Uint8List.sublistView(elementary, offset + prefix + 1),
      );
      if (result != null) return result;
    }
  }
  return null;
}

class _Bits {
  _Bits(this.bytes);
  final List<int> bytes;
  int offset = 0;
  int read(int count) {
    if (count < 0 || count > 32 || offset + count > bytes.length * 8) {
      throw const FormatException('Truncated SPS');
    }
    var value = 0;
    for (var bit = 0; bit < count; bit++, offset++) {
      value = (value << 1) | ((bytes[offset >> 3] >> (7 - (offset & 7))) & 1);
    }
    return value;
  }

  int ue() {
    var zeroes = 0;
    while (read(1) == 0) {
      if (++zeroes > 24) throw const FormatException('Invalid SPS');
    }
    return (1 << zeroes) - 1 + read(zeroes);
  }

  int se() {
    final value = ue();
    return value.isOdd ? (value + 1) ~/ 2 : -(value ~/ 2);
  }
}

CinemaVideoMetadata? _h264(Uint8List bytes) {
  final rbsp = <int>[];
  for (var index = 0; index < bytes.length && rbsp.length < 4096; index++) {
    if (index >= 2 &&
        bytes[index] == 3 &&
        bytes[index - 1] == 0 &&
        bytes[index - 2] == 0) {
      continue;
    }
    rbsp.add(bytes[index]);
  }
  final bits = _Bits(rbsp);
  final profile = bits.read(8);
  bits.read(16);
  bits.ue(); // Sequence parameter set ID.
  var chroma = 1, separate = 0;
  if ([
    100,
    110,
    122,
    244,
    44,
    83,
    86,
    118,
    128,
    138,
    139,
    134,
    135,
  ].contains(profile)) {
    chroma = bits.ue();
    if (chroma > 3) return null;
    if (chroma == 3) separate = bits.read(1);
    bits.ue();
    bits.ue();
    bits.read(1);
    if (bits.read(1) != 0) {
      for (var index = 0; index < (chroma == 3 ? 12 : 8); index++) {
        if (bits.read(1) == 0) continue;
        var last = 8, next = 8;
        for (var item = 0; item < (index < 6 ? 16 : 64); item++) {
          if (next != 0) next = (last + bits.se() + 256) % 256;
          if (next != 0) last = next;
        }
      }
    }
  }
  bits.ue();
  final order = bits.ue();
  if (order == 0) {
    bits.ue();
  } else if (order == 1) {
    bits.read(1);
    bits.se();
    bits.se();
    final count = bits.ue();
    if (count > 256) return null;
    for (var index = 0; index < count; index++) {
      bits.se();
    }
  } else if (order > 2) {
    return null;
  }
  bits.ue();
  bits.read(1);
  final columns = bits.ue() + 1, rows = bits.ue() + 1;
  final frame = bits.read(1);
  if (frame == 0) bits.read(1);
  bits.read(1);
  var left = 0, right = 0, top = 0, bottom = 0;
  if (bits.read(1) != 0) {
    left = bits.ue();
    right = bits.ue();
    top = bits.ue();
    bottom = bits.ue();
  }
  final array = separate != 0 ? 0 : chroma;
  final cropX = array == 0 || array == 3 ? 1 : 2;
  final cropY = (array == 1 ? 2 : 1) * (2 - frame);
  final width = columns * 16 - (left + right) * cropX;
  final height = (2 - frame) * rows * 16 - (top + bottom) * cropY;
  return _validSize(width, height)
      ? CinemaVideoMetadata(width, height, 'H.264')
      : null;
}
