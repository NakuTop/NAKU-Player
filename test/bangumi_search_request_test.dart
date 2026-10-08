import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/network/bangumi_acceleration.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:logger/logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  late Directory directory;
  late PathProviderPlatform previousPaths;
  late _SearchAdapter adapter;

  setUpAll(() async {
    Logger.level = Level.off;
    directory = await Directory.systemTemp.createTemp('kazumi_search_request_');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(directory.path);
    Hive.init(directory.path);
    await GStorage.init();
  });

  setUp(() async {
    await GStorage.putSetting(SettingsKeys.bangumiAcceleration, '');
    await GStorage.putSetting(SettingsKeys.enableBangumiProxy, true);
    await GStorage.putSetting(SettingsKeys.bangumiSyncEnable, false);
    await GStorage.putSetting(SettingsKeys.bangumiAccessToken, '');
    DioFactory.reset();
    adapter = _SearchAdapter();
    DioFactory.bangumiDio.httpClientAdapter.close();
    DioFactory.bangumiDio.httpClientAdapter = adapter;
  });

  tearDownAll(() async {
    DioFactory.reset();
    await Hive.close();
    PathProviderPlatform.instance = previousPaths;
    await directory.delete(recursive: true);
  });

  test(
    'personal build searches Cyberpunk despite the default mirror setting',
    () async {
      final page = await BangumiApi.bangumiSearch('赛博朋克');
      expect(page, isNotNull);
      expect(page!.items.map((item) => item.id), contains(309311));
      final request = adapter.requests.single;
      expect(request.uri.host, 'api.bgm.tv');
      expect(request.headers.containsKey('X-AppId'), isFalse);
      expect(request.headers.containsKey('X-Signature'), isFalse);
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(GStorage.getSetting(SettingsKeys.enableBangumiProxy), isTrue);
    },
  );

  test(
    'keeps Chinese JSON, pagination, unranked and original-title results',
    () async {
      await GStorage.putSetting(SettingsKeys.bangumiAcceleration, 'direct');
      final page = await BangumiApi.bangumiSearch(
        '赛博朋克：边缘行者 & Cyberpunk',
        limit: 3,
        offset: 20,
      );
      expect(page, isNotNull);
      expect(page!.rawCount, 3);
      expect(page.items.map((item) => item.id), [309311, 513878, 491585]);
      expect(page.items[1].rank, 0);
      expect(page.items[2].nameCn, '赛博剑仙铁雨');
      expect(page.items[2].airDate, isEmpty);
      expect(adapter.requestBodies.single['keyword'], '赛博朋克：边缘行者 & Cyberpunk');
      expect(adapter.requests.single.uri.queryParameters, {
        'limit': '3',
        'offset': '20',
      });
    },
  );

  test(
    'unprotected public calendar keeps the requested mirror route',
    () async {
      await BangumiClient.instance.get('https://next.bgm.tv/p1/calendar');
      final request = adapter.requests.single;
      expect(request.uri.host, 'api.kazumi.fyi');
      expect(request.uri.path, '/p1/calendar');
    },
  );
  test(
    'configured mirror signing and explicit direct/ECH modes are preserved',
    () {
      final search = Uri.parse('https://api.bgm.tv/v0/search/subjects');
      BangumiAcceleration resolve(BangumiAcceleration mode, bool configured) =>
          BangumiAcceleration.resolveForRequest(
            mode: mode,
            uri: search,
            method: 'POST',
            mirrorCredentialsAvailable: configured,
          );
      expect(
        resolve(BangumiAcceleration.mirror, false),
        BangumiAcceleration.direct,
      );
      expect(
        resolve(BangumiAcceleration.mirror, true),
        BangumiAcceleration.mirror,
      );
      expect(
        resolve(BangumiAcceleration.direct, false),
        BangumiAcceleration.direct,
      );
      expect(resolve(BangumiAcceleration.ech, false), BangumiAcceleration.ech);
    },
  );

  test(
    'unsigned protected comments use official routes without rerouting writes',
    () {
      final comments = Uri.parse(
        'https://next.bgm.tv/p1/subjects/309311/comments',
      );
      expect(
        BangumiAcceleration.resolveForRequest(
          mode: BangumiAcceleration.mirror,
          uri: comments,
          method: 'GET',
          mirrorCredentialsAvailable: false,
        ),
        BangumiAcceleration.direct,
      );
      expect(
        BangumiAcceleration.requiresMirrorSignature(comments, 'POST'),
        isFalse,
      );
      expect(
        BangumiAcceleration.requiresMirrorSignature(
          Uri.parse('https://example.com/v0/search/subjects'),
          'POST',
        ),
        isFalse,
      );
    },
  );

  test(
    'live default personal-build search finds Cyberpunk and Frieren',
    () async {
      await _configureSystemProxy();
      DioFactory.reset();
      final cyberpunk = await BangumiApi.bangumiSearch('赛博朋克');
      expect(cyberpunk, isNotNull);
      expect(cyberpunk!.items.map((item) => item.id), contains(309311));
      final nextPage = await BangumiApi.bangumiSearch(
        '赛博朋克',
        offset: cyberpunk.rawCount,
      );
      expect(nextPage, isNotNull);
      expect(nextPage!.rawCount, greaterThan(0));
      expect(
        nextPage.items
            .map((item) => item.id)
            .toSet()
            .intersection(cyberpunk.items.map((item) => item.id).toSet()),
        isEmpty,
      );
      final frieren = await BangumiApi.bangumiSearch('葬送的芙莉莲');
      expect(frieren, isNotNull);
      expect(frieren!.items.any((item) => item.nameCn.contains('芙莉莲')), isTrue);
      final evidence = {
        'checkedAt': DateTime.now().toUtc().toIso8601String(),
        'scope':
            'Real public HTTP through production BangumiApi/BangumiClient, not UI or playback acceptance',
        'configuredMode': BangumiAcceleration.current.name,
        'effectiveSearchMode': BangumiAcceleration.forRequest(
          Uri.parse('https://api.bgm.tv/v0/search/subjects'),
          'POST',
        ).name,
        'cyberpunk': {
          'rawCount': cyberpunk.rawCount,
          'items': cyberpunk.items
              .map(
                (item) => {
                  'id': item.id,
                  'name': item.nameCn,
                  'rank': item.rank,
                },
              )
              .toList(),
        },
        'cyberpunkNextPage': {
          'rawCount': nextPage.rawCount,
          'ids': nextPage.items.map((item) => item.id).toList(),
        },
        'frieren': {
          'rawCount': frieren.rawCount,
          'items': frieren.items
              .take(5)
              .map((item) => {'id': item.id, 'name': item.nameCn})
              .toList(),
        },
      };
      final evidenceDirectory = Directory('../bangumi-search-diagnosis');
      await evidenceDirectory.create(recursive: true);
      await File(
        '${evidenceDirectory.path}/production-live.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(evidence));
    },
    skip: !const bool.fromEnvironment('BANGUMI_SEARCH_LIVE_TEST'),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}

Future<void> _configureSystemProxy() async {
  if (!Platform.isMacOS) return;
  final result = await Process.run('/usr/sbin/scutil', ['--proxy']);
  if (result.exitCode != 0) {
    throw StateError('Cannot read the macOS proxy setting');
  }
  final text = result.stdout.toString();
  final configuration = <String, dynamic>{};
  for (final key in [
    'HTTPEnable',
    'HTTPProxy',
    'HTTPPort',
    'HTTPSEnable',
    'HTTPSProxy',
    'HTTPSPort',
  ]) {
    final value = RegExp(
      '^\\s*$key : (.+)'
      r'$',
      multiLine: true,
    ).firstMatch(text)?.group(1)?.trim();
    if (value != null) configuration[key] = int.tryParse(value) ?? value;
  }
  MacOSSystemProxy.setConfiguration(configuration);
}

Map<String, dynamic> _subject(
  int id,
  String name,
  String nameCn,
  int rank, {
  String? date,
}) => {
  'id': id,
  'type': 2,
  'name': name,
  'name_cn': nameCn,
  'date': date,
  'rating': {
    'rank': rank,
    'score': 8.3,
    'total': 10,
    'count': {for (var i = 1; i <= 10; i++) '$i': 1},
  },
  'images': <String, String>{},
};

class _SearchAdapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final requestBodies = <Map<String, dynamic>>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      if (bytes.isNotEmpty) {
        requestBodies.add(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      }
    }
    final mirrorSearch =
        options.uri.host == 'api.kazumi.fyi' && options.method == 'POST';
    return ResponseBody.fromString(
      jsonEncode(
        mirrorSearch
            ? {
                'error': {
                  'code': 'unauthorized',
                  'message': 'invalid request signature',
                },
              }
            : {
                // Selected public API cases observed on 2026-10-08, with synthetic votes.
                'data': [
                  _subject(
                    309311,
                    'Cyberpunk: Edgerunners',
                    '赛博朋克：边缘行者',
                    98,
                    date: '2022-09-13',
                  ),
                  _subject(
                    513878,
                    'Cyberpunk: Edgerunners 2',
                    '赛博朋克：边缘行者 2',
                    0,
                    date: '2026-10-20',
                  ),
                  _subject(491585, '赛博剑仙铁雨', '', 0),
                ],
                'total': 74,
                'limit': 3,
                'offset': 20,
              },
      ),
      mirrorSearch ? 401 : 200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}
