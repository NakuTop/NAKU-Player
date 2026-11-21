import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_original_engine.dart';
import 'package:kazumi/features/cinema/cinema_original_match.dart';

class _Streams extends CinemaOriginalEngine {
  _Streams(this.server);
  final HttpServer server;
  final opened = <String>[], released = <String>[];

  @override
  Future<OriginalStream> open(
    OriginalMatches matches,
    OriginalEdition edition, {
    required CancelToken cancel,
    Duration budget = const Duration(seconds: 15),
  }) async {
    opened.add(edition.hash);
    return OriginalStream(
      Uri.http('127.0.0.1:${server.port}', '/${edition.hash}'),
      {'X-Fixture': 'range-check'},
      OriginalFile(1, edition.name, 50 << 20),
      () async {
        released.add(edition.hash);
      },
    );
  }
}

OriginalEdition _edition(String hash, int seeds, {bool chinese = false}) =>
    OriginalEdition(
      hash: hash,
      name: 'Open Film 2025 2160p ${chinese ? "CHS" : "WEB"}',
      seeds: seeds,
      pack: false,
      size: 50 << 20,
      magnet: '',
      subtitleHint: chinese,
    );

void main() {
  test(
    'real range reads prefer the faster edition even when a slow Chinese edition has 100 seeds',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final engine = _Streams(server);
      addTearDown(() => server.close(force: true));
      final paths = <String, String?>{};
      final prefix = Uint8List(512 * 1024);
      final slowGate = Completer<void>();
      final done = Completer<void>();
      server.listen((request) async {
        final name = request.uri.pathSegments.single;
        paths[name] = request.headers.value(HttpHeaders.rangeHeader);
        try {
          expect(request.headers.value('X-Fixture'), 'range-check');
          request.response.statusCode = 206;
          if (name == 'offline') {
            request.response.statusCode = 503;
            return;
          }
          request.response.contentLength = prefix.length;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes 0-524287/52428800',
          );
          if (name == 'many') await slowGate.future;
          request.response.add(prefix);
        } finally {
          try {
            await request.response.close();
          } on SocketException {
            /* client selected a different edition */
          }
          if (name == 'many' && !done.isCompleted) done.complete();
        }
      });
      final many = _edition('many', 100, chinese: true),
          few = _edition('few', 3),
          offline = _edition('offline', 22);
      final matches = OriginalMatches(
        OriginalWork(names: ['Open Film'], years: {'2025'}),
        [many, offline, few],
      );
      final failed = <String>[];
      expect(engine.preferred(matches)?.edition, same(many));
      final result = await engine.openFastest(
        matches,
        many,
        excluding: {},
        cancel: CancelToken(),
        onFailure: failed.add,
      );
      try {
        expect(result.edition, same(few));
        expect(result.stream.url.path, '/few');
        expect(engine.opened, ['many', 'offline', 'few']);
        expect(paths, {
          'many': 'bytes=0-524287',
          'few': 'bytes=0-524287',
          'offline': 'bytes=0-524287',
        });
        expect(failed, ['offline']);
        expect(engine.released, isNot(contains('few')));
      } finally {
        slowGate.complete();
        await result.stream.close();
      }
      await done.future.timeout(const Duration(seconds: 3));
      for (var i = 0; i < 30 && engine.released.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.released, unorderedEquals(['many', 'offline', 'few']));
    },
  );

  test(
    'a lower-count candidate is tried while the three busiest swarms are still silent',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final engine = _Streams(server);
      server.listen((request) async {
        if (request.uri.path != '/fourth') return;
        request.response.statusCode = 206;
        request.response.contentLength = 512 * 1024;
        request.response.add(Uint8List(512 * 1024));
        await request.response.close();
      });
      final versions = [
        _edition('one', 100),
        _edition('two', 80),
        _edition('three', 60),
        _edition('fourth', 3),
      ];
      final matches = OriginalMatches(
        OriginalWork(names: ['Open Film'], years: {'2025'}),
        versions,
      );
      final failed = <String>[];
      final result = await engine
          .openFastest(
            matches,
            versions.first,
            excluding: {},
            cancel: CancelToken(),
            onFailure: failed.add,
          )
          .timeout(const Duration(seconds: 7));
      expect(result.edition.hash, 'fourth');
      expect(failed, isEmpty);
      await result.stream.close();
    },
  );

  test(
    'changing source cancels every pending read and releases every lease',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final engine = _Streams(server), bothRequested = Completer<void>();
      var count = 0;
      server.listen((req) {
        if (++count == 2) bothRequested.complete();
      });
      final two = [_edition('one', 20), _edition('two', 4)];
      final matches = OriginalMatches(
        OriginalWork(names: ['Open Film'], years: {'2025'}),
        two,
      );
      final cancel = CancelToken(), failed = <String>[];
      final pending = engine.openFastest(
        matches,
        two.first,
        excluding: {},
        cancel: cancel,
        onFailure: failed.add,
      );
      await bothRequested.future.timeout(const Duration(seconds: 3));
      cancel.cancel('manual change');
      await expectLater(pending, throwsA(isA<FormatException>()));
      for (var i = 0; i < 30 && engine.released.length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.released, unorderedEquals(['one', 'two']));
      expect(failed, isEmpty);
    },
  );

  test(
    'the measured peer rate distinguishes similarly quick cached first reads',
    () {
      const quick = OriginalStartupSample(25, 60, 524288, 5000000);
      const trickle = OriginalStartupSample(18, 40, 524288, 180000);
      expect(quick.startupEstimate, lessThan(trickle.startupEstimate));
    },
  );
}
