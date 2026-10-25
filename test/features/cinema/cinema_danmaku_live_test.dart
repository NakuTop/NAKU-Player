import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_danmaku.dart';

void main() {
  const enabled = bool.fromEnvironment('NAKU_LIVE_DANMAKU');
  test('public Tencent-page source returns usable timed comments', () async {
    final client = CinemaPublicDanmakuClient(
      dio: Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 25),
        ),
      ),
    );
    addTearDown(client.close);
    final rows = await client.load(
      'https://v.qq.com/x/cover/53q0eh78q97e4d1/x00174aq5no.html',
    );
    expect(rows.length, greaterThan(50));
    expect(
      rows.every((entry) => entry.time >= 0 && entry.message.isNotEmpty),
      isTrue,
    );
    // Intentional stdout evidence for the opt-in live probe.
    // ignore: avoid_print
    print('LIVE_DANMAKU: ${rows.length} accepted timed comments');
  }, skip: !enabled);
}
