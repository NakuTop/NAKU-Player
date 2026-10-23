import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/logvar_credential_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File pending;
  late LogvarCredentialStore store;
  Map<String, String>? saved;
  int saves = 0, clears = 0;
  bool blocked = false, rejectSave = false;
  Completer<void>? clearGate;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const fixture = {
    'version': 1,
    'baseUrl': 'http://192.168.1.10:9321',
    'token': 'fixture-token-12345',
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('naku-credential-test-');
    pending = File('${directory.path}/provision.json');
    store = LogvarCredentialStore(provisioningFile: () async => pending);
    saved = null;
    saves = clears = 0;
    blocked = rejectSave = false;
    clearGate = null;
    messenger.setMockMethodCallHandler(LogvarCredentialStore.channel, (
      call,
    ) async {
      switch (call.method) {
        case 'read':
          if (blocked) {
            throw PlatformException(
              code: 'keychain',
              message: 'fixture old signature',
            );
          }
          return saved;
        case 'clear':
          clears++;
          if (clears == 1) await clearGate?.future;
          saved = null;
          blocked = false;
          return null;
        case 'save':
          saves++;
          if (rejectSave) {
            throw PlatformException(
              code: 'keychain',
              message: 'fixture save failure',
            );
          }
          saved = Map<String, String>.from(call.arguments as Map);
          return null;
      }
      throw MissingPluginException();
    });
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(LogvarCredentialStore.channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'local provisioning repairs an unreadable old item and removes the file after verified save',
    () async {
      blocked = true;
      await pending.writeAsString(jsonEncode(fixture));
      final config = await store.read();
      expect(config?.token, fixture['token']);
      expect(config?.baseUrl.origin, fixture['baseUrl']);
      expect(clears, 1);
      expect(saves, 1);
      expect(await pending.exists(), false);
      expect((await store.read())?.token, fixture['token']);
      expect(saves, 1);
    },
  );

  test(
    'a valid existing manual configuration wins over a pending file',
    () async {
      saved = {'id': 'https://captions.example', 'secret': 'manual-token-6789'};
      await pending.writeAsString(jsonEncode(fixture));
      expect((await store.read())?.token, 'manual-token-6789');
      expect(clears, 0);
      expect(saves, 0);
      expect(await pending.exists(), false);
    },
  );

  test(
    'invalid provisioning never deletes or replaces a Keychain item',
    () async {
      await pending.writeAsString(
        jsonEncode({...fixture, 'baseUrl': 'http://public.example'}),
      );
      await expectLater(store.read(), throwsFormatException);
      expect(clears, 0);
      expect(saves, 0);
      expect(await pending.exists(), true);
    },
  );

  test(
    'a failed save keeps the private pending configuration available for retry',
    () async {
      rejectSave = true;
      await pending.writeAsString(jsonEncode(fixture));
      await expectLater(store.read(), throwsFormatException);
      expect(await pending.exists(), true);
      rejectSave = false;
      expect((await store.read())?.token, fixture['token']);
      expect(await pending.exists(), false);
    },
  );

  test('concurrent reads share one import', () async {
    await pending.writeAsString(jsonEncode(fixture));
    final first = store.read(), second = store.read();
    expect(identical(first, second), true);
    expect(
      (await Future.wait([
        first,
        second,
      ])).every((c) => c?.token == fixture['token']),
      true,
    );
    expect(saves, 1);
  });

  test(
    'an explicit clear cancels a pending import without resurrecting credentials',
    () async {
      blocked = true;
      await pending.writeAsString(jsonEncode(fixture));
      clearGate = Completer<void>();
      final reading = store.read();
      while (clears == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await store.clear();
      clearGate!.complete();
      expect(await reading, null);
      expect(saved, null);
      expect(saves, 0);
      expect(await pending.exists(), false);
    },
  );
}
