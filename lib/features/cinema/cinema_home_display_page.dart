import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:kazumi/services/platform/desktop_fullscreen.dart';
import 'package:window_manager/window_manager.dart';

import 'cinema_home_display_bridge.dart';
import 'cinema_nas_media.dart';
import 'cinema_neon_decode.dart';
import 'cinema_theme.dart';

const cinemaHomeDisplayUrl = 'https://between-us-home.pages.dev/display';

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
  const CinemaHomeDisplayPage({super.key, this.client, this.onOpenNAS});

  final CinemaNASClient? client;
  final Future<void> Function()? onOpenNAS;

  @override
  State<CinemaHomeDisplayPage> createState() => _CinemaHomeDisplayPageState();
}

class _CinemaHomeDisplayPageState extends State<CinemaHomeDisplayPage>
    with WidgetsBindingObserver, WindowListener {
  late final _client = widget.client ?? CinemaNASClient();
  PlatformInAppWebViewWidget? _webView;
  PlatformInAppWebViewController? _controller;
  Uint8List? _preview;
  Timer? _timeout, _captureTimer, _settleTimer, _renewTimer;
  bool _loading = true, _overlay = true, _hidden = false;
  bool _capturePending = false, _authorizing = false, _needsNAS = false;
  int _generation = 0, _document = 0, _captures = 0, _progress = 0;
  String? _error;
  String _url = cinemaHomeDisplayUrl;

  bool _active(int generation) => mounted && generation == _generation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    unawaited(_open());
  }

  Future<void> _open() async {
    if (_authorizing) return;
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
        _needsNAS = access['reason'] == 'nas_login_required';
        throw StateError(
          _needsNAS
              ? '请先登录 NAS'
              : access['reason'] == 'backend_unconfigured'
              ? '网站尚未配置 NAS 展示授权'
              : 'Home Display 授权暂不可用，请稍后重试',
        );
      }
      // A hidden page must not create a native document or start its polling.
      // Resume revalidates before constructing a fresh document below.
      if (_hidden) return;
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
          _needsNAS = access['reason'] == 'nas_login_required';
          _showError('NAS 会话已失效，请重新登录');
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
                  _hidden ||
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
          if (_active(generation)) {
            setState(() => _progress = value.clamp(0, 100));
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
      _error = null;
    });
    final document = _document;
    if (!_hidden) _armTimeout(document);
  }

  void _armTimeout(int document) {
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 40), () {
      if (mounted && !_hidden && document == _document && _loading) {
        _showError('页面仍未准备好，请检查连接后重试');
      }
    });
  }

  void _startCaptures(int generation, int document) {
    if (!_loading || _captureTimer != null || _hidden) return;
    unawaited(_capture(generation, document));
    _captureTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!_active(generation) ||
          document != _document ||
          !_loading ||
          _hidden ||
          _captures >= 24) {
        _captureTimer?.cancel();
        _captureTimer = null;
        return;
      }
      unawaited(_capture(generation, document));
    });
  }

  Future<void> _capture(int generation, int document) async {
    final controller = _controller;
    if (_capturePending || controller == null || _hidden) return;
    _capturePending = true;
    ++_captures;
    try {
      final bytes = await controller
          .takeScreenshot(
            screenshotConfiguration: ScreenshotConfiguration(
              snapshotWidth: 960,
            ),
          )
          .timeout(const Duration(seconds: 3));
      if (_active(generation) &&
          document == _document &&
          _overlay &&
          bytes != null) {
        final previous = _preview;
        setState(() => _preview = bytes);
        if (previous != null && !identical(previous, bytes)) {
          PaintingBinding.instance.imageCache.evict(MemoryImage(previous));
        }
      }
    } catch (_) {
      // A snapshot failure does not stop the native page or change readiness.
    } finally {
      _capturePending = false;
    }
  }

  Future<void> _finishDocument(int generation, int document) async {
    if (!_loading || !_active(generation) || document != _document) return;
    _timeout?.cancel();
    _captureTimer?.cancel();
    _captureTimer = null;
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
    if (previous != null) {
      PaintingBinding.instance.imageCache.evict(MemoryImage(previous));
    }
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

  @override
  void onWindowMinimize() => unawaited(_visibility(true));
  @override
  void onWindowRestore() => unawaited(_visibility(false));
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      unawaited(_visibility(true));
    } else if (state == AppLifecycleState.resumed && _hidden) {
      unawaited(_visibility(false));
    }
  }

  @override
  void dispose() {
    ++_generation;
    _cancelLoadingTimers();
    _renewTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    // Disposing the native page releases its WebGL contexts and website polling.
    _webView?.dispose();
    _controller = null;
    _webView = null;
    _releasePreview();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: CinemaTheme.of(context),
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Home Display'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _authorizing ? null : _open,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: '全屏',
            onPressed: () async {
              try {
                await DesktopFullscreen.setFullScreen(
                  !await DesktopFullscreen.isFullScreen(),
                );
              } catch (_) {}
            },
            icon: const Icon(Icons.fullscreen_rounded),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (_webView != null) _webView!.build(context),
          if (_overlay && _error == null)
            IgnorePointer(
              child: CinemaNeonDecode(
                loading: _loading,
                progress: (_progress / 100) * .75,
                child: ColoredBox(
                  color: CinemaTheme.background.withValues(alpha: 1),
                  child: _preview == null
                      ? const SizedBox.expand()
                      : Image.memory(
                          _preview!,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.high,
                          excludeFromSemantics: true,
                        ),
                ),
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
        ],
      ),
    ),
  );
}
