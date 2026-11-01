import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/repositories/collect_crud_repository.dart';
import 'package:kazumi/services/plugin/anime_source_names.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';

class _Crud extends Fake implements ICollectCrudRepository {}

Plugin _plugin(String name) => Plugin.fromTemplate()..name = name;
void main() {
  test(
    'source keywords retain seasons, prioritize Chinese/original and deduplicate typography',
    () {
      expect(
        animeSourceKeywords(
          chineseTitle: ' 测试动画 第二季 ',
          originalTitle: 'Test Animation II',
          aliases: ['测试动画：第二季', '测试动画 第一季', '別名'],
        ),
        ['测试动画 第二季', 'Test Animation II', '测试动画 第一季', '別名'],
      );
      expect(mergeAnimeSourceAliases(['新官方别名'], ['旧自定义别名', '新官方别名']), [
        '新官方别名',
        '旧自定义别名',
      ]);
    },
  );
  test(
    'empty Chinese results retry original name and stop at a confirmed title',
    () async {
      final info = InfoController(CollectController(_Crud()));
      final plugins = PluginsController()..pluginList.add(_plugin('fixture'));
      final names = <String>[];
      final service = PluginSearchService(
        infoController: info,
        pluginsController: plugins,
        searchRunner: (p, keyword, token) async {
          names.add(keyword);
          if (keyword == '中文名') throw const NoResultException('fixture');
          return PluginSearchResponse(
            pluginName: p.name,
            data: [
              SearchItem(name: 'Original Name', src: 'https://example.com/1'),
            ],
          );
        },
      );
      addTearDown(service.cancel);
      await service.queryAllSource(
        '中文名',
        alternativeKeywords: ['Original Name', '其他别名'],
      );
      expect(names, ['中文名', 'Original Name']);
      expect(info.pluginSearchStatus['fixture'], PluginSearchStatus.success);
      expect(service.effectiveKeywords['fixture'], 'Original Name');
    },
  );
  test(
    'broad unrelated results do not suppress explicit alias search',
    () async {
      final info = InfoController(CollectController(_Crud()));
      final plugins = PluginsController()..pluginList.add(_plugin('fixture'));
      final service = PluginSearchService(
        infoController: info,
        pluginsController: plugins,
        searchRunner: (p, keyword, token) async => PluginSearchResponse(
          pluginName: p.name,
          data: [
            SearchItem(
              name: keyword == '中文名' ? '其他作品' : keyword,
              src: 'https://example.com/$keyword',
            ),
          ],
        ),
      );
      addTearDown(service.cancel);
      await service.queryAllSource(
        '中文名',
        alternativeKeywords: ['Original Name'],
      );
      expect(
        info.pluginSearchResponseList.single.data.first.name,
        'Original Name',
      );
    },
  );
  test('captcha stops aliases while independent sources continue', () async {
    final info = InfoController(CollectController(_Crud()));
    final plugins = PluginsController()
      ..pluginList.addAll([_plugin('captcha'), _plugin('working')]);
    final calls = <String>[];
    final service = PluginSearchService(
      infoController: info,
      pluginsController: plugins,
      searchRunner: (p, keyword, token) async {
        calls.add(p.name);
        if (p.name == 'captcha') {
          throw const CaptchaRequiredException('captcha');
        }
        return PluginSearchResponse(
          pluginName: p.name,
          data: [SearchItem(name: keyword, src: 'https://example.com/ok')],
        );
      },
    );
    addTearDown(service.cancel);
    await service.queryAllSource('中文名', alternativeKeywords: ['别名']);
    expect(calls.where((s) => s == 'captcha').length, 1);
    expect(info.pluginSearchStatus['captcha'], PluginSearchStatus.captcha);
    expect(info.pluginSearchStatus['working'], PluginSearchStatus.success);
  });
  test(
    'manual replacement invalidates stale alias results and cancels its request',
    () async {
      final info = InfoController(CollectController(_Crud()));
      final plugins = PluginsController()..pluginList.add(_plugin('fixture'));
      final old = Completer<PluginSearchResponse>();
      final started = Completer<void>();
      dynamic oldToken;
      final service = PluginSearchService(
        infoController: info,
        pluginsController: plugins,
        searchRunner: (p, keyword, token) async {
          if (keyword == '旧名称') {
            oldToken = token;
            started.complete();
            return old.future;
          }
          return PluginSearchResponse(
            pluginName: p.name,
            data: [SearchItem(name: keyword, src: 'https://example.com/new')],
          );
        },
      );
      addTearDown(service.cancel);
      final first = service.queryAllSource('旧名称', alternativeKeywords: ['旧别名']);
      await started.future;
      await service.querySource('新名称', 'fixture');
      old.complete(
        PluginSearchResponse(
          pluginName: 'fixture',
          data: [SearchItem(name: '旧名称', src: 'https://example.com/old')],
        ),
      );
      await first;
      expect(oldToken.isCancelled, isTrue);
      expect(info.pluginSearchResponseList.single.data.single.name, '新名称');
    },
  );
  test(
    'manual search supersedes a source still waiting in the initial queue',
    () async {
      final info = InfoController(CollectController(_Crud()));
      final plugins = PluginsController()
        ..pluginList.addAll(['one', 'two', 'three', 'queued'].map(_plugin));
      final gates = <Completer<PluginSearchResponse>>[];
      final calls = <String>[];
      final service = PluginSearchService(
        infoController: info,
        pluginsController: plugins,
        searchRunner: (p, keyword, token) async {
          calls.add('${p.name}:$keyword');
          if (p.name != 'queued') {
            final gate = Completer<PluginSearchResponse>();
            gates.add(gate);
            return gate.future;
          }
          return PluginSearchResponse(
            pluginName: p.name,
            data: [SearchItem(name: keyword, src: 'https://example.com/new')],
          );
        },
      );
      addTearDown(service.cancel);
      final initial = service.queryAllSource('旧名称');
      expect(gates, hasLength(3));
      await service.querySource('新名称', 'queued');
      for (var i = 0; i < gates.length; i++) {
        gates[i].complete(
          PluginSearchResponse(
            pluginName: plugins.pluginList[i].name,
            data: [],
          ),
        );
      }
      await initial;
      expect(calls, contains('queued:新名称'));
      expect(calls, isNot(contains('queued:旧名称')));
      expect(
        info.pluginSearchResponseList
            .singleWhere((r) => r.pluginName == 'queued')
            .data
            .single
            .name,
        '新名称',
      );
    },
  );
  test('timeout reports unavailable, not a false no-result', () async {
    final info = InfoController(CollectController(_Crud()));
    final plugins = PluginsController()..pluginList.add(_plugin('fixture'));
    final service = PluginSearchService(
      infoController: info,
      pluginsController: plugins,
      requestTimeout: const Duration(milliseconds: 5),
      searchRunner: (_, _, _) => Completer<PluginSearchResponse>().future,
    );
    addTearDown(service.cancel);
    await service.queryAllSource('中文名', alternativeKeywords: ['别名']);
    expect(info.pluginSearchStatus['fixture'], PluginSearchStatus.error);
  });
  test(
    'recommended rules add once, preserve custom edits and respect later removal',
    () async {
      final dir = await Directory.systemTemp.createTemp('naku-anime-rules-');
      addTearDown(() => dir.delete(recursive: true));
      var writes = 0;
      final c =
          PluginsController(
              pluginJsonWriter: (_) async {
                writes++;
              },
            )
            ..newPluginDirectory = dir
            ..pluginList.add(_plugin('AGE')..version = 'custom');
      expect(
        await c.installRecommendedAnimeRules([_plugin('AGE'), _plugin('MXdm')]),
        1,
      );
      expect(c.pluginList.first.version, 'custom');
      expect(writes, 1);
      c.pluginList.removeWhere((p) => p.name == 'MXdm');
      expect(
        await c.installRecommendedAnimeRules([_plugin('AGE'), _plugin('MXdm')]),
        0,
      );
      expect(c.pluginList.map((p) => p.name), ['AGE']);
    },
  );
}
