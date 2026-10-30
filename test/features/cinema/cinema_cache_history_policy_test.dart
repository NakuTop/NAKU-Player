import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_media_cache.dart';
import 'package:kazumi/features/cinema/cinema_store.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';

void main() {
  late Directory dir;
  late CinemaMediaCache cache;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('naku-history-cache-');
    cache = CinemaMediaCache(
      directory: dir,
      preferences: const CinemaCachePreferences(quotaMB: 1),
    );
  });
  tearDown(() async {
    await cache.shutdown();
    cache.dispose();
    // dispose invokes shutdown again; it must not race directory removal.
    await Future<void>.delayed(Duration.zero);
    await dir.delete(recursive: true);
  });
  Future<void> seed(Map<String, List<String>> owners) async {
    await File('${dir.path}/owners-v1.json').writeAsString(jsonEncode(owners));
  }

  Future<File> fragment(String name, {int bytes = 64, int age = 0}) async {
    final f = File('${dir.path}/$name.bin');
    await f.writeAsBytes(List.filled(bytes, 1));
    await f.setLastModified(DateTime.now().subtract(Duration(days: age)));
    return f;
  }

  test('quota evicts oldest accessed fragment first', () async {
    final older = await fragment('old', bytes: 700000, age: 3);
    final newer = await fragment('new', bytes: 700000, age: 1);
    await cache.initialize();
    expect(await older.exists(), false);
    expect(await newer.exists(), true);
    expect(cache.bytesUsed, 700000);
  });
  test('history deletion removes owned fragments even below quota', () async {
    final removed = await fragment('removed');
    final retained = await fragment('retained');
    await seed({
      'removed': ['season10'],
      'retained': ['season11'],
    });
    await cache.retainHistory({'season11'});
    expect(await removed.exists(), false);
    expect(await retained.exists(), true);
    expect(cache.bytesUsed, 64);
    final index =
        jsonDecode(await File('${dir.path}/owners-v1.json').readAsString())
            as Map;
    expect(index.containsKey('removed'), false);
  });
  test('shared fragment remains while any history owner remains', () async {
    final f = await fragment('shared');
    await seed({
      'shared': ['season10', 'season11'],
    });
    await cache.retainHistory({'season11'});
    expect(await f.exists(), true);
    await cache.retainHistory({});
    expect(await f.exists(), false);
  });
  test(
    'unknown legacy fragments remain bounded instead of misclassified',
    () async {
      final f = await fragment('legacy');
      await cache.retainHistory({});
      expect(await f.exists(), true);
    },
  );
  test('active title defers orphan deletion until session closes', () async {
    final f = await fragment('active');
    await seed({
      'active': ['playing'],
    });
    final opened = await cache.open(
      'https://example.invalid/video.m3u8',
      {},
      titleKey: 'playing',
      backgroundPrefetchAllowed: false,
    );
    await cache.retainHistory({});
    expect(await f.exists(), true);
    await opened!.session.close();
    expect(await f.exists(), false);
  });
  test('restart restores ownership before history reconciliation', () async {
    final f = await fragment('old');
    await seed({
      'old': ['season10'],
    });
    await cache.initialize();
    await cache.shutdown();
    cache.dispose();
    cache = CinemaMediaCache(directory: dir);
    await cache.retainHistory({'season11'});
    expect(await f.exists(), false);
  });
  test('real HTTP writes persist title ownership and history removal deletes it', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = HttpClient();
    origin.listen((request) async {
      if (request.uri.path.endsWith('.m3u8')) {
        request.response.write('#EXTM3U\n#EXTINF:10,\nsegment.ts\n#EXT-X-ENDLIST\n');
      } else {
        request.response.add(List.filled(1024, 7));
      }
      await request.response.close();
    });
    try {
      await cache.retainHistory({'season11'});
      final opened = await cache.open('http://127.0.0.1:${origin.port}/video.m3u8', {},
          titleKey: 'season11', backgroundPrefetchAllowed: false);
      final manifest = await (await client.getUrl(Uri.parse(opened!.url))).close();
      final text = await utf8.decoder.bind(manifest).join();
      final segment = text.split('\n').firstWhere((line) => line.startsWith('http'));
      final response = await (await client.getUrl(Uri.parse(segment))).close();
      expect(await response.fold<int>(0, (total, bytes) => total + bytes.length), 1024);
      await opened.session.close();
      final index = jsonDecode(await File('${dir.path}/owners-v1.json').readAsString()) as Map;
      expect(index.values.single, ['season11']);
      expect(dir.listSync().where((f) => f.path.endsWith('.bin')).length, 1);
      await cache.retainHistory({});
      expect(dir.listSync().where((f) => f.path.endsWith('.bin')), isEmpty);
    } finally {
      client.close(force: true);
      await origin.close(force: true);
    }
  });

  test('real library deletion notifies cache and removes its fragments', () async {
    final store = CinemaStore(file: File('${dir.path}/library.json'), defaults: [], sourcePacks: []);
    const title = CinemaTitle(id: 'season10', sourceId: 'source', title: '美国恐怖故事 第十季');
    await store.load();
    await store.recordProgress(title: title, routeIndex: 0, episodeIndex: 0,
        positionSeconds: 30, durationSeconds: 100);
    final f = await fragment('season10');
    await seed({'season10': [title.key]});
    await cache.bindHistory(store);
    expect(await f.exists(), true);
    await store.removeHistory(title);
    // A maintenance barrier waits for the notification's reconciliation.
    await cache.configure(cache.preferences);
    expect(await f.exists(), false);
    store.dispose();
  });
  test('failed library load never supplies an empty deletion policy', () async {
    final library = File('${dir.path}/library.json');
    await library.writeAsString('broken json');
    final store = CinemaStore(file: library, defaults: [], sourcePacks: []);
    final f = await fragment('known');
    await seed({'known': ['history-title']});
    await expectLater(cache.bindHistory(store), throwsFormatException);
    expect(await f.exists(), true);
    store.dispose();
  });

}
