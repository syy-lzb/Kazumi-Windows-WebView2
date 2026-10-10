import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart';

const sourcePriorityThreshold = .8;
const sourcePossibleThreshold = .6;

String _normalize(String value) => String.fromCharCodes(
  value.runes.map(
    (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
  ),
).toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

final _seasonPattern = RegExp(
  r'第?([0-9一二三四五六七八九十]+)[季期]|season\s*([0-9]+)',
  caseSensitive: false,
);
final _filmPattern = RegExp(
  r'剧场版|劇場版|the movie|\bmovie\b',
  caseSensitive: false,
);
final _specialPattern = RegExp(
  r'(?<![a-z])(?:ova|oad|ona)(?![a-z])|剧场版|劇場版|the movie|\bmovie\b',
  caseSensitive: false,
);

String _seriesTitle(String value) {
  final marker = _specialPattern.firstMatch(value);
  if (marker == null) return value;
  final prefix = value.substring(0, marker.start).trim();
  return _normalize(prefix).runes.length >= 4 ? prefix : value;
}

int? _season(String value) {
  final match = _seasonPattern.firstMatch(value);
  if (match == null) return null;
  final raw = match.group(1) ?? match.group(2)!;
  final arabic = int.tryParse(raw);
  if (arabic != null) return arabic;
  const digits = '〇一二三四五六七八九';
  if (raw == '十') return 10;
  if (raw.contains('十')) {
    final parts = raw.split('十');
    return (parts.first.isEmpty ? 1 : digits.indexOf(parts.first)) * 10 +
        (parts.last.isEmpty ? 0 : digits.indexOf(parts.last));
  }
  return digits.indexOf(raw);
}

double _similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 1;
  final x = a.runes.take(256).toList();
  final y = b.runes.take(256).toList();
  var previous = List.generate(y.length + 1, (i) => i);
  for (var i = 0; i < x.length; i++) {
    final row = List.filled(y.length + 1, i + 1);
    for (var j = 0; j < y.length; j++) {
      final delete = previous[j + 1] + 1;
      final insert = row[j] + 1;
      final replace = previous[j] + (x[i] == y[j] ? 0 : 1);
      row[j + 1] = [delete, insert, replace].reduce((a, b) => a < b ? a : b);
    }
    previous = row;
  }
  final longest = x.length > y.length ? x.length : y.length;
  final shortest = x.length < y.length ? x.length : y.length;
  final score = 1 - previous.last / longest;
  // 很短的标题不能仅凭一两个共同字进入优先结果。
  return shortest <= 3
      ? score.clamp(0, .49)
      : (shortest <= 4 ? score.clamp(0, .79) : score);
}

double titleRelevance(
  String target,
  String candidate, {
  Iterable<String> aliases = const [],
}) {
  final references = [target, ...aliases.where((e) => e.trim().isNotEmpty)];
  // 季数单独比较，避免相同作品的“第一季”后缀稀释标题匹配。
  String titleBody(String value) =>
      _normalize(value.replaceAll(_seasonPattern, ''));
  final normalized = titleBody(candidate);
  var score = _similarity(titleBody(target), normalized);
  for (final alias in references.skip(1)) {
    final aliasScore = _similarity(titleBody(alias), normalized) * .97;
    if (aliasScore > score) score = aliasScore;
  }
  // 类型和副标题缺失时仅提供同系列候选，不冒充准确版本。
  if (_seriesTitle(target) != target || _seriesTitle(candidate) != candidate) {
    final seriesScore =
        _similarity(
          titleBody(_seriesTitle(target)),
          titleBody(_seriesTitle(candidate)),
        ) *
        .74;
    if (seriesScore > score) score = seriesScore;
  }
  final wantedType = _specialPattern
      .firstMatch(target)
      ?.group(0)
      ?.toLowerCase();
  final actualType = _specialPattern
      .firstMatch(candidate)
      ?.group(0)
      ?.toLowerCase();
  if (wantedType != actualType) score = score.clamp(0, .74);
  final wantedSeason = _season(target) ?? 1;
  final actualSeason = _season(candidate) ?? 1;
  if (wantedSeason != actualSeason) score = (score - .32).clamp(0, .59);
  if (_filmPattern.hasMatch(candidate) !=
      references.any(_filmPattern.hasMatch)) {
    score = score.clamp(0, .74);
  }
  return score;
}

List<String> supplementalKeywords(
  String target, {
  Iterable<String> aliases = const [],
}) {
  final seen = {_normalize(target)};
  final candidates = <String>[];
  void add(String word) {
    final normalized = _normalize(word);
    if (normalized.runes.length >= 4 && seen.add(normalized)) {
      candidates.add(word.trim());
    }
  }

  final usefulAliases =
      aliases.where((e) => _normalize(e).runes.length >= 4).toList()..sort(
        (a, b) => _similarity(
          _normalize(target),
          _normalize(b),
        ).compareTo(_similarity(_normalize(target), _normalize(a))),
      );
  for (final alias in usefulAliases) {
    add(alias);
    if (candidates.isNotEmpty) break;
  }
  if (_seriesTitle(target) != target) add(_seriesTitle(target));
  final core = _normalize(
    target.replaceAll(_seasonPattern, '').replaceAll(_filmPattern, ''),
  );
  final letters = core.runes.toList();
  if (letters.length >= 6) {
    final width = (letters.length * .6).ceil().clamp(4, letters.length - 1);
    add(String.fromCharCodes(letters.take(width)));
    add(String.fromCharCodes(letters.skip(letters.length - width)));
  }
  return candidates.take(2).toList();
}

List<SearchItem> rankSourceResults(
  String target,
  Iterable<SearchItem> items, {
  Iterable<String> aliases = const [],
}) {
  final unique = <String, ({SearchItem item, int order})>{};
  var order = 0;
  for (final item in items) {
    final ranked = SearchItem(
      name: item.name,
      src: item.src,
      relevance: titleRelevance(target, item.name, aliases: aliases),
    );
    final existing = unique[item.src.trim()];
    if (existing == null || ranked.relevance > existing.item.relevance) {
      unique[item.src.trim()] = (item: ranked, order: existing?.order ?? order);
    }
    order++;
  }
  final ranked = unique.values.toList()
    ..sort((a, b) {
      final byScore = b.item.relevance.compareTo(a.item.relevance);
      return byScore == 0 ? a.order.compareTo(b.order) : byScore;
    });
  return ranked.map((e) => e.item).toList();
}

class AdaptiveSourceSearch {
  final _cache =
      <(String, String), ({DateTime time, PluginSearchResponse response})>{};
  Future<List<SearchItem>> search({
    required String sourceName,
    required String keyword,
    Iterable<String> aliases = const [],
    required Future<PluginSearchResponse> Function(String keyword) fetch,
    required void Function(List<SearchItem> items, bool complete) onUpdate,
    required bool Function() isCurrent,
    PluginSearchResponse? initialResponse,
  }) async {
    final collected = <SearchItem>[];
    var ranked = <SearchItem>[];
    final words = [keyword, ...supplementalKeywords(keyword, aliases: aliases)];
    for (var index = 0; index < words.length; index++) {
      if (!isCurrent()) return ranked;
      final key = (sourceName, words[index]);
      PluginSearchResponse response;
      try {
        final cached = _cache[key];
        if (index == 0 && initialResponse != null) {
          response = initialResponse;
        } else if (cached != null &&
            DateTime.now().difference(cached.time) <
                const Duration(minutes: 2)) {
          response = cached.response;
        } else {
          response = await fetch(words[index]);
        }
      } on NoResultException {
        response = PluginSearchResponse(pluginName: sourceName, data: []);
      } catch (_) {
        // 不因补搜失败清空已有结果，也不反复重试超时或验证挑战。
        if (collected.isEmpty) rethrow;
        break;
      }
      if (!isCurrent()) return ranked;
      _cache[key] = (time: DateTime.now(), response: response);
      if (_cache.length > 64) _cache.remove(_cache.keys.first);
      collected.addAll(response.data);
      ranked = rankSourceResults(keyword, collected, aliases: aliases);
      final complete =
          index == words.length - 1 ||
          ranked.any((e) => e.relevance >= sourcePriorityThreshold);
      onUpdate(ranked, complete);
      if (complete) return ranked;
    }
    if (isCurrent()) onUpdate(ranked, true);
    return ranked;
  }

  void clear(String sourceName) =>
      _cache.removeWhere((key, value) => key.$1 == sourceName);
}
