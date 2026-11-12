import 'dart:typed_data';

/// Metadata inspection uses the encryption and byte range belonging to the
/// sampled segment, not a later key rotation elsewhere in the playlist.
class CinemaHlsProbeEncryption {
  const CinemaHlsProbeEncryption(this.key, this.iv);
  final Uri? key;
  final Uint8List? iv;
}

class CinemaHlsProbeResource {
  const CinemaHlsProbeResource(
    this.uri,
    this.encryption, {
    this.start = 0,
    this.length,
  });
  final Uri uri;
  final CinemaHlsProbeEncryption? encryption;
  final int start;
  final int? length;
  int sampleLength(int limit) =>
      length == null || length! > limit ? limit : length!;
  String range(int limit) => 'bytes=$start-${start + sampleLength(limit) - 1}';
}

({CinemaHlsProbeResource media, CinemaHlsProbeResource? initialization})
cinemaHlsProbeSample(String manifest, Uri base) {
  final sequence =
      BigInt.tryParse(
        RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(manifest)?[1] ?? '0',
      ) ??
      BigInt.zero;
  Map<String, String>? key;
  CinemaHlsProbeResource? initialization;
  String? range;
  Uri resolve(String path) {
    final uri = base.resolve(path);
    if (!['http', 'https'].contains(uri.scheme)) {
      throw const FormatException('不支持的媒体地址');
    }
    return uri;
  }

  CinemaHlsProbeEncryption? encryption({bool map = false}) {
    if (key == null || key['METHOD'] == 'NONE') return null;
    final values = key;
    if (values['METHOD'] != 'AES-128' ||
        (values['KEYFORMAT'] ?? 'identity') != 'identity' ||
        values['URI'] == null ||
        map && values['IV'] == null) {
      return const CinemaHlsProbeEncryption(null, null);
    }
    final raw = values['IV'];
    final number = raw == null
        ? sequence
        : RegExp(r'^0[xX][0-9a-fA-F]{1,32}$').hasMatch(raw)
        ? BigInt.parse(raw.substring(2), radix: 16)
        : null;
    if (number == null || number.isNegative || number.bitLength > 128) {
      return const CinemaHlsProbeEncryption(null, null);
    }
    final iv = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      iv[15 - i] = ((number >> (i * 8)) & BigInt.from(255)).toInt();
    }
    return CinemaHlsProbeEncryption(resolve(values['URI']!), iv);
  }

  CinemaHlsProbeResource resource(
    String path,
    String? range, {
    bool map = false,
  }) {
    final parts = range?.split('@');
    final length = parts == null ? null : int.tryParse(parts.first);
    final start = parts == null
        ? 0
        : parts.length == 2
        ? int.tryParse(parts[1])
        : map
        ? 0
        : null;
    if (start == null ||
        start < 0 ||
        parts != null && (length == null || length <= 0)) {
      throw const FormatException('媒体分段范围无效');
    }
    return CinemaHlsProbeResource(
      resolve(path),
      encryption(map: map),
      start: start,
      length: length,
    );
  }

  for (final raw in manifest.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('#EXT-X-KEY:')) {
      final next = _attributes(line);
      // Ignore alternative key formats when an identity key is also supplied.
      if ((next['KEYFORMAT'] ?? 'identity') == 'identity' || key == null) {
        key = next;
      }
    } else if (line.startsWith('#EXT-X-MAP:')) {
      final map = _attributes(line);
      if (map['URI'] != null) {
        initialization = resource(map['URI']!, map['BYTERANGE'], map: true);
      }
    } else if (line.startsWith('#EXT-X-BYTERANGE:')) {
      range = line.substring('#EXT-X-BYTERANGE:'.length);
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      return (media: resource(line, range), initialization: initialization);
    }
  }
  throw const FormatException('媒体清单没有片段');
}

Map<String, String> _attributes(String line) => {
  for (final match in RegExp(
    r'([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))',
  ).allMatches(line))
    match[1]!: match[2] ?? match[3]!,
};
