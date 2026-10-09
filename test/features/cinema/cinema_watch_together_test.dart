import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_sync_session.dart';
import 'package:kazumi/features/cinema/cinema_watch_together.dart';
import 'cinema_sync_test.dart' show FakeClient;

class _DelayedDisconnect extends FakeClient {
  Completer<void>? block;
  Completer<void>? entered;
  @override
  Future<void> disconnect() async {
    entered?.complete();
    await block?.future;
    await super.disconnect();
  }
}

void main() {
  test(
    'missing platform storage does not throw out of player initialization',
    () async {
      final together = CinemaWatchTogether();
      addTearDown(together.dispose);
      await together.initialize();
      expect(together.isPaired, isFalse);
      expect(together.session.connected, isFalse);
    },
  );

  for (final unpairLast in [true, false]) {
    test(
      'latest pairing mutation wins delayed disconnect: unpairLast=$unpairLast',
      () async {
        final dir = await Directory.systemTemp.createTemp('pair-race-');
        final file = File('${dir.path}/pair.json');
        final first = _DelayedDisconnect();
        var clients = 0;
        final together = CinemaWatchTogether(
          pairingFile: file,
          clientFactory: (_, _) => clients++ == 0 ? first : FakeClient(),
        );
        addTearDown(() async {
          together.dispose();
          await dir.delete(recursive: true);
        });
        await together.pair(
          endpoint: 'example.com:8996',
          roomName: 'first',
          username: 'me',
        );
        first.block = Completer<void>();
        first.entered = Completer<void>();
        final delayed = unpairLast
            ? together.pair(
                endpoint: 'example.com:8996',
                roomName: 'obsolete',
                username: 'me',
              )
            : together.unpair();
        await first.entered!.future;
        if (unpairLast) {
          await together.unpair();
        } else {
          await together.pair(
            endpoint: 'example.com:8996',
            roomName: 'latest',
            username: 'me',
          );
        }
        first.block!.complete();
        await delayed;
        final saved = jsonDecode(await file.readAsString());
        expect(together.isPaired, !unpairLast);
        if (unpairLast) {
          expect(saved['paired'], isFalse);
          expect(together.session.connected, isFalse);
        } else {
          expect(saved['room'], 'latest');
          expect(together.session.room, 'latest');
        }
      },
    );
  }

  test(
    'catalogue hints permit verified missing ID but reject conflicts, seasons and episodes',
    () {
      CinemaTitle work({
        String id = '12345',
        String year = '2022',
        String name = '流人第一季',
        String ep = '第01集',
      }) => CinemaTitle(
        id: 'one',
        sourceId: 'local',
        title: name,
        year: year,
        category: '欧美剧',
        doubanId: id,
        routes: [
          CinemaRoute(
            name: 'local',
            episodes: [
              CinemaEpisode(name: ep, url: 'https://local.invalid/video'),
            ],
          ),
        ],
      );
      final anchor = work();
      final media = CinemaSyncMedia.fromSelection(
        anchor,
        anchor.routes.single.episodes.single,
      );
      bool matches(CinemaTitle target) =>
          media.matches(target, target.routes.single.episodes.single);
      expect(matches(work(id: '', ep: 'EP01', name: '流人第一季（国语版）')), isTrue);
      expect(matches(work(id: '67890')), isFalse);
      expect(matches(work(year: '2023')), isFalse);
      expect(matches(work(name: '流人第二季')), isFalse);
      expect(matches(work(ep: '第02集')), isFalse);
      final decoded = CinemaSyncMedia.fromJson({
        ...media.toJson(),
        'url': 'https://untrusted.invalid/execute',
      });
      expect(decoded!.toJson().containsKey('url'), isFalse);
      expect(
        CinemaSyncMedia.fromJson({...media.toJson(), 'title': 'bad\ncommand'}),
        isNull,
      );
    },
  );

  test(
    'cancel expected peer state allows same ready movie to seed a new room',
    () async {
      var states = 0;
      final client = _CountingClient(() => states++);
      final session = CinemaSyncSession(
        position: () => const Duration(seconds: 12),
        duration: () => const Duration(hours: 2),
        playing: () => true,
        applyRemote: (_, _) async {},
        clientFactory: (_, _) => client,
      );
      addTearDown(session.dispose);
      const episode = CinemaEpisode(
        name: '第01集',
        url: 'https://local.invalid/video',
      );
      const title = CinemaTitle(
        id: 'a',
        sourceId: 'a',
        title: '流人第一季',
        year: '2022',
        category: '欧美剧',
      );
      await session.updateMedia(
        title,
        episode,
        canonical: CinemaSyncMedia.fromSelection(title, episode),
      );
      expect(session.awaitingPeerState, isTrue);
      session.cancelExpectedPeerState();
      await session.connect(
        endpoint: 'example.com:8996',
        roomName: 'new-room',
        username: 'me',
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(session.awaitingPeerState, isFalse);
      expect(states, 1);
    },
  );
}

class _CountingClient extends FakeClient {
  _CountingClient(this.count);
  final void Function() count;
  @override
  Future<void> sendSyncPlaySyncRequest({bool? doSeek}) async => count();
}
