import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void registerBangumiDataLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['bangumi-data'],
      await rootBundle.loadString('assets/statements/bangumi_data_license.txt'),
    );
  });
}
