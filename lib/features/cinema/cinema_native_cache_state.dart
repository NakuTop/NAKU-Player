import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/generated/libmpv/bindings.dart' as mpv;

/// Structured MPV properties must be read as NODE. The packaged engine does
/// not expose fw-bytes through the string subproperty API.
Map<String, num> cinemaNativeCacheState(NativePlayer player) {
  if (player.ctx == nullptr) return const {};
  final name = 'demuxer-cache-state'.toNativeUtf8();
  final node = calloc<mpv.mpv_node>();
  final values = <String, num>{};
  var allocated = false;
  try {
    final result = player.mpv.mpv_get_property(
      player.ctx,
      name.cast(),
      mpv.mpv_format.MPV_FORMAT_NODE,
      node.cast(),
    );
    if (result < 0) return const {};
    allocated = true;
    if (node.ref.format != mpv.mpv_format.MPV_FORMAT_NODE_MAP ||
        node.ref.u.list == nullptr) {
      return const {};
    }
    final list = node.ref.u.list.ref;
    if (list.num < 0 ||
        list.num > 128 ||
        list.values == nullptr ||
        list.keys == nullptr) {
      return const {};
    }
    for (var i = 0; i < list.num; i++) {
      final key = list.keys[i].cast<Utf8>().toDartString();
      if (!const {
        'fw-bytes',
        'cache-duration',
        'cache-end',
        'raw-input-rate',
        'eof-cached',
      }.contains(key)) {
        continue;
      }
      final value = list.values[i];
      switch (value.format) {
        case mpv.mpv_format.MPV_FORMAT_INT64:
          values[key] = value.u.int64;
        case mpv.mpv_format.MPV_FORMAT_DOUBLE:
          if (value.u.double_.isFinite) values[key] = value.u.double_;
        case mpv.mpv_format.MPV_FORMAT_FLAG:
          values[key] = value.u.flag;
      }
    }
    return values;
  } finally {
    if (allocated) player.mpv.mpv_free_node_contents(node);
    calloc.free(node);
    calloc.free(name);
  }
}
