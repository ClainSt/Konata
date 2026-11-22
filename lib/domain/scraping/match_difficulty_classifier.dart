import '../matching/directory_grouper.dart';
import 'directory_analyzer.dart';

/// 作品目录刮削匹配难度分级：
/// - [easy]：携带显式 TMDB / Bangumi 编号且非混杂合集，可走直连快通道瞬间出图；
/// - [medium]：无显式编号但目录名规范清晰，常规双引擎 1~2 波即可高置信命中；
/// - [hard]：乱目录、伪年份冲突、拆簇子作、混杂合集、无年份 OVA/短名/整理噪声目录，
///   排在最后执行并在首轮未自动绑定时自动激活第二套困难目录专属救援规则。
enum MatchDifficulty {
  /// 简单：显式 ID 直连通道。
  easy(0, '简单'),

  /// 中等：标准片名无 ID 常规匹配。
  medium(1, '中等'),

  /// 困难：乱目录、高歧义或含整理噪声目录。
  hard(2, '困难');

  const MatchDifficulty(this.priority, this.label);

  /// 调度优先级（数值越小越先执行）。
  final int priority;

  /// 简体中文展示名称。
  final String label;
}

/// 零 IO、常数时间（O(1)）的目录匹配难度分级与稳定排序工具。
///
/// 严格复用归组阶段已在内存产出的目录画像字段，绝不额外遍历文件系统或重复扫描视频列表，
/// 确保扫描与聚合阶段零性能损耗。
abstract final class MatchDifficultyClassifier {
  static final RegExp _cjkPattern = RegExp(r'[\u3040-\u9fff]');
  static final RegExp _wsPattern = RegExp(r'\s+');

  static final RegExp _hardOrganizerNoise = RegExp(
    r'(?<![a-z0-9])(?:sp\d+|10bit|8bit|collection|selection|extra|club|edition|video)(?![a-z0-9])|'
    r'系列$|合集$|作品集$|テレビアニメ|TVアニメ|电视动画',
    caseSensitive: false,
  );

  /// 依据已有归组元数据执行 O(1) 匹配难度判定。
  static MatchDifficulty classify(GroupedWorkFolder folder) {
    final inv = folder.inventory;
    if (inv?.shape == WorkShape.anthology) {
      return MatchDifficulty.hard;
    }
    if (!folder.ignoreExplicitTmdb &&
        (folder.explicitTmdbId != null || folder.explicitBangumiId != null)) {
      return MatchDifficulty.easy;
    }
    if (folder.isSplitCluster) {
      return MatchDifficulty.hard;
    }
    if (DirectoryAnalyzer.isGenericOrIrregularFolderName(folder.folderName)) {
      return MatchDifficulty.hard;
    }
    if (inv != null &&
        inv.fileYear != null &&
        folder.year != null &&
        inv.fileYear != folder.year) {
      return MatchDifficulty.hard;
    }
    if (folder.year == null &&
        (DirectoryAnalyzer.isOvaText(folder.cleanTitle) ||
            (inv != null && DirectoryAnalyzer.isOva(inv)))) {
      return MatchDifficulty.hard;
    }
    final cleanNorm = DirectoryAnalyzer.normalize(folder.cleanTitle);
    if (folder.year == null && cleanNorm.length <= 4) {
      return MatchDifficulty.hard;
    }
    if (_hardOrganizerNoise.hasMatch(folder.cleanTitle)) {
      return MatchDifficulty.hard;
    }
    if (folder.titleHints.isEmpty && folder.fileHints.isNotEmpty) {
      return MatchDifficulty.hard;
    }
    if (folder.year == null &&
        !_cjkPattern.hasMatch(folder.cleanTitle) &&
        folder.cleanTitle.trim().split(_wsPattern).length <= 2) {
      return MatchDifficulty.hard;
    }
    return MatchDifficulty.medium;
  }

  /// 统计各难度分档的作品数量。
  static ({int easy, int medium, int hard}) countByDifficulty(
    Iterable<GroupedWorkFolder> folders,
  ) {
    var easy = 0;
    var medium = 0;
    var hard = 0;
    for (final folder in folders) {
      switch (folder.matchDifficulty) {
        case MatchDifficulty.easy:
          easy++;
        case MatchDifficulty.medium:
          medium++;
        case MatchDifficulty.hard:
          hard++;
      }
    }
    return (easy: easy, medium: medium, hard: hard);
  }

  /// 按 `简单 -> 中等 -> 困难` 执行确定性稳定排序（同档保持原有相对顺序）。
  static List<GroupedWorkFolder> sortByDifficulty(
    List<GroupedWorkFolder> folders,
  ) {
    if (folders.length <= 1) {
      return List<GroupedWorkFolder>.of(folders, growable: false);
    }
    final easy = <GroupedWorkFolder>[];
    final medium = <GroupedWorkFolder>[];
    final hard = <GroupedWorkFolder>[];
    for (final folder in folders) {
      switch (folder.matchDifficulty) {
        case MatchDifficulty.easy:
          easy.add(folder);
        case MatchDifficulty.medium:
          medium.add(folder);
        case MatchDifficulty.hard:
          hard.add(folder);
      }
    }
    return <GroupedWorkFolder>[...easy, ...medium, ...hard];
  }
}
