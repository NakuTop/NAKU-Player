import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_movie_versions.dart';

CinemaTitle movie(List<String> names, {String category = '科幻片'}) => CinemaTitle(
  id: 'movie',
  sourceId: 'zuid',
  title: '电影',
  category: category,
  routes: [
    CinemaRoute(
      name: 'zuidam3u8',
      episodes: [
        for (final name in names)
          CinemaEpisode(name: name, url: 'https://fixture.invalid/$name.m3u8'),
      ],
    ),
  ],
);
void main() {
  test('TC and TD editions yield to HD, then 1080p and 4K', () {
    expect(cinemaPreferredEpisode(movie(['TC', 'HD']), 0), 1);
    expect(cinemaPreferredEpisode(movie(['TD', 'HD', '1080P', '4K']), 0), 3);
    expect(
      cinemaVersionQuality('HDCAM 1080P'),
      lessThan(cinemaVersionQuality('HD')),
    );
  });
  test(
    'numbered episodes, multipart movies and series are not movie editions',
    () {
      for (final title in [
        movie(['第01集', '第02集']),
        movie(['上', '下']),
        movie(['TC', 'HD'], category: '欧美剧'),
      ]) {
        expect(cinemaHasMovieVersions(title, 0), false);
        expect(cinemaPreferredEpisode(title, 0), 0);
      }
    },
  );
  test('empty titles and unknown edition labels retain safe defaults', () {
    expect(cinemaPreferredRoute(movie([])), -1);
    expect(cinemaPreferredEpisode(movie(['未知', 'HD']), 0), 0);
  });
}
