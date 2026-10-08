import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_webview_page.dart';

void main() {
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
}
