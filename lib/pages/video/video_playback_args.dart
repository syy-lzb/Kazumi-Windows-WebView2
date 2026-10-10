import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    this.startAtSource = false,
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;
  final bool startAtSource;

  /// 明确点击单视频搜索结果时，播放该 URL 在归集列表中的位置。
  int? get initialEpisode {
    if (!startAtSource || roads.isEmpty) return null;
    final index = roads.first.data.indexOf(plugin.buildFullUrl(src));
    return index < 0 ? null : index + 1;
  }

  bool canResumeEpisode(int episode, int road) =>
      initialEpisode == null || (road == 0 && episode == initialEpisode);
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
