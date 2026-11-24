import 'package:konata_contracts/konata_contracts.dart';

export 'package:konata_contracts/konata_contracts.dart'
    show EpisodeCategory, ExtraKind;

/// 逻辑剧集与特典条目领域实体。
class Episode {
  /// 创建逻辑剧集实例。
  const Episode({
    required this.id,
    required this.workId,
    required this.seasonNumber,
    this.episodeNumber,
    this.episodeNumberEnd,
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

  /// 多集合并文件的区间结束集号（`null` 表示单集；非空时必须大于 [episodeNumber]，仅用于正片）。
  final int? episodeNumberEnd;

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

  /// 该条目覆盖的最后一集集号（单集时等于 [episodeNumber]）。
  int? get lastEpisodeNumber => episodeNumberEnd ?? episodeNumber;

  /// 是否为多集合并条目。
  bool get isEpisodeRange =>
      category == EpisodeCategory.main &&
      episodeNumber != null &&
      episodeNumberEnd != null &&
      episodeNumberEnd! > episodeNumber!;

  /// 是否为特典/附加映像（非正片时为 `true`，供各选集列表统一判断徽章样式）。
  bool get isSpecial => category == EpisodeCategory.extra;

  /// 复制并按需更新部分剧集字段（保留未指定字段不变）。
  Episode copyWith({
    int? seasonNumber,
    int? episodeNumber,
    int? episodeNumberEnd,
    EpisodeCategory? category,
    ExtraKind? extraType,
    String? title,
    String? overview,
    String? stillPath,
  }) {
    return Episode(
      id: id,
      workId: workId,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      episodeNumberEnd: episodeNumberEnd ?? this.episodeNumberEnd,
      category: category ?? this.category,
      extraType: extraType ?? this.extraType,
      title: title ?? this.title,
      overview: overview ?? this.overview,
      stillPath: stillPath ?? this.stillPath,
    );
  }

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
