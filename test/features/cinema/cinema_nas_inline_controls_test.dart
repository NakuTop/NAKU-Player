import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/features/cinema/cinema_nas_playback.dart';

final _options = CinemaNASPlaybackOptions.fromMap({
  'profiles': [
    {'id': '1080p', 'label': '1080P 高清'},
    {'id': '480p', 'label': '480P 流畅'},
  ],
  'audios': [
    {'id': 12, 'label': '国语 · EAC3'},
    {'id': 31, 'label': '英语 · AAC'},
  ],
  'subtitles': [
    {'id': -1, 'label': '关闭 NAS 字幕'},
    {'id': 27, 'label': '简体中文'},
  ],
});

Widget _host({
  required ValueChanged<CinemaNASPlaybackSelection> onApply,
  bool enabled = true,
  String resolution = '1080p',
  int? audio = 12,
  int? subtitle = -1,
  double width = 720,
}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: SizedBox(
        width: width,
        child: CinemaNASInlinePlaybackControls(
          options: _options,
          resolution: resolution,
          audio: audio,
          subtitle: subtitle,
          enabled: enabled,
          bitrate: 2500000,
          onApply: onApply,
        ),
      ),
    ),
  ),
);

void main() {
  Future<void> select(
    WidgetTester tester,
    String trigger,
    String option,
  ) async {
    await tester.tap(find.text(trigger));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  testWidgets('independent menus immediately apply real NAS IDs', (
    tester,
  ) async {
    CinemaNASPlaybackSelection? applied;
    await tester.pumpWidget(_host(onApply: (v) => applied = v));
    expect(find.text('清晰度'), findsOneWidget);
    expect(find.text('NAS 音轨'), findsOneWidget);
    expect(find.text('NAS 字幕'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('应用并保留播放进度'), findsNothing);
    await select(tester, '清晰度', '480P 流畅');
    expect(applied?.resolution, '480p');
    expect(applied?.audio, 12);
    expect(applied?.subtitle, -1);
    await tester.pumpWidget(
      _host(resolution: '480p', onApply: (v) => applied = v),
    );
    await select(tester, 'NAS 音轨', '英语 · AAC');
    expect(applied?.audio, 31);
    await tester.pumpWidget(
      _host(resolution: '480p', audio: 31, onApply: (v) => applied = v),
    );
    await select(tester, 'NAS 字幕', '简体中文');
    expect(applied?.subtitle, 27);
    expect(applied?.audio, 31);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('disabled controls cannot open selection menus', (tester) async {
    await tester.pumpWidget(
      _host(enabled: false, onApply: (_) => fail('disabled')),
    );
    expect(
      tester
          .widget<PopupMenuButton<String>>(find.byType(PopupMenuButton<String>))
          .enabled,
      false,
    );
    for (final menu in tester.widgetList<PopupMenuButton<int>>(
      find.byType(PopupMenuButton<int>),
    )) {
      expect(menu.enabled, false);
    }
  });

  testWidgets(
    'new playback values update selection and original disables NAS tracks',
    (tester) async {
      CinemaNASPlaybackSelection? applied;
      await tester.pumpWidget(_host(onApply: (v) => applied = v));
      await tester.pumpWidget(
        _host(
          resolution: '480p',
          audio: 31,
          subtitle: 27,
          onApply: (v) => applied = v,
        ),
      );
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>),
            )
            .initialValue,
        '480p',
      );
      expect(
        tester
            .widget<PopupMenuButton<int>>(
              find.byType(PopupMenuButton<int>).first,
            )
            .initialValue,
        31,
      );
      await select(tester, '清晰度', '原文件直连');
      expect(applied?.resolution, nasOriginalFileProfile);
      expect(applied?.audio, isNull);
      expect(applied?.subtitle, isNull);
      await tester.pumpWidget(
        _host(resolution: nasOriginalFileProfile, onApply: (_) {}),
      );
      for (final menu in tester.widgetList<PopupMenuButton<int>>(
        find.byType(PopupMenuButton<int>),
      )) {
        expect(menu.enabled, false);
      }
    },
  );

  testWidgets('narrow menu triggers wrap without overflow', (tester) async {
    await tester.pumpWidget(_host(width: 180, onApply: (_) {}));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('NAS 音轨')).dy,
      greaterThan(tester.getTopLeft(find.text('清晰度')).dy),
    );
  });
}
