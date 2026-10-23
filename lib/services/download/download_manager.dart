import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:dio/dio.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/request/clients/download_http_client.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/utils/m3u8_parser.dart';
import 'package:kazumi/utils/m3u8_ad_filter.dart';
import 'package:kazumi/utils/format.dart' as fmt;
import 'package:kazumi/utils/file_system.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/platform/secure_bookmark_service.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path/path.dart' as path;
import 'package:kazumi/services/download/download_integrity.dart';
import 'package:kazumi/services/download/download_catalog.dart';

class _NotM3u8Exception implements Exception {
  final String message;
  _NotM3u8Exception(this.message);
  @override
  String toString() => message;
}

class _InsufficientStorageException implements Exception {
  final int availableBytes;
  final int requiredBytes;
  _InsufficientStorageException(this.availableBytes, this.requiredBytes);
  @override
  String toString() => '存储空间不足';
}

class DownloadTask {
  final String recordKey;
  final int episodeNumber;
  CancelToken cancelToken;
  bool isPaused;
  final finished = Completer<void>();

  DownloadTask({
    required this.recordKey,
    required this.episodeNumber,
    CancelToken? cancelToken,
    this.isPaused = false,
  }) : cancelToken = cancelToken ?? CancelToken();
}

typedef ProgressCallback =
    void Function(
      String recordKey,
      int episodeNumber,
      DownloadEpisode episode,
      double speed,
    );

final _m3u8SegmentFileNamePattern = RegExp(r'^seg_\d+\.ts$');

Future<int> calculateM3u8VideoBytes(String episodeDir) async {
  final dir = Directory(episodeDir);
  if (!await dir.exists()) return 0;

  var totalBytes = 0;
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.uri.pathSegments.isNotEmpty
        ? Uri.decodeComponent(entity.uri.pathSegments.last)
        : entity.path.split(Platform.pathSeparator).last;
    if (!_m3u8SegmentFileNamePattern.hasMatch(name)) continue;

    try {
      totalBytes += await entity.length();
    } on FileSystemException {
      // Ignore transient filesystem failures while reporting display size.
    }
  }
  return totalBytes;
}

class DownloadRequest {
  final String recordKey;
  final int bangumiId;
  final String pluginName;
  final int episodeNumber;
  final String m3u8Url;
  final Map<String, String> httpHeaders;
  final bool adBlockerEnabled;
  final DownloadEpisode episode;

  const DownloadRequest({
    required this.recordKey,
    required this.bangumiId,
    required this.pluginName,
    required this.episodeNumber,
    required this.m3u8Url,
    required this.httpHeaders,
    required this.adBlockerEnabled,
    required this.episode,
  });
}

abstract class IDownloadManager {
  ProgressCallback? onProgress;

  bool isDownloading(String recordKey, int episodeNumber);
  Future<void> enqueue(DownloadRequest request);
  Future<void> enqueuePriority(DownloadRequest request);
  void pause(String recordKey, int episodeNumber);
  Future<void> resume(DownloadRequest request);
  void cancel(String recordKey, int episodeNumber);
  String? getLocalVideoPath(DownloadEpisode? episode);
  Future<void> deleteEpisodeFiles(
    int bangumiId,
    String pluginName,
    int episodeNumber, {
    DownloadEpisode? episode,
  });
  Future<void> deleteRecordFiles(
    int bangumiId,
    String pluginName, {
    DownloadRecord? record,
  });
  double getSpeed(String recordKey, int episodeNumber);
}

class _SpeedTracker {
  int _lastBytes = 0;
  DateTime _lastTime = DateTime.now();
  double currentSpeed = 0.0; // bytes/sec

  void update(int totalBytes) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastTime).inMilliseconds;
    if (elapsed > 500) {
      final bytesDownloaded = totalBytes - _lastBytes;
      currentSpeed = bytesDownloaded / (elapsed / 1000);
      _lastBytes = totalBytes;
      _lastTime = now;
    }
  }

  void reset() {
    _lastBytes = 0;
    _lastTime = DateTime.now();
    currentSpeed = 0.0;
  }
}

class DownloadManager implements IDownloadManager {
  final Map<String, int> _resolvedOwners = {};

  bool _reserveSource(DownloadRequest request) {
    final identity = '${request.recordKey}\u0000${request.m3u8Url}';
    int? owner = _resolvedOwners[identity];
    final record = GStorage.downloads.get(request.recordKey);
    for (final other in record?.episodes.values ?? <DownloadEpisode>[]) {
      if (other.episodeNumber != request.episodeNumber &&
          other.networkM3u8Url == request.m3u8Url &&
          {
            DownloadStatus.completed,
            DownloadStatus.downloading,
            DownloadStatus.pending,
          }.contains(other.status)) {
        owner = other.episodeNumber;
        break;
      }
    }
    if (owner != null && owner != request.episodeNumber) {
      request.episode.status = DownloadStatus.failed;
      request.episode.errorMessage = DuplicateDownloadException(
        '$owner',
      ).toString();
      request.episode.networkM3u8Url = '';
      _notifyProgress(
        request.recordKey,
        request.episodeNumber,
        request.episode,
      );
      return false;
    }
    _resolvedOwners[identity] = request.episodeNumber;
    return true;
  }

  DownloadManager() {
    _loadSettings();
  }

  final DownloadHttpClient _http = DownloadHttpClient.instance;

  final Map<String, DownloadTask> _activeTasks = {};
  final List<DownloadRequest> _queue = [];
  final Map<String, DownloadTask> _runningTasks = {};
  final Map<String, _SpeedTracker> _speedTrackers = {};
  int maxParallelEpisodes = 2;
  int maxParallelSegments = 3;
  int _runningCount = 0;

  @override
  ProgressCallback? onProgress;

  static const _minRequiredSpace = 100 * 1024 * 1024; // 100MB minimum
  static const _storageChannel = MethodChannel('com.predidit.kazumi/storage');

  void _loadSettings() {
    maxParallelEpisodes = GStorage.getSetting(
      SettingsKeys.downloadParallelEpisodes,
    );
    maxParallelSegments = GStorage.getSetting(
      SettingsKeys.downloadParallelSegments,
    );
  }

  /// Returns available bytes, or -1 if unable to determine
  Future<int> _getAvailableStorage(String path) async {
    try {
      final result = await _storageChannel.invokeMethod<int>(
        'getAvailableStorage',
        {'path': path},
      );
      return result ?? -1;
    } on MissingPluginException {
      return -1;
    } catch (e) {
      KazumiLogger().w('DownloadManager: failed to get storage info', error: e);
      return -1;
    }
  }

  Future<void> _checkStorageSpace(
    String downloadDir, {
    int requiredBytes = 0,
  }) async {
    final available = await _getAvailableStorage(downloadDir);
    if (available == -1) return; // Skip check if unable to determine

    final required = requiredBytes > 0 ? requiredBytes : _minRequiredSpace;
    if (available < required) {
      throw _InsufficientStorageException(available, required);
    }
  }

  String _getStorageErrorMessage(FileSystemException e) {
    // POSIX error code 28 = ENOSPC (No space left on device)
    if (e.osError?.errorCode == 28) {
      return '存储空间不足，请清理后重试';
    }
    // POSIX error code 13 = EACCES (Permission denied)
    if (e.osError?.errorCode == 13) {
      return '存储权限被拒绝';
    }
    // POSIX error code 30 = EROFS (Read-only file system)
    if (e.osError?.errorCode == 30) {
      return '存储为只读，无法写入';
    }
    return '存储错误: ${e.message}';
  }

  @override
  double getSpeed(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    return _speedTrackers[key]?.currentSpeed ?? 0.0;
  }

  String _taskKey(String recordKey, int episodeNumber) =>
      '${recordKey}_$episodeNumber';

  @override
  bool isDownloading(String recordKey, int episodeNumber) =>
      _activeTasks.containsKey(_taskKey(recordKey, episodeNumber));

  Future<String> get _downloadBaseDir async {
    if (supportsCustomDownloadDirectory) {
      final customDir = GStorage.getSetting(
        SettingsKeys.downloadDirectory,
      ).trim();
      if (customDir.isNotEmpty) {
        // On macOS this re-establishes sandbox access after a restart;
        // elsewhere it returns the path unchanged.
        final usable = await SecureBookmarkService.restore(customDir);
        if (usable != null) return usable;
        KazumiLogger().w(
          'DownloadManager: custom download directory unavailable, falling back to default',
        );
      }
    }
    return getDefaultDownloadDirectory();
  }

  String _getEpisodeDir(
    String downloadBase,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) {
    return path.join(
      downloadBase,
      '${bangumiId}_$pluginName',
      '$episodeNumber',
    );
  }

  /// Resolves the episode directory (kept from a previous attempt if any),
  /// verifies it is writable, and persists it on the episode.
  Future<String> _prepareEpisodeDir(
    DownloadEpisode episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode.downloadDirectory.trim();
    final episodeDir = storedDir.isNotEmpty
        ? storedDir
        : _getEpisodeDir(
            await _downloadBaseDir,
            bangumiId,
            pluginName,
            episodeNumber,
          );
    await ensureDirectoryWritable(episodeDir);
    episode.downloadDirectory = episodeDir;
    await _checkStorageSpace(episodeDir);
    return episodeDir;
  }

  /// Directory to remove for an episode: the recorded one, or the default
  /// location for episodes that never started downloading.
  Future<String> _episodeDirForDeletion(
    DownloadEpisode? episode,
    int bangumiId,
    String pluginName,
    int episodeNumber,
  ) async {
    final storedDir = episode?.downloadDirectory.trim() ?? '';
    if (storedDir.isNotEmpty) return storedDir;
    return _getEpisodeDir(
      await getDefaultDownloadDirectory(),
      bangumiId,
      pluginName,
      episodeNumber,
    );
  }

  @override
  Future<void> enqueue(DownloadRequest request) async {
    final key = _taskKey(request.recordKey, request.episodeNumber);
    final running = _runningTasks[key];
    if (running != null && running.cancelToken.isCancelled) {
      await running.finished.future;
    }
    final old = _activeTasks[key];
    if (old != null && !old.cancelToken.isCancelled) return;
    if (!_reserveSource(request)) return;
    _activeTasks.remove(key);
    _queue.removeWhere(
      (r) =>
          r.recordKey == request.recordKey &&
          r.episodeNumber == request.episodeNumber,
    );

    final task = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );

    if (_runningCount < maxParallelEpisodes) {
      _runningCount++;
      _activeTasks[key] = task;
      _runEpisodeDownload(
        task: task,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    } else {
      request.episode.status = DownloadStatus.pending;
      _queue.add(request);
      _activeTasks[key] = task;
    }
  }

  @override
  Future<void> enqueuePriority(DownloadRequest request) async {
    final key = _taskKey(request.recordKey, request.episodeNumber);
    if (_runningTasks.containsKey(key)) return;
    if (!_reserveSource(request)) return;
    _queue.removeWhere(
      (r) =>
          r.recordKey == request.recordKey &&
          r.episodeNumber == request.episodeNumber,
    );
    _activeTasks[key] = DownloadTask(
      recordKey: request.recordKey,
      episodeNumber: request.episodeNumber,
    );
    request.episode.status = DownloadStatus.pending;
    _queue.insert(0, request);
    _processQueue();
  }

  @override
  void pause(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      task.isPaused = true;
      task.cancelToken.cancel('paused');
    }
  }

  @override
  Future<void> resume(DownloadRequest request) => enqueue(request);

  @override
  void cancel(String recordKey, int episodeNumber) {
    final key = _taskKey(recordKey, episodeNumber);
    final task = _activeTasks[key];
    if (task != null) {
      task.cancelToken.cancel('cancelled');
      _activeTasks.remove(key);
      _queue.removeWhere(
        (r) => r.recordKey == recordKey && r.episodeNumber == episodeNumber,
      );
    }
  }

  void _processQueue() {
    while (_runningCount < maxParallelEpisodes && _queue.isNotEmpty) {
      final request = _queue.removeAt(0);
      final key = _taskKey(request.recordKey, request.episodeNumber);
      final existingTask = _activeTasks[key];
      if (existingTask == null ||
          existingTask.isPaused ||
          existingTask.cancelToken.isCancelled) {
        _activeTasks.remove(key);
        continue;
      }

      _runningCount++;
      _runEpisodeDownload(
        task: existingTask,
        bangumiId: request.bangumiId,
        pluginName: request.pluginName,
        m3u8Url: request.m3u8Url,
        httpHeaders: request.httpHeaders,
        adBlockerEnabled: request.adBlockerEnabled,
        episode: request.episode,
      );
    }
  }

  Future<void> _runEpisodeDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String m3u8Url,
    required Map<String, String> httpHeaders,
    required bool adBlockerEnabled,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    _runningTasks[key] = task;
    try {
      final episodeDir = await _prepareEpisodeDir(
        episode,
        bangumiId,
        pluginName,
        task.episodeNumber,
      );

      episode.status = DownloadStatus.downloading;
      episode.networkM3u8Url = isNASMediaReference(episode.episodePageUrl)
          ? episode.episodePageUrl
          : m3u8Url;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      if (isNASMediaReference(episode.episodePageUrl)) {
        await _runDirectFileDownload(
          task: task,
          bangumiId: bangumiId,
          pluginName: pluginName,
          videoUrl: m3u8Url,
          httpHeaders: httpHeaders,
          episode: episode,
        );
        return;
      }
      String m3u8Content;
      try {
        m3u8Content = await _fetchM3u8(m3u8Url, httpHeaders, task.cancelToken);
      } on _NotM3u8Exception {
        KazumiLogger().i(
          'DownloadManager: URL is not M3U8, falling back to direct file download '
          'for episode ${task.episodeNumber}',
        );
        await _runDirectFileDownload(
          task: task,
          bangumiId: bangumiId,
          pluginName: pluginName,
          videoUrl: m3u8Url,
          httpHeaders: httpHeaders,
          episode: episode,
        );
        return;
      }

      String mediaM3u8Content = m3u8Content;
      String mediaM3u8Url = m3u8Url;
      String? audioUrl;

      for (
        var depth = 0;
        M3u8Parser.detectType(mediaM3u8Content) == M3u8Type.master;
        depth++
      ) {
        if (depth >= 3) throw const FormatException('视频播放列表嵌套过深');
        final master = M3u8Parser.parseMasterPlaylist(
          mediaM3u8Content,
          mediaM3u8Url,
        );
        final bestVariant = master.bestVariant;
        final audio = master.audio
            .where((a) => a.group == bestVariant.audioGroup)
            .toList();
        if (audio.isNotEmpty) {
          audioUrl =
              (audio.where((a) => a.isDefault).firstOrNull ?? audio.first).uri;
        }
        mediaM3u8Url = bestVariant.uri;
        mediaM3u8Content = await _fetchM3u8(
          mediaM3u8Url,
          httpHeaders,
          task.cancelToken,
        );
      }

      final playlist = M3u8Parser.parseMediaPlaylist(
        mediaM3u8Content,
        mediaM3u8Url,
      );

      // 展开嵌套 m3u8 片段（部分源将实际内容嵌套在 m3u8 引用中）
      final resolvedSegments = await M3u8Parser.resolveNestedSegments(
        playlist.segments,
        (url) => _fetchM3u8(url, httpHeaders, task.cancelToken),
      );
      final resolvedPlaylist = M3u8MediaPlaylist(
        segments: resolvedSegments,
        targetDuration: playlist.targetDuration,
        isVod: playlist.isVod,
      );

      if (!resolvedPlaylist.isVod) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '不支持下载直播流 (无有效分片)';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      if (resolvedPlaylist.segments.isEmpty) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = 'M3U8 中未找到可下载的分片';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      List<M3u8Segment> segments = resolvedPlaylist.segments;
      final filterAds = adBlockerEnabled && audioUrl == null;
      if (filterAds) {
        segments = M3u8AdFilter.filterAds(segments);
      }
      await _prepareHlsPlan(segments, episodeDir);

      final keys = M3u8Parser.extractUniqueKeys(
        M3u8MediaPlaylist(
          segments: segments,
          targetDuration: resolvedPlaylist.targetDuration,
          isVod: true,
        ),
      );
      final keyUriToLocal = <String, String>{};
      for (int i = 0; i < keys.length; i++) {
        final keyFile = 'key_$i.key';
        final keyPath = path.join(episodeDir, keyFile);
        await _downloadFile(
          keys[i].uri,
          keyPath,
          httpHeaders,
          task.cancelToken,
        );
        keyUriToLocal[keys[i].uri] = keyFile;
      }

      final initializationToLocal = await _cacheInitializations(
        segments,
        episodeDir,
        httpHeaders,
        task.cancelToken,
      );

      episode.totalSegments = segments.length;
      episode.downloadedSegments = 0;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      final existingSegments = <int>{};
      var existingBytes = 0;
      for (int i = 0; i < segments.length; i++) {
        final segFile = File(
          path.join(episodeDir, 'seg_${i.toString().padLeft(5, '0')}.ts'),
        );
        if (await segFile.exists()) {
          final segmentBytes = await segFile.length();
          if (segmentBytes <= 0) continue;
          existingSegments.add(i);
          episode.downloadedSegments++;
          existingBytes += segmentBytes;
        }
      }
      episode.totalBytes = existingBytes;
      episode.progressPercent = episode.totalSegments > 0
          ? episode.downloadedSegments / episode.totalSegments
          : 0.0;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      final pendingIndices = <int>[];
      for (int i = 0; i < segments.length; i++) {
        if (!existingSegments.contains(i)) {
          pendingIndices.add(i);
        }
      }

      var sessionBytes = 0;
      int failedCount = 0;
      var nextIndex = 0;
      _speedTrackers[key] = _SpeedTracker();
      Future<void> worker() async {
        while (nextIndex < pendingIndices.length &&
            !task.isPaused &&
            !task.cancelToken.isCancelled) {
          final idx = pendingIndices[nextIndex++];
          try {
            final bytes = await _downloadSegmentWithRetry(
              segments[idx].uri,
              path.join(episodeDir, 'seg_${idx.toString().padLeft(5, '0')}.ts'),
              httpHeaders,
              task.cancelToken,
              byteRange: segments[idx].byteRange,
            );
            if (task.isPaused || task.cancelToken.isCancelled) return;
            sessionBytes += bytes;
            episode.downloadedSegments++;
            episode.totalBytes = existingBytes + sessionBytes;
            episode.progressPercent =
                episode.downloadedSegments / episode.totalSegments;
            _speedTrackers[key]?.update(sessionBytes);
            _notifyProgress(task.recordKey, task.episodeNumber, episode);
          } catch (_) {
            failedCount++;
          }
        }
      }

      // Await workers even after cancellation, so deletion/resume cannot race
      // a late segment rename from the old attempt.
      await Future.wait(
        List.generate(maxParallelSegments.clamp(1, 12), (_) => worker()),
      );

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      if (failedCount > 0) {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = '$failedCount 个分片下载失败';
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      final targetDuration = filterAds
          ? M3u8AdFilter.calculateTargetDuration(segments)
          : resolvedPlaylist.targetDuration;
      final localM3u8 = M3u8Parser.buildLocalM3u8(
        segments,
        targetDuration: targetDuration,
        keyUriToLocal: keyUriToLocal,
        initializationToLocal: initializationToLocal,
      );
      final m3u8Path = path.join(episodeDir, 'playlist.m3u8');
      await File(m3u8Path).writeAsString(localM3u8);
      final finalVideoBytes = await calculateM3u8VideoBytes(episodeDir);
      var localPath = m3u8Path;
      var extraBytes = 0;
      if (audioUrl != null) {
        extraBytes = await _cacheAudio(
          audioUrl,
          path.join(episodeDir, 'audio'),
          httpHeaders,
          task.cancelToken,
          onProgress: (done, total) {
            episode.totalSegments = segments.length + total;
            episode.downloadedSegments = segments.length + done;
            episode.progressPercent =
                episode.downloadedSegments / episode.totalSegments;
            _notifyProgress(task.recordKey, task.episodeNumber, episode);
          },
        );
        localPath = path.join(episodeDir, 'master.m3u8');
        await File(localPath).writeAsString(
          '#EXTM3U\n#EXT-X-VERSION:7\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="音轨",DEFAULT=YES,AUTOSELECT=YES,URI="audio/playlist.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=10000000,AUDIO="audio"\nplaylist.m3u8\n',
        );
      }
      if (task.isPaused || task.cancelToken.isCancelled) return;

      await DownloadIntegrity.verifyHls(Directory(episodeDir));
      if (task.isPaused || task.cancelToken.isCancelled) return;
      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = localPath;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes =
          (finalVideoBytes > 0
              ? finalVideoBytes
              : existingBytes + sessionBytes) +
          extraBytes;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      KazumiLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed. '
        '${segments.length} segments, ${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
    } catch (e) {
      if (e is DuplicateDownloadException) episode.networkM3u8Url = '';
      episode.status = task.isPaused
          ? DownloadStatus.paused
          : DownloadStatus.failed;
      episode.errorMessage = task.isPaused
          ? ''
          : isNASMediaReference(episode.episodePageUrl)
          ? 'NAS 下载失败，请重新连接 NAS 后重试。'
          : e.toString();
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().e(
        'DownloadManager: episode download failed',
        error: isNASMediaReference(episode.episodePageUrl) ? 'NAS 请求失败' : e,
      );
    } finally {
      _onTaskComplete(key, task);
    }
  }

  Future<void> _runDirectFileDownload({
    required DownloadTask task,
    required int bangumiId,
    required String pluginName,
    required String videoUrl,
    required Map<String, String> httpHeaders,
    required DownloadEpisode episode,
  }) async {
    final key = _taskKey(task.recordKey, task.episodeNumber);
    try {
      final episodeDir = await _prepareEpisodeDir(
        episode,
        bangumiId,
        pluginName,
        task.episodeNumber,
      );

      final originalExtension = isNASMediaReference(episode.episodePageUrl)
          ? path
                .extension(
                  parseNASMediaReference(episode.episodePageUrl)['path']!,
                )
                .toLowerCase()
          : '.mp4';
      final extension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(originalExtension)
          ? originalExtension
          : '.mp4';
      final filePath = path.join(episodeDir, 'video$extension');
      final tmpPath = '$filePath.tmp';
      final transfer = File(path.join(episodeDir, '.naku-transfer.json'));
      final identity = sha256
          .convert(
            utf8.encode(
              isNASMediaReference(episode.episodePageUrl)
                  ? episode.episodePageUrl
                  : videoUrl,
            ),
          )
          .toString();
      Map<String, dynamic> previousTransfer = {};
      try {
        previousTransfer =
            jsonDecode(await transfer.readAsString()) as Map<String, dynamic>;
      } catch (_) {
        /* Legacy partial downloads have no transfer metadata. */
      }
      if (previousTransfer['identity'] != null &&
          previousTransfer['identity'] != identity &&
          await File(tmpPath).exists()) {
        // Never append bytes from a changed source to an earlier partial file.
        await File(tmpPath).rename(
          path.join(
            episodeDir,
            '.preserved-transfer-${DateTime.now().microsecondsSinceEpoch}.tmp',
          ),
        );
        previousTransfer = {};
      }

      int existingBytes = 0;
      final tmpFile = File(tmpPath);
      if (await tmpFile.exists()) {
        existingBytes = await tmpFile.length();
      }

      episode.totalSegments = 1;
      episode.downloadedSegments = 0;
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      final requestHeaders = Map<String, String>.from(httpHeaders);
      bool useRange = existingBytes > 0;
      if (useRange) {
        requestHeaders['Range'] = 'bytes=$existingBytes-';
        final validator =
            previousTransfer['etag'] ?? previousTransfer['lastModified'];
        if (validator is String && validator.isNotEmpty) {
          requestHeaders['If-Range'] = validator;
        }
      }

      Response<ResponseBody> response;
      try {
        response = await _http.getStream(
          videoUrl,
          headers: requestHeaders,
          receiveTimeout: const Duration(minutes: 30),
          cancelToken: task.cancelToken,
        );
      } on NetworkException catch (e) {
        if (e.statusCode == 416 && useRange) {
          KazumiLogger().w(
            'DownloadManager: 416 Range Not Satisfiable, deleting tmp file and retrying',
          );
          await tmpFile.delete();
          existingBytes = 0;
          requestHeaders.remove('Range');
          response = await _http.getStream(
            videoUrl,
            headers: requestHeaders,
            receiveTimeout: const Duration(minutes: 30),
            cancelToken: task.cancelToken,
          );
        } else {
          rethrow;
        }
      }

      final contentRange = response.headers.value('content-range');
      final transferPending = File('${transfer.path}.pending');
      await transferPending.writeAsString(
        jsonEncode({
          'identity': identity,
          if (response.headers.value('etag') case final String value)
            'etag': value,
          if (response.headers.value('last-modified') case final String value)
            'lastModified': value,
        }),
        flush: true,
      );
      await transferPending.rename(transfer.path);
      if (response.statusCode == 200 && existingBytes > 0) {
        // Some servers ignore Range. Restart instead of appending a complete
        // response to a partial file and silently corrupting the video.
        existingBytes = 0;
      }
      if (response.statusCode == 206) {
        final start = RegExp(r'^bytes (\d+)-').firstMatch(contentRange ?? '');
        if (start == null || int.parse(start.group(1)!) != existingBytes) {
          await response.data!.stream.listen(null).cancel();
          throw const FormatException('片源返回了错误的断点续传范围，请重新下载');
        }
      }
      final type = response.headers.value('content-type')?.toLowerCase() ?? '';
      if (type.contains('text/html') ||
          type.contains('application/json') ||
          type.contains('dash+xml')) {
        await response.data!.stream.listen(null).cancel();
        throw const FormatException('此地址返回网页或 DASH 清单，请选择 MP4 或 HLS 线路下载');
      }
      final contentLength =
          int.tryParse(
            response.headers.value(Headers.contentLengthHeader) ?? '',
          ) ??
          0;
      int totalSize;
      if (contentRange != null) {
        final totalMatch = RegExp(r'/(\d+)').firstMatch(contentRange);
        totalSize = totalMatch != null ? int.parse(totalMatch.group(1)!) : 0;
      } else {
        totalSize = existingBytes + contentLength;
      }

      final raf = await tmpFile.open(
        mode: existingBytes > 0 ? FileMode.append : FileMode.write,
      );
      int received = existingBytes;

      _speedTrackers[key] = _SpeedTracker();

      try {
        await for (final chunk in response.data!.stream) {
          if (task.isPaused || task.cancelToken.isCancelled) break;
          if (received == 0) {
            final prefix = ascii
                .decode(chunk.take(256).toList(), allowInvalid: true)
                .trimLeft()
                .toLowerCase();
            if (prefix.startsWith('<!doctype') ||
                prefix.startsWith('<html') ||
                prefix.startsWith('<?xml') ||
                prefix.startsWith('<mpd')) {
              throw const FormatException('片源返回的不是可保存的视频文件');
            }
          }
          await raf.writeFrom(chunk);
          received += chunk.length;
          episode.totalBytes = received;
          episode.progressPercent = totalSize > 0 ? received / totalSize : 0;
          // Update speed tracker
          _speedTrackers[key]?.update(received);
          _notifyProgress(task.recordKey, task.episodeNumber, episode);
        }
      } finally {
        await raf.close();
      }

      if (task.isPaused || task.cancelToken.isCancelled) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
        _notifyProgress(task.recordKey, task.episodeNumber, episode);
        return;
      }

      if (received == 0 || (totalSize > 0 && received != totalSize)) {
        throw const FormatException('视频传输不完整，请继续下载');
      }
      await DownloadIntegrity.commitFile(File(tmpPath), File(filePath));

      episode.status = DownloadStatus.completed;
      episode.localM3u8Path = filePath;
      episode.downloadedSegments = 1;
      episode.progressPercent = 1.0;
      episode.completedAt = DateTime.now();
      episode.totalBytes = await File(filePath).length();
      _notifyProgress(task.recordKey, task.episodeNumber, episode);

      KazumiLogger().i(
        'DownloadManager: episode ${task.episodeNumber} completed (direct download). '
        '${(episode.totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } on _InsufficientStorageException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage =
          '存储空间不足 (可用: ${fmt.formatBytes(e.availableBytes)})';
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().w('DownloadManager: insufficient storage space', error: e);
    } on FileSystemException catch (e) {
      episode.status = DownloadStatus.failed;
      episode.errorMessage = _getStorageErrorMessage(e);
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().e('DownloadManager: file system error', error: e);
    } on NetworkException catch (e) {
      if (e.type == NetworkExceptionType.cancel) {
        if (task.isPaused) {
          episode.status = DownloadStatus.paused;
        }
      } else {
        episode.status = DownloadStatus.failed;
        episode.errorMessage = e.message;
      }
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
    } catch (e) {
      if (e is DuplicateDownloadException) episode.networkM3u8Url = '';
      episode.status = task.isPaused
          ? DownloadStatus.paused
          : DownloadStatus.failed;
      episode.errorMessage = task.isPaused
          ? ''
          : isNASMediaReference(episode.episodePageUrl)
          ? 'NAS 下载失败，请重新连接 NAS 后重试。'
          : e.toString();
      _notifyProgress(task.recordKey, task.episodeNumber, episode);
      KazumiLogger().e(
        'DownloadManager: direct file download failed',
        error: isNASMediaReference(episode.episodePageUrl) ? 'NAS 请求失败' : e,
      );
    }
  }

  void _onTaskComplete(String key, DownloadTask task) {
    if (identical(_activeTasks[key], task)) _activeTasks.remove(key);
    if (identical(_runningTasks[key], task)) _runningTasks.remove(key);
    _speedTrackers.remove(key);
    _runningCount--;
    if (!task.finished.isCompleted) task.finished.complete();
    _processQueue();
  }

  void _notifyProgress(
    String recordKey,
    int episodeNumber,
    DownloadEpisode episode,
  ) {
    final key = _taskKey(recordKey, episodeNumber);
    final speed = _speedTrackers[key]?.currentSpeed ?? 0.0;
    onProgress?.call(recordKey, episodeNumber, episode, speed);
  }

  Future<String> _fetchM3u8(
    String url,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    final fetchToken = CancelToken();
    unawaited(
      cancelToken.whenCancel.then((_) => fetchToken.cancel('task cancelled')),
    );

    if (cancelToken.isCancelled) {
      throw NetworkException(
        type: NetworkExceptionType.cancel,
        message: '请求已被取消，请重新请求',
      );
    }

    try {
      final content = await _http.getPlain(
        url,
        headers: headers,
        receiveTimeout: const Duration(seconds: 15),
        cancelToken: fetchToken,
        onReceiveProgress: (received, total) {
          if (cancelToken.isCancelled) {
            fetchToken.cancel('task cancelled');
            return;
          }
          if (received > 2 * 1024 * 1024) {
            fetchToken.cancel('too large');
          }
        },
      );

      final trimmed = content.trimLeft();
      if (!trimmed.startsWith('#EXTM3U')) {
        throw _NotM3u8Exception('URL 不是 M3U8 播放列表');
      }

      return content;
    } on NetworkException catch (e) {
      if (cancelToken.isCancelled) rethrow;
      if (e.type == NetworkExceptionType.cancel) {
        throw _NotM3u8Exception('响应过大，非 M3U8 播放列表');
      }
      rethrow;
    }
  }

  Future<void> _prepareHlsPlan(
    List<M3u8Segment> segments,
    String directory,
  ) async {
    await Directory(directory).create(recursive: true);
    final file = File(path.join(directory, 'download-plan.json'));
    final plan = jsonEncode(
      segments
          .map(
            (s) => [
              s.uri,
              s.byteRange?.identity,
              s.initializationIdentity,
              s.key?.uri,
              s.key?.iv,
              s.sequence,
            ],
          )
          .toList(),
    );
    if (await FileSystemEntity.isLink(file.path)) {
      throw const FileSystemException('下载计划是符号链接，已保留原文件');
    }
    if (await file.exists() && await file.readAsString() == plan) return;

    final retained = <FileSystemEntity>[];
    await for (final entry in Directory(directory).list(followLinks: false)) {
      final name = path.basename(entry.path);
      if ((entry is File &&
              (RegExp(
                    r'^(seg_\d+\.ts|init_\d+\.mp4|key_\d+\.key)(\.tmp)?$',
                  ).hasMatch(name) ||
                  {
                    'playlist.m3u8',
                    'master.m3u8',
                    'download-plan.json',
                    '.naku-content.json',
                  }.contains(name))) ||
          (entry is Directory && name == 'audio')) {
        retained.add(entry);
      }
    }
    if (retained.isNotEmpty) {
      final complete = await DownloadCatalog.findVideo(Directory(directory));
      if (complete != null && complete.path.endsWith('.m3u8')) {
        throw const FileSystemException('此集已有完整视频，已保留原文件，未更换下载线路');
      }
      // A changed playlist must never reuse old numbered segments or destroy
      // them. Keep the entire previous HLS attempt available for recovery.
      final preserved = await Directory(
        path.join(
          directory,
          '.preserved-hls-${DateTime.now().microsecondsSinceEpoch}',
        ),
      ).create();
      for (final entry in retained) {
        await entry.rename(
          path.join(preserved.path, path.basename(entry.path)),
        );
      }
    }
    final pending = File('${file.path}.pending');
    await pending.writeAsString(plan, flush: true);
    await pending.rename(file.path);
  }

  Future<Map<String, String>> _cacheInitializations(
    List<M3u8Segment> segments,
    String directory,
    Map<String, String> headers,
    CancelToken token,
  ) async {
    final files = <String, String>{};
    for (final segment in segments) {
      final id = segment.initializationIdentity;
      if (id == null || files.containsKey(id)) continue;
      if (segment.key != null && segment.key!.iv == null) {
        throw const FormatException('加密初始化分片缺少 IV，无法保存');
      }
      final name = 'init_${files.length}.mp4';
      await _downloadSegmentWithRetry(
        segment.initializationUri!,
        path.join(directory, name),
        headers,
        token,
        byteRange: segment.initializationRange,
      );
      files[id] = name;
    }
    return files;
  }

  Future<int> _cacheAudio(
    String url,
    String directory,
    Map<String, String> headers,
    CancelToken token, {
    required void Function(int, int) onProgress,
  }) async {
    var content = await _fetchM3u8(url, headers, token);
    for (
      var depth = 0;
      M3u8Parser.detectType(content) == M3u8Type.master;
      depth++
    ) {
      if (depth >= 3) throw const FormatException('音轨播放列表嵌套过深');
      url = M3u8Parser.parseMasterPlaylist(content, url).bestVariant.uri;
      content = await _fetchM3u8(url, headers, token);
    }
    final playlist = M3u8Parser.parseMediaPlaylist(content, url);
    if (!playlist.isVod || playlist.segments.isEmpty) {
      throw const FormatException('此音轨无法离线保存，请选择其他线路');
    }
    final segments = await M3u8Parser.resolveNestedSegments(
      playlist.segments,
      (uri) => _fetchM3u8(uri, headers, token),
    );
    await _prepareHlsPlan(segments, directory);
    final keys = <String, String>{};
    for (final segment in segments) {
      final key = segment.key;
      if (key == null || keys.containsKey(key.uri)) continue;
      final name = 'key_${keys.length}.key';
      await _downloadFile(key.uri, path.join(directory, name), headers, token);
      keys[key.uri] = name;
    }
    final init = await _cacheInitializations(
      segments,
      directory,
      headers,
      token,
    );
    var bytes = 0;
    onProgress(0, segments.length);
    for (var i = 0; i < segments.length; i++) {
      if (token.isCancelled) throw const FormatException('下载已暂停');
      final file = File(
        path.join(directory, 'seg_${i.toString().padLeft(5, '0')}.ts'),
      );
      if (!await file.exists() || await file.length() == 0) {
        await _downloadSegmentWithRetry(
          segments[i].uri,
          file.path,
          headers,
          token,
          byteRange: segments[i].byteRange,
        );
      }
      bytes += await file.length();
      onProgress(i + 1, segments.length);
    }
    await File(path.join(directory, 'playlist.m3u8')).writeAsString(
      M3u8Parser.buildLocalM3u8(
        segments,
        targetDuration: playlist.targetDuration,
        keyUriToLocal: keys,
        initializationToLocal: init,
      ),
    );
    return bytes;
  }

  Future<void> _downloadFile(
    String url,
    String savePath,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    await _downloadSegmentWithRetry(url, savePath, headers, cancelToken);
    if (await File(savePath).length() != 16) {
      throw const FormatException('AES-128 密钥长度不正确');
    }
  }

  Future<int> _downloadSegmentWithRetry(
    String url,
    String savePath,
    Map<String, String> headers,
    CancelToken cancelToken, {
    int maxRetries = 3,
    M3u8ByteRange? byteRange,
  }) async {
    final tmpPath = '$savePath.tmp';
    int retryCount = 0;
    while (true) {
      try {
        if (byteRange == null) {
          await _http.download(
            url,
            tmpPath,
            headers: headers,
            cancelToken: cancelToken,
          );
        } else {
          final response = await _http.getStream(
            url,
            headers: {...headers, 'Range': byteRange.header},
            cancelToken: cancelToken,
          );
          final range = response.headers.value('content-range') ?? '';
          if (response.statusCode != 206 ||
              !range.startsWith(
                'bytes ${byteRange.offset}-${byteRange.offset + byteRange.length - 1}/',
              )) {
            await response.data!.stream.listen(null).cancel();
            throw const FormatException('片源不支持视频分段下载');
          }
          final sink = File(tmpPath).openWrite();
          var bytes = 0;
          try {
            await for (final chunk in response.data!.stream) {
              bytes += chunk.length;
              if (bytes > byteRange.length) {
                throw const FormatException('视频分段大小不匹配');
              }
              sink.add(chunk);
            }
          } finally {
            await sink.close();
          }
          if (bytes != byteRange.length) {
            throw const FormatException('视频分段下载不完整');
          }
        }
        if (await File(tmpPath).length() == 0) {
          throw const FormatException('片源返回空分片');
        }
        await File(tmpPath).rename(savePath);
        return await File(savePath).length();
      } catch (e) {
        try {
          final tmpFile = File(tmpPath);
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
        if (cancelToken.isCancelled) rethrow;
        retryCount++;
        if (retryCount >= maxRetries) rethrow;
        final delay = Duration(seconds: [1, 3, 9][retryCount - 1]);
        await Future.delayed(delay);
      }
    }
  }

  @override
  Future<void> deleteEpisodeFiles(
    int bangumiId,
    String pluginName,
    int episodeNumber, {
    DownloadEpisode? episode,
  }) async {
    final recordKey = '${pluginName}_$bangumiId';
    final running = _runningTasks[_taskKey(recordKey, episodeNumber)];
    cancel(recordKey, episodeNumber);
    if (running != null) await running.finished.future;
    final dir = Directory(
      await _episodeDirForDeletion(
        episode,
        bangumiId,
        pluginName,
        episodeNumber,
      ),
    );
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _resolvedOwners.removeWhere(
      (source, owner) =>
          source.startsWith('$recordKey\u0000') && owner == episodeNumber,
    );
  }

  @override
  Future<void> deleteRecordFiles(
    int bangumiId,
    String pluginName, {
    DownloadRecord? record,
  }) async {
    final recordKey = '${pluginName}_$bangumiId';
    final tasks = _activeTasks.values
        .where((t) => t.recordKey == recordKey)
        .toList();
    final running = _runningTasks.values
        .where((t) => t.recordKey == recordKey)
        .toList();
    for (final task in tasks) {
      cancel(recordKey, task.episodeNumber);
    }
    await Future.wait(running.map((t) => t.finished.future));
    if (record == null) {
      final dir = Directory(
        path.join(
          await getDefaultDownloadDirectory(),
          '${bangumiId}_$pluginName',
        ),
      );
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _resolvedOwners.removeWhere(
        (source, _) => source.startsWith('$recordKey\u0000'),
      );
      return;
    }

    // Episodes may live under different base directories, so delete each
    // episode directory individually.
    final parentDirs = <String>{};
    for (final entry in record.episodes.entries) {
      final episodeDir = await _episodeDirForDeletion(
        entry.value,
        bangumiId,
        pluginName,
        entry.key,
      );
      final dir = Directory(episodeDir);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
      parentDirs.add(path.dirname(episodeDir));
    }

    for (final parentDir in parentDirs) {
      try {
        await Directory(parentDir).delete();
      } on FileSystemException {
        // Parent is missing or still holds other files; leave it.
      }
    }
    _resolvedOwners.removeWhere(
      (source, _) => source.startsWith('$recordKey\u0000'),
    );
  }

  @override
  String? getLocalVideoPath(DownloadEpisode? episode) {
    if (episode == null) return null;
    if (episode.status != DownloadStatus.completed) return null;
    if (episode.localM3u8Path.isEmpty) return null;
    final file = File(episode.localM3u8Path);
    if (!file.existsSync()) return null;
    return episode.localM3u8Path;
  }
}
