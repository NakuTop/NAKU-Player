import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_search_discovery.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test(
    'live bilingual titles and actor work discovery',
    () async {
      final proxy = Uri.tryParse(Platform.environment['HTTPS_PROXY'] ?? '');
      if (proxy != null && proxy.host.isNotEmpty) {
        MacOSSystemProxy.setConfiguration({
          'HTTPSEnable': 1,
          'HTTPSProxy': proxy.host,
          'HTTPSPort': proxy.port,
        });
      }
      final repository = CinemaSearchDiscoveryRepository();
      final title = await repository.search('Mutiny');
      expect(
        title.titles.any((t) => t.id == '36889088' && t.title == '怒之杀'),
        isTrue,
      );
      final actor = await repository.search('Jason Statham');
      expect(actor.celebrityName, '杰森·斯坦森');
      expect(actor.titles, isNotEmpty);
      final more = await repository.actorWorks(
        actor.celebrityId,
        actor.celebrityName,
        start: actor.nextStart,
      );
      expect(more.nextStart, greaterThan(actor.nextStart));
    },
    skip: Platform.environment['NAKU_LIVE_TESTS'] != '1',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
