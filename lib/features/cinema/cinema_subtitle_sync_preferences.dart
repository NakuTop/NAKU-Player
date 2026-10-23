import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:media_kit/media_kit.dart';
import 'cinema_external_subtitles.dart';
import 'cinema_store.dart';
import 'cinema_subtitle_timing.dart';

final _timingWrites = Expando<Future<void>>();

Future<void> flushCinemaSubtitleTiming(CinemaStore store) =>
    _timingWrites[store] ?? Future<void>.value();

/// Store only hashed media/content keys and timing numbers, never the private
/// media reference, subtitle dialogue or a signed playback URL.
void bindCinemaSubtitleTiming(
  Player player,
  CinemaStore store,
  String mediaIdentity, {
  CinemaSubtitleTiming? Function(String content)? fallbackTiming,
  Future<void> Function(String content, CinemaSubtitleTiming timing)?
  onTimingSaved,
}) {
  final session = cinemaExternalSubtitleState(player);
  final mediaKey = sha256.convert(utf8.encode(mediaIdentity)).toString();
  const field = 'subtitleTimingV1';
  String key(String content) => '$mediaKey:$content';
  session.readSavedTiming = (content) {
    final records = store.extras[field];
    final value = records is Map ? records[key(content)] : null;
    if (value is! Map) return fallbackTiming?.call(content);
    final scale = value['scale'], offset = value['offset'];
    if (scale is! num ||
        offset is! num ||
        !scale.isFinite ||
        !offset.isFinite ||
        scale < .5 ||
        scale > 2 ||
        offset.abs() > 21600) {
      return fallbackTiming?.call(content);
    }
    return CinemaSubtitleTiming(
      scale: scale.toDouble(),
      offsetSeconds: offset.toDouble(),
    );
  };
  session.saveTiming = (content, timing) {
    // Capture ownership now: changing episode may dispose the old controller
    // while its disk write is queued, but this calibration must still persist.
    final relatedSave = Future<void>.sync(
      () => onTimingSaved?.call(content, timing),
    );
    final previous = _timingWrites[store] ?? Future<void>.value();
    late Future<void> pending;
    pending = previous
        .catchError((Object _) {})
        .then((_) async {
          final old = store.extras[field];
          final records = <String, dynamic>{
            if (old is Map)
              for (final item in old.entries)
                if (item.key is String) item.key as String: item.value,
          };
          records.remove(key(content));
          records[key(content)] = {
            'scale': timing.scale,
            'offset': timing.offsetSeconds,
          };
          while (records.length > 64) {
            records.remove(records.keys.first);
          }
          await store.setExtra(field, records);
        })
        .whenComplete(() {
          if (identical(_timingWrites[store], pending)) {
            _timingWrites[store] = null;
          }
        });
    _timingWrites[store] = pending;
    return Future.wait<void>([pending, relatedSave]).then((_) {});
  };
}
