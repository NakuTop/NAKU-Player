import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_direct_media.dart';
import 'package:kazumi/features/cinema/cinema_grouping.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_player_page.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_work_sources.dart';

void main() {
  test(
    'signed extensionless streams remain intact without exposing their URL in a title',
    () {
      final title = createCinemaDirectMedia(
        ' https://video.example/play?id=4&token=fixture ',
      );
      expect(title.title, '我的直链视频');
      expect(title.id, isNot(contains('token')));
      final roundTrip = CinemaTitle.fromJson(title.toJson());
      expect(
        roundTrip.routes.single.episodes.single.url,
        'https://video.example/play?id=4&token=fixture',
      );
      expect(
        cinemaUsesDirectMedia(
          cinemaDirectSource,
          roundTrip.routes.single,
          roundTrip.routes.single.episodes.single,
        ),
        isTrue,
      );
      for (final url in [
        'file:///tmp/a.mp4',
        'javascript:alert(1)',
        'https://u:p@a.example/video',
        'https://a.example/a\nhttps://b.example/b',
        '',
      ]) {
        expect(() => createCinemaDirectMedia(url), throwsFormatException);
      }
    },
  );

  test(
    'opening a direct link never queries catalogues or discovers public matches',
    () async {
      var requests = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              requests++;
              handler.reject(DioException(requestOptions: options));
            },
          ),
        );
      final repository = CinemaRepository(dio: dio);
      final title = createCinemaDirectMedia(
        'https://example.com/video',
        name: 'Private title',
      );
      expect(await repository.detail(cinemaDirectSource, title), same(title));
      expect((await repository.browse(cinemaDirectSource)).items, isEmpty);
      expect(await repository.categories(cinemaDirectSource), isEmpty);
      expect(
        (await repository.search(cinemaDirectSource, title.title)).items,
        isEmpty,
      );
      expect(
        await discoverCinemaWorkSources(
          anchor: title,
          known: [],
          sources: const [
            CinemaSource(
              id: 'test',
              name: 'test',
              kind: CinemaSourceKind.maccms,
              url: 'https://example.com/api',
            ),
          ],
          repository: repository,
          isCurrent: () => true,
        ).toList(),
        isEmpty,
      );
      expect(requests, 0);
    },
  );

  test(
    'direct-link favorites and progress survive a restart without adding a catalogue',
    () async {
      final dir = await Directory.systemTemp.createTemp('naku-direct-');
      final file = File('${dir.path}/library.json');
      final store = CinemaStore(
        file: file,
        defaults: const [],
        sourcePacks: const [],
      );
      final title = createCinemaDirectMedia(
        'https://example.com/master.m3u8',
        name: '测试4K',
      );
      final other = createCinemaDirectMedia(
        'https://example.com/other.m3u8',
        name: '测试4K',
      );
      try {
        await store.load();
        await store.toggleFavorite(title);
        await store.recordProgress(
          title: title,
          routeIndex: 0,
          episodeIndex: 0,
          positionSeconds: 90,
          durationSeconds: 1000,
        );
        await store.flush();
        final reopened = CinemaStore(
          file: file,
          defaults: const [],
          sourcePacks: const [],
        );
        await reopened.load();
        expect(reopened.sources, isEmpty);
        expect(reopened.favorites.single.key, title.key);
        expect(reopened.historyFor(title)!.positionSeconds, 90);
        expect(groupCinemaTitles([title, other]).length, 2);
        reopened.dispose();
      } finally {
        store.dispose();
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets(
    'direct-link dialog validates before submitting the requested action',
    (tester) async {
      ({CinemaTitle title, bool favorite})? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  result = await showCinemaDirectMediaDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏并播放'));
      await tester.pumpAndSettle();
      expect(find.textContaining('地址必须是完整'), findsOneWidget);
      await tester.enterText(
        find.byType(TextField).first,
        'https://example.com/4k.m3u8',
      );
      await tester.enterText(find.byType(TextField).last, '测试视频');
      await tester.tap(find.text('收藏并播放'));
      await tester.pumpAndSettle();
      expect(result?.favorite, isTrue);
      expect(result?.title.title, '测试视频');
      expect(tester.takeException(), isNull);
    },
  );
}
