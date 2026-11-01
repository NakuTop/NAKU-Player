// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;

/// Only plain Dart values cross the worker boundary; no player, Dio or UI state.
typedef OverseasComment = ({
  double time,
  String message,
  int color,
  int type,
  String source,
});

typedef OverseasCommentBatch = ({
  List<Map> rows,
  bool renren,
  double leadInSeconds,
});

Future<dynamic> decodeOverseasResponse(Uint8List raw) async {
  const limit = 8 * 1024 * 1024;
  if (raw.length > limit) throw const FormatException('平台弹幕数据过大');
  if (raw.length > 2 && raw[0] == 31 && raw[1] == 139) {
    final decoded = BytesBuilder(copy: false);
    await for (final part in gzip.decoder.bind(Stream.value(raw))) {
      if (decoded.length + part.length > limit) {
        throw const FormatException('平台弹幕数据过大');
      }
      decoded.add(part);
    }
    raw = decoded.takeBytes();
  }
  var result = jsonDecode(utf8.decode(raw));
  if (result is String) result = jsonDecode(result);
  return result;
}

List<OverseasComment> parseOverseasComments(OverseasCommentBatch batch) {
  final entries = <OverseasComment>[];
  final seen = <String>{};
  for (final row in batch.rows.take(100000)) {
    final p = batch.renren ? '${row['p'] ?? ''}'.split(',') : null;
    if (p != null && p.length < 4) continue;
    final seconds = double.tryParse('${p == null ? row['second'] : p[0]}');
    if (seconds == null || !seconds.isFinite) continue;
    final time = seconds - (batch.renren ? batch.leadInSeconds : 0);
    if (time < 0 || time >= 86400) continue;
    final value = batch.renren
        ? row['d'] ?? row['content']
        : row['contxt'] ?? row['content'];
    final message =
        (html.parseFragment(value is String ? value : '').text ?? '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    if (message.isEmpty || message.length > 120) continue;
    final color = batch.renren
        ? int.tryParse(p![3]) ?? 0xffffff
        : row['color'] ?? 0xffffff;
    final hex = '$color'.replaceFirst('#', '').replaceFirst('0x', '');
    final rgb = color is int ? color : int.tryParse(hex, radix: 16) ?? 0xffffff;
    final mode = batch.renren
        ? int.tryParse(p![1])
        : row['position'] == 1
        ? 5
        : 1;
    final type = [1, 4, 5].contains(mode) ? mode! : 1;
    if (!seen.add('${time.toStringAsFixed(2)}:$type:$message')) continue;
    entries.add((
      time: time,
      message: message,
      color: 0xff000000 | (rgb & 0xffffff),
      type: type,
      source: batch.renren ? '[renren]' : '[aiyifan]',
    ));
    if (entries.length == 80000) break;
  }
  entries.sort((a, b) => a.time.compareTo(b.time));
  return entries;
}
