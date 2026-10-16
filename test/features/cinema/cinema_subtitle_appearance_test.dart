import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_appearance.dart';

void main() {
  test('persisted subtitle settings configure the actual Flutter renderer', () {
    final value = CinemaSubtitleAppearance.from({'fontSize': 48, 'bottom': 72});
    final restored = CinemaSubtitleAppearance.from(value.toJson());
    expect(restored.configuration.style.fontSize, 48);
    expect(restored.configuration.padding.bottom, 72);
    expect(restored.configuration.visible, isTrue);
  });
  test('invalid saved appearance cannot break subtitle layout', () {
    final corrupt = CinemaSubtitleAppearance.from({
      'fontSize': double.nan,
      'bottom': 'invalid',
    });
    expect(corrupt.configuration.style.fontSize, 32);
    expect(corrupt.configuration.padding.bottom, 24);
    expect(CinemaSubtitleAppearance.from({'fontSize': 10000}).fontSize, 64);
    expect(CinemaSubtitleAppearance.from({'bottom': -99}).bottom, 0);
  });
}
