import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/request/clients/bilibili_danmaku_client.dart';
import 'package:kazumi/services/player/bilibili_anime_matcher.dart';

void main() {
  test(
    'public anime metadata automatically supplies two different episode pools',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'naku-bili-live-',
      );
      final dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 15)));
      addTearDown(dio.close);
      addTearDown(() => directory.delete(recursive: true));
      final client = BilibiliDanmakuClient(dio: dio);
      final matcher = BilibiliAnimeMatcher(
        client: client,
        directory: directory,
        mappingLoader: () async {
          final data =
              jsonDecode(
                    await File(
                      'assets/data/bangumi_bilibili.json',
                    ).readAsString(),
                  )
                  as Map;
          return (data['subjects'] as Map).map(
            (key, value) => MapEntry('$key', List<String>.from(value as List)),
          );
        },
      );
      final subject = BangumiItem.fromJson({
        'id': 328609,
        'name': 'ぼっち・ざ・ろっく！',
        'name_cn': '孤独摇滚！',
        'date': '2022-10-08',
        'images': <String, String>{},
        'rating': <String, dynamic>{},
      });
      final matches = await matcher.discover(subject);
      expect(matches.automatic?.reference, 'md28339735');
      final video = await matcher.video(matches.automatic!.reference);
      final first = BilibiliAnimeMatcher.episode(video, 1);
      final second = BilibiliAnimeMatcher.episode(video, 2);
      expect(first, isNotNull);
      expect(second, isNotNull);
      expect(first!.cid, isNot(second!.cid));
      for (final episode in [1, 2]) {
        final entries = await matcher.load(subject, episode);
        expect(entries, isNotEmpty);
        expect(entries.every((entry) => entry.source == '[BiliBili]'), isTrue);
      }
      final found = await client.searchAnime('葬送的芙莉莲');
      expect(found.any((candidate) => candidate.title == '葬送的芙莉莲'), isTrue);
    },
    skip: Platform.environment['NAKU_BILIBILI_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
