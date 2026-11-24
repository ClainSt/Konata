import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

import '../playback/cue_and_lrc_parser.dart';

/// `foobar2000` 外部控制组件（`foo_beefweb`）集中配置常量。
abstract final class FoobarBeefwebConfig {
  /// 默认本地回环监听端口。
  static const int defaultPort = 8880;

  /// 默认本地回环主机地址。
  static const String loopbackHost = '127.0.0.1';

  /// 官方组件详情与下载页面地址（供用户浏览器跳转下载 `.fb2k-component`）。
  static const String officialDownloadUrl =
      'https://www.foobar2000.org/components/view/foo_beefweb';

  /// `Konata` 投递音频时在 `foobar2000` 中隔离维护的专属播放列表名称（防止覆盖用户默认播放列表）。
  static const String dedicatedPlaylistTitle = 'Konata';

  /// 构建指定端口的本地回环基础地址。
  static String buildLoopbackBaseUrl([int port = defaultPort]) {
    final safePort = port.clamp(1, 65535);
    return 'http://$loopbackHost:$safePort';
  }
}

/// 桌面外部音频播放器与 `foo_beefweb` 组件就绪态枚举。
enum FoobarComponentState {
  /// 尚未配置外部音频播放器路径或可执行文件不存在。
  unconfigured,

  /// 当前配置的外部音频播放器并非 `foobar2000`（例如 `mpv.exe` 或其他独立程序）。
  notFoobar,

  /// 已定位 `foobar2000.exe`，但既未连通端口也未在组件目录发现 `foo_beefweb.dll`。
  missingComponent,

  /// 组件目录已检测到 `foo_beefweb.dll`，待启动 `foobar2000` 后即可建立连接。
  installedPendingStart,

  /// 本地 `foo_beefweb` HTTP 接口已实时握手连通。
  connected,
}

/// 桌面外部音频播放器组件探测结果快照。
class FoobarComponentStatusSnapshot {
  /// 创建组件探测快照。
  const FoobarComponentStatusSnapshot({
    required this.state,
    this.executablePath = '',
    this.port = FoobarBeefwebConfig.defaultPort,
  });

  /// 当前组件就绪状态。
  final FoobarComponentState state;

  /// 已解析的外部音频可执行文件路径。
  final String executablePath;

  /// 检测时使用的端口号。
  final int port;

  /// 当前是否属于已配置 `foobar2000` 的场景。
  bool get isFoobarConfigured =>
      state == FoobarComponentState.missingComponent ||
      state == FoobarComponentState.installedPendingStart ||
      state == FoobarComponentState.connected;

  /// 是否已具备 `foo_beefweb` 同步能力（已连通或已安装待启动）。
  bool get isBeefwebReady =>
      state == FoobarComponentState.connected ||
      state == FoobarComponentState.installedPendingStart;
}

/// 外部音频接力单条逻辑曲目描述符（同时覆盖散装单曲与 `.cue` 虚拟子曲目）。
class ExternalAudioTrackDescriptor {
  /// 创建外部音频曲目描述符。
  const ExternalAudioTrackDescriptor({
    required this.recordId,
    required this.episodeId,
    required this.variant,
    required this.title,
    this.performer = '',
    this.albumTitle = '',
    this.trackNumber,
    this.isCueSubtrack = false,
    this.cueStartSeconds,
    this.cueEndSeconds,
    this.knownDurationSeconds,
  });

  /// 对应的播放历史记录主键（如 `cd::<cueId>::track_1` 或 `cd::<variantId>`）。
  final String recordId;

  /// 对应的逻辑音轨剧集主键。
  final EpisodeId episodeId;

  /// 关联的底层物理音频变体。
  final MediaVariantRecord variant;

  /// 清洗后的展示曲名。
  final String title;

  /// 演唱者或声优名称。
  final String performer;

  /// 所属专辑展示名称。
  final String albumTitle;

  /// 曲目序号（从 1 开始）。
  final int? trackNumber;

  /// 是否为 `.cue` 整轨拆分出的虚拟子曲目。
  final bool isCueSubtrack;

  /// `.cue` 子曲目在物理母音频中的起始秒数。
  final double? cueStartSeconds;

  /// `.cue` 子曲目在物理母音频中的结束秒数（末轨可为空）。
  final double? cueEndSeconds;

  /// 已知的单曲时长（秒）。
  final int? knownDurationSeconds;

  /// 计算已知或由 `.cue` 边界推导出的曲目时长（秒）。
  int get resolvedDurationSeconds {
    if (knownDurationSeconds != null && knownDurationSeconds! > 0) {
      return knownDurationSeconds!;
    }
    final start = cueStartSeconds;
    final end = cueEndSeconds;
    if (start != null && end != null && end > start) {
      return (end - start).round();
    }
    return 0;
  }
}

/// 外部音频专辑/分轨进度回写回调签名（感知跨轨自动切歌与单轨完播）。
typedef ExternalAudioProgressCallback =
    Future<void> Function(
      ExternalAudioTrackDescriptor track,
      int positionSeconds,
      int durationSeconds, {
      required bool isCompleted,
      required bool isFinal,
    });

/// 外部音频专辑队列与 `.cue` 分轨接力启动请求。
class ExternalAudioAlbumRelayRequest {
  /// 创建外部音频专辑接力请求。
  const ExternalAudioAlbumRelayRequest({
    required this.work,
    required this.tracks,
    this.initialTrackIndex = 0,
    this.startSeconds = 0,
    this.exactStartSeconds,
    this.pairedCueVariant,
    this.parsedCueSheet,
    this.source,
    this.targetId,
    this.beefwebPort = FoobarBeefwebConfig.defaultPort,
    this.allowWithoutBeefweb = false,
  });

  /// 所属作品实体。
  final WorkRecord work;

  /// 当前专辑按播放顺序排列的全部逻辑曲目列表（非空）。
  final List<ExternalAudioTrackDescriptor> tracks;

  /// 本次起播的目标曲目在 [tracks] 中的索引。
  final int initialTrackIndex;

  /// 目标曲目内的相对续播起始秒数。
  final int startSeconds;

  /// 目标曲目内的双精度起始秒数（可选）。
  final double? exactStartSeconds;

  /// 若为整轨 + `.cue` 专辑，携带配对的 `.cue` 变体。
  final MediaVariantRecord? pairedCueVariant;

  /// 若为整轨 + `.cue` 专辑，携带已解析完成的 [CueSheet]。
  final CueSheet? parsedCueSheet;

  /// 所属媒体源只读视图。
  final MediaSourceView? source;

  /// 显式指定的外部播放器配置 ID（可选）。
  final String? targetId;

  /// `foo_beefweb` 本地回环端口号。
  final int beefwebPort;

  /// 当检测到 `foobar2000` 缺少 `foo_beefweb` 时，是否允许直接降级为单向命令行拉起。
  final bool allowWithoutBeefweb;

  /// 当前起播的目标曲目描述符。
  ExternalAudioTrackDescriptor get initialTrack {
    final safeIdx = initialTrackIndex.clamp(0, tracks.length - 1);
    return tracks[safeIdx];
  }
}
