import 'dart:io' as io;
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/services.dart';

/// All extraction is in memory. Archive filenames are never filesystem paths.
abstract final class CinemaSubtitleArchive {
  static const maxBytes = 8 * 1024 * 1024;
  static const maxEntries = 1000;
  static const _channel = MethodChannel('naku/subtitle_archive');
  static bool safeName(String name) =>
      name.isNotEmpty &&
      name.length <= 1024 &&
      !name.startsWith('/') &&
      !name.startsWith('\\') &&
      !name.contains('..') &&
      !name.contains(':') &&
      !name.contains('\u0000') &&
      RegExp(r'\.(srt|ass|ssa|vtt)$', caseSensitive: false).hasMatch(name);
  static bool isZip(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      (bytes[2] == 3 && bytes[3] == 4 ||
          bytes[2] == 5 && bytes[3] == 6 ||
          bytes[2] == 7 && bytes[3] == 8);
  static bool isRar(List<int> bytes) =>
      bytes.length >= 7 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x61 &&
      bytes[2] == 0x72 &&
      bytes[3] == 0x21 &&
      bytes[4] == 0x1a &&
      bytes[5] == 0x07;
  static void _validate(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('字幕压缩包过大或无效');
    }
  }

  static Future<String> decodeChinese(List<int> bytes) async {
    _validate(bytes);
    try {
      final value = await _channel
          .invokeMethod<String>('decodeChinese', {
            'bytes': Uint8List.fromList(bytes),
          })
          .timeout(const Duration(seconds: 10));
      if (value == null || value.isEmpty || value.length > maxBytes) {
        throw const FormatException('字幕编码无法读取');
      }
      return value;
    } on PlatformException {
      throw const FormatException('字幕编码不是 UTF-8 / UTF-16 / GB18030');
    }
  }

  static List<ZipFileHeader> _zip(List<int> bytes) {
    _validate(bytes);
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    var endRecord = -1;
    for (
      var at = bytes.length - 22;
      at >= math.max(0, bytes.length - 65557);
      at--
    ) {
      if (data.getUint32(at, Endian.little) == 0x06054b50 &&
          at + 22 + data.getUint16(at + 20, Endian.little) == bytes.length) {
        endRecord = at;
        break;
      }
    }
    if (endRecord < 0) throw const FormatException('ZIP 字幕包目录无效');
    final entries = data.getUint16(endRecord + 10, Endian.little);
    final start = data.getUint32(endRecord + 16, Endian.little);
    final end = start + data.getUint32(endRecord + 12, Endian.little);
    if (entries > maxEntries ||
        end > endRecord ||
        start < 0 ||
        endRecord >= 20 &&
            data.getUint32(endRecord - 20, Endian.little) == 0x07064b50) {
      throw const FormatException('字幕包文件数量过多或 ZIP64 暂不支持');
    }
    var count = 0, position = start;
    while (position < end) {
      if (++count > maxEntries ||
          position + 46 > end ||
          data.getUint32(position, Endian.little) != 0x02014b50) {
        throw const FormatException('ZIP 字幕包目录无效');
      }
      position +=
          46 +
          data.getUint16(position + 28, Endian.little) +
          data.getUint16(position + 30, Endian.little) +
          data.getUint16(position + 32, Endian.little);
      if (position > end) throw const FormatException('ZIP 字幕包目录无效');
    }
    if (count != entries) throw const FormatException('ZIP 字幕包文件数量不一致');
    try {
      // Directory parsing is lazy: unlike ZipDecoder it never decompresses a
      // symbolic-link target while reading an untrusted directory.
      return (ZipDirectory()..read(InputMemoryStream(bytes))).fileHeaders;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('ZIP 字幕包无法读取');
    }
  }

  static bool _eligible(ZipFileHeader header) {
    final file = header.file;
    return file != null &&
        (file.flags & 1) == 0 &&
        (header.externalFileAttributes >> 16 & 0xf000) != 0xa000 &&
        file.uncompressedSize > 0 &&
        file.uncompressedSize <= maxBytes &&
        safeName(file.filename);
  }

  static Future<List<String>> list(List<int> bytes) async {
    _validate(bytes);
    if (isZip(bytes)) {
      return [
        for (final header in _zip(bytes))
          if (_eligible(header)) header.file!.filename,
      ];
    }
    if (io.Platform.isAndroid && isRar(bytes)) {
      try {
        final rows = await _channel
            .invokeListMethod<String>('list', {
              'bytes': Uint8List.fromList(bytes),
            })
            .timeout(const Duration(seconds: 20));
        return (rows ?? const []).where(safeName).take(maxEntries).toList();
      } on PlatformException {
        throw const FormatException('RAR 字幕包无法读取，可能为加密或不支持的版本');
      }
    }
    throw const FormatException('该字幕压缩格式暂不可读取');
  }

  static Future<List<int>> extract(List<int> bytes, String entry) async {
    _validate(bytes);
    if (!safeName(entry)) throw const FormatException('字幕包路径无效');
    if (isZip(bytes)) {
      try {
        final headers = _zip(
          bytes,
        ).where((h) => h.file?.filename == entry).toList();
        if (headers.length != 1 || !_eligible(headers.single)) {
          throw const FormatException('字幕包文件无效或不唯一');
        }
        final file = headers.single.file!;
        final output = _BoundedOutput(maxBytes);
        final raw = file.getStream(decompress: false);
        if (file.compressionMethod == CompressionType.deflate) {
          // archive's default stream decoder collects every output chunk first.
          // This sink applies our limit during inflation, before accumulating.
          final decoder = io.ZLibDecoder(
            raw: true,
          ).startChunkedConversion(_BoundedSink(output));
          try {
            while (!raw.isEOS) {
              decoder.add(
                raw.readBytes(math.min(1024, raw.length)).toUint8List(),
              );
            }
            decoder.close();
          } catch (_) {
            try {
              decoder.close();
            } catch (_) {}
            rethrow;
          }
        } else if (file.compressionMethod == CompressionType.none) {
          output.writeStream(raw);
        } else {
          throw const FormatException('该 ZIP 字幕压缩算法暂不支持');
        }
        final result = output.getBytes();
        if (result.length != file.uncompressedSize ||
            getCrc32(result) != headers.single.crc32) {
          throw const FormatException('字幕包校验失败');
        }
        return result;
      } on FormatException {
        rethrow;
      } catch (_) {
        throw const FormatException('ZIP 字幕解压失败');
      }
    }
    if (io.Platform.isAndroid && isRar(bytes)) {
      try {
        final result = await _channel
            .invokeMethod<Uint8List>('extract', {
              'bytes': Uint8List.fromList(bytes),
              'entry': entry,
            })
            .timeout(const Duration(seconds: 25));
        if (result == null || result.isEmpty || result.length > maxBytes) {
          throw const FormatException('RAR 字幕解压失败');
        }
        return result;
      } on PlatformException {
        throw const FormatException('RAR 字幕解压失败，请换一个字幕版本');
      }
    }
    throw const FormatException('该字幕压缩格式暂不可读取');
  }
}

class _BoundedOutput extends OutputStream {
  _BoundedOutput(this.limit) : super(byteOrder: ByteOrder.littleEndian);
  final int limit;
  final _bytes = BytesBuilder(copy: false);
  @override
  int get length => _bytes.length;
  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw const FormatException('字幕解压后过大');
    }
  }

  @override
  void clear() => _bytes.clear();
  @override
  void flush() {}
  @override
  void writeByte(int value) {
    _check(1);
    _bytes.addByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    _check(count);
    _bytes.add(count == bytes.length ? bytes : bytes.sublist(0, count));
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(stream.readBytes(math.min(8192, stream.length)).toUint8List());
    }
  }

  @override
  Uint8List subset(int start, [int? end]) =>
      Uint8List.sublistView(_bytes.toBytes(), start, end);
  @override
  Uint8List getBytes() => _bytes.toBytes();
}

class _BoundedSink implements Sink<List<int>> {
  _BoundedSink(this.output);
  final _BoundedOutput output;
  @override
  void add(List<int> data) => output.writeBytes(data);
  @override
  void close() {}
}
