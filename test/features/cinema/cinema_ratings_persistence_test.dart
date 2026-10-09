import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_ratings.dart';

CinemaTitle _title(String id, {String rt = ''}) => CinemaTitle(
  id: id,
  sourceId: 'persistence-fixture',
  title: 'Movie $id',
  rottenTomatoesId: rt,
);

Map<String, dynamic> _cacheFile({
  Map<String, dynamic> bindings = const {},
  Map<String, dynamic> cache = const {},
  Map<String, dynamic> subjects = const {},
}) => {
  'version': 1,
  'bindings': bindings,
  'cache': cache,
  'mappings': {},
  'doubanDetails': {},
  'doubanSubjects': subjects,
};

Map<String, dynamic> _copy(Map<String, dynamic> data) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(data)));

void main() {
  late Directory directory;
  late File file;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rating-persistence-');
    file = File('${directory.path}/ratings-v1.json');
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'restored provider and subject cache hits do not rewrite the file',
    () async {
      final now = DateTime.now();
      final stored = _cacheFile(
        cache: {
          '烂番茄:m/test_movie': {
            ...CinemaRating(
              provider: '烂番茄',
              value: 83,
              scale: 100,
              note: 'fixture',
              verified: true,
              fetchedAt: now,
            ).toJson(),
            'schema': 2,
          },
        },
        subjects: {
          '123': {
            'kind': 'movie',
            'data': DoubanSubjectDetails(
              doubanId: '123',
              title: 'Restored subject',
              fetchedAt: now,
            ).toJson(),
          },
        },
      );
      await file.writeAsString(jsonEncode(stored));
      final original = await file.readAsString();
      var writes = 0, requests = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (_, _) async => writes++,
        fetch: (_, _) async {
          requests++;
          throw StateError('Unexpected network request');
        },
      );
      final item = _title('cached', rt: 'm/test_movie');
      for (var i = 0; i < 8; i++) {
        expect((await repository.load(item)).ratings.last.value, 83);
        expect((await repository.loadForCard(item)).ratings.last.value, 83);
      }
      expect(requests, 0);
      expect(
        writes,
        0,
        reason: 'Scrolling back over cached cards is read-only',
      );
      expect(await file.readAsString(), original);
    },
  );

  test(
    'concurrent identity changes coalesce into one persisted snapshot',
    () async {
      final snapshots = <Map<String, dynamic>>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (_, snapshot) async => snapshots.add(_copy(snapshot)),
      );
      await repository.load(_title('initialize'));
      await Future.wait([
        for (var i = 0; i < 30; i++)
          repository.setIdentity(
            _title('$i'),
            RatingIdentity(doubanId: '${1000 + i}', confirmed: true),
          ),
      ]);
      expect(snapshots, hasLength(1));
      expect(snapshots.single['bindings'], hasLength(30));
    },
  );

  test(
    'updates during an in-flight write persist once more with newest state',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final snapshots = <Map<String, dynamic>>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (path, snapshot) async {
          snapshots.add(_copy(snapshot));
          if (snapshots.length == 1) {
            entered.complete();
            await release.future;
          }
          await File(path).writeAsString(jsonEncode(snapshot), flush: true);
        },
      );
      final first = repository.setIdentity(
        _title('A'),
        const RatingIdentity(doubanId: '1001'),
      );
      await entered.future;
      final more = [
        repository.setIdentity(
          _title('B'),
          const RatingIdentity(doubanId: '1002'),
        ),
        repository.setIdentity(
          _title('C'),
          const RatingIdentity(doubanId: '1003'),
        ),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(snapshots.single['bindings'], hasLength(1));
      release.complete();
      await Future.wait([first, ...more]);
      expect(snapshots, hasLength(2));
      expect(snapshots.last['bindings'], hasLength(3));
      final restored = CinemaRatingsRepository(directory: directory);
      await restored.setIdentity(
        _title('D'),
        const RatingIdentity(doubanId: '1004'),
      );
      final restoredBindings = jsonDecode(
        await file.readAsString(),
      )['bindings'];
      expect(restoredBindings, hasLength(4));
      for (final id in ['A', 'B', 'C']) {
        expect(
          restoredBindings[_title(id).key],
          snapshots.last['bindings'][_title(id).key],
        );
      }
    },
  );

  test(
    'a later failed revision never rolls back a binding already persisted',
    () async {
      final firstEntered = Completer<void>();
      final releaseFirst = Completer<void>();
      final secondEntered = Completer<void>();
      final failSecond = Completer<void>();
      var writes = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (path, snapshot) async {
          writes++;
          if (writes == 1) {
            firstEntered.complete();
            await releaseFirst.future;
          } else if (writes == 2) {
            secondEntered.complete();
            await failSecond.future;
            throw const FileSystemException('second revision fails');
          }
          await File(path).writeAsString(jsonEncode(snapshot), flush: true);
        },
      );
      final first = repository.setIdentity(
        _title('A'),
        const RatingIdentity(doubanId: '1001'),
      );
      await firstEntered.future;
      final second = repository.setIdentity(
        _title('B'),
        const RatingIdentity(doubanId: '1002'),
      );
      final secondResult = expectLater(
        second,
        throwsA(isA<FileSystemException>()),
      );
      releaseFirst.complete();
      await secondEntered.future;
      await first.timeout(const Duration(seconds: 1));
      // Completion of A is independent of the still-blocked newer B revision.
      expect(
        jsonDecode(await file.readAsString())['bindings'][_title(
          'A',
        ).key]['doubanId'],
        '1001',
      );
      failSecond.complete();
      await secondResult;
      await repository.load(_title('flush-rollback'));
      final persisted = jsonDecode(await file.readAsString())['bindings'];
      expect(persisted[_title('A').key]['doubanId'], '1001');
      expect(persisted.containsKey(_title('B').key), isFalse);
      final restored = CinemaRatingsRepository(directory: directory);
      await restored.setIdentity(
        _title('C'),
        const RatingIdentity(doubanId: '1003'),
      );
      expect(
        jsonDecode(await file.readAsString())['bindings'][_title(
          'A',
        ).key]['doubanId'],
        '1001',
      );
    },
  );

  test(
    'a failed manual binding rolls back and is absent from the next save',
    () async {
      final title = _title('bound');
      final original = _cacheFile(
        bindings: {
          title.key: const RatingIdentity(
            doubanId: '111',
            confirmed: true,
          ).toJson(),
        },
      );
      await file.writeAsString(jsonEncode(original));
      var writes = 0;
      final snapshots = <Map<String, dynamic>>[];
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (path, snapshot) async {
          writes++;
          if (writes == 1) throw const FileSystemException('fixture disk full');
          snapshots.add(_copy(snapshot));
          await File(path).writeAsString(jsonEncode(snapshot));
        },
      );
      await expectLater(
        repository.setIdentity(title, const RatingIdentity(doubanId: '222')),
        throwsA(isA<FileSystemException>()),
      );
      expect(jsonDecode(await file.readAsString()), original);
      await repository.load(_title('unrelated'));
      expect(writes, 2);
      expect(snapshots.single['bindings'][title.key]['doubanId'], '111');
      expect(
        jsonDecode(
          await file.readAsString(),
        )['bindings'][title.key]['doubanId'],
        '111',
      );
    },
  );

  test(
    'failed cache writes retry without fetching already loaded ratings again',
    () async {
      var writes = 0, requests = 0;
      final repository = CinemaRatingsRepository(
        directory: directory,
        cacheWriter: (path, snapshot) async {
          writes++;
          if (writes == 1) throw const FileSystemException('fixture disk full');
          await File(path).writeAsString(jsonEncode(snapshot));
        },
        fetch: (_, _) async {
          requests++;
          return utf8.encode(
            '<script type="application/ld+json">${jsonEncode({
              '@type': 'Movie',
              'url': 'https://www.rottentomatoes.com/m/test_movie',
              'aggregateRating': {'name': 'Tomatometer', 'bestRating': 100, 'ratingValue': 83, 'ratingCount': 100},
            })}</script>',
          );
        },
      );
      final item = _title('fresh', rt: 'm/test_movie');
      final first = await repository.load(item);
      expect(first.message, contains('评分缓存保存失败'));
      final second = await repository.load(item);
      expect(second.ratings.last.value, 83);
      expect(requests, 1);
      expect(writes, 2);
      expect(
        jsonDecode(
          await file.readAsString(),
        )['cache']['烂番茄:m/test_movie']['value'],
        83,
      );
    },
  );

  test(
    'default background writer finishes an atomic save before returning',
    () async {
      final repository = CinemaRatingsRepository(directory: directory);
      final item = _title('real-writer');
      await repository.setIdentity(
        item,
        const RatingIdentity(doubanId: '1889243'),
      );
      expect(
        jsonDecode(await file.readAsString())['bindings'][item.key]['doubanId'],
        '1889243',
      );
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );

  test(
    'incremental disk writes preserve all unchanged sections and bounded caches',
    () async {
      final now = DateTime.now();
      final original = _cacheFile(
        bindings: {
          'existing::1': const RatingIdentity(doubanId: '111').toJson(),
        },
        cache: {
          'fixture': {'value': 8.1, 'note': 'keep this entry'},
        },
        subjects: {
          for (var i = 0; i < 82; i++)
            '${1000 + i}': {
              'kind': 'movie',
              'data': DoubanSubjectDetails(
                doubanId: '${1000 + i}',
                title: 'Subject $i',
                fetchedAt: now,
              ).toJson(),
            },
        },
      );
      original['mappings'] = {
        '111': {
          'qid': 'Q111',
          'entity': {
            'labels': {
              'en': {'value': 'Fixture'},
            },
          },
        },
      };
      original['doubanDetails'] = {
        for (var i = 0; i < 66; i++)
          '$i': {
            'data': {'fixture': i},
          },
      };
      await file.writeAsString(jsonEncode(original));
      final repository = CinemaRatingsRepository(directory: directory);
      final changed = _title('new-binding');
      await repository.setIdentity(
        changed,
        const RatingIdentity(doubanId: '222'),
      );
      await repository.setIdentity(
        changed,
        const RatingIdentity(doubanId: '333'),
      );
      final saved = jsonDecode(await file.readAsString());
      expect(saved['cache'], original['cache']);
      expect(saved['mappings'], original['mappings']);
      expect(
        saved['bindings']['existing::1'],
        original['bindings']['existing::1'],
      );
      expect(saved['bindings'][changed.key]['doubanId'], '333');
      expect(saved['doubanDetails'], hasLength(64));
      expect(saved['doubanDetails'].containsKey('0'), isFalse);
      expect(saved['doubanSubjects'], hasLength(80));
      expect(saved['doubanSubjects'].containsKey('1000'), isFalse);
      expect(
        saved['doubanSubjects']['1081']['data'],
        original['doubanSubjects']['1081']['data'],
      );
      expect(await File('${file.path}.tmp').exists(), isFalse);
      final restored = CinemaRatingsRepository(directory: directory);
      final another = _title('after-restart');
      await restored.setIdentity(
        another,
        const RatingIdentity(doubanId: '444'),
      );
      final roundTrip = jsonDecode(await file.readAsString());
      for (final section in [
        'cache',
        'mappings',
        'doubanSubjects',
        'doubanDetails',
      ]) {
        expect(
          roundTrip[section],
          saved[section],
          reason: '$section survives a fresh repository',
        );
      }
      for (final entry in (saved['bindings'] as Map).entries) {
        expect(roundTrip['bindings'][entry.key], entry.value);
      }
      expect(roundTrip['bindings'][another.key]['doubanId'], '444');
    },
  );

  test(
    'an externally removed base file restores unchanged in-memory entries',
    () async {
      final original = _cacheFile(
        cache: {
          'fixture': {'value': 9.0},
        },
      );
      await file.writeAsString(jsonEncode(original));
      final repository = CinemaRatingsRepository(directory: directory);
      await repository.load(_title('initialize'));
      await file.delete();
      await repository.setIdentity(
        _title('new'),
        const RatingIdentity(doubanId: '123'),
      );
      final restored = jsonDecode(await file.readAsString());
      expect(restored['cache'], original['cache']);
      expect(restored['bindings'][_title('new').key]['doubanId'], '123');
    },
  );
}
