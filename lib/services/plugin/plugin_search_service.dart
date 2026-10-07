import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';
import 'package:kazumi/utils/async_session.dart';

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

  Future<void> querySource(String keyword, String pluginName) async {
    for (final plugin in pluginsController.pluginList) {
      if (plugin.name == pluginName) {
        prepareExternalSearch(pluginName);
        await _queryPlugin(plugin, keyword);
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

  Future<void> _queryPlugin(Plugin plugin, String keyword) async {
    if (_isCancelled) return;
    final session = _querySessions
        .putIfAbsent(plugin.name, AsyncSessionOwner.new)
        .begin();
    try {
      final result = await plugin.queryBangumi(
        keyword,
        shouldRethrow: true,
        cancelToken: _cancelToken,
      );
      if (_isCancelled || session.isStale) return;
      infoController.pluginSearchStatus[plugin.name] =
          PluginSearchStatus.success;
      if (result.data.isNotEmpty) {
        pluginsController.validityTracker.markSearchValid(plugin.name);
      }
      infoController.pluginSearchResponseList.add(result);
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
