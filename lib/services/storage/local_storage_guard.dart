import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:hive_ce/hive.dart';
import 'package:path/path.dart' as p;

class LocalStorageException implements Exception {
  const LocalStorageException(this.directory, {required this.busy});
  final String directory;
  final bool busy;
  @override
  String toString() => busy
      ? '本地数据库正在被其他进程使用，请退出其他版本后重新打开。数据已保留。'
      : '无法读取本地数据库，原始数据已保留。请使用备份恢复，或联系开发者排查。';
}

/// Never unlink a lock or database in response to an open failure. In
/// particular, a failed file lock says nothing about the validity of the data.
class LocalStorageGuard {
  LocalStorageGuard(this.directory);
  final String directory;
  RandomAccessFile? _lease;

  Future<void> acquire() async {
    if (_lease != null) return;
    RandomAccessFile? lease;
    try {
      await Directory(directory).create(recursive: true);
      lease = await File(
        p.join(directory, '.naku-session.lock'),
      ).open(mode: FileMode.append);
      await lease.lock(FileLock.exclusive);
      _lease = lease;
    } on FileSystemException catch (error) {
      await lease?.close();
      throw LocalStorageException(directory, busy: _isLockError(error));
    }
  }

  Future<Box<T>> openBox<T>(String name) async {
    try {
      // Hive's optional crash recovery may truncate unreadable frames. Keep
      // the original intact on corruption or an unsupported future schema.
      final box = await Hive.openBox<T>(name, crashRecovery: false);
      await snapshot(box);
      return box;
    } catch (error) {
      if (error is LocalStorageException) rethrow;
      throw LocalStorageException(directory, busy: _isLockError(error));
    }
  }

  static bool _isLockError(Object error) =>
      error is FileSystemException &&
      (error.message.toLowerCase().contains('lock') ||
          {11, 32, 35}.contains(error.osError?.errorCode));

  /// Snapshot only successfully opened, flushed files, while their Hive lock
  /// is held. Keep five distinct nonempty generations per box, outside hive/.
  Future<void> snapshot(Box box) async {
    final path = box.path;
    if (path == null) return;
    await box.flush();
    final source = File(path);
    if (!await source.exists() || await source.length() == 0) return;
    final digest = (await sha256.bind(source.openRead()).first).toString();
    final root = Directory(
      p.join(p.dirname(directory), 'storage-backups', box.name),
    );
    await root.create(recursive: true);
    final existing = await root
        .list()
        .where((e) => e is File && e.path.endsWith('.hive'))
        .cast<File>()
        .toList();
    if (existing.any((f) => f.path.endsWith('-$digest.hive'))) return;
    final destination = p.join(
      root.path,
      '${DateTime.now().microsecondsSinceEpoch}-$digest.hive',
    );
    final pending = File('$destination.pending');
    await source.copy(pending.path);
    final output = await pending.open(mode: FileMode.append);
    try {
      await output.flush();
    } finally {
      await output.close();
    }
    await pending.rename(destination);
    existing.add(File(destination));
    existing.sort((a, b) => a.path.compareTo(b.path));
    for (final old in existing.take((existing.length - 5).clamp(0, 100000))) {
      await old.delete();
    }
  }

  Future<void> release() async {
    final lease = _lease;
    _lease = null;
    if (lease != null) {
      await lease.unlock();
      await lease.close();
    }
  }
}
