/// 配置切片与数据的跨设备同步策略。
enum SyncPolicy {
  /// 可跨设备便携同步并纳入 `.konata` 备份。
  portable,

  /// 仅在本机设备生效，绝不进入备份或 WebDAV 同步载荷。
  deviceLocal,
}

/// Konata 支持的宿主运行形态枚举（用于扩展点与设置项按平台过滤）。
enum KonataPlatform {
  /// Windows 桌面端（绿色便携版）。
  windows,

  /// Android 手机端（`shortestSide < 600dp`）。
  androidPhone,

  /// Android 平板端（`shortestSide >= 600dp`）。
  androidTablet,
}

/// 媒体源协议类型。
enum MediaSourceKind {
  /// 本地磁盘目录。
  local,

  /// WebDAV 远程只读目录。
  webdav,

  /// SMB / CIFS 局域网只读共享目录。
  smb,
}

/// TMDB 条目媒体类型。
enum TmdbMediaType {
  /// 剧集 / 番剧（TV）。
  tv,

  /// 电影 / 剧场版（Movie）。
  movie,
}

/// 作品刮削匹配状态。
enum ScrapeStatus {
  /// 已高置信匹配并绑定元数据。
  matched,

  /// 存在歧义或待人工复核确认。
  needsReview,

  /// 尚未识别到匹配条目。
  unmatched,
}

/// 逻辑剧集分类。
enum EpisodeCategory {
  /// 正片剧集。
  main,

  /// 特典与附加映像。
  extra,
}

/// 特典映像细分类型。
enum ExtraKind {
  /// 无字幕片头曲（NCOP）。
  ncop,

  /// 无字幕片尾曲（NCED）。
  nced,

  /// 宣传预告（PV / CM）。
  pv,

  /// 原创动画录影带（OVA / OAD）。
  ova,

  /// 特别篇（SP / Special）。
  sp,

  /// 光盘菜单（Menu）。
  menu,

  /// 音乐录影带（MV / Music Video）。
  mv,
}

/// 物理媒体资产分类。
enum AssetKind {
  /// 视频文件。
  video,

  /// 音乐 CD 专辑 / CUE 音轨。
  cdAlbum,

  /// 扫图 / 设定集画廊。
  scanGallery,
}

/// 合集附属资源（特典 / CD / Scan）在系列内的可见作用域。
enum SupplementaryAssetScope {
  /// 仅当前所属作品条目可见。
  workExclusive,

  /// 同系列内所有成员共享可见。
  seriesShared,
}

/// 播放器媒体运行模式（用于侧栏扩展点按音视频形态过滤）。
enum PlayerMediaMode {
  /// 视频播放舞台。
  video,

  /// 音频播放舞台。
  audio,
}
