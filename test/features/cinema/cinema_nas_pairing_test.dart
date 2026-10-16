import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_sync_sheet.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';
import 'cinema_sync_test.dart' show FakeClient;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late CinemaWatchTogether together;
  late FakeClient relay;
  final calls = <MethodCall>[];
  var authenticated = true;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('nas-pairing-');
    relay = FakeClient();
    together = CinemaWatchTogether(
      pairingFile: File('${dir.path}/pair.json'),
      clientFactory: (_, _) => relay,
    );
    calls.clear();
    authenticated = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CinemaNASClient.channel, (call) async {
          calls.add(call);
          if (!authenticated)
            throw PlatformException(code: 'expired', message: '请先登录 NAS');
          if (call.method == 'ensure') return {'namespace': 'a' * 64};
          expect(call.method, 'pairingIdentity');
          expect(call.arguments['peer'], 'bob');
          return {
            'namespace': 'a' * 64,
            'account': 'alice',
            'peerAccount': 'bob',
            'room': 'NP-${'c' * 32}',
            'username': 'N-${'a' * 14}',
            'peerUsername': 'N-${'b' * 14}',
          };
        });
  });
  tearDown(() async {
    together.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(CinemaNASClient.channel, null);
    await dir.delete(recursive: true);
  });
  test(
    'NAS pairing saves reciprocal account identity, validates login, and reconnects without room entry',
    () async {
      await together.pairNAS(' bob ');
      expect(together.isNASPaired, isTrue);
      expect(together.nasAccount, 'alice');
      expect(together.nasPeerAccount, 'bob');
      expect(together.session.connected, isTrue);
      expect(relay.tls, isTrue);
      expect(calls.map((c) => c.method), ['pairingIdentity', 'ensure']);
      final restored = CinemaWatchTogether(
        pairingFile: File('${dir.path}/pair.json'),
        clientFactory: (_, _) => FakeClient(),
      );
      addTearDown(restored.dispose);
      await restored.initialize();
      await Future<void>.delayed(Duration.zero);
      expect(restored.nasPeerAccount, 'bob');
      expect(calls.last.method, 'ensure');
      await together.pauseNASPairing();
    expect(relay.online, isFalse);
    await together.resumeNASPairing('b' * 64);
    expect(relay.online, isFalse);
    await together.resumeNASPairing('a' * 64);
    expect(relay.online, isTrue);
    await together.unpair();
      expect(together.isNASPaired, isFalse);
    },
  );
  test(
    'expired NAS login cannot create a pairing or connect to relay',
    () async {
      authenticated = false;
      await expectLater(
        together.pairNAS('bob'),
        throwsA(isA<PlatformException>()),
      );
      expect(together.isPaired, isFalse);
      expect(relay.online, isFalse);
    },
  );
  testWidgets(
    'NAS pairing dialog has one account field and no invite, QR, room or server inputs',
    (tester) async {
      await tester.runAsync(together.initialize);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCinemaSyncSheet(context, coordinator: together),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('open'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();
      expect(find.text('NAS 用户配对'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('对方的 NAS 账号'), findsOneWidget);
      expect(find.text('邀请链接与二维码'), findsNothing);
      expect(find.text('Syncplay 服务器'), findsNothing);
      await tester.enterText(find.byType(TextField), 'bob');
      await tester.runAsync(() async {
        await tester.tap(find.text('确认配对'));
        for (var i = 0; i < 100 && !together.session.connected; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('我的 NAS 账号：alice'), findsOneWidget);
      expect(find.text('配对账号：bob'), findsOneWidget);
      expect(find.text('等待对方填写你的账号并确认配对'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
    },
  );
}
