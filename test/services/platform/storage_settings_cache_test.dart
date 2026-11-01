import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/bean/settings/settings_detail_scaffold.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/pages/settings/storage_settings.dart';
import 'package:kazumi/services/storage/image_cache_service.dart';

class _Images extends ImageCacheService {
  var clears = 0;
  @override
  Future<int> sizeInBytes() async => clears > 0 ? 0 : 2 * 1024 * 1024;
  @override
  Future<void> clear() async => clears++;
}

class _Video extends CinemaMediaCache {
  var clears = 0;
  @override
  Future<({int totalBytes, int protectedBytes, int clearableBytes})>
  usage() async => (
    totalBytes: (clears > 0 ? 3 : 10) * 1024 * 1024,
    protectedBytes: 3 * 1024 * 1024,
    clearableBytes: (clears > 0 ? 0 : 7) * 1024 * 1024,
  );
  @override
  Future<void> clear() async => clears++;
}

void main() {
  Future<void> mount(WidgetTester tester, _Images images, _Video video) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsPaneScope(
          embedded: true,
          showBackButton: false,
          onBack: () {},
          child: StorageSettingsPage(
            imageCache: images,
            videoCache: video,
            showVideoCache: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows category totals and protected playback bytes', (
    tester,
  ) async {
    final images = _Images(), video = _Video();
    await mount(tester, images, video);
    expect(find.text('缓存 · 共 12.00 MB'), findsOneWidget);
    expect(find.text('2.00 MB'), findsOneWidget);
    expect(find.text('10.00 MB · 可清理 7.00 MB\n当前播放保留 3.00 MB'), findsOneWidget);
    await tester.tap(find.text('视频分片缓存'));
    await tester.pumpAndSettle();
    expect(find.textContaining('下载文件、观看记录和设置不会删除'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(video.clears, 0);
  });

  testWidgets('video clear only calls video cache and refreshes usage', (
    tester,
  ) async {
    final images = _Images(), video = _Video();
    await mount(tester, images, video);
    await tester.tap(find.text('视频分片缓存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除缓存'));
    await tester.pumpAndSettle();
    expect(video.clears, 1);
    expect(images.clears, 0);
    expect(find.text('缓存 · 共 5.00 MB'), findsOneWidget);
    expect(find.text('3.00 MB · 可清理 0.00 MB\n当前播放保留 3.00 MB'), findsOneWidget);
  });
}
