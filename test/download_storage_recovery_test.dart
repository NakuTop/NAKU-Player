import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:kazumi/services/download/download_catalog.dart';
import 'package:kazumi/services/download/download_integrity.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:path/path.dart' as p;
import 'package:hive_ce/hive.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _RecoveryPaths extends PathProviderPlatform {
  _RecoveryPaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

const mp4 = <int>[
  0,
  0,
  0,
  8,
  109,
  111,
  111,
  118,
  0,
  0,
  0,
  9,
  109,
  100,
  97,
  116,
  1,
];
Future<File> video(String root, String series, int episode) async {
  final f = File(p.join(root, series, '$episode', 'video.mp4'));
  await f.parent.create(recursive: true);
  await f.writeAsBytes(mp4);
  return f;
}

Future<Directory> hls(String root, int episode, {int init = 1}) async {
  final dir = await Directory(
    p.join(root, '42_fixture', '$episode'),
  ).create(recursive: true);
  await File(p.join(dir.path, 'playlist.m3u8')).writeAsString(
    '#EXTM3U\n#EXT-X-MAP:URI="init_0.mp4"\n#EXTINF:5,\nseg_00000.ts\n#EXT-X-ENDLIST\n',
  );
  await File(p.join(dir.path, 'init_0.mp4')).writeAsBytes([init]);
  await File(p.join(dir.path, 'seg_00000.ts')).writeAsBytes([2, 3, 4]);
  return dir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('naku-recovery-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  for (final mode in ['hold', 'legacy-hold']) {
    test(
      'OS lock against $mode preserves bytes and records after restart',
      () async {
        final dart = p.normalize(
          p.join(Directory.current.path, '../toolchains/flutter/bin/dart'),
        );
        const script = 'test/native/storage_guard_probe.dart';
        final holder = await Process.start(dart, [
          'run',
          script,
          mode,
          root.path,
        ]);
        addTearDown(() async {
          holder.kill();
        });
        final ready = await holder.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first;
        expect(jsonDecode(ready)['ready'], true);
        final db = File(p.join(root.path, 'downloads.hive'));
        final before = sha256.convert(await db.readAsBytes());
        final lock = File(p.join(root.path, 'downloads.lock'));
        final lockBefore = await lock.readAsBytes();
        final compacting = File(p.join(root.path, 'downloads.hivec'));
        await compacting.writeAsString('active compaction must be preserved');
        final contender = await Process.run(dart, [
          'run',
          script,
          'probe',
          root.path,
        ]);
        expect(
          contender.exitCode,
          73,
          reason: '${contender.stdout} ${contender.stderr}',
        );
        expect(jsonDecode('${contender.stdout}'.trim())['busy'], true);
        expect(sha256.convert(await db.readAsBytes()), before);
        expect(await lock.readAsBytes(), lockBefore);
        expect(
          await compacting.readAsString(),
          'active compaction must be preserved',
        );
        holder.stdin.writeln('close');
        await holder.stdin.close();
        expect(await holder.exitCode, 0);
        final reopened = await Process.run(dart, [
          'run',
          script,
          'probe',
          root.path,
        ]);
        expect(reopened.exitCode, 0, reason: '${reopened.stderr}');
        expect(jsonDecode('${reopened.stdout}'.trim())['records'], 1);
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }

  test(
    'a real emptied Hive index is restored from the independent catalog without redownloading',
    () async {
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _RecoveryPaths(root.path);
      await Directory(p.join(root.path, 'hive')).create();
      Hive.init(p.join(root.path, 'hive'));
      await GStorage.init();
      try {
        final f = await video(p.join(root.path, 'downloads'), '42_fixture', 1);
        final catalog = await DownloadCatalog.application();
        final scanned = await catalog.recover([p.join(root.path, 'downloads')]);
        scanned.single.bangumiName = '升级前标题';
        await catalog.save(scanned.single);
        expect(GStorage.downloads.length, 0);
        final first = DownloadRepository();
        expect(await first.recoverLocalRecords(), 1);
        expect(first.getRecord('fixture_42')!.bangumiName, '升级前标题');
        await GStorage.downloads.clear();
        await GStorage.downloads.flush();
        final restored = DownloadRepository();
        expect(await restored.recoverLocalRecords(), 1);
        expect(await restored.recoverLocalRecords(), 0);
        expect(
          restored.getAllRecords().single.episodes[1]!.localM3u8Path,
          f.path,
        );
        expect(await f.readAsBytes(), mp4);
      } finally {
        await Hive.close();
        PathProviderPlatform.instance = oldPaths;
      }
    },
  );

  test('corrupt database is preserved byte for byte', () async {
    final db = File(p.join(root.path, 'downloads.hive'));
    final bytes = List.generate(117, (i) => (i * 31) % 256);
    await db.writeAsBytes(bytes);
    final result = await Process.run(
      p.normalize(
        p.join(Directory.current.path, '../toolchains/flutter/bin/dart'),
      ),
      ['run', 'test/native/storage_guard_probe.dart', 'probe', root.path],
    );
    expect(result.exitCode, 73, reason: '${result.stderr}');
    expect(jsonDecode('${result.stdout}'.trim())['busy'], false);
    expect(await db.readAsBytes(), bytes);
  });

  test(
    'a crashed database owner releases only the OS lock and records reopen intact',
    () async {
      final dart = p.normalize(
        p.join(Directory.current.path, '../toolchains/flutter/bin/dart'),
      );
      const script = 'test/native/storage_guard_probe.dart';
      final holder = await Process.start(dart, [
        'run',
        script,
        'hold',
        root.path,
      ]);
      addTearDown(() async {
        holder.kill();
      });
      final ready = await holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      expect(jsonDecode(ready)['ready'], true);
      final before = await File(
        p.join(root.path, 'downloads.hive'),
      ).readAsBytes();
      holder.kill(ProcessSignal.sigkill);
      await holder.exitCode;
      expect(await File(p.join(root.path, 'downloads.lock')).exists(), isTrue);
      final reopened = await Process.run(dart, [
        'run',
        script,
        'probe',
        root.path,
      ]);
      expect(reopened.exitCode, 0, reason: '${reopened.stderr}');
      expect(jsonDecode('${reopened.stdout}'.trim())['records'], 1);
      expect(
        await File(p.join(root.path, 'downloads.hive')).readAsBytes(),
        before,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'old HLS downloads without markers still prevent duplicate completion and recovery',
    () async {
      final one = await hls(root.path, 1);
      final two = await hls(root.path, 2);
      await expectLater(
        DownloadIntegrity.verifyHls(two),
        throwsA(isA<DuplicateDownloadException>()),
      );
      expect(await DownloadCatalog.findVideo(one), isNotNull);
      expect(await DownloadCatalog.findVideo(two), isNull);
      final catalog = DownloadCatalog(Directory(p.join(root.path, 'index')));
      final recovered = await catalog.recover([root.path]);
      expect(recovered.single.episodes.keys.toList(), [1]);
      expect(await File(p.join(one.path, 'seg_00000.ts')).readAsBytes(), [
        2,
        3,
        4,
      ]);
    },
  );

  test(
    'removed media cannot leave a ghost duplicate marker and init data distinguishes HLS',
    () async {
      final one = await hls(root.path, 1);
      await DownloadIntegrity.verifyHls(one);
      final marker = await File(
        p.join(one.path, '.naku-content.json'),
      ).readAsString();
      await File(p.join(one.path, 'seg_00000.ts')).delete();
      final two = await hls(root.path, 2);
      await DownloadIntegrity.verifyHls(two);
      expect(
        await File(p.join(one.path, '.naku-content.json')).readAsString(),
        marker,
      );
      final three = await hls(root.path, 3, init: 9);
      await DownloadIntegrity.verifyHls(three);
      expect(await DownloadCatalog.findVideo(two), isNotNull);
      expect(await DownloadCatalog.findVideo(three), isNotNull);
    },
  );

  test(
    'an unknown future adapter preserves the database instead of resetting it',
    () async {
      final dart = p.normalize(
        p.join(Directory.current.path, '../toolchains/flutter/bin/dart'),
      );
      const script = 'test/native/storage_guard_probe.dart';
      final written = await Process.run(dart, [
        'run',
        script,
        'future',
        root.path,
      ]);
      expect(written.exitCode, 0, reason: '${written.stderr}');
      final db = File(p.join(root.path, 'downloads.hive'));
      final before = await db.readAsBytes();
      final result = await Process.run(dart, [
        'run',
        script,
        'probe',
        root.path,
      ]);
      expect(result.exitCode, 73, reason: '${result.stderr}');
      expect(await db.readAsBytes(), before);
    },
  );

  test(
    'empty index recovery, sidecar roundtrip and deletion tombstone are idempotent',
    () async {
      final media = p.join(root.path, 'media');
      final f = await video(media, '42_fixture', 1);
      final catalog = DownloadCatalog(Directory(p.join(root.path, 'index')));
      final initial = await catalog.recover([media]);
      expect(initial.single.episodes[1]!.status, DownloadStatus.completed);
      initial.single.bangumiName = '保留标题';
      initial.single.mediaMetadata = 'original-metadata';
      await catalog.save(initial.single);
      final reloaded = await catalog.recover([media]);
      expect(reloaded.single.bangumiName, '保留标题');
      expect(reloaded.single.episodes[1]!.localM3u8Path, f.path);
      expect(reloaded.single.mediaMetadata, 'original-metadata');
      await catalog.remove(initial.single.key);
      expect(await catalog.recover([media]), isEmpty);
      final primary =
          (await catalog.directory
                  .list()
                  .where((f) => f.path.endsWith('.json'))
                  .toList())
              .single;
      await File(primary.path).writeAsString('interrupted metadata');
      expect(await catalog.recover([media]), isEmpty);
      expect(await f.readAsBytes(), mp4);
    },
  );

  test(
    'partial MP4, pending transfers, remote HLS and symlinks never become completed',
    () async {
      final media = p.join(root.path, 'media');
      final f = await video(media, '42_fixture', 1);
      await f.writeAsBytes([0, 0, 0, 99, 109, 111, 111, 118]);
      final tmp = File(p.join(media, '42_fixture', '2', 'video.mp4.tmp'));
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(mp4);
      final hls = File(p.join(media, '42_fixture', '3', 'playlist.m3u8'));
      await hls.parent.create(recursive: true);
      await hls.writeAsString(
        '#EXTM3U\n#EXTINF:5,\nhttps://remote.invalid/1.ts\n#EXT-X-ENDLIST\n',
      );
      final outside = await video(root.path, 'outside', 1);
      await Link(p.join(media, '42_fixture', '4')).create(outside.parent.path);
      final catalog = DownloadCatalog(Directory(p.join(root.path, 'index')));
      expect(await catalog.recover([media]), isEmpty);
    },
  );

  test(
    'duplicate content across URLs and replacing a different existing video are blocked',
    () async {
      final old = await video(root.path, '42_fixture', 1);
      final second = File(
        p.join(root.path, '42_fixture', '2', 'video.mp4.tmp'),
      );
      await second.parent.create(recursive: true);
      await second.writeAsBytes(mp4);
      await expectLater(
        DownloadIntegrity.commitFile(
          second,
          File(p.join(second.parent.path, 'video.mp4')),
        ),
        throwsA(isA<DuplicateDownloadException>()),
      );
      expect(await old.readAsBytes(), mp4);
      expect(await second.exists(), true);
      final staged = File('${old.path}.tmp');
      await staged.writeAsBytes([...mp4, 2]);
      await expectLater(
        DownloadIntegrity.commitFile(staged, old),
        throwsA(isA<FileSystemException>()),
      );
      expect(await old.readAsBytes(), mp4);
    },
  );

  test(
    'different episodes commit and a missing file is recovered as paused',
    () async {
      final one = await video(root.path, '42_fixture', 1);
      final two = File(p.join(root.path, '42_fixture', '2', 'video.mp4.tmp'));
      await two.parent.create(recursive: true);
      await two.writeAsBytes([...mp4.take(mp4.length - 1), 2]);
      await DownloadIntegrity.commitFile(
        two,
        File(p.join(two.parent.path, 'video.mp4')),
      );
      final catalog = DownloadCatalog(Directory(p.join(root.path, 'index')));
      final recovered = await catalog.recover([root.path]);
      expect(recovered.single.episodes.length, 2);
      await catalog.save(recovered.single);
      await one.delete();
      final again = await catalog.recover([root.path]);
      expect(again.single.episodes[1]!.status, DownloadStatus.paused);
      expect(again.single.episodes[2]!.status, DownloadStatus.completed);
    },
  );
}
