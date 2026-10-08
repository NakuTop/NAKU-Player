import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_website_store.dart';
import 'package:kazumi/features/cinema/cinema_websites_page.dart';

void main() {
  late Directory directory;
  late File file;
  late CinemaWebsiteStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('cinema-websites-ui-');
    file = File('${directory.path}/websites.json');
    store = CinemaWebsiteStore(
      file: file,
      defaults: const [
        CinemaWebsite(id: 'film', name: '影视样例', url: 'https://example.com/'),
        CinemaWebsite(
          id: 'anime',
          name: '动漫样例',
          url: 'https://example.org/',
          category: '动漫',
        ),
      ],
    );
  });
  tearDown(() async {
    await store.flush();
    store.dispose();
    await directory.delete(recursive: true);
  });
  testWidgets(
    'website category filter keeps matching website and preserves library',
    (tester) async {
      await tester.runAsync(store.load);
      await tester.pumpWidget(
        MaterialApp(home: CinemaWebsitesPage(store: store)),
      );
      await tester.pumpAndSettle();
      expect(find.text('影视样例'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '动漫'));
      await tester.pumpAndSettle();
      expect(find.text('影视样例'), findsNothing);
      expect(find.text('动漫样例'), findsOneWidget);
      expect(store.sites.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'restore preference can be changed through the screen and survives reload',
    (tester) async {
      await tester.runAsync(store.load);
      await tester.pumpWidget(
        MaterialApp(home: CinemaWebsitesPage(store: store)),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch));
        await store.flush();
      });
      await tester.pumpAndSettle();
      final reopened = CinemaWebsiteStore(file: file);
      await tester.runAsync(reopened.load);
      expect(reopened.restoreLastSite, isTrue);
      expect(reopened.lastSiteId, isNull);
      reopened.dispose();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
