import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_page.dart';
import 'package:kazumi/services/platform/naku_device.dart';

class FakeNAS extends CinemaNASClient {
  final calls = <(String, Map<String, dynamic>?)>[];
  bool reject = false, saved = false, collection = false;
  String qrState = "scanned";
  int collectionSize = 1, collectionType = 2;
  bool collectionFails = false;
  Completer<Map<String, dynamic>>? delayedCollection;
  int logouts = 0;
  bool active = false, libraryFails = false;
  Completer<Map<String, dynamic>>? delayedLogin, delayedCatalog;
  Map<String, dynamic>? videoInfo;
  String savedAddress = 'https://nas.test';
  Map<String, dynamic> connectionInfo = {};
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? args,
  ]) async {
    calls.add((method, args));
    if (method == 'currentSession') {
      return active
          ? {
              'name': 'Test NAS',
              'namespace': List.filled(64, 'a').join(),
              'address': savedAddress,
              'username': 'viewer',
            }
          : {};
    }
    if (method == 'savedLogin') {
      return saved ? {'address': savedAddress, 'username': 'saved-user'} : {};
    }
    if (method == 'forget') {
      logouts++;
      active = false;
      saved = false;
      return {};
    }
    if (method == 'connectionInfo') return connectionInfo;
    if (method == 'login' || method == 'restore' || method == 'restoreAt') {
      if (reject) {
        throw PlatformException(code: 'nas', message: '账号或密码不正确，请重新输入。');
      }
      active = true;
      if (delayedLogin != null) return delayedLogin!.future;
      return {'name': 'Test NAS', 'namespace': List.filled(64, 'a').join()};
    }
    if (method == 'qrCreate') return {'url': 'https://qr.ugnas.test/fixture'};
    if (method == 'qrPoll') return {'state': qrState};
    if (method == 'collection') {
      if (delayedCollection != null) return delayedCollection!.future;
      if (collectionFails) throw PlatformException(code: 'nas');
      return {
        'total_num': collectionSize,
        'video_arr': [
          for (var i = 0; i < collectionSize; i++)
            {
              'ug_video_info_id': 42 + i,
              'media_lib_set_id': 2,
              'name': '剧集第一季',
              'type': collectionType,
            },
        ],
      };
    }
    if (method == 'details') {
      return {
        if (videoInfo != null) 'video_info': videoInfo,
        'tv_info': [
          {
            'episode': 1,
            'ep_name': '开篇',
            'file_info': [
              {'path': '/volume1/series/e1.mkv'},
            ],
          },
        ],
      };
    }
    if (method == 'libraries') {
      if (libraryFails) {
        throw PlatformException(code: 'network', message: '临时连接失败');
      }
      return {
        'media_lib_set_arr': [
          {'media_lib_set_id': 2, 'media_name': '收藏', 'can_view': true},
          {'media_lib_set_id': 3, 'media_name': '无权限', 'can_view': false},
        ],
      };
    }
    if (method == 'catalog') {
      if (delayedCatalog != null) return delayedCatalog!.future;
      return {
        'video_arr': [
          {
            'ug_video_info_id': args?['page'],
            'name': '测试影片 ${args?['page']}',
            'type': collection ? 3 : 1,
            if (collection) 'collection_id': 'collection-identity',
            'year': collection ? 0 : 2026,
            'media_lib_set_id': 2,
          },
        ],
        'total_num': 2,
        'is_last_page': args?['page'] == 2,
      };
    }
    return {};
  }

  @override
  Future<String> asset(
    Map<String, dynamic> row,
    String path, {
    bool poster = false,
  }) async => '';
  @override
  Future<void> logout() async {
    active = false;
    logouts++;
  }
}

void main() {
  testWidgets(
    'TV opens QR automatically and has no account password or address form',
    (tester) async {
      NakuDevice.isTV = true;
      addTearDown(() => NakuDevice.isTV = false);
      final client = FakeNAS();
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(find.text('扫码登录 NAS'), findsWidgets);
      expect(find.byType(TextField), findsNothing);
      expect(client.calls.where((c) => c.$1 == 'qrCreate'), hasLength(1));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('大屏观看你的私人影院'), findsOneWidget);
      expect(find.text('NAS 密码'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'reentry renders cached NAS library immediately during slow background refresh',
    (tester) async {
      final client = FakeNAS()..saved = true;
      final cache = CinemaNASPageCache();
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaNASPage(client: client, cache: cache),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      client.delayedCatalog = Completer<Map<String, dynamic>>();
      final before = client.calls.length;
      await tester.pumpWidget(
        MaterialApp(
          home: CinemaNASPage(client: client, cache: cache),
        ),
      );
      await tester.pump();
      expect(find.text('Test NAS · 影视中心'), findsOneWidget);
      expect(find.text('测试影片 1'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('连接影视中心'), findsNothing);
      expect(
        client.calls
            .skip(before)
            .where(
              (c) => [
                'restore',
                'login',
                'libraries',
                'savedLogin',
              ].contains(c.$1),
            ),
        isEmpty,
      );
      expect(
        client.calls.lastWhere((e) => e.$1 == 'catalog').$2?['library'],
        2,
      );
      await tester.pumpWidget(const SizedBox());
      client.delayedCatalog!.complete({'video_arr': [], 'total_num': 0});
      await tester.pumpAndSettle();
    },
  );

  testWidgets('expired process session invalidates cached NAS library', (
    tester,
  ) async {
    final client = FakeNAS()..active = true;
    final cache = CinemaNASPageCache();
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaNASPage(client: client, cache: cache),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    client.active = false;
    await tester.pumpWidget(
      MaterialApp(
        home: CinemaNASPage(client: client, cache: cache),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接影视中心'), findsOneWidget);
    expect(find.text('测试影片 1'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'reopening NAS page reuses process session without saved credentials',
    (tester) async {
      final client = FakeNAS()..active = true;
      for (var i = 0; i < 3; i++) {
        await tester.pumpWidget(
          MaterialApp(home: CinemaNASPage(client: client)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Test NAS · 影视中心'), findsOneWidget);
        expect(find.text('连接影视中心'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
      expect(client.logouts, 0);
      expect(
        client.calls.where(
          (c) => ['savedLogin', 'restore', 'login'].contains(c.$1),
        ),
        isEmpty,
      );
    },
  );

  testWidgets('temporary library failure keeps native login for reentry', (
    tester,
  ) async {
    final client = FakeNAS()
      ..active = true
      ..libraryFails = true;
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(client.active, isTrue);
    expect(client.logouts, 0);
    await tester.pumpWidget(const SizedBox());
    client.libraryFails = false;
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('Test NAS · 影视中心'), findsOneWidget);
    expect(
      client.calls.where((c) => c.$1 == 'login' || c.$1 == 'restore'),
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'leaving during login completion does not log out application session',
    (tester) async {
      final client = FakeNAS()
        ..saved = true
        ..delayedLogin = Completer<Map<String, dynamic>>();
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      client.delayedLogin!.complete({
        'name': 'Test NAS',
        'namespace': List.filled(64, 'a').join(),
      });
      await tester.pumpAndSettle();
      expect(client.active, isTrue);
      expect(client.logouts, 0);
    },
  );

  test(
    'movie versions and NAS episode files preserve paths and remove duplicates',
    () {
      final files = nasFiles({
        'file_information': [
          {'name': '4K', 'path': '/movies/test.mkv'},
          {'name': 'duplicate', 'path': '/movies/test.mkv'},
          {'name': 'broken'},
        ],
        'tv_info': [
          {
            'episode': 2,
            'ep_name': '第二集',
            'file_info': [
              {'path': '/series/e2.mkv'},
            ],
          },
        ],
      });
      expect(files.map((f) => f.path), ['/movies/test.mkv', '/series/e2.mkv']);
      expect(files[1].label, contains('第 2 集'));
      expect(nasFiles({}), isEmpty);
    },
  );

  testWidgets('catalog reload updates actual LAN route and automatic status', (
    tester,
  ) async {
    final client = FakeNAS()..active = true;
    client.connectionInfo = {'currentAddress': 'https://fixture.cn21.ug.link'};
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.textContaining('自动连接 · 远程 UGlink'), findsOneWidget);
    client.connectionInfo = {
      'currentAddress': 'http://192.168.1.10:9999',
      'autoRouteStatus': '已自动切换局域网，同一设备与账号验证通过',
    };
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();
    expect(find.textContaining('自动连接 · 局域网直连'), findsOneWidget);
    expect(find.text('已自动切换局域网，同一设备与账号验证通过'), findsOneWidget);
    expect(client.calls.where((e) => e.$1 == 'login'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'requires login, filters libraries and honours server pagination',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = FakeNAS();
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(client.calls.map((e) => e.$1), ['currentSession', 'savedLogin']);
      expect(find.text('记住账号并自动登录'), findsNothing);
      expect(find.textContaining('勾选后'), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, isEmpty);
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, isEmpty);
      expect(tester.widget<TextField>(fields.at(2)).controller!.text, isEmpty);
      await tester.enterText(fields.at(0), 'my-nas-alias');
      await tester.enterText(fields.at(1), 'viewer');
      await tester.enterText(fields.at(2), 'password');
      await tester.ensureVisible(find.text('连接影视中心'));
      await tester.tap(find.text('连接影视中心'));
      await tester.pumpAndSettle();
      expect(
        client.calls.firstWhere((c) => c.$1 == 'login').$2?['remember'],
        isTrue,
      );
      expect(find.text('Test NAS · 影视中心'), findsOneWidget);
      expect(find.text('无权限'), findsNothing);
      expect(find.text('测试影片 1'), findsOneWidget);
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(
        client.calls.lastWhere((e) => e.$1 == 'catalog').$2?['library'],
        2,
      );
      await tester.scrollUntilVisible(
        find.text('加载更多'),
        400,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(client.calls.lastWhere((e) => e.$1 == 'catalog').$2?['page'], 2);
      expect(find.text('加载更多'), findsNothing);
      await tester.tap(find.text('退出并忘记账号'));
      await tester.pumpAndSettle();
      expect(find.text('连接影视中心'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        isEmpty,
      );
      expect(client.logouts, 1);
      await tester.pumpWidget(const SizedBox());
      expect(client.logouts, 1);
    },
  );

  testWidgets('rejected login clears password and does not load a catalogue', (
    tester,
  ) async {
    final client = FakeNAS()..reject = true;
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'viewer');
    await tester.enterText(find.byType(TextField).at(2), 'wrong');
    await tester.ensureVisible(find.text('连接影视中心'));
    await tester.tap(find.text('连接影视中心'));
    await tester.pumpAndSettle();
    expect(find.text('账号或密码不正确，请重新输入。'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
      isEmpty,
    );
    expect(client.calls.map((e) => e.$1), [
      'currentSession',
      'savedLogin',
      'login',
    ]);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'saved credentials restore natively without sending a password to Flutter',
    (tester) async {
      final client = FakeNAS()..saved = true;
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(find.text('Test NAS · 影视中心'), findsOneWidget);
      expect(client.calls.map((e) => e.$1), [
        'currentSession',
        'savedLogin',
        'restore',
        'autoConnect',
        'libraries',
        'connectionInfo',
        'catalog',
        'connectionInfo',
      ]);
      expect(
        client.calls.where((e) => e.$2?.containsKey('password') ?? false),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'collection opens its season identity instead of sending movie id zero',
    (tester) async {
      final client = FakeNAS()
        ..saved = true
        ..collection = true;
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('测试影片 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试影片 1'));
      await tester.pumpAndSettle();
      expect(client.calls.where((e) => e.$1 == 'collection'), isNotEmpty);
      expect(client.calls.where((e) => e.$1 == 'details'), isEmpty);
      await tester.tap(find.text('剧集第一季'));
      await tester.pumpAndSettle();
      expect(client.calls.last.$1, 'details');
      expect(client.calls.last.$2?['id'], 42);
      expect(find.byTooltip('下载到 Naku'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final entry in [(1, 2, '2部电影'), (2, 10, '10季')]) {
    testWidgets('collection cover shows ${entry.$3}', (tester) async {
      final client = FakeNAS()
        ..saved = true
        ..collection = true
        ..collectionType = entry.$1
        ..collectionSize = entry.$2;
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(find.text(entry.$3), findsOneWidget);
      expect(find.text('合集'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('failed collection count stays neutral and retries on refresh', (
    tester,
  ) async {
    final client = FakeNAS()
      ..saved = true
      ..collection = true
      ..collectionFails = true;
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('合集'), findsOneWidget);
    client.collectionFails = false;
    await tester.tap(find.byTooltip('刷新'));
    await tester.pumpAndSettle();
    expect(find.text('1季'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('late collection count cannot restore logged out cards', (
    tester,
  ) async {
    final pending = Completer<Map<String, dynamic>>();
    final client = FakeNAS()
      ..saved = true
      ..collection = true
      ..delayedCollection = pending;
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('合集'), findsOneWidget);
    await tester.tap(find.text('退出并忘记账号'));
    await tester.pumpAndSettle();
    pending.complete({
      'video_arr': [
        {'type': 1},
        {'type': 1},
      ],
      'total_num': 2,
    });
    await tester.pumpAndSettle();
    expect(find.text('2部电影'), findsNothing);
    expect(find.text('测试影片 1'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'QR polling shows scanned and expired states and cancels when closed',
    (tester) async {
      final client = FakeNAS();
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('使用绿联云 App 扫码登录'));
      await tester.tap(find.text('使用绿联云 App 扫码登录'));
      await tester.pumpAndSettle();
      expect(find.text('扫码登录 NAS'), findsOneWidget);
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('已扫码，请在手机上确认'), findsOneWidget);
      client.qrState = 'expired';
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.text('二维码已过期，请刷新'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(client.calls.last.$1, 'qrCancel');
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('NAS detail dialog retains full detail metadata', (tester) async {
    final client = FakeNAS()
      ..saved = true
      ..videoInfo = {
        'name': '详情影片名',
        'year': 1994,
        'introduction': '详情接口返回的影片简介',
        'douban_id': 1393859,
      };
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('测试影片 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试影片 1'));
    await tester.pumpAndSettle();
    expect(find.text('详情影片名'), findsOneWidget);
    expect(find.text('详情接口返回的影片简介'), findsOneWidget);
    expect(find.text('1994  ·  NAS 影视中心'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'LAN mode classifies private explicit hosts without treating aliases as LAN',
    () {
      for (final address in [
        'http://192.168.1.2:9999',
        'https://10.0.0.2',
        'http://172.31.2.3',
        'https://nas.local',
        'http://mynas:9999',
        'http://localhost',
      ]) {
        expect(isNASLANAddress(address), isTrue, reason: address);
      }
      for (final address in [
        'my-nas-alias',
        'https://my-nas.example.ug.link',
        'https://172.32.2.3',
        'http://8.8.8.8',
        'https://999.168.1.2',
      ]) {
        expect(isNASLANAddress(address), isFalse, reason: address);
      }
    },
  );

  testWidgets(
    'NAS connection form defaults to automatic selection without manual mode buttons',
    (tester) async {
      final client = FakeNAS();
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(find.text('自动选择连接'), findsOneWidget);
      expect(find.byType(SegmentedButton<String>), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'my-remote');
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'my-remote',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'switching uses saved credentials only through verified restoreAt',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = FakeNAS()
        ..saved = true
        ..connectionInfo = {
          'lanCandidates': ['http://192.168.1.5:9999'],
          'currentAddress': 'https://nas.test',
        };
      await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
      await tester.pumpAndSettle();
      expect(find.text('自动连接 · 远程 UGlink · https://nas.test'), findsOneWidget);
      await tester.tap(find.text('连接设置'));
      await tester.pumpAndSettle();
      expect(client.saved, isTrue);
      expect(client.calls.where((c) => c.$1 == 'forget'), isEmpty);
      await tester.enterText(
        find.byType(TextField).first,
        'http://192.168.1.5:9999',
      );
      client.connectionInfo = {'currentAddress': 'http://192.168.1.5:9999'};
      await tester.tap(find.text('连接影视中心'));
      await tester.pumpAndSettle();
      final restore = client.calls.where((c) => c.$1 == 'restoreAt').single.$2!;
      expect(restore['address'], 'http://192.168.1.5:9999');
      expect(restore['namespace'], List.filled(64, 'a').join());
      expect(restore.containsKey('password'), isFalse);
      expect(
        find.text('自动连接 · 局域网直连 · http://192.168.1.5:9999'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('restored LAN address selects actual LAN mode', (tester) async {
    final client = FakeNAS()
      ..saved = true
      ..savedAddress = 'http://192.168.1.7:9999';
    await tester.pumpWidget(MaterialApp(home: CinemaNASPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('自动连接 · 局域网直连 · http://192.168.1.7:9999'), findsOneWidget);
    expect(client.calls.where((c) => c.$1 == 'restore').length, 1);
    expect(client.calls.where((c) => c.$1 == 'restoreAt'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
