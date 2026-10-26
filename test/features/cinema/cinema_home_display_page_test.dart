import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_home_display_bridge.dart';
import 'package:kazumi/features/cinema/cinema_home_display_page.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_neon_decode.dart';
import 'package:kazumi/features/cinema/cinema_player_entrance.dart';
import 'package:kazumi/services/platform/desktop_window_controls.dart';

void main() {
  testWidgets(
    'return contracts real page pixels and keeps WebKit mounted until CRT finishes',
    (tester) async {
      final platform = _installFakeWebView();
      final png = await _previewPng(tester);
      final navigator = await _pushDisplay(tester, platform);
      platform.controller.screenshot = () async => png;
      await tester.tap(find.byTooltip('返回'));
      for (
        var attempt = 0;
        attempt < 30 && find.byType(CinemaPlayerEntrance).evaluate().isEmpty;
        attempt++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pump();
      final surface = tester.state<CinemaPlayerEntranceState>(
        find.byType(CinemaPlayerEntrance),
      );
      expect(surface.debugPhase, 'exiting');
      expect(platform.view.disposed, isFalse);
      expect(find.byKey(_nativeViewKey), findsNothing);
      expect(find.byKey(_nativeViewKey, skipOffstage: false), findsOneWidget);
      final raw = tester.widget<RawImage>(find.byType(RawImage));
      expect(raw.image!.width, 32);
      final bytes = await tester.runAsync(
        () => raw.image!.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      expect(bytes!.getUint8(0), 0x44);
      expect(bytes.getUint8(1), 0x77);
      expect(platform.controller.screenshotCalls, 1);
      unawaited(navigator.currentState!.maybePop());
      await tester.pump(const Duration(milliseconds: 200));
      expect(surface.debugPhase, 'exiting');
      expect(platform.view.disposed, isFalse);
      expect(platform.controller.screenshotCalls, 1);
      await tester.pump(const Duration(milliseconds: 301));
      await tester.pump();
      await tester.pump();
      expect(find.text('电影墙'), findsOneWidget);
      expect(find.byType(CinemaHomeDisplayPage), findsNothing);
      expect(platform.view.disposed, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final reduced in [false, true]) {
    testWidgets(
      'return remains usable with ${reduced ? 'reduced motion' : 'an unavailable native snapshot'}',
      (tester) async {
        final platform = _installFakeWebView();
        await _pushDisplay(tester, platform, reduced: reduced);
        platform.controller.screenshot = () async =>
            throw StateError('Snapshot unavailable');
        await tester.tap(find.byTooltip('返回'));
        await tester.pump();
        await tester.pump();
        await tester.pump();
        expect(find.text('电影墙'), findsOneWidget);
        expect(find.byType(CinemaPlayerEntrance), findsNothing);
        expect(platform.view.disposed, isTrue);
        expect(platform.controller.screenshotCalls, reduced ? 0 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('display fills the window behind transparent floating controls', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await _mountAuthorized(tester, platform);
    expect(find.byType(AppBar), findsNothing);
    expect(find.text('Home Display'), findsNothing);
    final view = tester.getRect(find.byKey(_nativeViewKey));
    final page = tester.getRect(find.byType(Scaffold));
    expect(view, page);
    expect(find.byTooltip('返回'), findsOneWidget);
    expect(find.byTooltip('刷新'), findsOneWidget);
    expect(find.byTooltip('全屏'), findsOneWidget);
    final controls = tester.getRect(
      find.byKey(const ValueKey('home-display-floating-controls')),
    );
    expect(controls.top, greaterThanOrEqualTo(28));
    expect(controls.bottom, lessThan(page.bottom));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'no native WebView is created before NAS authorization completes',
    (tester) async {
      final platform = _installFakeWebView();
      final authorization = Completer<Map<String, dynamic>>();
      final client = CinemaNASClient(
        invoke: (method, _) {
          expect(method, 'homeDisplayAuthorize');
          return authorization.future;
        },
      );

      await _mount(tester, client: client);
      await tester.pump(const Duration(seconds: 1));
      expect(platform.views, isEmpty);
      authorization.complete({'authenticated': true});
      await tester.pump();
      expect(platform.views, hasLength(1));
      expect(
        platform.view.params.initialUrlRequest?.url.toString(),
        cinemaHomeDisplayUrl,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('missing NAS session offers the login NAS action', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    var openedNAS = 0;
    await _mount(
      tester,
      client: CinemaNASClient(
        invoke: (_, _) async => {
          'authenticated': false,
          'reason': 'nas_login_required',
        },
      ),
      onOpenNAS: () async => openedNAS++,
    );

    expect(platform.views, isEmpty);
    expect(find.text('登录 NAS'), findsOneWidget);
    await tester.tap(find.text('登录 NAS'));
    await tester.pump();
    expect(openedNAS, 1);
    expect(platform.views, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'network progress 100 and load stop alone do not finish rendering',
    (tester) async {
      final platform = _installFakeWebView();
      await _mountAuthorized(tester, platform);
      platform.view.params.onProgressChanged!(platform.controller, 100);
      platform.view.params.onLoadStop!(
        platform.controller,
        WebUri(cinemaHomeDisplayUrl),
      );
      await tester.pump(const Duration(seconds: 2));

      expect(_decoding(tester).loading, isTrue);
      expect(platform.view.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('display ready requires WebGL and authenticated API evidence', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await _mountAuthorized(tester, platform);
    for (final invalid in <Map<String, dynamic>>[
      {..._readyState, 'surface': 'page'},
      {..._readyState, 'firstDrawObserved': false},
      {..._readyState, 'apiObserved': false},
      {..._readyState, 'apiStatus': 500},
      {..._readyState, 'href': 'https://between-us-home.pages.dev/settings'},
    ]) {
      platform.controller.emit(invalid);
      await tester.pump(const Duration(milliseconds: 600));
      expect(_decoding(tester).loading, isTrue, reason: '$invalid');
    }

    expect(platform.controller.emit(_readyState), isTrue);
    await tester.pump();
    await tester.pump(); // Apply the native snapshot future's state change.
    expect(_decoding(tester).loading, isFalse);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(CinemaNeonDecode), findsNothing);
    expect(find.byKey(_nativeViewKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'preview readbacks follow rendering milestones, not elapsed time',
    (tester) async {
      final platform = _installFakeWebView();
      await _mountAuthorized(tester, platform);
      platform.view.params.onPageCommitVisible!(
        platform.controller,
        WebUri(cinemaHomeDisplayUrl),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(platform.controller.screenshotCalls, 1);
      for (var update = 0; update < 20; update++) {
        platform.view.params.onLoadStop!(
          platform.controller,
          WebUri(cinemaHomeDisplayUrl),
        );
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(
        platform.controller.screenshotCalls,
        1,
        reason:
            'Repeated network callbacks do not trigger periodic GPU readbacks.',
      );
      platform.controller.emit({..._readyState, 'phase': 'loading'});
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(platform.controller.screenshotCalls, 2);
      for (var frame = 0; frame < 120; frame++) {
        platform.controller.emit({..._readyState, 'phase': 'loading'});
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(
        platform.controller.screenshotCalls,
        2,
        reason:
            'The front-end animation does not sample the native page per frame.',
      );
      expect(_decoding(tester).loading, isTrue);
      platform.controller.emit(_readyState);
      await tester.pump();
      await tester.pump();
      expect(platform.controller.screenshotCalls, 3);
      await tester.pump(const Duration(seconds: 20));
      expect(platform.controller.screenshotCalls, 3);
      expect(find.byType(CinemaNeonDecode), findsNothing);
      expect(platform.view.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'before the first real snapshot the native page stays visible without a fake field',
    (tester) async {
      final platform = _installFakeWebView();
      await _mountAuthorized(tester, platform);
      final screenshot = Completer<Uint8List?>();
      platform.controller.screenshot = () => screenshot.future;
      platform.view.params.onPageCommitVisible!(
        platform.controller,
        WebUri(cinemaHomeDisplayUrl),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final state = tester.state<CinemaNeonDecodeState>(
        find.byType(CinemaNeonDecode),
      );
      final before = state.debugSnapshot.elapsed;
      for (var frame = 0; frame < 30; frame++) {
        await tester.pump(const Duration(microseconds: 8333));
      }
      expect(state.debugSnapshot.elapsed, before);
      expect(state.debugSnapshot.running, isFalse);
      expect(state.widget.rasterSnapshot, isNull);
      expect(state.widget.child, isA<SizedBox>());
      expect(platform.controller.screenshotCalls, 1);
      expect(_decoding(tester).loading, isTrue);
      screenshot.complete(null);
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('API 401 revokes and disposes even after a pending screenshot', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await _mountAuthorized(tester, platform);
    final screenshot = Completer<Uint8List?>();
    platform.controller.screenshot = () => screenshot.future;
    platform.controller.emit(_readyState);
    await tester.pump();
    expect(platform.controller.screenshotCalls, 1);

    platform.controller.emit({
      ..._readyState,
      'phase': 'loading',
      'apiStatus': 401,
    });
    await tester.pump();
    expect(platform.view.disposed, isTrue);
    expect(find.byKey(_nativeViewKey), findsNothing);
    expect(find.text('展示权限已失效，请重新验证 NAS'), findsOneWidget);

    screenshot.complete(null);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('展示权限已失效，请重新验证 NAS'), findsOneWidget);
    expect(find.byKey(_nativeViewKey), findsNothing);
    expect(find.byType(CinemaNeonDecode), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden display pauses the 40 second loading timeout', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await _mountAuthorized(tester, platform);
    final previous = platform.view;
    final controls = _controls(tester);
    controls.setHidden(true);
    await tester.pump();
    await tester.pump(const Duration(seconds: 45));
    expect(platform.view.disposed, isFalse);
    expect(_decoding(tester).loading, isTrue);
    expect(find.textContaining('页面仍未准备好'), findsNothing);

    controls.setHidden(false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(platform.views, hasLength(2));
    expect(previous.disposed, isTrue);
    expect(platform.view.disposed, isFalse);
    expect(find.textContaining('页面仍未准备好'), findsNothing);
    expect(
      previous.controller.scripts.any(
        (source) => source.contains('setVisible(false)'),
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'fullscreen occlusion pauses loading and retains the native page',
    (tester) async {
      final platform = _installFakeWebView();
      var authorizations = 0;
      await _mount(
        tester,
        client: CinemaNASClient(
          invoke: (_, _) async {
            ++authorizations;
            return {'authenticated': true};
          },
        ),
      );
      final original = platform.view;
      original.params.onWebViewCreated!(original.controller);
      final lifecycle =
          tester.state(find.byType(CinemaHomeDisplayPage))
              as WidgetsBindingObserver;
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await tester.pump(const Duration(seconds: 45));
      expect(original.disposed, isFalse);
      expect(find.textContaining('页面仍未准备好'), findsNothing);
      lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(authorizations, 1);
      expect(platform.views, hasLength(1));
      expect(original.disposed, isFalse);
      expect(
        original.controller.scripts,
        contains('window.__nakuHomeDisplay?.setVisible(true)'),
      );
      original.controller.emit(_readyState);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(CinemaNeonDecode), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('initial native hidden state prevents creating a document', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    final controls = _FakeWindowControls()..hidden = true;
    await _mount(
      tester,
      client: CinemaNASClient(invoke: (_, _) async => {'authenticated': true}),
      windowControls: controls,
    );
    expect(platform.views, isEmpty);
    controls.setHidden(false);
    await tester.pump();
    expect(platform.views, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(controls.callbacks, isEmpty);
  });

  testWidgets(
    'expired hidden document 401 cannot dispose the gated resume replacement',
    (tester) async {
      final platform = _installFakeWebView();
      final resume = Completer<Map<String, dynamic>>();
      var calls = 0;
      await _mount(
        tester,
        client: CinemaNASClient(
          invoke: (_, _) => ++calls == 1
              ? Future.value({'authenticated': true})
              : resume.future,
        ),
      );
      final previous = platform.view;
      previous.params.onWebViewCreated!(previous.controller);
      previous.controller.emit(_readyState);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      final controls = _controls(tester);
      controls.setHidden(true);
      await tester.pump(const Duration(minutes: 6));
      final expired = {..._readyState, 'phase': 'loading', 'apiStatus': 401};
      expect(previous.controller.emit(expired), isFalse);
      expect(find.text('展示权限已失效，请重新验证 NAS'), findsNothing);

      controls.setHidden(false);
      await tester.pump();
      expect(calls, 2);
      expect(previous.disposed, isTrue);
      expect(platform.views, hasLength(1));
      expect(find.byKey(_nativeViewKey), findsNothing);
      expect(previous.controller.emit(expired), isFalse);
      expect(previous.controller.emit(_readyState), isFalse);
      expect(_decoding(tester).loading, isTrue);

      resume.complete({'authenticated': true});
      await tester.pump();
      expect(platform.views, hasLength(2));
      final replacement = platform.view;
      replacement.params.onWebViewCreated!(replacement.controller);
      expect(previous.controller.emit(expired), isFalse);
      expect(replacement.disposed, isFalse);
      replacement.controller.emit(_readyState);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(_nativeViewKey), findsOneWidget);
      expect(find.byType(CinemaNeonDecode), findsNothing);
      expect(find.text('展示权限已失效，请重新验证 NAS'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed resume keeps the retired document closed', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    final resume = Completer<Map<String, dynamic>>();
    var calls = 0;
    await _mount(
      tester,
      client: CinemaNASClient(
        invoke: (_, _) => ++calls == 1
            ? Future.value({'authenticated': true})
            : resume.future,
      ),
    );
    final previous = platform.view;
    previous.params.onWebViewCreated!(previous.controller);
    final controls = _controls(tester);
    controls.setHidden(true);
    controls.setHidden(false);
    await tester.pump();
    resume.complete({'authenticated': false, 'reason': 'nas_login_required'});
    await tester.pump();
    expect(previous.controller.emit(_readyState), isFalse);
    expect(previous.disposed, isTrue);
    expect(platform.views, hasLength(1));
    expect(find.byKey(_nativeViewKey), findsNothing);
    expect(find.text('请先登录 NAS'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('authorization completed while hidden creates no document', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    final initial = Completer<Map<String, dynamic>>();
    final resume = Completer<Map<String, dynamic>>();
    var calls = 0;
    await _mount(
      tester,
      client: CinemaNASClient(
        invoke: (_, _) => ++calls == 1 ? initial.future : resume.future,
      ),
    );
    final controls = _controls(tester);
    controls.setHidden(true);
    initial.complete({'authenticated': true});
    await tester.pump();
    expect(platform.views, isEmpty);
    controls.setHidden(false);
    await tester.pump();
    expect(calls, 2);
    expect(platform.views, isEmpty);
    resume.complete({'authenticated': true});
    await tester.pump();
    expect(platform.views, hasLength(1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dispose ignores a late successful NAS authorization', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    final authorization = Completer<Map<String, dynamic>>();
    await _mount(
      tester,
      client: CinemaNASClient(invoke: (_, _) => authorization.future),
    );
    await tester.pumpWidget(const SizedBox());
    authorization.complete({'authenticated': true});
    await tester.pump();
    expect(platform.views, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native quality keeps cache, images and the native user agent', (
    tester,
  ) async {
    final platform = _installFakeWebView();
    await _mountAuthorized(tester, platform);
    final settings = platform.view.params.initialSettings!;
    expect(settings.javaScriptEnabled, isTrue);
    expect(settings.cacheEnabled, isTrue);
    expect(settings.contentBlockers ?? <ContentBlocker>[], isEmpty);
    expect(settings.userAgent, anyOf(isNull, isEmpty));
    expect(settings.applicationNameForUserAgent, anyOf(isNull, isEmpty));
    expect(settings.pageZoom, 1);
    final scripts = platform.view.params.initialUserScripts!;
    expect(scripts, hasLength(1));
    expect(
      scripts.single.injectionTime,
      UserScriptInjectionTime.AT_DOCUMENT_START,
    );
    expect(scripts.single.forMainFrameOnly, isTrue);
    expect(scripts.single.source, cinemaHomeDisplayBridgeSource);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'navigation permits only the exact HTTPS display origin and entry paths',
    () {
      for (final url in [
        cinemaHomeDisplayUrl,
        'https://between-us-home.pages.dev:443/display',
        'https://between-us-home.pages.dev/login?return_to=%2Fdisplay',
      ]) {
        expect(cinemaAllowsHomeDisplayNavigation(url), isTrue, reason: url);
      }
      for (final url in <String?>[
        null,
        '',
        'http://between-us-home.pages.dev/display',
        'https://between-us-home.pages.dev:444/display',
        'https://between-us-home.pages.dev.evil.example/display',
        'https://user:password@between-us-home.pages.dev/display',
        'https://between-us-home.pages.dev/settings',
        'https://between-us-home.pages.dev/travel',
        'https://between-us-home.pages.dev/',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'about:blank',
      ]) {
        expect(cinemaAllowsHomeDisplayNavigation(url), isFalse, reason: '$url');
      }
      expect(
        cinemaAllowsHomeDisplayNavigation('about:blank', mainFrame: false),
        isTrue,
      );
      expect(
        cinemaAllowsHomeDisplayNavigation(
          'https://between-us-home.pages.dev/settings',
          mainFrame: false,
        ),
        isFalse,
      );
    },
  );
}

const _nativeViewKey = ValueKey('home-display-native-webview');

Future<Uint8List> _previewPng(WidgetTester tester) async =>
    (await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xFF447766), BlendMode.src);
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return Uint8List.fromList(data!.buffer.asUint8List());
      } finally {
        image.dispose();
        picture.dispose();
      }
    }))!;

Future<GlobalKey<NavigatorState>> _pushDisplay(
  WidgetTester tester,
  _FakeWebViewPlatform platform, {
  bool reduced = false,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('电影墙')),
    ),
  );
  unawaited(
    navigator.currentState!.push(
      PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
        pageBuilder: (_, _, _) => MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: CinemaHomeDisplayPage(
            client: CinemaNASClient(
              invoke: (_, _) async => {'authenticated': true},
            ),
            windowControls: _FakeWindowControls(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  platform.view.params.onWebViewCreated!(platform.controller);
  await tester.pump();
  return navigator;
}

const _readyState = <String, dynamic>{
  'href': cinemaHomeDisplayUrl,
  'phase': 'ready',
  'surface': 'display',
  'firstDrawObserved': true,
  'apiObserved': true,
  'apiStatus': 200,
};

CinemaNeonDecode _decoding(WidgetTester tester) =>
    tester.widget<CinemaNeonDecode>(find.byType(CinemaNeonDecode));

Future<void> _mount(
  WidgetTester tester, {
  required CinemaNASClient client,
  Future<void> Function()? onOpenNAS,
  _FakeWindowControls? windowControls,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CinemaHomeDisplayPage(
        client: client,
        onOpenNAS: onOpenNAS,
        windowControls: windowControls ?? _FakeWindowControls(),
      ),
    ),
  );
  await tester.pump();
}

_FakeWindowControls _controls(WidgetTester tester) =>
    tester
            .widget<CinemaHomeDisplayPage>(find.byType(CinemaHomeDisplayPage))
            .windowControls!
        as _FakeWindowControls;

class _FakeWindowControls extends DesktopWindowControls {
  _FakeWindowControls() : super(supported: true);
  final callbacks = <Object, WindowVisibilityCallback>{};
  @override
  Future<void> initialize() async {}
  @override
  Future<void> refreshVisibility() async {}
  @override
  void register(Object owner, WindowVisibilityCallback callback) {
    callbacks[owner] = callback;
  }

  @override
  void unregister(Object owner) => callbacks.remove(owner);
  void setHidden(bool value) {
    hidden = value;
    for (final callback in callbacks.values.toList()) {
      unawaited(callback(value));
    }
  }
}

Future<void> _mountAuthorized(
  WidgetTester tester,
  _FakeWebViewPlatform platform,
) async {
  await _mount(
    tester,
    client: CinemaNASClient(
      invoke: (method, _) async {
        expect(method, 'homeDisplayAuthorize');
        return {'authenticated': true};
      },
    ),
  );
  expect(platform.views, hasLength(1));
  platform.view.params.onWebViewCreated!(platform.controller);
  await tester.pump();
}

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
  final views = <_FakeWebView>[];
  _FakeWebView get view => views.last;
  _FakeWebViewController get controller => view.controller;

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = _FakeWebView(params);
    views.add(view);
    return view;
  }
}

class _FakeWebView extends PlatformInAppWebViewWidget {
  _FakeWebView(super.params) : super.implementation();
  final controller = _FakeWebViewController();
  bool disposed = false;

  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: _nativeViewKey);

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      controller as T;

  @override
  void dispose() => disposed = true;
}

class _FakeWebViewController extends PlatformInAppWebViewController {
  _FakeWebViewController()
    : super.implementation(
        const PlatformInAppWebViewControllerCreationParams(id: 'home-display'),
      );
  final handlers = <String, JavaScriptHandlerCallback>{};
  final scripts = <String>[];
  Future<Uint8List?> Function()? screenshot;
  int screenshotCalls = 0;

  dynamic emit(Map<String, dynamic> state) =>
      handlers[cinemaHomeDisplayBridgeHandlerName]!([state]);

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) => handlers[handlerName] = callback;

  @override
  Future<Uint8List?> takeScreenshot({
    ScreenshotConfiguration? screenshotConfiguration,
  }) async {
    screenshotCalls++;
    return screenshot == null ? null : await screenshot!();
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    return null;
  }
}
