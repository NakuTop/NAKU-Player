import 'dart:async';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/anime_source_names.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';

typedef PluginSearchRunner =
    Future<PluginSearchResponse> Function(
      Plugin plugin,
      String keyword,
      RuleCancelToken cancelToken,
    );

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
    PluginSearchRunner? searchRunner,
    this.requestTimeout = const Duration(seconds: 8),
  }) : _runner = searchRunner ?? _defaultSearch;

  final InfoController infoController;
  final PluginsController pluginsController;
  final PluginSearchRunner _runner;
  final Duration requestTimeout;
  final RuleCancelToken _cancelToken = RuleCancelToken();
  final Map<String, AsyncSessionOwner> _querySessions = {};
  final Map<String, RuleCancelToken> _sourceTokens = {};
  final Map<String, String> effectiveKeywords = {};
  final Map<String, int> attemptedNames = {};
  final Map<String, int> _intents = {};
  bool _isCancelled = false;

  static Future<PluginSearchResponse> _defaultSearch(
    Plugin plugin,
    String keyword,
    RuleCancelToken token,
  ) => plugin.queryBangumi(keyword, shouldRethrow: true, cancelToken: token);

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.pending;
      final intent = (_intents[plugin.name] ?? 0) + 1;
      _intents[plugin.name] = intent;
      await _queryPlugin(plugin, [keyword], intent: intent);
      return;
    }
  }

  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      _sourceTokens[pluginName]?.cancel(
        'verified search superseded previous request',
      );
      _querySessions[pluginName]?.begin();
      _intents[pluginName] = (_intents[pluginName] ?? 0) + 1;
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(
    String keyword, {
    Iterable<String> alternativeKeywords = const [],
  }) async {
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();
    final queries = uniqueAnimeSourceNames([keyword, ...alternativeKeywords]);
    final plugins = List<Plugin>.of(pluginsController.pluginList);
    final intents = <String, int>{};
    for (final plugin in plugins) {
      final intent = (_intents[plugin.name] ?? 0) + 1;
      intents[plugin.name] = intent;
      _intents[plugin.name] = intent;
      _sourceTokens[plugin.name]?.cancel();
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.pending;
    }
    var cursor = 0;
    Future<void> worker() async {
      while (!_isCancelled && cursor < plugins.length) {
        final plugin = plugins[cursor++];
        await _queryPlugin(plugin, queries, intent: intents[plugin.name]!);
      }
    }

    await Future.wait(
      List.generate(plugins.length.clamp(0, 3), (_) => worker()),
    );
  }

  Future<void> _queryPlugin(
    Plugin plugin,
    List<String> keywords, {
    required int intent,
  }) async {
    if (_isCancelled || _intents[plugin.name] != intent) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    _sourceTokens[plugin.name]?.cancel('superseded source query');
    final token = RuleCancelToken();
    _sourceTokens[plugin.name] = token;
    unawaited(
      _cancelToken.whenCancel.then((_) {
        if (!token.isCancelled) token.cancel();
      }),
    );
    final rows = <SearchItem>[];
    final seen = <String>{};
    final keys = keywords.map(animeSourceNameKey).toSet();
    Object? failure;
    final deadline = DateTime.now().add(const Duration(seconds: 24));
    attemptedNames[plugin.name] = 0;
    for (final keyword in keywords) {
      if (_isCancelled || session.isStale || _intents[plugin.name] != intent) {
        return;
      }
      effectiveKeywords[plugin.name] = keyword;
      attemptedNames[plugin.name] = attemptedNames[plugin.name]! + 1;
      try {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) {
          throw TimeoutException('source search time budget');
        }
        final result = await _runner(
          plugin,
          keyword,
          token,
        ).timeout(remaining < requestTimeout ? remaining : requestTimeout);
        if (_isCancelled ||
            session.isStale ||
            _intents[plugin.name] != intent) {
          return;
        }
        rows.addAll(
          result.data.where((r) => r.src.isNotEmpty && seen.add(r.src)),
        );
        // Stop on a confirmed supplied name; unrelated broad matches do not
        // prevent trying the original title and explicit aliases.
        if (rows.any((r) => keys.contains(animeSourceNameKey(r.name)))) break;
      } on NoResultException {
        continue;
      } on TimeoutException catch (error) {
        token.cancel('source query timed out');
        failure = error;
        break;
      } catch (error) {
        if (_isCancelled ||
            session.isStale ||
            _intents[plugin.name] != intent) {
          return;
        }
        failure = error;
        break; // Captcha or network errors are not solved by hammering aliases.
      }
    }
    if (_isCancelled || session.isStale || _intents[plugin.name] != intent) {
      return;
    }
    if (rows.isNotEmpty) {
      rows.sort(
        (a, b) => (keys.contains(animeSourceNameKey(a.name)) ? 0 : 1).compareTo(
          keys.contains(animeSourceNameKey(b.name)) ? 0 : 1,
        ),
      );
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(plugin.name);
      infoController.pluginSearchResponseList.add(
        PluginSearchResponse(pluginName: plugin.name, data: rows),
      );
    } else if (failure != null) {
      _handleSearchError(plugin, failure);
    } else {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.noResult;
    }
  }

  void _handleSearchError(Plugin plugin, Object error) {
    if (error is CaptchaRequiredException) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.captcha;
    } else if (error is NoResultException) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.noResult;
    } else {
      KazumiLogger().w('PluginSearchService: search failed for ${plugin.name}');
      infoController.pluginSearchStatus[plugin.name] = PluginSearchStatus.error;
    }
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
    for (final token in _sourceTokens.values) {
      if (!token.isCancelled) token.cancel();
    }
  }
}
