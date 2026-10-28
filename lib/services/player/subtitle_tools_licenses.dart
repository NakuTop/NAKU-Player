import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerSubtitleToolsLicenses() {
  LicenseRegistry.addLicense(() async* {
    for (final name in ['LICENSE', 'PATENTS', 'AUTHORS']) {
      yield LicenseEntryWithLineBreaks([
        'libfvad / WebRTC VAD',
      ], await rootBundle.loadString('licenses/libfvad/$name'));
    }
    yield LicenseEntryWithLineBreaks(
      ['LogVar / danmu_api protocol adapters'],
      '${await rootBundle.loadString('licenses/danmu_api/NOTICE')}\n${await rootBundle.loadString('licenses/danmu_api/LICENSE')}',
    );
    yield LicenseEntryWithLineBreaks([
      'Junrar / UnRAR subtitle archive reader',
    ], await rootBundle.loadString('licenses/junrar-LICENSE.txt'));
    yield LicenseEntryWithLineBreaks([
      'SLF4J API',
    ], await rootBundle.loadString('licenses/slf4j-LICENSE.txt'));
    final apache = await rootBundle.loadString(
      'licenses/android_tv/Apache-2.0.txt',
    );
    for (final entry in const {
      'AndroidX Media3 1.11.1': 'MEDIA3_NOTICE.txt',
      'OkHttp 4.12.0': 'OKHTTP_NOTICE.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks(
        [entry.key],
        '${await rootBundle.loadString('licenses/android_tv/${entry.value}')}\n$apache',
      );
    }
  });
}
