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
  testWidgets(
    'visible selectors apply actual NAS IDs without opening a modal',
    (tester) async {
      CinemaNASPlaybackSelection? applied;
      await tester.pumpWidget(_host(onApply: (value) => applied = value));
      expect(find.text('清晰度'), findsOneWidget);
      expect(find.text('NAS 音轨'), findsOneWidget);
      expect(find.text('NAS 字幕'), findsOneWidget);
      expect(find.text('当前输出约 2.50 Mbps'), findsOneWidget);
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged!('480p');
      await tester.pump();
      final fields = find.byType(DropdownButtonFormField<int>);
      tester.widget<DropdownButtonFormField<int>>(fields.at(0)).onChanged!(31);
      tester.widget<DropdownButtonFormField<int>>(fields.at(1)).onChanged!(27);
      await tester.pump();
      await tester.tap(find.text('应用并保留播放进度'));
      await tester.pump();
      expect(applied?.resolution, '480p');
      expect(applied?.audio, 31);
      expect(applied?.subtitle, 27);
      expect(find.byType(CinemaNASInlinePlaybackControls), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  testWidgets('disabled controls cannot apply or change tracks', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(enabled: false, onApply: (_) => fail('disabled apply')),
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          )
          .onChanged,
      isNull,
    );
    for (final field in tester.widgetList<DropdownButtonFormField<int>>(
      find.byType(DropdownButtonFormField<int>),
    )) {
      expect(field.onChanged, isNull);
    }
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets(
    'actual playback changes replace form state and original disables NAS tracks',
    (tester) async {
      CinemaNASPlaybackSelection? applied;
      await tester.pumpWidget(_host(onApply: (value) => applied = value));
      await tester.pumpWidget(
        _host(
          resolution: '480p',
          audio: 31,
          subtitle: 27,
          onApply: (value) => applied = value,
        ),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byType(DropdownButtonFormField<String>),
            )
            .initialValue,
        '480p',
      );
      final fields = find.byType(DropdownButtonFormField<int>);
      expect(
        tester.widget<DropdownButtonFormField<int>>(fields.at(0)).initialValue,
        31,
      );
      expect(
        tester.widget<DropdownButtonFormField<int>>(fields.at(1)).initialValue,
        27,
      );
      await tester.pumpWidget(
        _host(
          resolution: nasOriginalFileProfile,
          audio: 31,
          subtitle: 27,
          onApply: (value) => applied = value,
        ),
      );
      for (final field in tester.widgetList<DropdownButtonFormField<int>>(
        fields,
      )) {
        expect(field.onChanged, isNull);
      }
      await tester.tap(find.text('应用并保留播放进度'));
      expect(applied?.resolution, nasOriginalFileProfile);
      expect(applied?.audio, isNull);
      expect(applied?.subtitle, isNull);
    },
  );

  testWidgets('narrow controls wrap without overflow', (tester) async {
    await tester.pumpWidget(_host(width: 180, onApply: (_) {}));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('NAS 音轨'), findsOneWidget);
    expect(find.text('NAS 字幕'), findsOneWidget);
    final resolution = tester.getTopLeft(
      find.byType(DropdownButtonFormField<String>),
    );
    final audio = tester.getTopLeft(
      find.byType(DropdownButtonFormField<int>).first,
    );
    expect(audio.dy, greaterThan(resolution.dy));
  });
}
