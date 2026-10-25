import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_detail_artwork.dart';
import 'package:kazumi/features/cinema/cinema_featured_artwork.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

final _titles = List.generate(
  40,
  (i) => CinemaTitle(
    id: '$i',
    sourceId: 'fixture',
    title: '影片$i',
    poster: 'https://thumb.invalid/$i.jpg',
  ),
);

class _Request {
  _Request(this.title, this.identity, this.cancel);
  final CinemaTitle title;
  final RatingIdentity identity;
  final CancelToken cancel;
  final result = Completer<CinemaDetailArtwork>();
  void complete() => result.complete(
    CinemaDetailArtwork(
      url: 'https://original.invalid/${title.id}.jpg',
      width: 3840,
      height: 2160,
      highResolution: true,
    ),
  );
}

class _Repository extends CinemaDetailArtworkRepository {
  final requests = <_Request>[];
  @override
  Future<CinemaDetailArtwork> resolve(
    CinemaTitle title, {
    RatingIdentity identity = const RatingIdentity(),
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    bool force = false,
  }) {
    final request = _Request(title, identity, cancelToken!);
    requests.add(request);
    return request.result.future;
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    '40 catalogue cards upgrade only the hero and its next neighbour',
    () async {
      final repository = _Repository();
      final window = CinemaFeaturedArtworkWindow(repository: repository);
      window.update(_titles, 0);
      expect(repository.requests.map((r) => r.title.id), ['0', '1']);
      repository.requests[0].complete();
      repository.requests[1].complete();
      await _settle();
      expect(repository.requests, hasLength(2));
      expect(
        window.artworkFor(_titles[0]).url,
        'https://original.invalid/0.jpg',
      );
      expect(window.artworkFor(_titles[2]).url, _titles[2].poster);
      window.dispose();
    },
  );

  test(
    'fast swipes keep two slots and reject stale late completions',
    () async {
      final repository = _Repository();
      final window = CinemaFeaturedArtworkWindow(repository: repository);
      window.update(_titles, 0);
      window.update(_titles, 3);
      expect(repository.requests, hasLength(2));
      expect(repository.requests.every((r) => r.cancel.isCancelled), isTrue);
      repository.requests[0].complete();
      repository.requests[1].complete();
      await _settle();
      expect(repository.requests.map((r) => r.title.id), ['0', '1', '3', '4']);
      expect(window.artworkFor(_titles[0]).url, _titles[0].poster);
      window.dispose();
      repository.requests[2].complete();
      repository.requests[3].complete();
      await _settle();
      expect(repository.requests, hasLength(4));
    },
  );

  test(
    'last page prefetches the previous work and cached work is reused',
    () async {
      final repository = _Repository();
      final window = CinemaFeaturedArtworkWindow(repository: repository);
      window.update(_titles.take(3).toList(), 2);
      expect(repository.requests.map((r) => r.title.id), ['2', '1']);
      for (final request in repository.requests) {
        request.complete();
      }
      await _settle();
      window.update(_titles.take(3).toList(), 1);
      expect(repository.requests, hasLength(2));
      window.dispose();
    },
  );

  test(
    'backgrounding cancels work and identity corrections cannot reuse old art',
    () async {
      final repository = _Repository();
      final window = CinemaFeaturedArtworkWindow(repository: repository);
      window.update(_titles.take(1).toList(), 0);
      window.update(_titles, 0, active: false);
      expect(repository.requests.single.cancel.isCancelled, isTrue);
      repository.requests.single.complete();
      await _settle();
      const identity = RatingIdentity(imdbId: 'tt0120338');
      window.update(_titles.take(1).toList(), 0, identityFor: (_) => identity);
      expect(repository.requests, hasLength(2));
      expect(repository.requests.last.identity, identity);
      repository.requests.last.complete();
      await _settle();
      expect(window.artworkFor(_titles[0]).url, _titles[0].poster);
      expect(
        window.artworkFor(_titles[0], identity: identity).highResolution,
        isTrue,
      );
      window.dispose();
    },
  );

  test(
    'Retina decode preserves real pixels while respecting the 8 MP bound',
    () {
      const wide = CinemaDetailArtwork(url: '', width: 3840, height: 2160);
      expect(cinemaHeroDecodeWidth(wide, 1440, 2), 2880);
      expect(cinemaHeroDecodeWidth(wide, 3840, 2), 3200);
      const hd = CinemaDetailArtwork(url: '', width: 1920, height: 1080);
      expect(cinemaHeroDecodeWidth(hd, 1440, 2), 1920);
      const small = CinemaDetailArtwork(url: '', width: 480, height: 720);
      expect(cinemaHeroDecodeWidth(small, 1440, 2), 480);
      const tall = CinemaDetailArtwork(url: '', width: 4000, height: 6000);
      final width = cinemaHeroDecodeWidth(tall, 1440, 2);
      expect(width * width * 1.5, lessThanOrEqualTo(8000000));
      expect(width, greaterThan(1600));
    },
  );
}
