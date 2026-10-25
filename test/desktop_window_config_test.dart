import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/desktop_window_config.dart';

void main() {
  for (final platform in ['macos', 'windows']) {
    test(
      '$platform keeps native buttons despite a legacy hidden preference',
      () {
        var reads = 0;
        expect(
          DesktopWindowConfig.resolveWindowButtonVisibility(
            operatingSystem: platform,
            readPreference: () {
              reads++;
              return false;
            },
          ),
          isTrue,
        );
        expect(
          reads,
          0,
          reason: 'Native controls cannot depend on old opt-ins.',
        );
      },
    );
  }

  test(
    'other platforms retain their existing preference without a rewrite',
    () {
      for (final platform in ['linux', 'android', 'ios']) {
        for (final preference in [false, true]) {
          var reads = 0;
          expect(
            DesktopWindowConfig.resolveWindowButtonVisibility(
              operatingSystem: platform,
              readPreference: () {
                reads++;
                return preference;
              },
            ),
            preference,
          );
          expect(reads, 1);
        }
      }
    },
  );
}
