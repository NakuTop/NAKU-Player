import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/platform/desktop_fullscreen.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'package:window_manager/window_manager.dart';

import 'cinema_home_display_bridge.dart';
import 'cinema_nas_media.dart';
import 'cinema_neon_decode.dart';
import 'cinema_player_entrance.dart';
import 'cinema_theme.dart';

const cinemaHomeDisplayUrl = 'https://between-us-home.pages.dev/display';

bool cinemaHomeDisplayNeedsNAS(Map<String, dynamic> access) =>
    access['reason'] == 'nas_login_required' ||
    access['reason'] == 'nas_session_expired' ||
    (access['reason'] == 'nas_authentication_failed' &&
        access['nasSessionCheck'] == 'authentication_rejected');

/// Fixed public messages only; native diagnostics never expose NAS credentials.
String cinemaHomeDisplayAuthorizationMessage(Map<String, dynamic> access) {
  if (access['reason'] == 'nas_login_required') return '请先登录 NAS';
  if (cinemaHomeDisplayNeedsNAS(access)) return '请重新登录 NAS 后打开 Home Display';
  return switch (access['reason']) {
    'backend_unconfigured' => '网站尚未配置 NAS 展示授权',
    'nas_authentication_failed' when access['nasSessionVerified'] == true =>
      'NAS 登录正常，但网站未接受展示授权（401），请重试',
    'nas_authentication_failed' => 'NAS 与网站的授权验证未通过（401），请重试',
    'backend_access_rejected' => '网站拒绝了展示授权（403），请稍后重试',
    'backend_rate_limited' => '授权请求过于频繁，请稍后重试',
    'backend_timeout' => '网站授权连接超时，请检查网络后重试',
    'backend_network_error' => '无法连接网站授权服务，请检查网络后重试',
    'backend_http_error' => '网站授权服务暂时异常，请稍后重试',
    'authorization_cookie_install_failed' => '未能保存展示授权，请重试',
    'authorization_response_invalid' => '网站授权响应未通过校验，请重试',
    'nas_proof_unavailable' => '未能验证当前 NAS 登录，请重新打开 NAS 后重试',
    _ => 'Home Display 授权暂不可用，请稍后重试',
  };
}

/// Only the first-party display and its login may replace the main document.
/// Website requests retain their own CSP, cookies and native WebKit TLS checks.
bool cinemaAllowsHomeDisplayNavigation(String? value, {bool mainFrame = true}) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null) return false;
  if (!mainFrame && (value == 'about:blank' || value == 'about:srcdoc')) {
    return true;
  }
  return uri.scheme == 'https' &&
      uri.host == 'between-us-home.pages.dev' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      (uri.path == '/display' || uri.path == '/login');
}

/// A live WKWebView, with temporary native snapshots for the same Flutter
/// decoding effect used by film details. Filters cannot pixelate AppKit views.
/// Snapshots exist only during navigation, are bounded, and never touch disk.
class CinemaHomeDisplayPage extends StatefulWidget {
  const CinemaHomeDisplayPage({
    super.key,
    this.client,
    this.onOpenNAS,
    this.windowControls,
  });

  final CinemaNASClient? client;
  final Future<void> Function()? onOpenNAS;
  final DesktopWindowControls? windowControls;

  @override
  State<CinemaHomeDisplayPage> createState() => _CinemaHomeDisplayPageState();
}

class _CinemaHomeDisplayPageState extends State<CinemaHomeDisplayPage>
    with WidgetsBindingObserver, WindowListener {
  late final _client = widget.client ?? CinemaNASClient();
  late final _windowControls =
      widget.windowControls ?? DesktopWindowControls.instance;
  PlatformInAppWebViewWidget? _webView;
  PlatformInAppWebViewController? _controller;
  ui.Image? _preview;
  ui.Image? _exitPreview;
  final _exitSurface = GlobalKey<CinemaPlayerEntranceState>();
  bool _closing = false, _allowDisplayPop = false;
  Timer? _timeout, _captureTimer, _settleTimer, _renewTimer;
  bool _loading = true, _overlay = true, _hidden = false;
  bool _occluded = false, _minimized = false;
  bool _backgrounded = false;
  Completer<void>? _exitInterrupted;
  String? _exitFrameWait;
  bool get _suspended => _hidden || _occluded;

  @visibleForTesting
  String? get debugExitFrameWait => _exitFrameWait;
  Future<void>? _captureWork;
  bool _authorizing = false, _needsNAS = false;
  int _generation = 0, _document = 0, _captures = 0, _progress = 0;
  int _previewStage = 0;
  int? _finishingDocument;
  String? _error;
  String _url = cinemaHomeDisplayUrl;

  bool _active(int generation) =>
      mounted && !_closing && generation == _generation;

  @override
  void initState() {
    super.initState();
    _backgrounded = _isBackground(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    _windowControls.register(this, _nativeVisibilityChanged);
    unawaited(_initializeVisibility());
  }

  Future<void> _initializeVisibility() async {
    await _windowControls.initialize();
    if (!mounted) return;
    // A route opened while already hidden must not depend on pause-on-hide
    // playback preferences to receive its initial native visibility state.
    _hidden = _windowControls.hidden || _minimized;
    await _open();
  }

  Future<void> _nativeVisibilityChanged(bool hidden) =>
      _visibility(hidden || _minimized);

  Future<void> _open() async {
    if (_authorizing || _closing) return;
    final generation = ++_generation;
    _cancelLoadingTimers();
    _renewTimer?.cancel();
    final previous = _webView;
    _webView = null;
    _controller = null;
    previous?.dispose();
    _releasePreview();
    setState(() {
      _authorizing = true;
      _loading = true;
      _overlay = true;
      _preview = null;
      _error = null;
      _needsNAS = false;
      _progress = 0;
    });
    try {
      final access = await _client
          .call('homeDisplayAuthorize')
          .timeout(const Duration(seconds: 35));
      if (!_active(generation)) return;
      if (access['authenticated'] != true) {
        _needsNAS = cinemaHomeDisplayNeedsNAS(access);
        throw StateError(cinemaHomeDisplayAuthorizationMessage(access));
      }
      // A hidden page must not create a native document or start its polling.
      // Resume revalidates before constructing a fresh document below.
      if (_suspended) return;
      _scheduleRenewal(access, generation);
      _createWebView(generation);
    } on TimeoutException {
      if (_active(generation)) _showError('NAS 验证超时，请检查连接后重试');
    } catch (error) {
      if (_active(generation)) {
        _showError(
          error is StateError
              ? error.message.toString()
              : 'Home Display 暂未连接，请检查 NAS 与网站服务',
        );
      }
    } finally {
      if (_active(generation)) setState(() => _authorizing = false);
    }
  }

  void _scheduleRenewal(Map<String, dynamic> access, int generation) {
    _renewTimer?.cancel();
    // Revalidate with the NAS before the short, read-only web session expires.
    _renewTimer = Timer(const Duration(minutes: 4), () async {
      if (!_active(generation) || _hidden) return;
      try {
        final access = await _client
            .call('homeDisplayAuthorize')
            .timeout(const Duration(seconds: 35));
        if (!_active(generation)) return;
        if (access['authenticated'] != true) {
          _needsNAS = cinemaHomeDisplayNeedsNAS(access);
          _showError(cinemaHomeDisplayAuthorizationMessage(access));
          return;
        }
        _scheduleRenewal(access, generation);
      } catch (_) {
        if (_active(generation)) _showError('NAS 会话暂时无法验证，点击重试可恢复');
      }
    });
  }

  void _createWebView(int generation) {
    if (InAppWebViewPlatform.instance == null) {
      _showError('当前平台暂未提供原生网页组件');
      return;
    }
    _beginDocument(cinemaHomeDisplayUrl);
    _webView = PlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams(
        initialUrlRequest: URLRequest(url: WebUri(cinemaHomeDisplayUrl)),
        initialUserScripts: UnmodifiableListView([
          UserScript(
            source: cinemaHomeDisplayBridgeSource,
            injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
            forMainFrameOnly: true,
          ),
        ]),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          cacheEnabled: true,
          transparentBackground: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: false,
          useShouldOverrideUrlLoading: true,
          allowsBackForwardNavigationGestures: false,
          mediaPlaybackRequiresUserGesture: true,
          isInspectable: false,
        ),
        onWebViewCreated: (controller) {
          if (!_active(generation)) return;
          _controller = controller;
          controller.addJavaScriptHandler(
            handlerName: cinemaHomeDisplayBridgeHandlerName,
            callback: (args) {
              if (!_active(generation) ||
                  _suspended ||
                  args.length != 1 ||
                  args.single is! Map) {
                return false;
              }
              final state = Map<String, dynamic>.from(args.single as Map);
              final href = state['href'];
              if (href is! String ||
                  !cinemaAllowsHomeDisplayNavigation(href) ||
                  Uri.tryParse(href)?.path != Uri.tryParse(_url)?.path) {
                return false;
              }
              if (state['apiStatus'] == 401 || state['apiStatus'] == 403) {
                _showError('展示权限已失效，请重新验证 NAS');
                return false;
              }
              if (state['phase'] == 'ready') {
                if (state['surface'] == 'login') {
                  _showError('网站尚未接受 NAS 授权，请重试');
                  return false;
                }
                if (state['surface'] != 'display' ||
                    state['firstDrawObserved'] != true ||
                    state['apiObserved'] != true ||
                    state['apiStatus'] is! int ||
                    (state['apiStatus'] as int) < 200 ||
                    (state['apiStatus'] as int) >= 300) {
                  return false;
                }
                unawaited(_finishDocument(generation, _document));
              } else if (state['firstDrawObserved'] == true) {
                _requestPreview(generation, _document, stage: 2);
              }
              return true;
            },
          );
        },
        shouldOverrideUrlLoading: (_, action) async {
          if (!_active(generation)) return NavigationActionPolicy.CANCEL;
          return cinemaAllowsHomeDisplayNavigation(
                action.request.url?.toString(),
                mainFrame: action.isForMainFrame,
              )
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onCreateWindow: (_, _) async => false,
        onLoadStart: (_, url) {
          if (_active(generation) &&
              url != null &&
              cinemaAllowsHomeDisplayNavigation(url.toString())) {
            _beginDocument(url.toString());
          }
        },
        onProgressChanged: (_, value) {
          final next = value.clamp(0, 100);
          if (_active(generation) && _loading && next != _progress) {
            setState(() => _progress = next);
          }
        },
        onPageCommitVisible: (_, _) {
          if (!_active(generation)) return;
          _startCaptures(generation, _document);
        },
        onLoadStop: (_, _) {
          if (!_active(generation)) return;
          // Network completion is not a rendered WebGL frame. The JS bridge
          // waits for actual page data, fonts/images and rendering evidence.
          _startCaptures(generation, _document);
          unawaited(_replayBridge());
        },
        onUpdateVisitedHistory: (_, url, _) {
          if (!_active(generation) || url == null || url.toString() == _url) {
            return;
          }
          if (cinemaAllowsHomeDisplayNavigation(url.toString())) {
            _beginDocument(url.toString());
            unawaited(_replayBridge());
          }
        },
        onReceivedError: (_, request, error) {
          if (_active(generation) &&
              !_hidden &&
              request.isForMainFrame == true &&
              error.type != WebResourceErrorType.CANCELLED) {
            _showError('Home Display 暂时无法加载，请重试');
          }
        },
        onReceivedHttpError: (_, request, response) {
          if (_active(generation) &&
              !_hidden &&
              request.isForMainFrame == true) {
            _showError('Home Display 返回 HTTP ${response.statusCode ?? '错误'}');
          }
        },
        onWebContentProcessDidTerminate: (_) {
          if (_active(generation) && !_hidden) {
            _showError('网页进程已停止，点击重试可恢复');
          }
        },
        onPermissionRequest: (_, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
        onGeolocationPermissionsShowPrompt: (_, origin) async =>
            GeolocationPermissionShowPromptResponse(
              origin: origin,
              allow: false,
              retain: false,
            ),
      ),
    );
    setState(() {});
  }

  void _beginDocument(String url) {
    _cancelLoadingTimers();
    ++_document;
    _releasePreview();
    setState(() {
      _url = url;
      _loading = true;
      _overlay = true;
      _preview = null;
      _progress = 0;
      _captures = 0;
      _previewStage = 0;
      _finishingDocument = null;
      _error = null;
    });
    final document = _document;
    if (!_suspended) _armTimeout(document);
  }

  void _armTimeout(int document) {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 40), () {
      if (mounted && !_suspended && document == _document && _loading) {
        _showError('页面仍未准备好，请检查连接后重试');
      }
    });
  }

  void _startCaptures(int generation, int document) {
    _requestPreview(generation, document, stage: 1);
  }

  void _requestPreview(int generation, int document, {required int stage}) {
    if (!_active(generation) ||
        document != _document ||
        !_loading ||
        _suspended ||
        stage <= _previewStage) {
      return;
    }
    _previewStage = stage;
    _captureTimer?.cancel();
    // A native snapshot is a GPU readback plus PNG encode/decode. Capture only
    // meaningful page milestones; the front-end field animates independently.
    _captureTimer = Timer(const Duration(milliseconds: 150), () {
      _captureTimer = null;
      unawaited(() async {
        await _captureWork;
        if (!_active(generation) ||
            document != _document ||
            !_loading ||
            _suspended ||
            _finishingDocument == document ||
            _captures >= 2) {
          return;
        }
        await _capture(generation, document);
      }());
    });
  }

  Future<void> _capture(int generation, int document) {
    final pending = _captureWork;
    if (pending != null) return pending;
    final work = _captureOnce(generation, document);
    _captureWork = work;
    return work.whenComplete(() {
      if (identical(_captureWork, work)) _captureWork = null;
    });
  }

  Future<void> _captureOnce(int generation, int document) async {
    final controller = _controller;
    if (controller == null || _suspended) return;
    ++_captures;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final bytes = await controller
          .takeScreenshot(
            screenshotConfiguration: ScreenshotConfiguration(
              snapshotWidth: 640,
            ),
          )
          .timeout(const Duration(seconds: 3));
      if (bytes != null &&
          _active(generation) &&
          document == _document &&
          _overlay) {
        codec = await ui.instantiateImageCodec(
          bytes,
          targetWidth: 960,
          allowUpscaling: false,
        );
        image = (await codec.getNextFrame()).image;
      }
      if (_active(generation) &&
          document == _document &&
          _overlay &&
          image != null) {
        final previous = _preview;
        setState(() => _preview = image);
        image = null; // Ownership transfers to the front-end renderer.
        _retirePreview(previous);
      }
    } catch (_) {
      // A snapshot failure does not stop the native page or change readiness.
    } finally {
      codec?.dispose();
      image?.dispose();
    }
  }

  Future<void> _finishDocument(int generation, int document) async {
    if (!_loading ||
        !_active(generation) ||
        document != _document ||
        _finishingDocument == document) {
      return;
    }
    _finishingDocument = document;
    _timeout?.cancel();
    _captureTimer?.cancel();
    _captureTimer = null;
    await _captureWork;
    if (!_active(generation) || document != _document) return;
    await _capture(generation, document);
    if (!_active(generation) || document != _document) return;
    setState(() {
      _loading = false;
      _error = null;
    });
    _settleTimer?.cancel();
    _settleTimer = Timer(const Duration(milliseconds: 540), () {
      if (!_active(generation) || document != _document) return;
      _releasePreview();
      setState(() {
        _overlay = false;
      });
    });
  }

  void _showError(String message) {
    ++_document;
    _cancelLoadingTimers();
    _renewTimer?.cancel();
    _webView?.dispose();
    _webView = null;
    _controller = null;
    _releasePreview();
    setState(() {
      _loading = false;
      _overlay = false;
      _preview = null;
      _error = message;
    });
  }

  void _releasePreview() {
    final previous = _preview;
    _preview = null;
    _retirePreview(previous);
  }

  void _retirePreview(ui.Image? image) {
    if (image == null) return;
    // Let the previous painter leave the current frame before releasing its
    // GPU image. No snapshots or decoded frames enter the global image cache.
    WidgetsBinding.instance.addPostFrameCallback((_) => image.dispose());
  }

  void _cancelLoadingTimers() {
    _timeout?.cancel();
    _captureTimer?.cancel();
    _captureTimer = null;
    _settleTimer?.cancel();
  }

  Future<void> _replayBridge() async {
    try {
      await _controller?.evaluateJavascript(
        source: 'window.__nakuHomeDisplay?.refresh()',
      );
    } catch (_) {}
  }

  Future<void> _visibility(bool hidden) async {
    if (hidden) _interruptExit();
    if (_closing) return;
    if (_hidden == hidden) return;
    _hidden = hidden;
    if (!hidden) {
      // Website hooks stop permanently after an expired-cookie 401. Retire the
      // old callback generation before awaiting auth, then create a new document
      // after its cookie is installed; a stale 401 cannot dispose that document.
      await _open();
      return;
    }
    _timeout?.cancel();
    _captureTimer?.cancel();
    _captureTimer = null;
    _renewTimer?.cancel();
    try {
      await _controller?.evaluateJavascript(
        source: 'window.__nakuHomeDisplay?.setVisible(false)',
      );
    } catch (_) {}
  }

  Future<void> _occlusion(bool occluded) async {
    if (occluded) _interruptExit();
    if (_closing) return;
    if (_occluded == occluded) return;
    _occluded = occluded;
    if (_hidden) return;
    if (occluded) {
      _timeout?.cancel();
      _captureTimer?.cancel();
      _captureTimer = null;
    } else if (_webView == null) {
      await _open();
      return;
    } else if (_loading) {
      _armTimeout(_document);
      _startCaptures(_generation, _document);
    }
    try {
      await _controller?.evaluateJavascript(
        source: 'window.__nakuHomeDisplay?.setVisible(${!occluded})',
      );
      if (!occluded) await _replayBridge();
    } catch (_) {}
  }

  @override
  void onWindowMinimize() {
    _minimized = true;
    unawaited(_visibility(true));
  }

  @override
  void onWindowRestore() {
    _minimized = false;
    unawaited(_visibility(_windowControls.hidden));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _backgrounded = _isBackground(state);
    if (_backgrounded) _interruptExit();
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // Flutter maps AppKit occlusion (including fullscreen Space changes) to
      // hidden. It is not NSApp.hide. Keep the live WKWebView mounted while its
      // loading work is paused; tearing it down here can race CVDisplayLink.
      unawaited(_occlusion(true));
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_occlusion(false));
      unawaited(_windowControls.refreshVisibility());
    }
  }

  @override
  void dispose() {
    _interruptExit();
    ++_generation;
    _cancelLoadingTimers();
    _renewTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _windowControls.unregister(this);
    // Disposing the native page releases its WebGL contexts and website polling.
    _webView?.dispose();
    _controller = null;
    _webView = null;
    _releasePreview();
    _retirePreview(_exitPreview);
    _exitPreview = null;
    super.dispose();
  }

  Future<ui.Image?> _takeExitPreview(int generation) async {
    final current = _preview;
    if (current != null) return current.clone();
    final controller = _controller;
    if (controller == null || _captureWork != null) return null;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final bytes = await controller
          .takeScreenshot(
            screenshotConfiguration: ScreenshotConfiguration(
              snapshotWidth: 960,
            ),
          )
          .timeout(const Duration(milliseconds: 600));
      if (bytes == null || !mounted || generation != _generation) return null;
      codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: 1536,
        allowUpscaling: false,
      );
      image = (await codec.getNextFrame()).image;
      if (!mounted || generation != _generation) return null;
      final result = image;
      image = null;
      return result;
    } catch (_) {
      return null;
    } finally {
      codec?.dispose();
      image?.dispose();
    }
  }

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  void _interruptExit() {
    final interruption = _exitInterrupted;
    if (interruption != null && !interruption.isCompleted) {
      interruption.complete();
    }
  }

  Future<ui.Image?> _exitSnapshot(
    int generation,
    Completer<void> interruption,
  ) {
    final result = Completer<ui.Image?>();
    unawaited(
      interruption.future.then((_) {
        if (!result.isCompleted) result.complete(null);
      }),
    );
    unawaited(
      _takeExitPreview(generation).then((image) {
        if (result.isCompleted) {
          // Suspension may win while WebKit or the decoder is still working.
          // That late image was never handed to a painter and is ours to free.
          image?.dispose();
        } else {
          result.complete(image);
        }
      }),
    );
    return result.future;
  }

  Future<bool> _exitFrame(
    int generation,
    Completer<void> interruption,
    String stage,
  ) async {
    if (!mounted || _suspended || _backgrounded || interruption.isCompleted) {
      return false;
    }
    _exitFrameWait = stage;
    try {
      // hidden/paused stop frame production. They must release a wait that
      // already started in the foreground, without waiting for resume/timeout.
      await Future.any<void>([
        WidgetsBinding.instance.endOfFrame,
        interruption.future,
      ]);
    } finally {
      _exitFrameWait = null;
    }
    return mounted && generation == _generation && !interruption.isCompleted;
  }

  Future<void> _leave() async {
    if (_closing || !Navigator.of(context).canPop()) return;
    setState(() => _closing = true);
    final generation = ++_generation;
    final interruption = _exitInterrupted = Completer<void>();
    final navigator = Navigator.of(context);
    _cancelLoadingTimers();
    _renewTimer?.cancel();
    final animate =
        !_suspended &&
        !_backgrounded &&
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    try {
      final image = animate
          ? await _exitSnapshot(generation, interruption)
          : null;
      if (!mounted || generation != _generation || interruption.isCompleted) {
        image?.dispose();
        return;
      }
      if (image != null) {
        // A live AppKit view cannot safely follow the shrinking Flutter
        // transform. Keep it mounted offstage, then close its actual pixels.
        setState(() => _exitPreview = image);
        if (!await _exitFrame(generation, interruption, 'snapshot')) return;
        final closing = _exitSurface.currentState?.closeForExit();
        if (closing != null) {
          await Future.any<void>([closing, interruption.future]);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _allowDisplayPop = true);
        if (animate) await _exitFrame(generation, interruption, 'pop');
        if (mounted) navigator.pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowDisplayPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_leave());
    },
    child: Theme(
      data: CinemaTheme.of(context),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: IgnorePointer(
          ignoring: _closing,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_webView != null)
                Offstage(
                  offstage: _exitPreview != null,
                  child: _webView!.build(context),
                ),
              if (_overlay && _error == null && !_closing)
                IgnorePointer(
                  child: CinemaNeonDecode(
                    loading: _loading,
                    progress: (_progress / 100) * .75,
                    snapshotRendering: true,
                    rasterSnapshot: _preview,
                    // Until a real preview exists the native page itself remains
                    // visible. The overlay never substitutes generated tile colors.
                    child: const SizedBox.expand(),
                  ),
                ),
              if (_error != null)
                ColoredBox(
                  color: CinemaTheme.background,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        if (_needsNAS && widget.onOpenNAS != null)
                          FilledButton(
                            onPressed: () async {
                              await widget.onOpenNAS!();
                              if (mounted) await _open();
                            },
                            child: const Text('登录 NAS'),
                          )
                        else
                          TextButton(
                            onPressed: _authorizing ? null : _open,
                            child: const Text('重试'),
                          ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                key: const ValueKey('home-display-floating-controls'),
                top: MediaQuery.paddingOf(context).top + 34,
                left: 12,
                right: 12,
                child: Row(
                  children: [
                    _displayControl(
                      tooltip: '返回',
                      icon: Icons.chevron_left_rounded,
                      onPressed: () => unawaited(_leave()),
                    ),
                    const Spacer(),
                    _displayControl(
                      tooltip: '刷新',
                      icon: Icons.refresh_rounded,
                      onPressed: _authorizing ? null : _open,
                    ),
                    const SizedBox(width: 4),
                    _displayControl(
                      tooltip: '全屏',
                      icon: Icons.fullscreen_rounded,
                      onPressed: () async {
                        try {
                          await DesktopFullscreen.setFullScreen(
                            !await DesktopFullscreen.isFullScreen(),
                          );
                        } catch (_) {}
                      },
                    ),
                  ],
                ),
              ),
              if (_exitPreview != null)
                Positioned.fill(
                  child: CinemaPlayerEntrance(
                    key: _exitSurface,
                    generation: 0,
                    ready: true,
                    animateOnEntry: false,
                    child: RawImage(
                      image: _exitPreview,
                      fit: BoxFit.fill,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _displayControl({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      foregroundColor: Colors.white.withValues(alpha: .92),
      backgroundColor: Colors.transparent,
      disabledForegroundColor: Colors.white.withValues(alpha: .3),
      hoverColor: Colors.white.withValues(alpha: .1),
      focusColor: Colors.white.withValues(alpha: .1),
      highlightColor: Colors.white.withValues(alpha: .14),
      minimumSize: const Size.square(40),
      shape: const CircleBorder(),
    ),
    icon: Icon(
      icon,
      size: 23,
      shadows: const [Shadow(color: Colors.black54, blurRadius: 8)],
    ),
  );
}
