import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:html/parser.dart' as html;
import 'package:kazumi/modules/danmaku/danmaku_module.dart';
import 'cinema_logvar_client.dart';

/// Fallback for platforms that restrict the anonymous segmented API. Retain
/// compressed bytes only; decode as a stream in an isolate and keep this window.
class CinemaBilibiliXmlTimeline implements CinemaDanmakuTimeline {
  CinemaBilibiliXmlTimeline(this._bytes, this.encoding, this.endSeconds);
  Uint8List _bytes;
  final String encoding;
  @override
  final double endSeconds;
  bool _closed = false;
  Future<void> _tail = Future<void>.value();
  @override
  Future<CinemaDanmakuWindow> window(
    double position, {
    CancelToken? cancelToken,
  }) {
    void check() {
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      if (_closed) throw StateError('弹幕已关闭');
    }

    final near = position.clamp(0.0, endSeconds).toDouble();
    final work = _tail.catchError((Object _) {}).then((_) async {
      check();
      final rows = await compute(
        decodeCinemaBilibiliXmlWindow,
        <String, dynamic>{
          'bytes': _bytes,
          'encoding': encoding,
          'position': near,
        },
      );
      check();
      final entries = [
        for (final row in rows)
          DanmakuEntry(
            message: row['text'] as String,
            time: row['time'] as double,
            type: row['type'] as int,
            color: Color(0xff000000 | (row['color'] as int)),
            source: '[Bilibili]',
          ),
      ]..sort((a, b) => a.time.compareTo(b.time));
      return CinemaDanmakuWindow(
        entries,
        max(0.0, near - 30),
        min(endSeconds, near + 150),
      );
    });
    _tail = work.then<void>((_) {}, onError: (Object _) {});
    return work;
  }

  @override
  void close() {
    _closed = true;
    _bytes = Uint8List(0);
  }
}

Future<List<Map<String, dynamic>>> decodeCinemaBilibiliXmlWindow(
  Map<String, dynamic> input,
) async {
  final bytes = input['bytes'] as Uint8List;
  final at = input['position'] as double;
  final encoding = input['encoding'] as String;
  Stream<List<int>> stream = Stream<List<int>>.value(bytes);
  if (bytes.isNotEmpty && bytes.first != 60) {
    if (bytes.length >= 2 && bytes[0] == 31 && bytes[1] == 139) {
      stream = gzip.decoder.bind(stream);
    } else if (encoding == 'deflate') {
      // Bilibili serves raw DEFLATE with this header, rather than a zlib wrapper.
      stream = ZLibDecoder(
        raw:
            !(bytes.length >= 2 &&
                bytes[0] == 0x78 &&
                ((bytes[0] << 8) + bytes[1]) % 31 == 0),
      ).bind(stream);
    }
  }
  var decoded = 0;
  stream = stream.map((chunk) {
    decoded += chunk.length;
    if (decoded > 32 * 1024 * 1024) {
      throw const FormatException('Bilibili 弹幕解压数据过大');
    }
    return chunk;
  });
  final rows = <Map<String, dynamic>>[], seen = <String>{};
  final density = <int, int>{};
  var carry = '';
  final element = RegExp(
    r'''<d\s[^>]*\bp=["']([^"']+)["'][^>]*>([\s\S]*?)</d>''',
  );
  await for (final chunk in stream.transform(utf8.decoder)) {
    carry += chunk;
    var end = carry.indexOf('</d>');
    while (end >= 0) {
      final block = carry.substring(0, end + 4);
      carry = carry.substring(end + 4);
      final match = element.firstMatch(block);
      if (match != null && rows.length < 6000) {
        final p = match[1]!.split(',');
        final time = p.isNotEmpty ? double.tryParse(p[0]) : null;
        if (time != null &&
            time.isFinite &&
            time >= max(0, at - 30) &&
            time <= at + 180 &&
            p.length >= 4) {
          final type = int.tryParse(p[1]), color = int.tryParse(p[3]);
          if ([1, 4, 5].contains(type) &&
              color != null &&
              color >= 0 &&
              color <= 0xffffff &&
              (density[time.floor()] ?? 0) < 16) {
            final text = html.parseFragment(match[2]!).text?.trim() ?? '';
            if (text.isNotEmpty &&
                text.length <= 120 &&
                seen.add('$time:$text')) {
              rows.add({
                'text': text,
                'time': time,
                'type': type!,
                'color': color,
              });
              density.update(time.floor(), (n) => n + 1, ifAbsent: () => 1);
            }
          }
        }
      }
      end = carry.indexOf('</d>');
    }
    if (carry.length > 32768) carry = carry.substring(carry.length - 4096);
  }
  return rows;
}
