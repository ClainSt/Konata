import '../value_objects/ids.dart';

/// 跨 Feature 唯一合法导航路由端口（严禁跨包传递重型实体对象，一律只传强类型 ID）。
abstract interface class AppNavigator {
  /// 切换顶层主导航分区（例如 `library`、`sources`、`history`、`settings`）。
  Future<void> switchNavSection(String sectionId);

  /// 打开指定作品的详情页，可选定位到初始标签页（如 `scan_viewer`）。
  Future<void> openWorkDetail(WorkId workId, {String? initialTabId});

  /// 启动全屏视频播放舞台（仅传作品、剧集或物理版本标识）。
  Future<void> openVideoPlayer({
    required WorkId workId,
    EpisodeId? episodeId,
    VariantId? variantId,
  });

  /// 启动全屏流光音频播放舞台（可选 CUE 轨号及轨内续播秒数；普通选曲不传断点）。
  Future<void> openAudioPlayer({
    required WorkId workId,
    VariantId? variantId,
    int? initialCueTrackIndex,
    int? initialPositionSeconds,
  });

  /// 打开设置容器，可选直接定位至指定设置分区标识。
  Future<void> openSettings({String? sectionId});

  /// 弹出当前顶层子路由；若已处于根层则返回 `false`。
  Future<bool> pop();
}
