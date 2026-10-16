import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/naku_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('naku/updater');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'overlapping route leases have separate identities and idempotent close',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      final nas = NakuPlaybackUpdateLease(), web = NakuPlaybackUpdateLease();
      await nas.start();
      await nas.start();
      await web.start();
      await nas.close();
      await nas.close();
      await web.close();
      expect(calls.map((c) => c.method), everyElement('playbackSession'));
      final args = calls.map((c) => c.arguments as Map).toList();
      expect(args.map((a) => a['active']), [true, true, false, false]);
      expect(args[0]['id'], args[2]['id']);
      expect(args[1]['id'], args[3]['id']);
      expect(args[0]['id'], isNot(args[1]['id']));
    },
  );

  test(
    'dispose while initial bridge call is pending preserves activation order',
    () async {
      final started = Completer<void>(), release = Completer<void>();
      final calls = <bool>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final active = (call.arguments as Map)['active'] as bool;
        calls.add(active);
        if (active) {
          started.complete();
          await release.future;
        }
        return null;
      });
      final lease = NakuPlaybackUpdateLease();
      unawaited(lease.start());
      await started.future;
      final closed = lease.close();
      expect(calls, [true]);
      release.complete();
      await closed;
      expect(calls, [true, false]);
    },
  );

  test('unsupported platforms do not prevent route lifecycle', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException(),
    );
    final lease = NakuPlaybackUpdateLease();
    await lease.start();
    await lease.close();
  });
}
