import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_models.dart';
import 'package:kazumi/features/cinema/cinema_nas_media.dart';
import 'package:kazumi/features/cinema/cinema_tv_cast_receiver.dart';

final _accountA = 'a' * 64, _accountB = 'b' * 64;
const _source = CinemaSource(
  id: 'fixture-online',
  name: 'Fixture',
  kind: CinemaSourceKind.direct,
  url: 'https://media.example/',
);
CinemaTitle _title({CinemaSource source = _source, String? url}) => CinemaTitle(
  id: 'fixture-film',
  sourceId: source.id,
  title: '测试影片',
  routes: [
    CinemaRoute(
      name: '正片',
      episodes: [
        CinemaEpisode(
          name: '第 1 集',
          url: url ?? 'https://media.example/episode.mp4',
        ),
      ],
    ),
  ],
);

class _NAS extends CinemaNASClient {
  String? account = _accountA;
  int reads = 0;
  @override
  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic>? arguments,
  ]) async {
    expect(method, 'currentSession');
    ++reads;
    return {if (account != null) 'namespace': account};
  }
}

void main() {
  test(
    'valid acceptance wakes then confirms and rechecks account before play',
    () async {
      final client = _NAS(), order = <String>[];
      final receiver = CinemaTVCastReceiver(
        client: client,
        wakeScreensaver: () async {
          order.add('wake');
        },
        confirm: (title, source, route, episode, position) async {
          order.add('confirm');
          expect(position, 42);
          return true;
        },
        play: (title, source, route, episode, position) {
          order.add('play');
          expect(position, 42);
        },
      );
      await receiver.receive(_title(), _source, 0, 0, 42);
      expect(order, ['wake', 'confirm', 'play']);
      expect(client.reads, 2);
    },
  );

  test(
    'decline preserves current playback and does not read a second session',
    () async {
      final client = _NAS();
      var plays = 0;
      final receiver = CinemaTVCastReceiver(
        client: client,
        confirm: (_, _, _, _, _) async => false,
        play: (_, _, _, _, _) {
          plays++;
        },
      );
      await receiver.receive(_title(), _source, 0, 0, 42);
      expect(plays, 0);
      expect(client.reads, 1);
    },
  );

  test(
    'account change while the confirmation is open rejects acceptance',
    () async {
      final client = _NAS(), decision = Completer<bool>();
      var prompts = 0, plays = 0;
      final receiver = CinemaTVCastReceiver(
        client: client,
        confirm: (_, _, _, _, _) {
          prompts++;
          return decision.future;
        },
        play: (_, _, _, _, _) {
          plays++;
        },
      );
      final request = receiver.receive(_title(), _source, 0, 0, 42);
      await Future<void>.delayed(Duration.zero);
      expect(prompts, 1);
      client.account = _accountB;
      decision.complete(true);
      await request;
      expect(plays, 0);
      expect(client.reads, 2);
    },
  );

  test('no account cannot wake, prompt or play', () async {
    final client = _NAS()..account = null;
    var wakes = 0, prompts = 0, plays = 0;
    final receiver = CinemaTVCastReceiver(
      client: client,
      wakeScreensaver: () async {
        wakes++;
      },
      confirm: (_, _, _, _, _) async {
        prompts++;
        return true;
      },
      play: (_, _, _, _, _) {
        plays++;
      },
    );
    await receiver.receive(_title(), _source, 0, 0, 42);
    expect([wakes, prompts, plays], [0, 0, 0]);
  });

  test(
    'a second pending request does not create another confirmation',
    () async {
      final client = _NAS(), decision = Completer<bool>();
      var prompts = 0;
      final receiver = CinemaTVCastReceiver(
        client: client,
        confirm: (_, _, _, _, _) {
          prompts++;
          return decision.future;
        },
        play: (_, _, _, _, _) {},
      );
      final first = receiver.receive(_title(), _source, 0, 0, 42);
      await Future<void>.delayed(Duration.zero);
      await receiver.receive(_title(), _source, 0, 0, 43);
      expect(prompts, 1);
      expect(client.reads, 1);
      decision.complete(false);
      await first;
    },
  );

  test(
    'confirmation exception releases the gate for the next request',
    () async {
      var prompts = 0, plays = 0;
      final receiver = CinemaTVCastReceiver(
        client: _NAS(),
        confirm: (_, _, _, _, _) async {
          if (++prompts == 1) throw StateError('fixture');
          return true;
        },
        play: (_, _, _, _, _) {
          plays++;
        },
      );
      await receiver.receive(_title(), _source, 0, 0, 42);
      await receiver.receive(_title(), _source, 0, 0, 43);
      expect(prompts, 2);
      expect(plays, 1);
    },
  );

  test('NAS references must all belong to the current namespace', () async {
    var prompts = 0, plays = 0;
    final receiver = CinemaTVCastReceiver(
      client: _NAS(),
      confirm: (_, _, _, _, _) async {
        prompts++;
        return true;
      },
      play: (_, _, _, _, _) {
        plays++;
      },
    );
    String ref(String account) => nasMediaReference(
      namespace: account,
      id: 1,
      library: 2,
      path: '/movies/one.mkv',
    );
    await receiver.receive(
      _title(source: cinemaNASSource, url: ref(_accountB)),
      cinemaNASSource,
      0,
      0,
      0,
    );
    expect([prompts, plays], [0, 0]);
    await receiver.receive(
      _title(source: cinemaNASSource, url: ref(_accountA)),
      cinemaNASSource,
      0,
      0,
      0,
    );
    expect([prompts, plays], [1, 1]);
    await receiver.receive(_title(url: ref(_accountA)), _source, 0, 0, 0);
    expect(
      [prompts, plays],
      [1, 1],
      reason: 'A NAS reference cannot masquerade as an online source.',
    );
  });

  test(
    'invalid route, episode, source and position are rejected before prompting',
    () async {
      var prompts = 0;
      final receiver = CinemaTVCastReceiver(
        client: _NAS(),
        confirm: (_, _, _, _, _) async {
          prompts++;
          return true;
        },
        play: (_, _, _, _, _) => fail('must not play'),
      );
      for (final indices in [
        [-1, 0, 0],
        [1, 0, 0],
        [0, -1, 0],
        [0, 1, 0],
        [0, 0, -1],
        [0, 0, 604801],
      ]) {
        await receiver.receive(
          _title(),
          _source,
          indices[0],
          indices[1],
          indices[2],
        );
      }
      await receiver.receive(
        _title(),
        _source.copyWith(id: 'other-source'),
        0,
        0,
        0,
      );
      expect(prompts, 0);
    },
  );

  test('becoming inactive after accepting does not start playback', () async {
    var active = true, plays = 0;
    final receiver = CinemaTVCastReceiver(
      client: _NAS(),
      isActive: () => active,
      confirm: (_, _, _, _, _) async {
        active = false;
        return true;
      },
      play: (_, _, _, _, _) {
        plays++;
      },
    );
    await receiver.receive(_title(), _source, 0, 0, 0);
    expect(plays, 0);
  });

  test(
    'a player-route lifetime cannot keep the confirmation gate busy',
    () async {
      final lifetime = Completer<void>();
      var prompts = 0;
      final receiver = CinemaTVCastReceiver(
        client: _NAS(),
        confirm: (_, _, _, _, _) async {
          prompts++;
          return prompts == 1;
        },
        play: (_, _, _, _, _) => lifetime.future,
      );
      final first = receiver.receive(_title(), _source, 0, 0, 0);
      await Future<void>.delayed(Duration.zero);
      await receiver.receive(_title(), _source, 0, 0, 0);
      expect(prompts, 2);
      lifetime.complete();
      await first;
    },
  );
}
