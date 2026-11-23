import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_match.dart';
import 'package:kazumi/features/cinema/cinema_video_metadata.dart';

OriginalEdition _edition(String hash, int seeds, {bool chinese = false}) =>
    OriginalEdition(
      hash: hash,
      name: 'Open Film 2025 2160p ${chinese ? "CHS" : "WEB"}',
      seeds: seeds,
      pack: false,
      size: 50 << 20,
      magnet: '',
      subtitleHint: chinese,
    );

void main() {
  test(
    '4K selection uses subtitle evidence then seed count and respects an explicit choice',
    () {
      final engine = CinemaOriginalEngine();
      final low = _edition('few', 4, chinese: true);
      final high = _edition('many', 90, chinese: true);
      final unknown = _edition('unlabelled', 600);
      final matches = OriginalMatches(
        OriginalWork(names: ['Open Film'], years: {'2025'}),
        [unknown, low, high],
      );
      expect(engine.preferred(matches)?.edition, same(high));
      expect(
        engine.preferred(matches, excluding: {'many'})?.edition,
        same(low),
      );
      expect(
        engine.preferred(matches, preferredHash: 'unlabelled')?.edition,
        same(unknown),
      );
      expect(
        engine.preferred(matches, excluding: {'many', 'few'})?.edition,
        same(unknown),
      );
    },
  );

  test(
    'an edition confirmed below 4K is excluded on reopening the same episode',
    () {
      final engine = CinemaOriginalEngine();
      final wrong = _edition('not-4k', 1000, chinese: true);
      final next = _edition('real-4k', 12, chinese: true);
      final matches = OriginalMatches(
        OriginalWork(
          names: ['Open Series'],
          years: {'2025'},
          season: 1,
          episode: 2,
        ),
        [wrong, next],
      );
      engine.record(
        matches,
        wrong,
        const CinemaVideoMetadata(1920, 1080, 'h264'),
      );
      expect(
        engine.preferred(matches, preferredHash: wrong.hash)?.edition,
        same(next),
      );
      expect(engine.preferred(matches, excluding: {next.hash}), isNull);
    },
  );
}
