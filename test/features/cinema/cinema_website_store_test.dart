import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_website_store.dart';

const website = CinemaWebsite(
  id: 'custom',
  name: '测试站点',
  url: 'https://example.com/',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ten default bookmarks preserve the nine Joyflix URLs and user URL', () {
    expect(bundledCinemaWebsites.map((site) => site.url).toList(), [
      'https://www.kkys20.com/',
      'https://v.luttt.com/',
      'https://skr.skr2.cc:666/',
      'https://omofun.in/',
      'https://gaze.red/',
      'https://adys.tv/',
      'https://www.gying.si',
      'https://tv.cctv.com/live/',
      'https://live.wxhbts.com/',
      'https://www.xn--kivn76b41nnhi.com/',
    ]);
    expect(bundledCinemaWebsites.map((site) => site.id).toSet(), hasLength(10));
    expect(bundledCinemaWebsites.map((site) => site.category).toList(), [
      '影视',
      '影视',
      '动漫',
      '动漫',
      '影视',
      '影视',
      '影视',
      '直播',
      '直播',
      '影视',
    ]);
    for (final site in bundledCinemaWebsites) {
      site.validate();
      expect(CinemaWebsite.fromJson(site.toJson()).toJson(), site.toJson());
    }
  });

  test('validation rejects non-web URLs, empty names and IDs', () {
    for (final url in [
      'file:///tmp/video.html',
      'javascript:alert(1)',
      'data:text/html,hello',
      '/relative',
      'https://',
      'https://user:password@example.com/',
    ]) {
      expect(
        () => website.copyWith(url: url).validate(),
        throwsFormatException,
      );
    }
    expect(
      () => website.copyWith(name: '  ').validate(),
      throwsFormatException,
    );
    expect(() => website.copyWith(id: '').validate(), throwsFormatException);
    website.copyWith(url: 'http://example.com:8080/video').validate();
    expect(
      CinemaWebsite.fromJson({
        'id': 'id',
        'name': '网站',
        'url': 'https://example.com',
      }).category,
      '影视',
    );
    expect(
      () => CinemaWebsite.fromJson({...website.toJson(), 'name': 123}),
      throwsFormatException,
    );
  });

  group('website library persistence', () {
    late Directory directory;
    late File file;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('kazumi-website-test-');
      file = File('${directory.path}/cinema/websites-v1.json');
    });
    tearDown(() async {
      await directory.delete(recursive: true);
    });

    test(
      'CRUD persists across instances and an empty library stays empty',
      () async {
        final store = CinemaWebsiteStore(file: file, defaults: [website]);
        await store.load();
        expect(store.loaded, isTrue);
        expect(store.restoreLastSite, isFalse);
        expect(store.lastSiteId, isNull);
        await store.saveSite(
          website.copyWith(name: '更新名称', url: 'https://example.com/watch'),
        );
        await store.saveSite(website.copyWith(id: 'second', name: '另一站点'));
        final restored = CinemaWebsiteStore(file: file);
        await restored.load();
        expect(restored.sites.map((site) => site.name), ['更新名称', '另一站点']);
        expect(restored.sites.first.url, 'https://example.com/watch');
        await restored.removeSite('custom');
        await restored.removeSite('second');
        final empty = CinemaWebsiteStore(file: file);
        await empty.load();
        expect(empty.sites, isEmpty);
        store.dispose();
        restored.dispose();
        empty.dispose();
      },
    );

    test(
      'last site and restore preference persist independently across restart',
      () async {
        final store = CinemaWebsiteStore(file: file, defaults: [website]);
        await store.load();
        await store.recordLastSite(website.id);
        expect(store.restoreLastSite, isFalse);
        await store.setRestoreLastSite(true);
        final restored = CinemaWebsiteStore(file: file);
        await restored.load();
        expect(restored.lastSiteId, website.id);
        expect(restored.restoreLastSite, isTrue);
        await restored.setRestoreLastSite(false);
        final again = CinemaWebsiteStore(file: file);
        await again.load();
        expect(again.lastSiteId, website.id);
        expect(again.restoreLastSite, isFalse);
        store.dispose();
        restored.dispose();
        again.dispose();
      },
    );

    test(
      'deleting the last site clears its identity but keeps the preference',
      () async {
        final store = CinemaWebsiteStore(file: file, defaults: [website]);
        await store.load();
        await store.recordLastSite(website.id);
        await store.setRestoreLastSite(true);
        await store.removeSite(website.id);
        expect(store.lastSiteId, isNull);
        final restored = CinemaWebsiteStore(file: file);
        await restored.load();
        expect(restored.lastSiteId, isNull);
        expect(restored.restoreLastSite, isTrue);
        expect(restored.sites, isEmpty);
        store.dispose();
        restored.dispose();
      },
    );

    test(
      'corrupt JSON is preserved and cannot be silently overwritten',
      () async {
        await file.parent.create(recursive: true);
        const original = '{broken';
        await file.writeAsString(original);
        final store = CinemaWebsiteStore(file: file);
        await expectLater(store.load(), throwsFormatException);
        expect(store.loaded, isFalse);
        expect(store.lastError, contains('原文件已保留'));
        await expectLater(store.saveSite(website), throwsFormatException);
        expect(await file.readAsString(), original);
        store.dispose();
      },
    );

    test(
      'invalid schema, duplicate IDs and dangling last-site references are preserved',
      () async {
        await file.parent.create(recursive: true);
        final valid = {
          'version': 1,
          'sites': [website.toJson()],
          'lastSiteId': null,
          'restoreLastSite': false,
        };
        for (final body in [
          {...valid, 'restoreLastSite': 'false'},
          {
            ...valid,
            'sites': [null],
          },
          {
            ...valid,
            'sites': [website.toJson(), website.toJson()],
          },
          {...valid, 'lastSiteId': 'missing'},
          {...valid, 'version': 2},
        ]) {
          final original = jsonEncode(body);
          await file.writeAsString(original);
          final store = CinemaWebsiteStore(file: file);
          await expectLater(store.load(), throwsFormatException);
          expect(await file.readAsString(), original);
          store.dispose();
        }
      },
    );

    test(
      'queued operations retain every mutation and unknown last sites do not poison writes',
      () async {
        final store = CinemaWebsiteStore(file: file, defaults: [website]);
        await store.load();
        await expectLater(store.recordLastSite('missing'), throwsArgumentError);
        await Future.wait([
          store.saveSite(website.copyWith(id: 'second')),
          store.setRestoreLastSite(true),
          store.recordLastSite('custom'),
        ]);
        await store.flush();
        final restored = CinemaWebsiteStore(file: file);
        await restored.load();
        expect(restored.sites, hasLength(2));
        expect(restored.restoreLastSite, isTrue);
        expect(restored.lastSiteId, 'custom');
        store.dispose();
        restored.dispose();
      },
    );

    test(
      'pending writes finish after disposal without notifying disposed listeners',
      () async {
        final store = CinemaWebsiteStore(file: file, defaults: [website]);
        await store.load();
        final write = store.setRestoreLastSite(true);
        store.dispose();
        await write;
        final restored = CinemaWebsiteStore(file: file);
        await restored.load();
        expect(restored.restoreLastSite, isTrue);
        restored.dispose();
      },
    );
  });
}
