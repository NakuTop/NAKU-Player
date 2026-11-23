import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_catalog_categories.dart';
import 'package:kazumi/features/cinema/cinema_repository.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';

void main() {
  test(
    'production film library recovers older theatrical titles from broad searches',
    () async {
      final client =
          Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 8),
              ),
            )
            ..httpClientAdapter = IOHttpClientAdapter(
              createHttpClient: () =>
                  HttpClient()..findProxy = HttpClient.findProxyFromEnvironment,
            );
      final requests = <String>[];
      client.interceptors.add(
        InterceptorsWrapper(
          onRequest: (req, next) {
            requests.add('${req.uri.queryParameters}');
            next.next(req);
          },
        ),
      );
      final repo = CinemaRepository(dio: client, hideShortDramas: true);
      try {
        for (final sample in [
          ('离婚', '1992', '王好为'),
          ('茶馆', '1982', '谢添'),
          ('芙蓉镇', '1987', '谢晋'),
        ]) {
          final page = await repo.search(cinemaFilmLibrarySource, sample.$1);
          expect(page.items.where((t) => cinemaIsAiDrama(t, {})), isEmpty);
          final match = page.items.firstWhere(
            (t) =>
                t.title == sample.$1 &&
                t.year == sample.$2 &&
                t.director.contains(sample.$3),
            orElse: () => throw StateError(
              'Missing ${sample.$1} ${sample.$2}; returned ${page.items.take(8).map((t) => [t.title, t.year])}; requests $requests',
            ),
          );
          requests.clear();
          final detail = await repo.detail(cinemaFilmLibrarySource, match);
          expect(
            detail.routes
                .expand((r) => r.episodes)
                .where((e) => e.url.contains('.m3u8')),
            isNotEmpty,
          );
          // ignore: avoid_print
          print(
            'LIVE_ANDROID_CATALOG ${match.title} ${match.year} ${match.id} ${detail.routes.length}',
          );
        }
      } finally {
        client.close(force: true);
      }
    },
    skip: !const bool.fromEnvironment('NAKU_LIVE_ANDROID_CATALOG'),
  );
}
