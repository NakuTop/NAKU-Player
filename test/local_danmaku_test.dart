import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/player/local_danmaku_store.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/services/platform/dandan_credential_store.dart';
import 'package:kazumi/pages/player/controller/player_danmaku_controller.dart';
import 'package:kazumi/pages/settings/danmaku/danmaku_service_status_tile.dart';
import 'package:kazumi/utils/dandan_credentials.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'XML and JSON preserve text, time, mode and color; invalid records rejected',
    () {
      final xml = parseLocalDanmaku('''<?xml version="1.0"?><i>
<d p="2.5,1,25,16711680,0,0,0">hello &amp; world</d>
<d p="1,5,25,16777215,0,0,0">top</d>
<d p="NaN,1,25,1">invalid</d><d p="1,8,25,1">script ignored</d>
</i>''');
      expect(xml.map((e) => e.message), ['top', 'hello & world']);
      expect(xml.last.time, 2.5);
      expect(xml.last.color, const Color(0xffff0000));
      expect(xml.every((e) => e.source == '[Local]'), isTrue);
      final json = parseLocalDanmaku(
        '{"comments":[{"p":"3.5,4,255,[DanDan]","m":"字幕"}]}',
      );
      expect(json.single.type, 4);
      expect(json.single.color, const Color(0xff0000ff));
      for (final content in [
        '<!DOCTYPE x><i><d p="1,1,25,1">x</d></i>',
        '[]',
        '[{"p":"-1,1,255","m":"x"}]',
      ]) {
        expect(() => parseLocalDanmaku(content), throwsFormatException);
      }
    },
  );

  test(
    'import survives restart and plays offline without credentials or plugin',
    () async {
      final dir = await Directory.systemTemp.createTemp('naku-local-danmaku-');
      addTearDown(() => dir.delete(recursive: true));
      final store = LocalDanmakuStore(directory: dir);
      await store.save(
        309311,
        2,
        parseLocalDanmaku('[{"p":"2,1,255","m":"离线测试"}]'),
      );
      final reopened = LocalDanmakuStore(directory: dir);
      final controller = PlayerDanmakuController(
        isLocalPlayback: () => true,
        localStore: reopened,
        downloadController: _NoDownloads(),
      );
      final result = await controller.fetchDanmaku(
        309311,
        'unavailable-plugin',
        2,
      );
      expect(result.hasDanmakus, isTrue);
      expect(result.danmakus.single.message, '离线测试');
      expect(await reopened.read(309311, 1), isNull);
      await reopened.remove(309311, 2);
      expect(await reopened.read(309311, 2), isNull);
    },
  );

  testWidgets('settings save and remove credentials through Keychain channel', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    Map<String, String>? stored;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(DandanCredentialStore.channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'read') return stored;
      if (call.method == 'save') {
        stored = Map<String, String>.from(call.arguments as Map);
      }
      if (call.method == 'clear') stored = null;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        DandanCredentialStore.channel,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DanmakuServiceDialog())),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), ' fixture-id ');
    await tester.enterText(fields.at(1), ' fixture-secret ');
    expect(tester.widget<TextField>(fields.at(1)).obscureText, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(stored, {'id': 'fixture-id', 'secret': 'fixture-secret'});
    expect((await DandanCredentialStore.instance.read()).isConfigured, isTrue);
    await tester.tap(find.text('移除本机配置'));
    await tester.pumpAndSettle();
    expect(stored, isNull);
    expect(calls.map((c) => c.method), containsAll(['read', 'save', 'clear']));
    expect(tester.takeException(), isNull);
    await expectLater(
      DandanCredentialStore.instance.save(
        const DandanCredentials(id: 'bad\nid', secret: 'fixture'),
      ),
      throwsFormatException,
    );
    await tester.pumpWidget(const SizedBox());
  });
}

class _NoDownloads implements DownloadController {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Local import must avoid plugin and remote calls');
}
