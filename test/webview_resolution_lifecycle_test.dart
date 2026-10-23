import 'package:kazumi/services/video_source/video_source_format.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/video_source/services.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';

class _Webview extends VideoWebviewController {
  Completer<void>? initializing, navigating;
  int loads = 0;
  bool disposed = false;
  @override
  Future<void> init() async {
    await initializing?.future;
  }

  void emit(String url) =>
      notifyVideoSourceResolved(url, format: VideoSourceFormat.hls);
  @override
  Future<void> loadUrl(String url, bool legacy, {int offset = 0}) async {
    loads++;
    this.offset = offset;
    emit('$url/stream');
    // A real platform-channel load can finish after its parser callback.
    await Future<void>.delayed(Duration.zero);
    await navigating?.future;
  }

  @override
  Future<void> unloadPage() async {}
  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  test(
    'cached page result emitted during load is retained, including HLS hint',
    () async {
      final controllers = <_Webview>[];
      final service = WebViewVideoSourceService(
        createWebview: () {
          final view = _Webview();
          controllers.add(view);
          return view;
        },
      );
      final result = await service.resolve(
        'https://fixture.invalid/1',
        useLegacyParser: false,
        offset: 42,
        timeout: const Duration(milliseconds: 100),
      );
      expect(result.url, endsWith('/1/stream'));
      expect(result.offset, 42);
      expect(result.format, VideoSourceFormat.hls);
      final second = await service.resolve(
        'https://fixture.invalid/2',
        useLegacyParser: false,
      );
      expect(second.url, endsWith('/2/stream'));
      expect(controllers.length, 2);
      expect(controllers.every((v) => v.loads == 1 && v.disposed), isTrue);
      await service.dispose();
      for (final view in controllers) {
        view.disposeEventControllers();
      }
    },
  );

  test(
    'late callback after a successful episode cannot resolve the next one',
    () async {
      final old = _Webview();
      final next = _Webview()..initializing = Completer<void>();
      var created = 0;
      final service = WebViewVideoSourceService(
        createWebview: () => created++ == 0 ? old : next,
      );
      await service.resolve(
        'https://fixture.invalid/1',
        useLegacyParser: false,
      );
      final resolving = service.resolve(
        'https://fixture.invalid/2',
        useLegacyParser: false,
      );
      await Future<void>.delayed(Duration.zero);
      old.emit('https://fixture.invalid/1/stream');
      next.initializing!.complete();
      expect((await resolving).url, endsWith('/2/stream'));
      await service.dispose();
      old.disposeEventControllers();
      next.disposeEventControllers();
    },
  );

  test('a different provider parser mode gets a fresh controller', () async {
    final controllers = <_Webview>[];
    final service = WebViewVideoSourceService(
      createWebview: () {
        final webview = _Webview();
        controllers.add(webview);
        return webview;
      },
    );
    await service.resolve(
      'https://fixture.invalid/modern',
      useLegacyParser: false,
    );
    await service.resolve(
      'https://fixture.invalid/legacy',
      useLegacyParser: true,
    );
    expect(controllers.length, 2);
    expect(controllers.first.disposed, isTrue);
    await service.dispose();
    for (final webview in controllers) {
      webview.disposeEventControllers();
    }
  });

  for (final duringInit in [true, false]) {
    test(
      'deadline includes ${duringInit ? 'initialization' : 'navigation'} and next resolve recovers',
      () async {
        final stalled = Completer<void>();
        final old = _Webview();
        if (duringInit) {
          old.initializing = stalled;
        } else {
          old.navigating = stalled;
        }
        final next = _Webview();
        var created = 0;
        final service = WebViewVideoSourceService(
          createWebview: () => created++ == 0 ? old : next,
        );
        await expectLater(
          service.resolve(
            'https://fixture.invalid/old',
            useLegacyParser: false,
            timeout: const Duration(milliseconds: 30),
          ),
          throwsA(isA<VideoSourceTimeoutException>()),
        );
        expect(old.disposed, isTrue);
        final result = service.resolve(
          'https://fixture.invalid/new',
          useLegacyParser: false,
        );
        old.emit('https://fixture.invalid/stale');
        stalled.complete();
        expect((await result).url, endsWith('/new/stream'));
        if (duringInit) expect(old.loads, 0);
        await service.dispose();
        old.disposeEventControllers();
        next.disposeEventControllers();
      },
    );
  }

  test('cancel interrupts a stuck init and dispose remains bounded', () async {
    final webview = _Webview()..initializing = Completer<void>();
    final service = WebViewVideoSourceService(createWebview: () => webview);
    final result = service.resolve(
      'https://fixture.invalid/1',
      useLegacyParser: false,
    );
    final assertion = expectLater(
      result,
      throwsA(isA<VideoSourceCancelledException>()),
    );
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    await assertion;
    await service.dispose().timeout(const Duration(milliseconds: 100));
    webview.initializing!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(webview.loads, 0);
    webview.disposeEventControllers();
  });
}
