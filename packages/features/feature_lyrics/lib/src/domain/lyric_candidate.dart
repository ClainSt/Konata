/// 歌词候选来源枚举。
enum LyricSource {
  /// 音频同目录外挂 `.lrc` 或音轨内嵌歌词标签。
  local,

  /// LRCLIB 开源同步歌词库。
  lrclib,

  /// 网易云音乐公开歌词接口。
  netease,

  /// AMLL TTML 开源逐字歌词库（按网易云歌曲标识直取）。
  amll,

  /// QQ 音乐非官方公开歌词接口（默认关闭，首次开启需用户确认免责声明）。
  qq,
}

/// 单条在线歌词候选（元数据用于打分，`lrcContent` 为统一的增强 LRC 正文）。
class LyricCandidate {
  /// 创建歌词候选。
  const LyricCandidate({
    required this.source,
    required this.sourceId,
    required this.title,
    required this.lrcContent,
    this.artist = '',
    this.album = '',
    this.durationSeconds,
    this.hasTranslation = false,
    this.hasWordTiming = false,
    this.hasRomaji = false,
    this.isSynced = true,
    this.isInstrumental = false,
    this.translationLrc = '',
    this.romajiLrc = '',
    this.plainLyrics = '',
    this.credits = const [],
  });

  /// 候选来源。
  final LyricSource source;

  /// 来源内部歌曲标识（用于缓存与换候选）。
  final String sourceId;

  /// 候选曲名。
  final String title;

  /// 候选歌手（多歌手以 `/` 连接）。
  final String artist;

  /// 候选专辑名。
  final String album;

  /// 候选时长（秒）。
  final double? durationSeconds;

  /// 增强 LRC 正文（可含同时间戳译文行、`roma:` 罗马音行、`<mm:ss.xx>` 逐字标签与 `bg:` 和声行）。
  final String lrcContent;

  /// 是否携带有效中文译文。
  final bool hasTranslation;

  /// 是否携带逐字时间轴。
  final bool hasWordTiming;

  /// 是否携带罗马音注音轨道。
  final bool hasRomaji;

  /// 是否具备同步时间轴（纯文本歌词候选为 `false`）。
  final bool isSynced;

  /// 来源是否显式声明该曲目为纯音乐/伴奏。
  final bool isInstrumental;

  /// 可选独立译文轨道原始 LRC（供跨源对齐与借译文复用）。
  final String translationLrc;

  /// 可选独立罗马音轨道原始 LRC（供跨源对齐与借罗马音复用）。
  final String romajiLrc;

  /// 可选纯文本无时间戳歌词（仅同步歌词缺失时保留，供后续手动或对齐使用）。
  final String plainLyrics;

  /// 经清洗提取的制作人员署名信息（作词 / 作曲 / 编曲等）。
  final List<String> credits;

  /// 复制并覆盖局部字段（用于跨源借译文/借罗马音合并后生成增强候选）。
  LyricCandidate copyWith({
    LyricSource? source,
    String? sourceId,
    String? title,
    String? artist,
    String? album,
    double? durationSeconds,
    String? lrcContent,
    bool? hasTranslation,
    bool? hasWordTiming,
    bool? hasRomaji,
    bool? isSynced,
    bool? isInstrumental,
    String? translationLrc,
    String? romajiLrc,
    String? plainLyrics,
    List<String>? credits,
  }) {
    return LyricCandidate(
      source: source ?? this.source,
      sourceId: sourceId ?? this.sourceId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      lrcContent: lrcContent ?? this.lrcContent,
      hasTranslation: hasTranslation ?? this.hasTranslation,
      hasWordTiming: hasWordTiming ?? this.hasWordTiming,
      hasRomaji: hasRomaji ?? this.hasRomaji,
      isSynced: isSynced ?? this.isSynced,
      isInstrumental: isInstrumental ?? this.isInstrumental,
      translationLrc: translationLrc ?? this.translationLrc,
      romajiLrc: romajiLrc ?? this.romajiLrc,
      plainLyrics: plainLyrics ?? this.plainLyrics,
      credits: credits ?? this.credits,
    );
  }
}

/// 已打分的歌词候选。
class ScoredLyricCandidate {
  /// 创建已打分候选。
  const ScoredLyricCandidate(
    this.candidate,
    this.score, {
    this.crossSourceAgreed = false,
  });

  /// 原始或跨源增强后的候选。
  final LyricCandidate candidate;

  /// 综合得分（元数据 `0.0 ~ 1.0` 加能力加分与交叉验证加分，可略高于 1.0）。
  final double score;

  /// 是否已与其他独立来源完成时间轴一致性交叉验证。
  final bool crossSourceAgreed;
}
