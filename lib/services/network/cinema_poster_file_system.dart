import 'package:file/file.dart' show File;
import 'package:file/local.dart' show LocalFileSystem;
import 'package:flutter_cache_manager/flutter_cache_manager.dart'
    show FileSystem;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Posters survive OS temporary-directory cleanup and full application quits.
/// CacheManager still bounds and expires unused images normally.
class CinemaPosterFileSystem implements FileSystem {
  CinemaPosterFileSystem({String? root}) : _root = root;
  final String? _root;

  static Future<String> get root async => p.join(
    (await getApplicationSupportDirectory()).path,
    'cinema',
    'posters',
  );

  @override
  Future<File> createFile(String name) async {
    final directory = const LocalFileSystem().directory(_root ?? await root);
    await directory.create(recursive: true);
    return directory.childFile(p.basename(name));
  }
}
