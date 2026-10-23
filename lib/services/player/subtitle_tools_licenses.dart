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
  });
}
