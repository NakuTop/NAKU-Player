import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ratings-queue-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  CinemaTitle title(String id) => CinemaTitle(
    id: id,
    sourceId: 'fixture',
    title: id,
    doubanId: const {
      'first': '12341',
      'second': '12342',
      'skipped': '12343',
    }[id]!,
  );
  List<int> response(String path) => utf8.encode(
    jsonEncode({
      'id': path.split('/').last,
      'type': 'movie',
      'title': 'Fixture movie',
      'rating': {'max': 10, 'value': 8, 'count': 100},
    }),
  );

  test(
    'poster queue serializes requests, cancels stale work, then continues',
    () async {
      final firstStarted = Completer<void>();
      final releaseFirst = Completer<void>();
      final paths = <String>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          paths.add(uri.path);
          if (uri.path == '/rexxar/api/v2/movie/12341') {
            firstStarted.complete();
            await releaseFirst.future;
          }
          return response(uri.path);
        },
      );
      final first = repository.loadForCard(title('first'));
      await firstStarted.future;
      final skipped = repository.loadForCard(
        title('skipped'),
        isCurrent: () => false,
      );
      final expectedSkip = expectLater(skipped, throwsStateError);
      final second = repository.loadForCard(title('second'));
      expect(paths, ['/rexxar/api/v2/movie/12341']);
      releaseFirst.complete();
      await first;
      await expectedSkip;
      final result = await second;
      expect(paths, [
        '/rexxar/api/v2/movie/12341',
        '/rexxar/api/v2/movie/12342',
      ]);
      expect(result.ratings.first.value, 8);
      expect(repository.peek(title('second')), same(result));
    },
  );
  test(
    'saved manual binding is used even when a poster has no original IDs',
    () async {
      const item = CinemaTitle(
        id: 'blank',
        sourceId: 'fixture',
        title: 'Movie',
      );
      final first = CinemaRatingsRepository(directory: directory);
      await first.setIdentity(
        item,
        const RatingIdentity(doubanId: '12345', confirmed: true),
      );
      final paths = <String>[];
      final restored = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          paths.add(uri.path);
          return response(uri.path);
        },
      );
      final result = await restored.loadForCard(item);
      expect(paths, ['/rexxar/api/v2/movie/12345']);
      expect(result.ratings.first.value, 8);
    },
  );
  test(
    'manual correction invalidates an already running poster result',
    () async {
      const item = CinemaTitle(
        id: 'same',
        sourceId: 'fixture',
        title: 'Movie',
        doubanId: '12341',
      );
      final started = Completer<void>();
      final release = Completer<void>();
      final repository = CinemaRatingsRepository(
        directory: directory,
        fetch: (uri, _) async {
          if (uri.path == '/rexxar/api/v2/movie/12341') {
            started.complete();
            await release.future;
          }
          return response(uri.path);
        },
      );
      final oldCard = repository.loadForCard(item);
      await started.future;
      await repository.setIdentity(
        item,
        const RatingIdentity(doubanId: '12342', confirmed: true),
      );
      final corrected = await repository.load(item, force: true);
      release.complete();
      final delivered = await oldCard;
      expect(delivered.identity.doubanId, '12342');
      expect(delivered.ratings.first.url, corrected.ratings.first.url);
    },
  );
}
