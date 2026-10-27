import 'cinema_swipe_navigation.dart';
import 'package:kazumi/features/cinema/naku_update_service.dart';
import 'package:kazumi/services/platform/desktop_fullscreen.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/services/player/pip_utils.dart';
import 'dart:convert';
import 'package:kazumi/services/platform/desktop_window_controls.dart';
import 'cinema_webview_media.dart';
import 'cinema_moyu_exports.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

import 'cinema_theme.dart';

/// Keep documents on the web; allow embedded media and blank iframe documents.
bool cinemaAllowsWebNavigation(String? value, {required bool isMainFrame}) {
  final uri = value == null ? null : Uri.tryParse(value);
  if (uri == null) return false;
  if ((uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty) {
    return true;
  }
  return !isMainFrame &&
      (uri.scheme == 'blob' ||
          uri.scheme == 'data' ||
          value == 'about:blank' ||
          value == 'about:srcdoc');
}

/// WebKit does not expose [NavigationAction.hasGesture]; its link navigation
/// type is the available positive signal. Unknown/script popups stay blocked.
bool cinemaAllowsWebPopup({
  required String? url,
  bool? hasGesture,
  NavigationType? navigationType,
}) =>
    cinemaAllowsWebNavigation(url, isMainFrame: true) &&
    (hasGesture == true || navigationType == NavigationType.LINK_ACTIVATED);

/// Exact hosts from Joyflix's navigation ad list, excluding its parser hosts.
/// Network blocking only: no page rewriting, broad URL terms or captcha rules.
List<ContentBlocker> cinemaWebsiteContentBlockers() => [
  for (final host in const [
    'ynjczy.net',
    'ylbdtg.com',
    '662820.com',
    'f.qcwzx.net.cn',
    'adx.dlads.cn',
    'dlads.cn',
    'wuo.8h2x.com',
    'strip.alicdn.com',
  ])
    ContentBlocker(
      trigger: ContentBlockerTrigger(
        // WebKit rejects alternation (|). Network URLs have a normalized
        // slash after the authority, including a host with an empty path.
        urlFilter: '^https?://${RegExp.escape(host)}(:[0-9]+)?/',
      ),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
];

class CinemaWebviewPage extends StatefulWidget {
  const CinemaWebviewPage({
    super.key,
    required this.title,
    required this.url,
    this.mediaToolsEnabled = true,
    this.visible = true,
    this.onClose,
  });

  final String title;
  final String url;
  final bool mediaToolsEnabled;
  final bool visible;
  final VoidCallback? onClose;

  @override
  State<CinemaWebviewPage> createState() => _CinemaWebviewPageState();
}

class _CinemaWebviewPageState extends State<CinemaWebviewPage> {
  bool _videoWindow = false, _videoWindowChanging = false;
  Rect? _videoWindowBounds;
  bool _videoWindowOnTop = false;
  Future<void> _videoWindowPending = Future.value();
  final _windowControls = DesktopWindowControls.instance;
  CinemaWebMediaLifecycle? _mediaLifecycle;
  PlatformInAppWebViewWidget? _webView;
  PlatformInAppWebViewController? _controller;
  String _currentUrl = '';
  String? _error;
  bool _loading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
  bool _blockAds = true;
  bool _changingSettings = false;
  int _progress = 0;
  int _revision = 0;
  int _historyRequest = 0;
  bool _disposed = false;
  bool _exporting = false;
  Timer? _loadTimeout;
  bool _timedOut = false;
  // macOS plugin 1.1.2 loads rejected popup requests into the current view.
  // Veto that one fallback navigation while returning false so the plugin
  // releases its temporary window transport instead of retaining a child view.
  final Map<String, DateTime> _popupVetoes = {};

  NakuPlaybackUpdateLease? _updatePlaybackLease;

  @override
  void initState() {
    super.initState();
    _syncLease();
    _windowControls.register(this, _visibilityChanged);
    _createWebView();
  }

  void _syncLease() {
    if (!widget.visible) {
      final lease = _updatePlaybackLease;
      _updatePlaybackLease = null;
      if (lease != null) unawaited(lease.close());
    } else {
      _updatePlaybackLease ??= NakuPlaybackUpdateLease();
      unawaited(_updatePlaybackLease!.start());
    }
  }

  @override
  void didUpdateWidget(CinemaWebviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visible != widget.visible) {
      _syncLease();
      unawaited(
        _mediaLifecycle?.setHidden(
          !widget.visible || _windowControls.blocksPlayback,
        ),
      );
    }
  }

  void _closePage() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  bool _active(int revision) => mounted && !_disposed && revision == _revision;

  void _createWebView() {
    _currentUrl = widget.url;
    if (!cinemaAllowsWebNavigation(widget.url, isMainFrame: true)) {
      _loading = false;
      _error = '这个地址无法打开，请返回站点列表并检查 HTTP 或 HTTPS 地址。';
      return;
    }
    if (InAppWebViewPlatform.instance == null) {
      _loading = false;
      _error = '当前平台暂未提供内嵌网页组件，请返回站点列表。';
      return;
    }
    final revision = _revision;
    _webView = PlatformInAppWebViewWidget(
      PlatformInAppWebViewWidgetCreationParams(
        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
        initialUserScripts: UnmodifiableListView([
          if (!widget.mediaToolsEnabled && cinemaIsMoyuUrl(widget.url))
            UserScript(
              source: cinemaMoyuExportBridge,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: true,
            ),
          if (widget.mediaToolsEnabled)
            UserScript(
              source: cinemaWebVideoPipScript,
              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
              forMainFrameOnly: false,
            ),
        ]),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          cacheEnabled: true,
          incognito: false,
          mediaPlaybackRequiresUserGesture: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: true,
          useShouldOverrideUrlLoading: true,
          allowsBackForwardNavigationGestures: true,
          isInspectable: false,
          contentBlockers: widget.mediaToolsEnabled
              ? cinemaWebsiteContentBlockers()
              : [],
        ),
        onWebViewCreated: (controller) {
          if (!_active(revision)) return;
          setState(() => _controller = controller);
          if (!widget.mediaToolsEnabled && cinemaIsMoyuUrl(widget.url)) {
            controller.addJavaScriptHandler(
              handlerName: 'nakuMoyuExport',
              callback: (args) async {
                if (!_active(revision) || !widget.visible || _exporting) {
                  return false;
                }
                final currentUrl = await controller.getUrl();
                if (!mounted ||
                    !_active(revision) ||
                    !widget.visible ||
                    _exporting ||
                    !cinemaIsMoyuUrl(currentUrl?.toString())) {
                  return false;
                }
                _exporting = true;
                try {
                  final export = CinemaMoyuExport.decode(args);
                  final path = await FilePicker.platform.saveFile(
                    dialogTitle: '保存摸鱼记录',
                    fileName: export.name,
                  );
                  if (!_active(revision) || !widget.visible || path == null) {
                    return false;
                  }
                  await File(path).writeAsBytes(export.bytes, flush: true);
                  return true;
                } catch (_) {
                  if (mounted && _active(revision)) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('文件未能保存，可重试或在浏览器中打开')),
                    );
                  }
                  return false;
                } finally {
                  _exporting = false;
                }
              },
            );
          }
          if (widget.mediaToolsEnabled) {
            controller.addJavaScriptHandler(
              handlerName: 'nakuVideoWindow',
              callback: (args) async {
                if (!_active(revision) ||
                    args.length != 1 ||
                    !const ['enter', 'exit'].contains(args.single)) {
                  return false;
                }
                final enter = args.single == 'enter';
                _videoWindowPending = _videoWindowPending
                    .catchError((_) {})
                    .then((_) => _setVideoWindow(enter));
                await _videoWindowPending;
                return true;
              },
            );
          }
          _mediaLifecycle = CinemaWebMediaLifecycle(
            pause: controller.pauseAllMediaPlayback,
            suspend: (value) =>
                controller.setAllMediaPlaybackSuspended(suspended: value),
          );
          if (!widget.visible || _windowControls.blocksPlayback) {
            unawaited(_mediaLifecycle!.setHidden(true));
          }
          unawaited(_updateHistory(controller, revision));
        },
        shouldOverrideUrlLoading: (controller, action) async {
          if (!_active(revision)) return NavigationActionPolicy.CANCEL;
          final url = action.request.url?.toString();
          final now = DateTime.now();
          _popupVetoes.removeWhere((_, expiry) => expiry.isBefore(now));
          if (action.isForMainFrame &&
              action.navigationType != NavigationType.LINK_ACTIVATED &&
              url != null &&
              _popupVetoes.remove(url) != null) {
            return NavigationActionPolicy.CANCEL;
          }
          final allowed = cinemaAllowsWebNavigation(
            url,
            isMainFrame: action.isForMainFrame,
          );
          if (allowed && action.isForMainFrame && url != null) {
            setState(() => _currentUrl = url);
          }
          return allowed
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onCreateWindow: (controller, action) async {
          if (!_active(revision)) return false;
          final url = action.request.url?.toString();
          if (!cinemaAllowsWebPopup(
            url: url,
            hasGesture: action.hasGesture,
            navigationType: action.navigationType,
          )) {
            if (url != null) {
              if (_popupVetoes.length >= 32) _popupVetoes.clear();
              _popupVetoes[url] = DateTime.now().add(
                const Duration(seconds: 5),
              );
            }
            return false;
          }
          // The macOS implementation's false/default response already loads
          // this request into the existing view. Do not issue it twice.
          if (Theme.of(context).platform == TargetPlatform.macOS) return false;
          await _runAction(
            () => controller.loadUrl(urlRequest: action.request),
          );
          return false;
        },
        onLoadStart: (controller, url) {
          if (!_active(revision)) return;
          _videoWindowPending = _videoWindowPending
              .catchError((_) {})
              .then((_) => _setVideoWindow(false));
          _startLoadTimeout(revision);
          setState(() {
            if (url != null &&
                cinemaAllowsWebNavigation(url.toString(), isMainFrame: true)) {
              _currentUrl = url.toString();
            }
            _loading = true;
            _progress = 0;
            _error = null;
          });
        },
        onProgressChanged: (controller, progress) {
          if (!_active(revision)) return;
          setState(() => _progress = progress.clamp(0, 100));
        },
        onPageCommitVisible: (controller, url) {
          if (!_active(revision)) return;
          unawaited(_mediaLifecycle?.documentReady());
          _loadTimeout?.cancel();
          // A slow page may still arrive after the timeout. Do not leave the
          // timeout overlay covering it, or time out on its later resources.
          if (_timedOut) {
            setState(() {
              _timedOut = false;
              _error = null;
              _loading = true;
            });
          }
        },
        onLoadStop: (controller, url) {
          if (!_active(revision)) return;
          unawaited(_mediaLifecycle?.documentReady());
          _loadTimeout?.cancel();
          setState(() {
            if (url != null &&
                cinemaAllowsWebNavigation(url.toString(), isMainFrame: true)) {
              _currentUrl = url.toString();
            }
            _loading = false;
            _progress = 100;
            if (_timedOut) {
              _timedOut = false;
              _error = null;
            }
          });
          unawaited(_updateHistory(controller, revision));
        },
        onUpdateVisitedHistory: (controller, url, isReload) {
          if (!_active(revision)) return;
          if (url != null &&
              cinemaAllowsWebNavigation(url.toString(), isMainFrame: true)) {
            setState(() => _currentUrl = url.toString());
          }
          unawaited(_updateHistory(controller, revision));
        },
        onReceivedError: (controller, request, error) {
          if (!_active(revision) ||
              request.isForMainFrame != true ||
              error.type == WebResourceErrorType.CANCELLED ||
              request.url.toString() != _currentUrl) {
            return;
          }
          _showError('网页暂时未能加载。可以重试，或返回列表切换站点。');
        },
        onReceivedHttpError: (controller, request, response) {
          if (!_active(revision) ||
              request.isForMainFrame != true ||
              request.url.toString() != _currentUrl) {
            return;
          }
          _showError('网页返回 HTTP ${response.statusCode ?? '错误'}。可以重试，或切换站点。');
        },
        onWebContentProcessDidTerminate: (controller) {
          if (_active(revision)) _showError('网页进程已停止，点击重试可重新加载。');
        },
        onPermissionRequest: (controller, request) async => PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        ),
        onGeolocationPermissionsShowPrompt: (controller, origin) async =>
            GeolocationPermissionShowPromptResponse(
              origin: origin,
              allow: false,
              retain: false,
            ),
        // Certificate challenges deliberately use the platform's default.
      ),
    );
    // Also cover native initialization failures that never emit onLoadStart.
    _startLoadTimeout(revision);
  }

  void _startLoadTimeout(int revision) {
    _loadTimeout?.cancel();
    _timedOut = false;
    _loadTimeout = Timer(const Duration(seconds: 30), () {
      if (!_active(revision) || !_loading) return;
      _timedOut = true;
      _showError('网页加载等待超过 30 秒。可以重试，或在网页设置中关闭广告过滤后重试。');
    });
  }

  Future<void> _updateHistory(
    PlatformInAppWebViewController controller,
    int revision,
  ) async {
    final request = ++_historyRequest;
    try {
      final state = await Future.wait([
        controller.canGoBack(),
        controller.canGoForward(),
      ]);
      if (!_active(revision) || request != _historyRequest) return;
      setState(() {
        _canGoBack = state[0];
        _canGoForward = state[1];
      });
    } catch (_) {
      // Navigation can end while the route is being disposed.
    }
  }

  void _showError(String message) {
    if (!mounted || _disposed) return;
    _loadTimeout?.cancel();
    setState(() {
      _error = message;
      _loading = false;
    });
  }

  Future<void> _runAction(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _showError('网页操作暂时未完成，请重试。');
    }
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;
    _startLoadTimeout(_revision);
    setState(() {
      _error = null;
      _loading = true;
      _progress = 0;
    });
    // loadUrl also retries a failed first navigation with no committed history.
    await _runAction(
      () =>
          controller.loadUrl(urlRequest: URLRequest(url: WebUri(_currentUrl))),
    );
  }

  Future<void> _toggleAdBlocking() async {
    final controller = _controller;
    if (controller == null || _changingSettings) return;
    final next = !_blockAds;
    setState(() => _changingSettings = true);
    try {
      final settings = await controller.getSettings();
      if (!mounted || _disposed) return;
      if (settings == null) throw StateError('WebView settings unavailable');
      settings.contentBlockers = next ? cinemaWebsiteContentBlockers() : [];
      await controller.setSettings(settings: settings);
      if (!mounted || _disposed) return;
      setState(() => _blockAds = next);
      await _reload();
    } catch (_) {
      _showError('广告过滤设置暂未生效，请重试。');
    } finally {
      if (mounted && !_disposed) setState(() => _changingSettings = false);
    }
  }

  Future<void> _visibilityChanged(bool hidden) async {
    await _mediaLifecycle?.setHidden(
      !widget.visible || (hidden && _windowControls.blocksPlayback),
    );
  }

  Future<void> _restoreVideoWindow() async {
    final bounds = _videoWindowBounds;
    if (bounds == null) return;
    await windowManager.setAspectRatio(0);
    await windowManager.setMinimumSize(const Size(800, 600));
    await windowManager.setAlwaysOnTop(_videoWindowOnTop);
    await windowManager.setBounds(bounds);
    _videoWindowBounds = null;
  }

  Future<void> _setVideoWindow(bool enter) async {
    if (_disposed ||
        !mounted ||
        (_videoWindow == enter && (enter || _videoWindowBounds == null))) {
      return;
    }
    if (!(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
    _videoWindowChanging = true;
    try {
      if (enter) {
        if (await DesktopFullscreen.isFullScreen()) {
          await DesktopFullscreen.setFullScreen(false);
          for (
            var i = 0;
            i < 30 && await DesktopFullscreen.isFullScreen();
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (await DesktopFullscreen.isFullScreen()) {
            throw StateError('Fullscreen transition pending');
          }
        }
        _videoWindowBounds = await windowManager.getBounds();
        _videoWindowOnTop = await windowManager.isAlwaysOnTop();
        await windowManager.setMinimumSize(const Size(320, 180));
        await PipUtils.enterDesktopPIPWindow();
        if (_disposed || !mounted) {
          await _restoreVideoWindow();
          return;
        }
      } else {
        await _controller?.evaluateJavascript(
          source:
              "window.__nakuExitVideoWindow && window.__nakuExitVideoWindow()",
        );
        await _restoreVideoWindow();
      }
      if (mounted && !_disposed) setState(() => _videoWindow = enter);
    } catch (_) {
      try {
        await _controller?.evaluateJavascript(
          source:
              "window.__nakuExitVideoWindow && window.__nakuExitVideoWindow()",
        );
      } catch (_) {}
      try {
        await _restoreVideoWindow();
      } catch (_) {}
      if (mounted && !_disposed) {
        setState(() => _videoWindow = false);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('视频浮窗暂时无法打开，已恢复网页')));
      }
    } finally {
      _videoWindowChanging = false;
    }
  }

  Future<void> _videoAction(String action) async {
    final controller = _controller;
    if (controller == null || _windowControls.blocksPlayback) return;
    Object? result;
    try {
      result = await controller.evaluateJavascript(
        source: cinemaWebVideoAction(action),
      );
    } catch (_) {}
    if (!mounted || _disposed) return;
    if (action == 'pip' && result != 'started') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('当前网页或系统引擎未支持视频画中画；如站点提供自身画中画按钮，可使用站点按钮。'),
        ),
      );
    }
  }

  Future<void> _showMediaTools() async {
    final controller = _controller;
    if (controller == null) return;
    Map? media;
    try {
      var raw = await controller.evaluateJavascript(
        source: cinemaWebMediaInspection,
      );
      if (raw is String) raw = jsonDecode(raw);
      if (raw is Map) media = raw;
    } catch (_) {}
    if (!mounted || _disposed) return;
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        List<Map> tracks(String key) => (media?[key] is List)
            ? (media![key] as List)
                  .whereType<Map>()
                  .where(
                    (v) =>
                        v['index'] is int &&
                        (v['index'] as int) >= 0 &&
                        (v['index'] as int) <= 128 &&
                        v['label'] is String,
                  )
                  .take(129)
                  .toList()
            : [];
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('网页媒体工具'),
                subtitle: Text('保留网页原有播放控件；跨域或受保护的播放器请使用网站提供的音轨、字幕和清晰度选项。'),
              ),
              for (final group in ['audio', 'subtitles']) ...[
                ListTile(
                  title: Text(group == 'audio' ? '音轨' : '字幕'),
                  subtitle: tracks(group).isEmpty
                      ? const Text('网页未提供可枚举轨道，请使用站点控件')
                      : null,
                ),
                if (group == 'subtitles' && tracks(group).isNotEmpty)
                  ListTile(
                    title: const Text('关闭字幕'),
                    onTap: () async {
                      try {
                        await controller.evaluateJavascript(
                          source: cinemaWebMediaTrackAction('subtitle', -1),
                        );
                      } catch (_) {}
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
                for (final track in tracks(group))
                  ListTile(
                    title: Text(
                      (track['label'] as String).substring(
                        0,
                        (track['label'] as String).length.clamp(0, 120),
                      ),
                    ),
                    onTap: () async {
                      try {
                        await controller.evaluateJavascript(
                          source: cinemaWebMediaTrackAction(
                            group == 'audio' ? 'audio' : 'subtitle',
                            track['index'] as int,
                          ),
                        );
                      } catch (_) {}
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                    },
                  ),
              ],
              const ListTile(
                title: Text('清晰度'),
                subtitle: Text('由站点播放器提供；请使用网页中的清晰度菜单'),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    final lease = _updatePlaybackLease;
    if (lease != null) unawaited(lease.close());
    _disposed = true;
    if (_videoWindowBounds != null && !_videoWindowChanging) {
      unawaited(_restoreVideoWindow());
    }
    _windowControls.unregister(this);
    final closingController = _controller;
    final mediaClosed = _mediaLifecycle?.close().then((_) async {
      try {
        await closingController?.evaluateJavascript(
          source:
              "window.__nakuExitVideoWindow && window.__nakuExitVideoWindow()",
        );
      } catch (_) {}
    });
    ++_revision;
    ++_historyRequest;
    _loadTimeout?.cancel();
    _popupVetoes.clear();
    _controller = null;
    final webView = _webView;
    if (mediaClosed == null) {
      webView?.dispose();
    } else {
      unawaited(mediaClosed.whenComplete(() => webView?.dispose()));
    }
    _webView = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final page = _buildPage(context);
    return widget.mediaToolsEnabled ? CinemaSwipeExclusion(child: page) : page;
  }

  Widget _buildPage(BuildContext context) {
    final controller = _controller;
    final uri = Uri.tryParse(_currentUrl);
    final host = uri?.host ?? '';
    final immersive = !widget.mediaToolsEnabled && cinemaIsMoyuUrl(widget.url);
    return CallbackShortcuts(
      bindings: {
        if (immersive)
          const SingleActivator(LogicalKeyboardKey.escape): _closePage,
      },
      child: Theme(
        data: CinemaTheme.of(context),
        child: Scaffold(
          backgroundColor: CinemaTheme.background,
          body: SafeArea(
            top: !immersive,
            bottom: !immersive,
            left: !immersive,
            right: !immersive,
            child: Column(
              children: [
                if (!_videoWindow && !immersive)
                  Container(
                    decoration: BoxDecoration(
                      color: CinemaTheme.surface,
                      border: const Border(
                        bottom: BorderSide(color: CinemaTheme.border),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: widget.mediaToolsEnabled
                                  ? '返回站点列表'
                                  : '返回',
                              onPressed: () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    host.isEmpty ? '网页观影' : host,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: CinemaTheme.muted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (widget.mediaToolsEnabled)
                              IconButton(
                                tooltip: '网页媒体工具',
                                onPressed: controller == null
                                    ? null
                                    : _showMediaTools,
                                icon: const Icon(Icons.tune),
                              ),
                            if (widget.mediaToolsEnabled)
                              IconButton(
                                tooltip: '视频画中画 / 视频浮窗',
                                onPressed: controller == null
                                    ? null
                                    : () => _videoAction('pip'),
                                icon: const Icon(Icons.picture_in_picture_alt),
                              ),
                            if (widget.mediaToolsEnabled)
                              PopupMenuButton<String>(
                                tooltip: '网页设置',
                                onSelected: (_) => _toggleAdBlocking(),
                                itemBuilder: (_) => [
                                  CheckedPopupMenuItem(
                                    value: 'ads',
                                    checked: _blockAds,
                                    enabled:
                                        controller != null &&
                                        !_changingSettings,
                                    child: const Text('过滤已知广告域名'),
                                  ),
                                ],
                              ),
                            if (!widget.mediaToolsEnabled)
                              IconButton(
                                tooltip: '在浏览器中打开',
                                onPressed: () => launchUrl(
                                  Uri.parse(_currentUrl),
                                  mode: LaunchMode.externalApplication,
                                ),
                                icon: const Icon(Icons.open_in_new_rounded),
                              ),
                          ],
                        ),
                        Row(
                          children: [
                            IconButton(
                              tooltip: '网页后退',
                              onPressed: controller != null && _canGoBack
                                  ? () => _runAction(controller.goBack)
                                  : null,
                              icon: const Icon(Icons.chevron_left_rounded),
                            ),
                            IconButton(
                              tooltip: '网页前进',
                              onPressed: controller != null && _canGoForward
                                  ? () => _runAction(controller.goForward)
                                  : null,
                              icon: const Icon(Icons.chevron_right_rounded),
                            ),
                            IconButton(
                              tooltip: _loading ? '停止加载' : '刷新网页',
                              onPressed: controller == null
                                  ? null
                                  : _loading
                                  ? () async {
                                      _loadTimeout?.cancel();
                                      await _runAction(controller.stopLoading);
                                      if (mounted) {
                                        setState(() => _loading = false);
                                      }
                                    }
                                  : _reload,
                              icon: Icon(
                                _loading
                                    ? Icons.close_rounded
                                    : Icons.refresh_rounded,
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (widget.mediaToolsEnabled)
                              const Expanded(
                                child: Text(
                                  '在网页中搜索、选集并点击播放',
                                  style: TextStyle(
                                    color: CinemaTheme.muted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                if (!_videoWindow && widget.mediaToolsEnabled)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: controller == null
                              ? null
                              : () => _videoAction('toggle'),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('播放 / 暂停'),
                        ),
                        TextButton(
                          onPressed: controller == null
                              ? null
                              : () => _videoAction('back'),
                          child: const Text('后退 10 秒'),
                        ),
                        TextButton(
                          onPressed: controller == null
                              ? null
                              : () => _videoAction('forward'),
                          child: const Text('前进 10 秒'),
                        ),
                        TextButton(
                          onPressed: controller == null
                              ? null
                              : () => _videoAction('speed'),
                          child: const Text('倍速'),
                        ),
                        TextButton(
                          onPressed: controller == null
                              ? null
                              : _showMediaTools,
                          child: const Text('音轨 / 字幕'),
                        ),
                        TextButton(
                          onPressed: controller == null
                              ? null
                              : _showMediaTools,
                          child: const Text('清晰度（站点控件）'),
                        ),
                      ],
                    ),
                  ),
                if (!_videoWindow && !immersive)
                  SizedBox(
                    height: 3,
                    child: _loading
                        ? LinearProgressIndicator(
                            value: _progress == 0 ? null : _progress / 100,
                            color: CinemaTheme.copper,
                            backgroundColor: CinemaTheme.raised,
                          )
                        : null,
                  ),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_webView != null) _webView!.build(context),
                      if (_error != null)
                        ColoredBox(
                          color: CinemaTheme.background,
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(28),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.public_off_rounded,
                                    color: CinemaTheme.copper,
                                    size: 38,
                                  ),
                                  const SizedBox(height: 18),
                                  Text(_error!, textAlign: TextAlign.center),
                                  const SizedBox(height: 18),
                                  if (controller != null)
                                    FilledButton.icon(
                                      onPressed: _reload,
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('重试'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (immersive)
                        Positioned(
                          top: 16,
                          right: 16,
                          child: Material(
                            color: const Color(0xD9282B30),
                            shape: const CircleBorder(),
                            elevation: 6,
                            shadowColor: Colors.black38,
                            child: IconButton(
                              key: const ValueKey('cinema-moyu-hide'),
                              tooltip: '返回首页（网页保留后台）',
                              onPressed: _closePage,
                              icon: const Icon(Icons.close_rounded, size: 20),
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
