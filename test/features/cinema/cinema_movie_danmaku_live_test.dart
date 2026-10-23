import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_direct_danmaku.dart';
import 'package:kazumi/features/cinema/cinema_logvar_client.dart';

void main() {
  test(
    'real drama film matching retains bounded comment windows',
    () async {
      const proxy = String.fromEnvironment('NAKU_TEST_PROXY');
      final dio = Dio();
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final http = HttpClient();
          if (proxy.isNotEmpty) http.findProxy = (_) => 'PROXY $proxy';
          return http;
        },
      );
      final client = CinemaDirectDanmakuClient(dio: dio);
      try {
        for (final label in ['泰坦尼克号国语4K', '泰坦尼克号4K', '泰坦尼克号（普通话版）']) {
          final query = CinemaLogvarQuery.parse(
            label,
            category: '剧情片',
            episodeName: 'HD中字',
            year: '1997',
          );
          expect(query.series, isFalse);
          final result = await client.match(query, onProgress: debugPrint);
          expect(result, isNotNull);
          expect(result!.entries, isNotEmpty);
          expect(result.entries.length, lessThanOrEqualTo(6000));
          expect(result.timeline, isNotNull);
          final seek = await result.timeline!.window(1200);
          expect(seek.entries, isNotEmpty);
          expect(
            seek.entries.every((e) => e.time >= 1170 && e.time <= 1380),
            isTrue,
          );
          debugPrint(
            'MOVIE_LIVE: title=${query.title} work=${result.work.title} provider=${result.provider} '
            'first=${result.entries.length} seek=${seek.entries.length}',
          );
        }
        final other = await client.match(
          CinemaLogvarQuery.parse(
            '给阿嬷的情书',
            category: '剧情片',
            episodeName: '正片',
            year: '2026',
          ),
          onProgress: debugPrint,
        );
        if (other != null) {
          expect(other.work.title, '给阿嬷的情书');
          expect(other.work.year, '2026');
        }
        debugPrint(
          'MOVIE_LIVE: 给阿嬷的情书 ${other == null ? 'no confirmed full-film catalogue match' : '${other.provider} ${other.entries.length}'}',
        );
      } finally {
        client.close();
      }
    },
    skip: !const bool.fromEnvironment('NAKU_DIRECT_DANMAKU_LIVE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
