import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';

import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/bean/settings/settings_list.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/services/storage/image_cache_service.dart';

typedef _VideoUsage = ({
  int totalBytes,
  int protectedBytes,
  int clearableBytes,
});
typedef _CacheUsage = ({int imageBytes, _VideoUsage? video});

class StorageSettingsPage extends StatefulWidget {
  const StorageSettingsPage({
    super.key,
    this.imageCache,
    this.videoCache,
    this.showVideoCache,
  });

  final ImageCacheService? imageCache;
  final CinemaMediaCache? videoCache;
  final bool? showVideoCache;

  @override
  State<StorageSettingsPage> createState() => _StorageSettingsPageState();
}

class _StorageSettingsPageState extends State<StorageSettingsPage> {
  late final _images = widget.imageCache ?? ImageCacheService();
  late final _video = widget.videoCache ?? CinemaMediaCache.instance;
  late final _showVideo = widget.showVideoCache ?? Platform.isMacOS;
  late Future<_CacheUsage> _cacheSize = _readUsage();
  String? _clearing;

  Future<_CacheUsage> _readUsage() async {
    final results = await Future.wait<Object?>([
      _images.sizeInBytes(),
      if (_showVideo) _video.usage(),
    ]);
    return (
      imageBytes: results[0] as int,
      video: _showVideo ? results[1] as _VideoUsage : null,
    );
  }

  void _refreshSize() => setState(() => _cacheSize = _readUsage());

  void _message(String message) {
    KazumiDialog.showToast(context: context, message: message);
  }

  Future<void> _confirmClear({required bool video}) async {
    if (_clearing != null) return;
    final label = video ? '视频分片' : '图片';
    final confirmed = await KazumiDialog.show<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_rounded),
        title: Text('清除$label缓存？'),
        content: Text(
          video
              ? '清除可重新下载的视频分片，保留当前播放需要的缓存。下载文件、观看记录和设置不会删除。'
              : '图片会在下次加载时重新下载。视频、观看记录和设置不会删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清除缓存'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _clearing = label);
    try {
      if (video) {
        await _video.clear();
      } else {
        await _images.clear();
      }
      if (!mounted) return;
      _message(video ? '可清理的视频分片已清除，当前播放缓存已保留' : '图片缓存已清除');
      _refreshSize();
    } catch (_) {
      if (mounted) _message('清除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _clearing = null);
    }
  }

  String _bytes(int value) => value >= 1024 * 1024 * 1024
      ? '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : '${(value / (1024 * 1024)).toStringAsFixed(2)} MB';

  String _description(
    AsyncSnapshot<_CacheUsage> snapshot, {
    required bool video,
  }) {
    if (_clearing == (video ? '视频分片' : '图片')) return '正在清除…';
    if (snapshot.connectionState != ConnectionState.done) return '正在统计…';
    if (snapshot.hasError) return '统计失败，点击重试';
    final data = snapshot.requireData;
    if (!video) return _bytes(data.imageBytes);
    final usage = data.video!;
    return '${_bytes(usage.totalBytes)} · 可清理 ${_bytes(usage.clearableBytes)}'
        '${usage.protectedBytes > 0 ? '\n当前播放保留 ${_bytes(usage.protectedBytes)}' : ''}';
  }

  @override
  Widget build(BuildContext context) => SettingsDetailScaffold(
    title: const Text('存储与日志'),
    body: FutureBuilder<_CacheUsage>(
      future: _cacheSize,
      builder: (context, snapshot) {
        final ready = snapshot.connectionState == ConnectionState.done;
        final failed = ready && snapshot.hasError;
        return SettingsList(
          sections: [
            SettingsSection(
              title: Text(
                snapshot.hasData
                    ? '缓存 · 共 ${_bytes(snapshot.requireData.imageBytes + (snapshot.requireData.video?.totalBytes ?? 0))}'
                    : '缓存',
              ),
              tiles: [
                SettingsTile(
                  leading: Icons.image_outlined,
                  title: const Text('图片缓存'),
                  description: Text(_description(snapshot, video: false)),
                  enabled: ready && _clearing == null,
                  onPressed: (_) =>
                      failed ? _refreshSize() : _confirmClear(video: false),
                  trailing: Icon(
                    failed
                        ? Icons.refresh_rounded
                        : Icons.cleaning_services_rounded,
                  ),
                ),
                if (_showVideo)
                  SettingsTile(
                    leading: Icons.movie_outlined,
                    title: const Text('视频分片缓存'),
                    description: Text(_description(snapshot, video: true)),
                    enabled: ready && _clearing == null,
                    onPressed: (_) =>
                        failed ? _refreshSize() : _confirmClear(video: true),
                    trailing: Icon(
                      failed
                          ? Icons.refresh_rounded
                          : Icons.cleaning_services_rounded,
                    ),
                  ),
              ],
            ),
            SettingsSection(
              title: const Text('诊断'),
              tiles: [
                SettingsTile(
                  leading: Icons.receipt_long_rounded,
                  title: const Text('错误日志'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onPressed: (_) => context.pushNamed('/settings/storage/logs'),
                ),
              ],
            ),
          ],
        );
      },
    ),
  );
}
