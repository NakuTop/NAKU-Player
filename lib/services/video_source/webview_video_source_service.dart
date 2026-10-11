import 'dart:async';

import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/video_source/video_source_service.dart';

/// WebView 视频源解析服务
///
/// 使用 WebView 解析视频页面，提取视频源 URL。
/// WebView 实例在服务生命周期内复用，切换集数时调用 unloadPage 释放页面资源，
/// 仅在 [dispose] 时才真正销毁 WebView。
class WebViewVideoSourceService implements IVideoSourceService {
  WebViewVideoSourceService({VideoWebviewController Function()? createWebview})
    : _createWebview =
          createWebview ?? VideoWebviewControllerFactory.getController;

  final VideoWebviewController Function() _createWebview;
  VideoWebviewController? _webview;
  bool? _legacyParser;
  StreamSubscription? _logSubscription;

  // 单个服务实例持有一个 WebView，因此解析任务按实例串行执行。
  // 下载并行通过多个服务实例实现。
  Future<void>? _resolveTail = Future<void>.value();
  _ResolveRequest? _activeRequest;

  final StreamController<String> _logController =
      StreamController<String>.broadcast();
  Stream<String> get onLog => _logController.stream;

  @override
  Future<VideoSource> resolve(
    String episodeUrl, {
    required bool useLegacyParser,
    int offset = 0,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final resolveTail = _resolveTail;
    if (resolveTail == null) {
      throw const VideoSourceCancelledException();
    }

    _activeRequest?.cancel();
    final request = _ResolveRequest();
    _activeRequest = request;

    final resolveFuture = resolveTail.then(
      (_) => _runResolve(
        request,
        episodeUrl,
        useLegacyParser: useLegacyParser,
        offset: offset,
        timeout: timeout,
      ),
    );

    _resolveTail = resolveFuture.then<void>((_) {}, onError: (_) {});
    return resolveFuture;
  }

  Future<VideoSource> _runResolve(
    _ResolveRequest request,
    String episodeUrl, {
    required bool useLegacyParser,
    required int offset,
    required Duration timeout,
  }) async {
    request.throwIfNotCurrent(_activeRequest);

    if (_webview != null && _legacyParser != useLegacyParser) {
      final previous = _webview!;
      _webview = null;
      await _logSubscription?.cancel();
      _logSubscription = null;
      unawaited(
        previous
            .dispose()
            .timeout(const Duration(seconds: 2))
            .catchError((Object _) {}),
      );
    }
    final needsInit = _webview == null;
    _legacyParser = useLegacyParser;
    final webview = _webview ??= _createWebview();
    if (needsInit) {
      _logSubscription = webview.onLog.listen((log) {
        if (!_logController.isClosed) {
          _logController.add(log);
        }
      });
    }

    // Subscribe before init/load: a cached page may report a URL before
    // loadUrl's platform-channel future completes.
    final parsed = Completer<VideoParserEvent>();
    parsed.future.ignore(); // A native stream error can arrive during init.
    final parserSubscription = webview.onVideoURLParser.listen(
      (event) {
        if (!parsed.isCompleted) parsed.complete(event);
      },
      onError: (Object error, StackTrace stack) {
        if (!parsed.isCompleted) parsed.completeError(error, stack);
      },
    );
    var reusable = false;
    try {
      final operation = () async {
        if (needsInit) await webview.init();
        request.throwIfNotCurrent(_activeRequest);
        await webview.loadUrl(episodeUrl, useLegacyParser, offset: offset);
        request.throwIfNotCurrent(_activeRequest);
        return parsed.future;
      }();
      final cancelFuture = request.cancelled.then<VideoParserEvent>((_) {
        throw const VideoSourceCancelledException();
      });
      // The deadline covers initialization and navigation, not just parsing.
      final event = await Future.any([operation, cancelFuture]).timeout(
        timeout,
        onTimeout: () {
          request.throwIfNotCurrent(_activeRequest);
          throw VideoSourceTimeoutException(timeout);
        },
      );
      request.throwIfNotCurrent(_activeRequest);
      reusable = true;
      return VideoSource(
        url: event.url,
        offset: event.offset,
        type: VideoSourceType.online,
        format: event.format,
      );
    } catch (e) {
      if (e is VideoSourceCancelledException) {
        rethrow;
      }
      request.throwIfNotCurrent(_activeRequest);
      rethrow;
    } finally {
      request.cancel();
      await parserSubscription.cancel();
      if (reusable) {
        try {
          await webview.unloadPage().timeout(const Duration(seconds: 2));
        } catch (_) {
          reusable = false;
        }
      }
      if (!reusable) {
        // Retire a timed-out controller. Its late callbacks must never resolve
        // a subsequent episode, and a stuck native dispose must not block it.
        if (identical(_webview, webview)) _webview = null;
        await _logSubscription?.cancel();
        _logSubscription = null;
        unawaited(
          webview
              .dispose()
              .timeout(const Duration(seconds: 2))
              .catchError((Object _) {}),
        );
      }
      if (identical(_activeRequest, request)) {
        _activeRequest = null;
      }
    }
  }

  @override
  void cancel() {
    _activeRequest?.cancel();
  }

  @override
  Future<void> dispose() async {
    final resolveTail = _resolveTail;
    _resolveTail = null;
    cancel();
    await resolveTail;
    _activeRequest = null;
    await _logSubscription?.cancel();
    _logSubscription = null;
    if (!_logController.isClosed) {
      await _logController.close();
    }
    await _webview?.dispose();
    _webview = null;
  }
}

class _ResolveRequest {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) {
      _cancelled.complete();
    }
  }

  void throwIfNotCurrent(_ResolveRequest? current) {
    if (_cancelled.isCompleted || !identical(current, this)) {
      throw const VideoSourceCancelledException();
    }
  }
}
