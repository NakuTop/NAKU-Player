import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_playback_buffer.dart';
import 'package:kazumi/services/player/macos_playback_profile.dart';
import 'package:kazumi/services/storage/storage.dart';

void main() {
  test(
    'personal Mac profile applies once and later manual settings remain authoritative',
    () async {
      final values = <String, Object?>{};
      T read<T>(SettingKey<T> key) =>
          (values[key.name] ?? key.defaultValue) as T;
      Future<void> write<T>(SettingKey<T> key, T value) async {
        values[key.name] = value;
      }

      await MacOSPlaybackProfile.apply(
        enabled: true,
        isMacOS: true,
        readSetting: read,
        writeSetting: write,
      );
      expect(values['videoBufferMegabytes'], 256);
      expect(values['mediaAutoRouting'], true);
      expect(values['mediaDirectConnection'], false);
      values['videoBufferMegabytes'] = 64;
      await MacOSPlaybackProfile.apply(
        enabled: true,
        isMacOS: true,
        readSetting: read,
        writeSetting: write,
      );
      expect(values['videoBufferMegabytes'], 64);
      values.clear();
      await MacOSPlaybackProfile.apply(
        enabled: true,
        isMacOS: false,
        readSetting: read,
        writeSetting: write,
      );
      expect(values, isEmpty);
      await MacOSPlaybackProfile.apply(
        enabled: false,
        isMacOS: true,
        readSetting: read,
        writeSetting: write,
      );
      expect(values, isEmpty);
    },
  );
  test(
    'native cache fills the selected 256 MiB while paused and keeps refilling during playback',
    () async {
      final library = Platform.environment['NAKU_BUFFER_MPV_LIBRARY']!;
      final process = await Process.start(
        'python3',
        ['test/support/native_buffer_probe.py'],
        environment: {
          'DYLD_FRAMEWORK_PATH': File(
            library,
          ).parent.path.replaceFirst(RegExp(r'/Mpv\.framework(?:/.*)?$'), ''),
        },
      );
      process.stdin.write(
        jsonEncode({
          'library': library,
          'properties': CinemaPlaybackBufferPolicy(
            1,
          ).nativeProperties(256 * 1024 * 1024),
        }),
      );
      await process.stdin.close();
      final stdout = process.stdout.transform(utf8.decoder).join(),
          stderr = process.stderr.transform(utf8.decoder).join();
      final timer = Timer(const Duration(seconds: 55), process.kill);
      final code = await process.exitCode;
      timer.cancel();
      final output = await stdout;
      expect(code, 0, reason: '${await stderr}\n$output');
      final data = jsonDecode(output) as Map;
      debugPrint('NATIVE_BUFFER: $output');
      final evidence = Platform.environment['NAKU_BUFFER_EVIDENCE'];
      if (evidence != null) {
        await File(evidence).writeAsString(jsonEncode(data));
      }
    },
    skip: Platform.environment['NAKU_BUFFER_MPV_LIBRARY'] == null,
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
