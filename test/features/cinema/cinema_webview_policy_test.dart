import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kazumi/features/cinema/cinema_moyu_host.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_webview_page.dart';

void main() {
  testWidgets('moyu uses its URL without exposing film controls', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await tester.pumpWidget(
      const MaterialApp(
        home: CinemaWebviewPage(
          title: '摸鱼',
          url: 'https://1in8b.life/zh-hans/',
          mediaToolsEnabled: false,
        ),
      ),
    );
    expect(
      platform.view.params.initialUrlRequest!.url.toString(),
      'https://1in8b.life/zh-hans/',
    );
    expect(platform.view.params.initialUserScripts, hasLength(1));
    expect(
      platform.view.params.initialUserScripts!.single.source,
      isNot(contains('nakuVideoWindow')),
    );
    expect(platform.view.params.initialSettings!.incognito, isFalse);
    expect(platform.view.params.initialSettings!.contentBlockers, isEmpty);
    expect(find.byTooltip('网页媒体工具'), findsNothing);
    expect(find.byTooltip('视频画中画 / 视频浮窗'), findsNothing);
    expect(find.text('倍速'), findsNothing);
    expect(find.text('在网页中搜索、选集并点击播放'), findsNothing);
    expect(find.byTooltip('网页后退'), findsNothing);
    expect(find.text('摸鱼'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    final safeArea = tester.widget<SafeArea>(find.byType(SafeArea).first);
    expect(safeArea.top, isFalse);
    expect(safeArea.bottom, isFalse);
    expect(find.byTooltip('停止加载'), findsNothing);
    platform.view.params.onLoadStop!(
      platform.controller,
      WebUri('https://1in8b.life/zh-hans/'),
    );
    await tester.pump();
    expect(find.byTooltip('刷新网页'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(platform.view.disposed, isTrue);
  });

  testWidgets(
    'floating close retains the document, pauses media and releases the update lease',
    (tester) async {
      final platform = _installFakeWebView();
      final session = CinemaMoyuSession();
      final sessions = <String, bool>{};
      const updater = MethodChannel('naku/updater');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(updater, (call) async {
        if (call.method == 'playbackSession') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          sessions[args['id'] as String] = args['active'] as bool;
        }
        return null;
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaMoyuHost(
            session: session,
            child: const Scaffold(body: Text('home retained')),
          ),
        ),
      );
      expect(find.byType(CinemaWebviewPage), findsNothing);
      session.show();
      await tester.pumpAndSettle();
      final document = platform.view;
      document.params.onWebViewCreated!(platform.controller);
      await tester.pumpAndSettle();
      expect(sessions.values.where((v) => v), hasLength(1));
      await tester.tap(find.byKey(const ValueKey('cinema-moyu-hide')));
      await tester.pumpAndSettle();
      expect(session.visible, isFalse);
      expect(document.disposed, isFalse);
      expect(platform.controller.suspensions.last, isTrue);
      expect(sessions.values.where((v) => v), isEmpty);
      expect(find.text('home retained'), findsOneWidget);
      session.show();
      await tester.pumpAndSettle();
      expect(identical(platform.view, document), isTrue);
      expect(platform.controller.suspensions.last, isFalse);
      expect(sessions.values.where((v) => v), hasLength(1));
      final navigator = Navigator.of(
        tester.element(find.byType(CinemaMoyuHost)),
      );
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.controller.suspensions.last, isTrue);
      expect(document.disposed, isFalse);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(platform.controller.suspensions.last, isFalse);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(document.disposed, isTrue);
      expect(sessions.values.where((v) => v), isEmpty);
      session.dispose();
      messenger.setMockMethodCallHandler(updater, null);
    },
  );

  testWidgets('silent native initialization failure has a bounded wait', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await tester.pumpWidget(_testPage());
    await tester.pump(const Duration(seconds: 30));
    expect(find.textContaining('网页加载等待超过 30 秒'), findsOneWidget);
    platform.view.params.onPageCommitVisible!(
      platform.controller,
      WebUri('https://example.com/'),
    );
    await tester.pump();
    expect(find.textContaining('网页加载等待超过 30 秒'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(platform.view.disposed, isTrue);
  });

  testWidgets('committed content is not covered while later resources load', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await tester.pumpWidget(_testPage());
    await tester.pump(const Duration(seconds: 2));
    platform.view.params.onPageCommitVisible!(
      platform.controller,
      WebUri('https://example.com/'),
    );
    await tester.pump(const Duration(seconds: 40));
    expect(find.textContaining('网页加载等待超过 30 秒'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving a pending page cancels its timeout', (tester) async {
    final platform = _installFakeWebView();
    await tester.pumpWidget(_testPage());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 40));
    expect(platform.view.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });

  test('main documents only navigate to complete HTTP(S) URLs', () {
    for (final url in [
      'https://example.com/watch',
      'http://example.com:8080/',
    ]) {
      expect(cinemaAllowsWebNavigation(url, isMainFrame: true), isTrue);
    }
    for (final url in [
      null,
      '',
      'https:missing-host',
      'file:///etc/passwd',
      'javascript:alert(1)',
      'intent://open',
      'weixin://open',
      'about:blank',
      'data:text/html,hello',
      'blob:https://example.com/id',
    ]) {
      expect(cinemaAllowsWebNavigation(url, isMainFrame: true), isFalse);
    }
  });

  test(
    'embedded media documents work without allowing external app schemes',
    () {
      for (final url in [
        'https://player.example.com/',
        'about:blank',
        'about:srcdoc',
        'blob:https://example.com/id',
        'data:text/html,hello',
      ]) {
        expect(cinemaAllowsWebNavigation(url, isMainFrame: false), isTrue);
      }
      for (final url in [
        'weixin://open',
        'file:///etc/passwd',
        'intent://open',
      ]) {
        expect(cinemaAllowsWebNavigation(url, isMainFrame: false), isFalse);
      }
    },
  );

  test('popup requires positive gesture or WebKit user-link evidence', () {
    const url = 'https://example.com/watch';
    expect(cinemaAllowsWebPopup(url: url), isFalse);
    expect(
      cinemaAllowsWebPopup(url: url, navigationType: NavigationType.OTHER),
      isFalse,
    );
    expect(
      cinemaAllowsWebPopup(
        url: url,
        navigationType: NavigationType.LINK_ACTIVATED,
      ),
      isTrue,
    );
    expect(cinemaAllowsWebPopup(url: url, hasGesture: true), isTrue);
    expect(
      cinemaAllowsWebPopup(url: 'weixin://open', hasGesture: true),
      isFalse,
    );
    expect(
      cinemaAllowsWebPopup(
        url: 'about:blank',
        navigationType: NavigationType.LINK_ACTIVATED,
      ),
      isFalse,
    );
  });

  test(
    'ad rules match exact network hosts and leave captcha/parser URLs alone',
    () {
      final rules = cinemaWebsiteContentBlockers();
      bool blocked(String url) => rules.any(
        (rule) =>
            RegExp(rule.trigger.urlFilter, caseSensitive: false).hasMatch(url),
      );
      expect(blocked('https://adx.dlads.cn/advert.js'), isTrue);
      expect(blocked('http://dlads.cn:8080/banner'), isTrue);
      expect(blocked('https://dlads.cn/'), isTrue);
      expect(blocked('https://dlads.cn:443/'), isTrue);
      for (final url in [
        'https://sub.dlads.cn/video',
        'https://dlads.cn.example.com/video',
        'https://dlads.cn.example.com:443/video',
        'https://example.com/?return=https://dlads.cn/ad',
        'https://example.com/dlads.cn/ad',
        'https://dlads.cn@example.com/ad',
        'https://dlads.cn:443@example.com/ad',
        'https://dlads.cn:443.evil.example/ad',
        'https://challenges.cloudflare.com/turnstile/v0/api.js',
        'https://api.vparse.org/player',
        'https://player.example.com/movie.m3u8',
      ]) {
        expect(blocked(url), isFalse, reason: url);
      }
      for (final rule in rules) {
        expect(rule.action.type, ContentBlockerActionType.BLOCK);
      }
    },
  );
}

Widget _testPage() => const MaterialApp(
  home: CinemaWebviewPage(title: 'Test site', url: 'https://example.com/'),
);

_FakeWebViewPlatform _installFakeWebView() {
  final previous = InAppWebViewPlatform.instance;
  final platform = _FakeWebViewPlatform();
  InAppWebViewPlatform.instance = platform;
  addTearDown(() {
    if (previous != null) InAppWebViewPlatform.instance = previous;
  });
  return platform;
}

class _FakeWebViewPlatform extends InAppWebViewPlatform {
  late _FakeWebView view;
  final controller = _FakeWebViewController();

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) => view = _FakeWebView(params);
}

class _FakeWebView extends PlatformInAppWebViewWidget {
  _FakeWebView(super.params) : super.implementation();

  bool disposed = false;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      controller as T;

  @override
  void dispose() => disposed = true;
}

class _FakeWebViewController extends PlatformInAppWebViewController {
  _FakeWebViewController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'test'),
      );

  final suspensions = <bool>[];
  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {}
  @override
  Future<void> pauseAllMediaPlayback() async {}
  @override
  Future<void> setAllMediaPlaybackSuspended({required bool suspended}) async {
    suspensions.add(suspended);
  }

  @override
  Future<bool> canGoBack() async => false;
  @override
  Future<bool> canGoForward() async => false;
}
