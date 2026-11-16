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

/// 逻辑剧集与特典条目领域实体。
class Episode {
  /// 创建逻辑剧集实例。
  const Episode({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.episodeNumber,
    this.category = EpisodeCategory.main,
    this.extraType,
    this.title,
    this.overview,
    this.stillPath,
  });

  /// 剧集唯一标识。
  final String id;

  /// 所属作品 ID。
  final String workId;

  /// 所属季号（特典通常为 0，正片从 1 开始）。
  final int seasonNumber;

  /// 集号或特典序号（无法提取编号的独立视频保持为空，绝不强行归为第 1 集）。
  final int? episodeNumber;

  /// 分类（正片或特典）。
  final EpisodeCategory category;

  /// 特典具体类型（仅 `category == EpisodeCategory.extra` 时有意义）。
  final ExtraKind? extraType;

  /// 单集标题。
  final String? title;

  /// 单集简介。
  final String? overview;

  /// 单集剧照路径。
  final String? stillPath;

  /// 是否为特典/附加映像（非正片时为 `true`，供各选集列表统一判断徽章样式）。
  bool get isSpecial => category == EpisodeCategory.extra;

  /// 正片严格置顶升序、特典（NCOP / NCED / PV / MENU 等）紧随其后的统一排序比较器。
  static int compareMainFirst(Episode a, Episode b) {
    final aCat = a.category == EpisodeCategory.main ? 0 : 1;
    final bCat = b.category == EpisodeCategory.main ? 0 : 1;
    if (aCat != bCat) return aCat.compareTo(bCat);

    if (a.category == EpisodeCategory.main) {
      final seasonCmp = a.seasonNumber.compareTo(b.seasonNumber);
      if (seasonCmp != 0) return seasonCmp;
    } else {
      final aType = a.extraType?.index ?? 99;
      final bType = b.extraType?.index ?? 99;
      if (aType != bType) return aType.compareTo(bType);
    }

    final aNum = a.episodeNumber ?? 999999;
    final bNum = b.episodeNumber ?? 999999;
    if (aNum != bNum) return aNum.compareTo(bNum);

    final titleCmp = (a.title ?? '').toLowerCase().compareTo(
      (b.title ?? '').toLowerCase(),
    );
    if (titleCmp != 0) return titleCmp;
    return a.id.compareTo(b.id);
  }

  /// 返回正片按集号升序置顶、特典置于正片之后的排序新列表。
  static List<Episode> sortMainFirst(Iterable<Episode> episodes) {
    final list = List<Episode>.of(episodes);
    list.sort(compareMainFirst);
    return list;
  }
}
