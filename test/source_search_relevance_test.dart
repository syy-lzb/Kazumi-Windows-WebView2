import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/plugin/source_search_relevance.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

void main() {
  test('类型与副标题不污染主体补搜，规则适用于不同作品', () {
    for (final pair in [
      ('圣痕炼金士OAD 女帝的肖像', '圣痕炼金士'),
      ('紫罗兰永恒花园OVA 特别篇', '紫罗兰永恒花园'),
      ('某个科学的超电磁炮 剧场版 特别故事', '某个科学的超电磁炮'),
    ]) {
      expect(supplementalKeywords(pair.$1), contains(pair.$2));
      final score = titleRelevance(pair.$1, '${pair.$2} 第一季');
      expect(score, greaterThanOrEqualTo(sourcePossibleThreshold));
      expect(score, lessThan(sourcePriorityThreshold));
    }
    expect(titleRelevance('圣痕炼金士OAD 女帝的肖像', '圣痕炼金士第二季'), lessThan(.6));
    expect(titleRelevance('圣痕炼金士OAD 女帝的肖像', '圣痕炼金士OAD 女帝的肖像'), 1);
    expect(titleRelevance('圣痕炼金士OAD 女帝的肖像', '钢之炼金术师'), lessThan(.6));
  });
  test('空白标题不能作为完全匹配', () {
    expect(titleRelevance('', ''), 0);
    expect(titleRelevance('！？', ' '), 0);
  });
  SearchItem item(String name, [String? url]) =>
      SearchItem(name: name, src: url ?? name);
  for (final pair in [
    ('圣痕炼金术士', '圣痕炼金士'),
    ('异世界迷宫黑心企业', '异世界迷宫的黑心企业'),
    ('关于我转生变成史莱姆这档事', '关于我转生成史莱姆这档事'),
  ]) {
    test('完整长标题的小幅差异优先：${pair.$1}', () {
      expect(titleRelevance(pair.$1, pair.$2), greaterThanOrEqualTo(.8));
    });
  }
  test('格式差异、已知别名，不依赖例子中的替换词', () {
    expect(titleRelevance('Fate/Zero', 'ＦＡＴＥ：ＺＥＲＯ'), 1);
    expect(
      titleRelevance('魔女之旅', '魔女的旅途', aliases: ['魔女的旅途']),
      greaterThanOrEqualTo(.95),
    );
  });
  test('共享宽泛词和短标题不能进入优先结果', () {
    expect(titleRelevance('圣痕炼金术士', '钢之炼金术师'), lessThan(.6));
    expect(titleRelevance('来自深渊', '深渊冒险者'), lessThan(.6));
    expect(titleRelevance('海王', '海贼王'), lessThan(.6));
    expect(titleRelevance('你的名字', '我的名字'), lessThan(.8));
  });
  test('不同季数和剧场版不能误判为同一版本', () {
    expect(titleRelevance('圣痕炼金术士', '圣痕炼金士 第一季'), greaterThanOrEqualTo(.8));
    expect(titleRelevance('圣痕炼金术士', '圣痕炼金士第二季'), lessThan(.6));
    expect(titleRelevance('某个科学的超电磁炮 第二季', '某个科学的超电磁炮 第一季'), lessThan(.6));
    expect(titleRelevance('某个科学的超电磁炮', '某个科学的超电磁炮 剧场版'), lessThan(.8));
  });
  test('按相关性排序、URL 去重、同分保留原顺序', () {
    final ranked = rankSourceResults('圣痕炼金术士', [
      item('钢之炼金术师'),
      item('圣痕炼金士', '/a'),
      item('圣痕炼金术士', '/b'),
      item('圣痕炼金士', '/a'),
      item('圣痕炼金术士', '/c'),
    ]);
    expect(ranked.map((e) => e.src), ['/b', '/c', '/a', '钢之炼金术师']);
  });
  test('补搜有界，不生成过短泛词，不为短标题截字', () {
    final words = supplementalKeywords('圣痕炼金术士');
    expect(words.length, lessThanOrEqualTo(2));
    expect(words, contains('圣痕炼金'));
    expect(words, isNot(contains('炼金')));
    expect(supplementalKeywords('海王'), isEmpty);
  });
  test('优先选取已知别名，同时保留一个部分关键词', () {
    final words = supplementalKeywords('圣痕炼金术士', aliases: ['圣痕炼金士', '圣痕炼金术士']);
    expect(words.first, '圣痕炼金士');
    expect(words.length, lessThanOrEqualTo(2));
  });
  test('已有高相关结果时不额外请求', () async {
    var requests = 0;
    await AdaptiveSourceSearch().search(
      sourceName: 'site',
      keyword: '异世界迷宫黑心企业',
      fetch: (keyword) async {
        requests++;
        return PluginSearchResponse(
          pluginName: 'site',
          data: [item('异世界迷宫黑心企业')],
        );
      },
      onUpdate: (_, complete) {},
      isCurrent: () => true,
    );
    expect(requests, 1);
  });
  test('补搜找到近似译名、逐步显示、成功后停止', () async {
    final requested = <String>[];
    final updates = <List<SearchItem>>[];
    final result = await AdaptiveSourceSearch().search(
      sourceName: 'site',
      keyword: '圣痕炼金术士',
      fetch: (keyword) async {
        requested.add(keyword);
        return PluginSearchResponse(
          pluginName: 'site',
          data: keyword == '圣痕炼金' ? [item('圣痕炼金士')] : [],
        );
      },
      onUpdate: (items, complete) => updates.add(items),
      isCurrent: () => true,
    );
    expect(result.single.name, '圣痕炼金士');
    expect(requested, ['圣痕炼金术士', '圣痕炼金']);
    expect(updates.first, isEmpty);
  });
  test('缓存复用，替换检索后旧结果不回写或追加请求', () async {
    final search = AdaptiveSourceSearch();
    var requests = 0;
    Future<PluginSearchResponse> fetch(String keyword) async {
      requests++;
      return PluginSearchResponse(pluginName: 'site', data: [item(keyword)]);
    }

    for (var i = 0; i < 2; i++) {
      await search.search(
        sourceName: 'site',
        keyword: '某部动画',
        fetch: fetch,
        onUpdate: (_, complete) {},
        isCurrent: () => true,
      );
    }
    expect(requests, 1);
    search.clear('site');
    var current = true;
    var writes = 0;
    await search.search(
      sourceName: 'site',
      keyword: '某部动画',
      fetch: (keyword) async {
        current = false;
        return fetch(keyword);
      },
      onUpdate: (_, complete) => writes++,
      isCurrent: () => current,
    );
    expect(writes, 0);
    expect(requests, 2);
  });
  test('验证收割结果不重新请求原词，无结果异常允许补搜', () async {
    var requests = 0;
    final result = await AdaptiveSourceSearch().search(
      sourceName: 'site',
      keyword: '圣痕炼金术士',
      initialResponse: PluginSearchResponse(pluginName: 'site', data: []),
      fetch: (keyword) async {
        requests++;
        return PluginSearchResponse(pluginName: 'site', data: [item('圣痕炼金士')]);
      },
      onUpdate: (_, complete) {},
      isCurrent: () => true,
    );
    expect(result, hasLength(1));
    expect(requests, 1);
    final empty = await AdaptiveSourceSearch().search(
      sourceName: 'other',
      keyword: '某个很长的动画标题',
      fetch: (keyword) async {
        requests++;
        throw const NoResultException('other');
      },
      onUpdate: (_, complete) {},
      isCurrent: () => true,
    );
    expect(empty, isEmpty);
    expect(requests, 4);
  });
  test('已有候选时补搜失败不清空结果；网络和验证错误不盲目重试', () async {
    var requests = 0;
    final result = await AdaptiveSourceSearch().search(
      sourceName: 'site',
      keyword: '某个很长的动画标题',
      fetch: (keyword) async {
        requests++;
        if (requests > 1) throw const CaptchaRequiredException('site');
        return PluginSearchResponse(pluginName: 'site', data: [item('无关候选')]);
      },
      onUpdate: (_, complete) {},
      isCurrent: () => true,
    );
    expect(result.single.name, '无关候选');
    expect(requests, 2);
  });
}
