import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';

void main() {
  CinemaLogvarQuery query(String label) => CinemaLogvarQuery.parse(
    '现在就出发第四季', category: '大陆综艺', episodeName: label, fallbackEpisode: 38);
  test('variety matching uses broadcast identity across reordered catalogues', () {
    final q = query('2026-11-20 第三期（上）');
    expect(q.episode, 3);
    expect(q.season, 4);
    expect(q.matchesEpisode('20261120 第3期上', 38), isTrue);
    expect(q.matchesEpisode('20261120 第3期下', 3), isFalse);
    expect(q.matchesEpisode('20261121 第3期上', 3), isFalse);
    expect(q.matchesEpisode('第38集', 38), isFalse);
    expect(q.matchesEpisode('20261120 第3期上 加更版'), isFalse);
  });
  test('pure cuts from the same day keep their individual titles', () {
    final q = query('20261120 纯享版：夜曲');
    expect(q.matchesEpisode('2026/11/20 纯享：夜曲'), isTrue);
    expect(q.matchesEpisode('20261120 纯享：晴天'), isFalse);
    expect(q.matchesEpisode('20261120 正片'), isFalse);
  });
}
