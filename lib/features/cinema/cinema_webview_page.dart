import 'dart:async';

import 'package:flutter/material.dart';
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
  const CinemaWebviewPage({super.key, required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<CinemaWebviewPage> createState() => _CinemaWebviewPageState();
}

class _CinemaWebviewPageState extends State<CinemaWebviewPage> {
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
  Timer? _loadTimeout;
  bool _timedOut = false;
  // macOS plugin 1.1.2 loads rejected popup requests into the current view.
  // Veto that one fallback navigation while returning false so the plugin
  // releases its temporary window transport instead of retaining a child view.
  final Map<String, DateTime> _popupVetoes = {};

  @override
  void initState() {
    super.initState();
    _createWebView();
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
        initialSettings: InAppWebViewSettings(
          mediaPlaybackRequiresUserGesture: true,
          javaScriptCanOpenWindowsAutomatically: false,
          supportMultipleWindows: true,
          useShouldOverrideUrlLoading: true,
          allowsBackForwardNavigationGestures: true,
          isInspectable: false,
          contentBlockers: cinemaWebsiteContentBlockers(),
        ),
        onWebViewCreated: (controller) {
          if (!_active(revision)) return;
          setState(() => _controller = controller);
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

  @override
  void dispose() {
    _disposed = true;
    ++_revision;
    ++_historyRequest;
    _loadTimeout?.cancel();
    _popupVetoes.clear();
    _controller = null;
    _webView?.dispose();
    _webView = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final uri = Uri.tryParse(_currentUrl);
    final host = uri?.host ?? '';
    return Theme(
      data: CinemaTheme.of(context),
      child: Scaffold(
        backgroundColor: CinemaTheme.background,
        body: SafeArea(
          child: Column(
            children: [
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
                          tooltip: '返回站点列表',
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
                        PopupMenuButton<String>(
                          tooltip: '网页设置',
                          onSelected: (_) => _toggleAdBlocking(),
                          itemBuilder: (_) => [
                            CheckedPopupMenuItem(
                              value: 'ads',
                              checked: _blockAds,
                              enabled: controller != null && !_changingSettings,
                              child: const Text('过滤已知广告域名'),
                            ),
                          ],
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
                                  if (mounted) setState(() => _loading = false);
                                }
                              : _reload,
                          icon: Icon(
                            _loading
                                ? Icons.close_rounded
                                : Icons.refresh_rounded,
                          ),
                        ),
                        const SizedBox(width: 8),
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
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
