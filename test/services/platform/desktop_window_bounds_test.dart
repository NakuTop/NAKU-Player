import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/platform/desktop_window_bounds.dart';

void main() {
  const main = Rect.fromLTWH(0, 24, 1440, 836);
  const left = Rect.fromLTWH(-1920, 24, 1920, 1056);

  test('preserves a valid window and negative monitor coordinates', () {
    const requested = Rect.fromLTWH(-1700, 100, 1000, 700);
    expect(clampDesktopWindowBounds(requested, [main, left]), requested);
  });

  test('unplugging the external screen restores the full window on main', () {
    final result = clampDesktopWindowBounds(
      const Rect.fromLTWH(2000, 100, 1200, 750),
      [main],
    );
    expect(result, const Rect.fromLTWH(240, 100, 1200, 750));
  });

  test('chooses the screen with greatest overlap before fitting bounds', () {
    final result = clampDesktopWindowBounds(
      const Rect.fromLTWH(-800, 50, 1000, 700),
      [main, left],
    );
    expect(result, const Rect.fromLTWH(-1000, 50, 1000, 700));
  });

  test('smaller work area reduces window to fit below the menu bar', () {
    const small = Rect.fromLTWH(0, 36, 720, 480);
    expect(
      clampDesktopWindowBounds(const Rect.fromLTWH(50, -20, 1200, 800), [
        small,
      ]),
      small,
    );
  });

  test('invalid saved geometry is replaced with centered usable geometry', () {
    final result = clampDesktopWindowBounds(
      const Rect.fromLTWH(double.nan, 0, double.infinity, 0),
      [main],
    );
    expect(result, const Rect.fromLTWH(220, 92, 1000, 700));
  });
}
