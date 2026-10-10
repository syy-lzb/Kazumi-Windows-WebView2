import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/services/plugin/plugin_validity_tracker.dart';

class TestInfoController extends Fake implements InfoController {
  @override
  final bangumiItem = BangumiItem(
    id: 1,
    type: 2,
    name: '圣痕炼金术士',
    nameCn: '圣痕炼金术士',
    summary: '',
    airDate: '',
    airWeekday: 0,
    rank: 0,
    images: {},
    tags: [],
    alias: [],
    ratingScore: 0,
    votes: 0,
    votesCount: [],
    info: '',
  );
  @override
  ObservableList<PluginSearchResponse> pluginSearchResponseList =
      ObservableList();
  @override
  ObservableMap<String, PluginSearchStatus> pluginSearchStatus =
      ObservableMap();
}

class TestPluginsController extends Fake implements PluginsController {
  @override
  ObservableList<Plugin> pluginList = ObservableList.of([
    Plugin.fromJson({
      'name': 'site',
      'baseURL': 'https://example.com',
      'searchList': '//li',
      'searchName': './/a',
      'searchResult': './/a',
    }),
  ]);
  @override
  final validityTracker = PluginValidityTracker();
}

void main() {
  late TestInfoController info;
  late PluginSearchService service;
  PluginSearchResponse response(String title) => PluginSearchResponse(
    pluginName: 'site',
    data: [SearchItem(name: title, src: '/watch')],
  );
  setUp(() {
    info = TestInfoController();
    service = PluginSearchService(
      infoController: info,
      pluginsController: TestPluginsController(),
    );
  });
  test('来源服务真正发布补搜结果和相关性，而不是仅排序函数', () async {
    final queries = <String>[];
    await service.querySource(
      '圣痕炼金术士',
      'site',
      fetch: (keyword) async {
        queries.add(keyword);
        return keyword == '圣痕炼金'
            ? response('圣痕炼金士')
            : PluginSearchResponse(pluginName: 'site', data: []);
      },
    );
    expect(queries, ['圣痕炼金术士', '圣痕炼金']);
    expect(info.pluginSearchStatus['site'], PluginSearchStatus.success);
    expect(
      info.pluginSearchResponseList.single.data.single.relevance,
      greaterThanOrEqualTo(.8),
    );
  });
  test('WebView 初始收割结果不会重新执行搜索或清空候选', () async {
    var requests = 0;
    await service.querySource(
      '圣痕炼金术士',
      'site',
      initialResponse: response('圣痕炼金士'),
      fetch: (keyword) async {
        requests++;
        throw StateError('不应重新请求');
      },
    );
    expect(requests, 0);
    expect(info.pluginSearchResponseList.single.data.single.name, '圣痕炼金士');
  });
  test('新关键词替代旧查询后，迟到的旧结果不能覆盖或补搜', () async {
    final oldResponse = Completer<PluginSearchResponse>();
    var oldRequests = 0;
    final oldTask = service.querySource(
      '旧标题',
      'site',
      fetch: (keyword) {
        oldRequests++;
        return oldResponse.future;
      },
    );
    await service.querySource(
      '新标题',
      'site',
      fetch: (keyword) async => response('新标题'),
    );
    oldResponse.complete(response('旧标题'));
    await oldTask;
    expect(oldRequests, 1);
    expect(info.pluginSearchResponseList.single.data.single.name, '新标题');
  });
  test('手动关键词不被原作品的别名带回；取消后不发布', () async {
    info.bangumiItem.alias.add('完全不同的别名');
    final queries = <String>[];
    await service.querySource(
      '手动词',
      'site',
      fetch: (keyword) async {
        queries.add(keyword);
        return PluginSearchResponse(pluginName: 'site', data: []);
      },
    );
    expect(queries, ['手动词']);
    expect(info.pluginSearchStatus['site'], PluginSearchStatus.noResult);
    final delayed = Completer<PluginSearchResponse>();
    final task = service.querySource(
      '另一关键词',
      'site',
      fetch: (keyword) => delayed.future,
    );
    service.cancel();
    delayed.complete(response('另一关键词'));
    await task;
    expect(info.pluginSearchResponseList, isEmpty);
  });
}
