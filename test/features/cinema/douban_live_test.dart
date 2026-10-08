import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/douban/douban_models.dart';
import 'package:kazumi/features/cinema/douban/douban_repository.dart';
import 'package:kazumi/services/network/macos_system_proxy.dart';

void main() {
  test('live official recommendations', () async {
    final proxy = Uri.tryParse(Platform.environment['HTTPS_PROXY'] ?? '');
    if (proxy != null && proxy.host.isNotEmpty) {
      MacOSSystemProxy.setConfiguration({
        'HTTPSEnable': 1,
        'HTTPSProxy': proxy.host,
        'HTTPSPort': proxy.port,
      });
    }
    final repo = DoubanRepository();
    final result = <String, dynamic>{};
    for (final kind in DoubanKind.values) {
      final page = await repo.browse(kind: kind);
      expect(page.items, isNotEmpty);
      result[kind.name] = {
        'count': page.items.length,
        'total': page.total,
        'sorts': page.sorts.map((e) => e.text).toList(),
        'sample': page.items
            .take(2)
            .map((e) => {'id': e.id, 'title': e.title, 'score': e.score})
            .toList(),
      };
    }
    await File(
      '../douban-live.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
  }, skip: Platform.environment['NAKU_LIVE_TESTS'] != '1');
}
