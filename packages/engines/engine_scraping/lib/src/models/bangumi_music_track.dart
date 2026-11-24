/// 从 Bangumi 关联音乐条目提取出的单条曲目信息（用于弱文件名补全与别名增强）。
class BangumiMusicTrack {
  /// 创建 Bangumi 音乐曲目记录。
  const BangumiMusicTrack({
    required this.subjectId,
    required this.subjectTitle,
    this.subjectTitleCn = '',
    this.relation = '',
    this.trackNumber,
    required this.title,
    this.titleCn = '',
  });

  /// 所属音乐条目 ID。
  final int subjectId;

  /// 音乐条目原名（专辑/单曲名）。
  final String subjectTitle;

  /// 音乐条目中文名。
  final String subjectTitleCn;

  /// 与主动画条目的关联关系（片头曲 / 片尾曲 / 插入歌 / 原声集 / 角色歌等）。
  final String relation;

  /// 光盘曲目序号（来自 Bangumi `sort` 或 `ep`）。
  final int? trackNumber;

  /// 曲目日文原名。
  final String title;

  /// 曲目中文名（可为空）。
  final String titleCn;
}
