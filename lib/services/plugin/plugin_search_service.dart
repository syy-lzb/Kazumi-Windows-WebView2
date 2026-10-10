import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/services/plugin/source_search_relevance.dart';

class PluginSearchService {
  PluginSearchService({
    required this.infoController,
    required this.pluginsController,
  });

  final InfoController infoController;
  final PluginsController pluginsController;
  final RuleCancelToken _cancelToken = RuleCancelToken();

  /// Per-plugin sessions so a replacement query (alias/manual search)
  /// invalidates the write-back of the still-running previous one.
  final Map<String, AsyncSessionOwner> _querySessions = {};
  bool _isCancelled = false;
  final _adaptiveSearch = AdaptiveSourceSearch();
  final _targetKeywords = <String, String>{};

  List<String> _aliasesFor(String keyword) {
    final item = infoController.bangumiItem;
    final primary = item.nameCn.isEmpty ? item.name : item.nameCn;
    // 用户手动改词后不再拿原条目的别名扩大搜索范围。
    return keyword.trim() == primary.trim()
        ? [item.name, item.nameCn, ...item.alias]
        : [];
  }

  /// Prepares a source for a result that will be supplied by an external
  /// transport (for example a verified WebView2 session).
  void prepareExternalSearch(String pluginName) {
    if (_isCancelled) return;
    infoController.pluginSearchResponseList.removeWhere(
      (response) => response.pluginName == pluginName,
    );
    infoController.pluginSearchStatus[pluginName] = PluginSearchStatus.pending;
  }

  void markCaptchaRequired(String pluginName) {
    if (_isCancelled) return;
    infoController.pluginSearchStatus[pluginName] = PluginSearchStatus.captcha;
  }

  void markSearchError(String pluginName) {
    if (_isCancelled) return;
    infoController.pluginSearchStatus[pluginName] = PluginSearchStatus.error;
  }

  void prepareAllSources() {
    if (_isCancelled) return;
    infoController.pluginSearchResponseList.clear();
    infoController.pluginSearchStatus.clear();
    for (final plugin in pluginsController.pluginList) {
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.pending;
    }
  }

  Future<void> querySource(String keyword, String pluginName, {
    Future<PluginSearchResponse> Function(String keyword)? fetch,
    PluginSearchResponse? initialResponse,
    bool refresh = false,
  }) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName) {
        prepareExternalSearch(pluginName);
        if (refresh) _adaptiveSearch.clear(pluginName);
        await _queryPlugin(plugin, keyword, fetch: fetch, initialResponse: initialResponse);
        return;
      }
    }
  }

  /// Publishes the result page harvested by the captcha webview, skipping
  /// one network round trip. A valid page with zero items is published as
  /// [PluginSearchStatus.noResult]. Returns false only when the HTML itself
  /// cannot be parsed as this rule's search page.
  bool applyHarvestedSearchResult(String pluginName, String html) {
    if (_isCancelled) return false;
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name != pluginName) continue;
      final result = plugin.parseHarvestedSearch(html);
      if (result == null) return false;
      final keyword = _targetKeywords[pluginName] ??
          (infoController.bangumiItem.nameCn.isEmpty
              ? infoController.bangumiItem.name : infoController.bangumiItem.nameCn);
      result.data = rankSourceResults(keyword, result.data, aliases: _aliasesFor(keyword));
      infoController.pluginSearchResponseList.removeWhere(
        (response) => response.pluginName == pluginName,
      );
      if (result.data.isEmpty) {
        infoController.pluginSearchStatus[pluginName] =
            PluginSearchStatus.noResult;
        KazumiLogger().i(
          'PluginSearchService: harvested page has no results for $pluginName',
        );
        return true;
      }
      infoController.pluginSearchStatus[pluginName] =
          PluginSearchStatus.success;
      pluginsController.validityTracker.markSearchValid(pluginName);
      infoController.pluginSearchResponseList.add(result);
      return true;
    }
    return false;
  }

  Future<void> queryAllSource(String keyword) async {
    prepareAllSources();
    final plugins = List<Plugin>.of(pluginsController.pluginList);
    await Future.wait(plugins.map((plugin) => _queryPlugin(plugin, keyword)));
  }

  Future<void> _queryPlugin(Plugin plugin, String keyword, {
    Future<PluginSearchResponse> Function(String keyword)? fetch,
    PluginSearchResponse? initialResponse,
  }) async {
    if (_isCancelled) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    _targetKeywords[plugin.name] = keyword;
    try {
      await _adaptiveSearch.search(
        sourceName: plugin.name,
        keyword: keyword,
        aliases: _aliasesFor(keyword),
        initialResponse: initialResponse,
        isCurrent: () => !_isCancelled && !session.isStale,
        fetch: fetch ?? (word) => plugin.queryBangumi(
          word, shouldRethrow: true, cancelToken: _cancelToken),
        onUpdate: (items, complete) {
          infoController.pluginSearchResponseList.removeWhere(
            (response) => response.pluginName == plugin.name);
          if (items.isNotEmpty) {
            pluginsController.validityTracker.markSearchValid(plugin.name);
            infoController.pluginSearchResponseList.add(
              PluginSearchResponse(pluginName: plugin.name, data: items));
          }
          infoController.pluginSearchStatus[plugin.name] = items.isNotEmpty
              ? PluginSearchStatus.success
              : (complete ? PluginSearchStatus.noResult : PluginSearchStatus.pending);
        },
      );
    } catch (error) {
      if (_isCancelled || session.isStale) return;
      _handleSearchError(plugin, error);
    }
  }

  void _handleSearchError(Plugin plugin, Object error) {
    if (error is CaptchaRequiredException) {
      KazumiLogger().i(
        'PluginSearchService: captcha required for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.captcha;
      return;
    }
    if (error is NoResultException) {
      KazumiLogger().i(
        'PluginSearchService: no results for ${error.pluginName}',
      );
      infoController.pluginSearchStatus[error.pluginName] =
          PluginSearchStatus.noResult;
      return;
    }
    final name = error is SearchErrorException ? error.pluginName : plugin.name;
    KazumiLogger().w('PluginSearchService: search error for $name');
    infoController.pluginSearchStatus[name] = PluginSearchStatus.error;
  }

  void cancel() {
    _isCancelled = true;
    _cancelToken.cancel();
  }
}
