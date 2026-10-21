import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_online_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_external_subtitles.dart';
import 'package:kazumi/features/cinema/cinema_subtitle_network.dart';
import 'package:kazumi/services/network/system_proxy_service.dart';

class _DirectHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)..findProxy = (_) => 'DIRECT';
}

class _ProductionHttp extends HttpOverrides {}

class _BrokenProxyAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw const HandshakeException('Simulated automatic proxy TLS failure');
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'automatic proxy outage recovers real Chinese archive and timed dialogue',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final dio =
            Dio(
                BaseOptions(
                  connectTimeout: const Duration(seconds: 12),
                  receiveTimeout: const Duration(seconds: 20),
                  headers: {
                    'User-Agent': 'NAKUPlayer/2.8.0',
                    'Accept': 'application/json',
                  },
                ),
              )
              ..httpClientAdapter = CinemaSubtitleNetworkAdapter(
                primary: _BrokenProxyAdapter(),
                systemProxy: (_) => 'PROXY unavailable.invalid:7890',
              );
        final client = CinemaOnlineSubtitles(dio: dio);
        try {
          final result = await client.aggregate(
            '美国恐怖故事 第十季',
            'series',
            season: 10,
            episode: 2,
          );
          final chinese = result.rows.where((row) => row['lang'] == 'zh');
          expect(chinese, hasLength(2), reason: result.status.toString());
          expect(
            chinese.every(
              (row) =>
                  row['lang'] == 'zh' && (row['chineseCueCount'] as int) > 300,
            ),
            isTrue,
          );
          expect(result.status['字幕源连接'], contains('直连恢复'));
          // ignore: avoid_print
          print('Forced system proxy TLS outage: ${result.status}');
        } finally {
          client.close();
        }
      }, _ProductionHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_PRODUCTION_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'production Windows system proxy aggregate verifies real Chinese dialogue',
    () async {
      // Keep the OS route used by the installed app. Earlier live tests forced
      // DIRECT and could therefore hide a system-proxy-only source failure.
      await HttpOverrides.runWithHttpOverrides(() async {
        SystemProxyService.refresh();
        final client = CinemaOnlineSubtitles();
        try {
          final result = await client.aggregate(
            '美国恐怖故事 第十季',
            'series',
            season: 10,
            episode: 2,
          );
          // Report no private filenames, proxy endpoints or subtitle dialogue.
          // ignore: avoid_print
          print('Production subtitle route: ${result.status}');
          expect(
            result.rows.where((row) => row['lang'] == 'zh'),
            isNotEmpty,
            reason: result.status.toString(),
          );
        } finally {
          client.close();
        }
      }, _ProductionHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_PRODUCTION_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
  test(
    'live default aggregate includes actual Chinese and English AHS S10E02 dialogue',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 20),
          ),
        )..httpClientAdapter = IOHttpClientAdapter();
        final client = CinemaOnlineSubtitles(dio: dio);
        try {
          final result = await client.aggregate(
            '美国恐怖故事 第十季',
            'series',
            season: 10,
            episode: 2,
            mediaRelease:
                'American.Horror.Story.S10E02.1080p.AMZN.WEB-DL.FLUX.mkv',
          );
          expect(result.rows, isNotEmpty, reason: result.status.toString());
          expect(
            result.rows.every(
              (row) =>
                  row['verified'] == true &&
                  cinemaSubtitleLanguageMatches('${row['lang']}', 'zh-eng'),
            ),
            isTrue,
          );
          expect(result.rows.first['lang'], 'zh');
          expect(result.rows.where((row) => row['lang'] == 'zh'), hasLength(2));
          expect(result.rows.any((row) => row['lang'] == 'eng'), isTrue);
          final row = result.rows.firstWhere(
            (row) =>
                row['lang'] == 'zh' &&
                '${row['subtitleFileName']}'.contains('S10E02'),
          );
          final text = await client.download(
            '${row['url']}',
            archiveEntry: row['archiveEntry'] as String?,
          );
          expect(text, contains('[Events]'));
          final cues = cinemaSubtitleCues(text);
          final chineseDialogue = cues
              .where((cue) => RegExp(r'[\u4e00-\u9fff]').hasMatch(cue.text))
              .length;
          expect(chineseDialogue, greaterThan(300));
          expect(row['chineseCueCount'], chineseDialogue);
          expect(row['bilingual'], isTrue);
          expect(row['releaseScore'], greaterThan(0));
          // ignore: avoid_print
          print(
            'Verified S10E02 resources: ${result.rows.length}; actual Chinese timed cues: $chineseDialogue; ${result.status}',
          );
        } finally {
          client.close();
        }
      }, _DirectHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_LIVE_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'live Chinese title to AHS S10E02 and downloadable subtitle',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final dio = Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 30),
          ),
        )..httpClientAdapter = IOHttpClientAdapter();
        final client = CinemaOnlineSubtitles(dio: dio);
        try {
          final works = await client.search('美国恐怖故事 第十季第二集', 'series');
          expect(works.any((w) => w['id'] == 'tt1844624'), isTrue);
          final rows = await client.subtitles(
            'tt1844624',
            'series',
            season: 10,
            episode: 2,
          );
          expect(rows, isNotEmpty);
          final english = rows.firstWhere(
            (r) => cinemaSubtitleLanguageMatches('${r['lang']}', 'eng'),
          );
          final text = await client.download('${english['url']}');
          expect(text, contains('-->'));
          // Report counts only, never downloaded dialogue or private playback data.
          // ignore: avoid_print
          print(
            'Live S10E02: ${rows.length} resources, ${rows.where((r) => cinemaSubtitleLanguageMatches('${r['lang']}', 'zh')).length} Chinese; download validated.',
          );
        } finally {
          client.close();
        }
      }, _DirectHttp());
    },
    skip: !const bool.fromEnvironment('NAKU_LIVE_SUBTITLE_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
