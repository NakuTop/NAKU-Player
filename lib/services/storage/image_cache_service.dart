import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:kazumi/services/network/cinema_poster_file_system.dart';
import 'package:kazumi/services/network/proxy_aware_image_cache_manager.dart';

class ImageCacheService {
  Stream<File> _files() async* {
    final temporary = await getTemporaryDirectory();
    for (final path in [
      p.join(temporary.path, DefaultCacheManager.key),
      await CinemaPosterFileSystem.root,
    ]) {
      final directory = Directory(path);
      if (!await directory.exists()) continue;
      yield* directory
          .list(recursive: true, followLinks: false)
          .where((entry) => entry is File)
          .cast<File>();
    }
  }

  Future<int> sizeInBytes() async {
    var bytes = 0;
    await for (final file in _files()) {
      // Files may expire during enumeration.
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.file) bytes += stat.size;
    }
    return bytes;
  }

  Future<void> clear() async {
    // Include orphaned files, but leave images cached after this snapshot.
    final files = await _files().toList();
    await DefaultCacheManager().emptyCache();
    await ProxyAwareImageCacheManager.cinemaInstance.emptyCache();
    for (final file in files) {
      try {
        await file.delete();
      } on PathNotFoundException {
        // Already removed by the cache manager.
      }
    }
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  }
}
