import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_tv_nas_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final namespace = 'a' * 64;
  CinemaTitle title({String? ns, int id = 42, int library = 3}) =>
      createCinemaNASTitle(
        namespace: ns ?? namespace,
        row: {
          'ug_video_info_id': id,
          'media_lib_set_id': library,
          'name': '旧 NAS 历史',
          'type': 1,
        },
        files: [(label: '原片', path: '/private/movie.mkv')],
      );
  test(
    'legacy NAS history restores poster path and exact score IDs without changing playback identity',
    () async {
      final calls = <String>[];
      final client = CinemaNASClient(
        invoke: (method, args) async {
          calls.add(method);
          if (method == 'ensure') {
            expect(args!['namespace'], namespace);
            return {};
          }
          expect(method, 'details');
          expect(args, {'id': 42, 'library': 3, 'tv': false});
          return {
            'video_info': {
              'ug_video_info_id': 42,
              'name': '原始资料标题',
              'poster_path': '/posters/local/42.jpg',
              'year': 2026,
              'douban_id': '36890123',
              'imdb_id': 'tt12345678',
            },
          };
        },
      );
      final repository = CinemaTVNASMetadataRepository(client);
      final original = title();
      final result = await repository.resolve(original);
      expect(result.title.key, original.key);
      expect(result.title.title, original.title);
      expect(result.title.routes, same(original.routes));
      expect(result.title.year, '2026');
      expect(result.title.doubanId, '36890123');
      expect(result.title.imdbId, 'tt12345678');
      expect(result.posterPath, '/posters/local/42.jpg');
      expect(
        result.title.poster,
        isEmpty,
        reason: 'session-bearing image URL never enters synced history',
      );
      expect(calls, ['ensure', 'details']);
      expect(
        (await repository.resolve(original)).title.doubanId,
        result.title.doubanId,
      );
      expect(calls, hasLength(2));
      repository.dispose();
    },
  );
  test(
    'cached metadata keeps newer routes and rejects a parent item identity',
    () async {
      final repository = CinemaTVNASMetadataRepository(
        CinemaNASClient(
          invoke: (method, args) async {
            if (method == 'ensure') return {};
            return {
              'video_info': {
                'ug_video_info_id': 42,
                'douban_id': '36890123',
                'poster_path': '/poster.jpg',
              },
            };
          },
        ),
      );
      final original = title();
      await repository.resolve(original);
      final updated = original.copyWith(
        routes: [
          CinemaRoute(name: '新版', episodes: original.routes.single.episodes),
        ],
      );
      final result = await repository.resolve(updated);
      expect(result.title.routes, same(updated.routes));
      expect(result.title.doubanId, '36890123');
      repository.dispose();
      final parent = CinemaTVNASMetadataRepository(
        CinemaNASClient(
          invoke: (method, args) async {
            if (method == 'ensure') return {};
            return {
              'video_info': {
                'ug_video_info_id': 999,
                'douban_id': '999999',
                'poster_path': '/wrong-season.jpg',
              },
            };
          },
        ),
      );
      final wrong = await parent.resolve(original);
      expect(wrong.title.doubanId, isEmpty);
      expect(wrong.posterPath, isEmpty);
      parent.dispose();
    },
  );

  test(
    'poster cache is stable across token changes and isolated by NAS, library and item',
    () {
      final key = cinemaTVNASPosterKey(title());
      expect(key, cinemaTVNASPosterKey(title()));
      expect(key, isNot(cinemaTVNASPosterKey(title(ns: 'b' * 64))));
      expect(key, isNot(cinemaTVNASPosterKey(title(library: 4))));
      expect(key, isNot(cinemaTVNASPosterKey(title(id: 43))));
      expect(key, isNot(contains('/private/')));
    },
  );
  test(
    'a mismatched saved identity and failed account check never read another NAS item',
    () async {
      final calls = <String>[];
      final repository = CinemaTVNASMetadataRepository(
        CinemaNASClient(
          invoke: (method, args) async {
            calls.add(method);
            throw StateError('fixture account mismatch');
          },
        ),
      );
      final original = title();
      final malformed = CinemaTitle(
        id: 'wrong-item',
        sourceId: cinemaNASSource.id,
        title: original.title,
        routes: original.routes,
      );
      expect(cinemaTVNASPosterKey(malformed), null);
      expect((await repository.resolve(malformed)).title.key, malformed.key);
      expect(calls, isEmpty);
      expect((await repository.resolve(original)).title.key, original.key);
      expect(calls, ['ensure']);
      repository.dispose();
    },
  );
  test(
    'visible duplicate cards share metadata work and at most two requests run',
    () async {
      int active = 0, maximum = 0, detailCalls = 0;
      final gates = <Completer<void>>[];
      final repository = CinemaTVNASMetadataRepository(
        CinemaNASClient(
          invoke: (method, args) async {
            if (method == 'ensure') return {};
            detailCalls++;
            active++;
            if (active > maximum) maximum = active;
            final gate = Completer<void>();
            gates.add(gate);
            await gate.future;
            active--;
            return {
              'video_info': {
                'ug_video_info_id': args!['id'],
                'poster_path': '/poster.jpg',
              },
            };
          },
        ),
      );
      final requests = [
        for (var i = 0; i < 5; i++) repository.resolve(title(id: 42 + i)),
      ];
      final duplicate = repository.resolve(title());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
        gates[i].complete();
      }
      await Future.wait([...requests, duplicate]);
      expect(detailCalls, 5);
      expect(maximum, 2);
      repository.dispose();
    },
  );
}
