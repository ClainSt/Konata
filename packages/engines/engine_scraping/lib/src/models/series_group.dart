import '../formatting/video_frame_selector.dart';
import '../parsing/bdrip_folder_cleaner.dart';
import '../parsing/season_number_parser.dart';
import 'work.dart';

/// 系列（Series）编组与条目标签预设。
class SeriesGroup {
  /// 创建系列分组实体。
  const SeriesGroup({
    required this.id,
    required this.title,
    this.tmdbCollectionId,
    this.rootFolderHint,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 系列唯一 ID。
  final String id;

  /// 系列名称（如主作中文名或合集目录名）。
  final String title;

  /// 关联的 TMDB 电影合集 ID（如剧场版系列）。
  final int? tmdbCollectionId;

  /// 关联的合集根目录提示（如媒体源内根目录相对路径）。
  final String? rootFolderHint;

  /// 创建时间。
  final DateTime createdAt;

  /// 最近更新时间。
  final DateTime updatedAt;

  /// 复制并按需替换系列元数据字段。
  SeriesGroup copyWith({
    String? title,
    int? tmdbCollectionId,
    bool clearTmdbCollectionId = false,
    String? rootFolderHint,
    bool clearRootFolderHint = false,
    DateTime? updatedAt,
  }) {
    return SeriesGroup(
      id: id,
      title: title ?? this.title,
      tmdbCollectionId: clearTmdbCollectionId
          ? null
          : (tmdbCollectionId ?? this.tmdbCollectionId),
      rootFolderHint: clearRootFolderHint
          ? null
          : (rootFolderHint ?? this.rootFolderHint),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// 同系列条目分类类型（用于统一时间线排序与季名/片名提炼）。
enum SeriesMemberKind {
  /// TV 常规分季（按 `matchedSeason` 升序排列）。
  tvSeason,

  /// 剧场版 / 电影（按上映年份时间序）。
  movie,

  /// OVA / OAD 映像（按发行时间序）。
  ova,

  /// 特别篇 / 总集篇 / 番外（按发行时间序）。
  special,
}

/// 同系列作品统一归组排序与「第 X 季 · 准确名称」格式化领域服务。
///
/// 全站唯一真源：被详情页 [SeriesSwitcherDropdown]、[workDetailBundleProvider]、
/// [SeriesAutoLinker]、播放器选集侧栏与跨季连播控制器共同复用，杜绝双轨分叉。
abstract final class SeriesSeasonFormatter {
  static final RegExp _genericRoleLabelPattern = RegExp(
    r'^(?:第\s*[0-9一二三四五六七八九十两]+\s*[季期]|season\s*\d+|特别篇|特別篇|OVA|OAD|SP|剧场版|劇場版|电影|電影|总集篇|總集篇|番外|特典|HD\s*重制版|HD\s*重製版|重制版|重製版|remaster(?:ed)?)$',
    caseSensitive: false,
  );

  static final RegExp _leadingSeasonTokenPattern = RegExp(
    r'^(?:第\s*[0-9一二三四五六七八九十两]+\s*[季期]|season[\s._-]*\d+|s\d{1,2}|\d+(?:st|nd|rd|th)\s*season)(?:[\s·:：\-_/]+|$)',
    caseSensitive: false,
  );

  static final RegExp _trailingOrdinalSeasonPattern = RegExp(
    r'(?:^|[\s·:：\-_/]+)(?:\d+(?:st|nd|rd|th)\s*season|part\s*\d+|cour\s*\d+)$',
    caseSensitive: false,
  );

  static final RegExp _leadingMoviePrefixPattern = RegExp(
    r'^(?:剧场版|劇場版|电影版|電影版|电影|電影|the\s+movie|movie)(?:[\s·:：\-_/]+|$)',
    caseSensitive: false,
  );

  static final RegExp _trailingMovieSuffixPattern = RegExp(
    r'(?:^|[\s·:：\-_/]+)(?:剧场版|劇場版|the\s+movie|movie)$',
    caseSensitive: false,
  );

  static final RegExp _leadingSpecialPrefixPattern = RegExp(
    r'^(?:特别篇|特別篇|总集篇|總集篇|番外篇|番外|special)(?:[\s·:：\-_/]+|$)',
    caseSensitive: false,
  );

  static final RegExp _trailingSpecialSuffixPattern = RegExp(
    r'(?:^|[\s·:：\-_/]+)(?:特别篇|特別篇|special)$',
    caseSensitive: false,
  );

  static final RegExp _leadingOvaPrefixPattern = RegExp(
    r'^(?:OVA|OAD)(?:[\s·:：\-_/]+|$)',
    caseSensitive: false,
  );

  static final RegExp _trailingOvaSuffixPattern = RegExp(
    r'(?:^|[\s·:：\-_/]+)(?:OVA|OAD)$',
    caseSensitive: false,
  );

  /// 剥离发布组、编码与分辨率噪点，保留干净的作品/季/剧场版名称。
  static String stripReleaseNoise(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isEmpty) return '';
    // 先保留副标题，只去掉发布组 `[VCB-Studio]`、`BDrip`、`HEVC`、`1080p` 等噪点
    final pre = trimmed
        .replaceAll(RegExp(r'^[\[【(][^\]】)]+[\]】)]\s*'), '')
        .trim();
    final cleaned = BdripFolderCleaner.parseFolderName(
      pre.isEmpty ? trimmed : pre,
    ).cleanTitle;
    return cleaned
        .replaceAll(RegExp(r'^[\s·:：\-_/]+|[\s·:：\-_/]+$'), '')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
  }

  static final RegExp _explicitOvaWordPattern = RegExp(
    r'(?<![a-z0-9])(?:ova|oad)(?![a-z0-9])',
    caseSensitive: false,
  );

  static final RegExp _explicitMovieWordPattern = RegExp(
    r'(?:剧场版|劇場版|电影版|電影版|\bmovie\b|\bfilm\b)',
    caseSensitive: false,
  );

  /// 判断系列成员归属类型（TV 季 / 剧场版 / OVA / 特别篇）。
  static SeriesMemberKind classifyMember(Work member) {
    final custom = member.seriesLabel?.trim().toLowerCase() ?? '';
    if (custom.startsWith('ova') || custom.startsWith('oad')) {
      return SeriesMemberKind.ova;
    }
    if (custom.startsWith('特别篇') ||
        custom.startsWith('特別篇') ||
        custom.startsWith('番外')) {
      return SeriesMemberKind.special;
    }
    if (custom.startsWith('剧场版') ||
        custom.startsWith('劇場版') ||
        custom.startsWith('电影') ||
        custom.startsWith('movie')) {
      return SeriesMemberKind.movie;
    }

    final titleCombined = '${member.title} ${member.originalTitle ?? ''}';
    if (member.tmdbMediaType == TmdbMediaType.movie) {
      if (_explicitOvaWordPattern.hasMatch(titleCombined) &&
          !_explicitMovieWordPattern.hasMatch(titleCombined)) {
        return SeriesMemberKind.ova;
      }
      return SeriesMemberKind.movie;
    }

    if (member.tmdbMediaType == TmdbMediaType.tv &&
        member.matchedSeason != null &&
        member.matchedSeason! > 0) {
      return SeriesMemberKind.tvSeason;
    }

    if (_explicitOvaWordPattern.hasMatch(titleCombined)) {
      return SeriesMemberKind.ova;
    }
    if (member.matchedSeason == 0) {
      return SeriesMemberKind.special;
    }
    return SeriesMemberKind.tvSeason;
  }

  /// 解析详情页应当展示的 16:9 横版背景来源（自身优先，缺失时自动复用同系列母剧横图）。
  ///
  /// 仅当作品明确归属某个系列（`seriesId` 非空且 [seriesMembers] 不少于 2 部）时借用兄弟作品横图；
  /// 优先选用母剧 TV 第 1 季 -> 其他 TV 季 -> 特别篇 -> 其他成员，且自动忽略未锁定的旧版低质自动抽帧背景。
  static ({String path, String ownerWorkId, bool isShared})?
  resolveEffectiveHeroBackdrop({
    required Work work,
    required List<Work> seriesMembers,
  }) {
    final own = work.backdropPath?.trim() ?? '';
    final ownIsOfficial =
        own.isNotEmpty &&
        (work.backdropLocked ||
            !VideoFrameSamplePlan.isLegacyAutoBackdropPath(own));
    if (ownIsOfficial) {
      return (path: own, ownerWorkId: work.id, isShared: false);
    }

    final seriesId = work.seriesId?.trim() ?? '';
    if (seriesId.isNotEmpty && seriesMembers.length >= 2) {
      final donors = <Work>[
        for (final member in seriesMembers)
          if (member.id != work.id &&
              (member.backdropPath?.trim().isNotEmpty ?? false) &&
              !VideoFrameSamplePlan.isLegacyAutoBackdropPath(
                member.backdropPath,
              ))
            member,
      ];
      if (donors.isNotEmpty) {
        donors.sort(_compareBackdropDonor);
        final best = donors.first;
        return (
          path: best.backdropPath!.trim(),
          ownerWorkId: best.id,
          isShared: true,
        );
      }
    }

    if (own.isNotEmpty) {
      return (path: own, ownerWorkId: work.id, isShared: false);
    }
    return null;
  }

  static int _backdropDonorRank(Work member) {
    if (member.tmdbMediaType == TmdbMediaType.tv) {
      final season = member.matchedSeason;
      if (season == 1) return 0;
      if (season != null && season > 1) return 1;
      if (season == 0) return 2;
      return 1;
    }
    return 3;
  }

  static int _compareBackdropDonor(Work a, Work b) {
    final rankCmp = _backdropDonorRank(a).compareTo(_backdropDonorRank(b));
    if (rankCmp != 0) return rankCmp;
    return compareSeriesMembers(a, b, respectLockedOrder: false);
  }

  /// 按「TV 季号升序 -> 首播时间升序 -> 剧场版/OVA 时间序」排序同系列成员。
  ///
  /// 当 [respectLockedOrder] 为 `true` 且任一方显式人工锁定系列顺序（`seriesLocked`）时，
  /// 优先尊从用户锁定的 `seriesOrder`。
  static int compareSeriesMembers(
    Work a,
    Work b, {
    bool respectLockedOrder = true,
  }) {
    if (respectLockedOrder && (a.seriesLocked || b.seriesLocked)) {
      final aOrder = a.seriesOrder ?? 99999;
      final bOrder = b.seriesOrder ?? 99999;
      if (aOrder != bOrder) return aOrder.compareTo(bOrder);
    }

    final aKind = classifyMember(a);
    final bKind = classifyMember(b);
    final aPrimaryRank = aKind == SeriesMemberKind.tvSeason ? 0 : 1;
    final bPrimaryRank = bKind == SeriesMemberKind.tvSeason ? 0 : 1;
    if (aPrimaryRank != bPrimaryRank) {
      return aPrimaryRank.compareTo(bPrimaryRank);
    }

    if (aPrimaryRank == 0) {
      final aSeason =
          a.matchedSeason ??
          SeasonNumberParser.splitSeasonSuffix(a.title).seasonNumber ??
          a.seriesOrder ??
          999;
      final bSeason =
          b.matchedSeason ??
          SeasonNumberParser.splitSeasonSuffix(b.title).seasonNumber ??
          b.seriesOrder ??
          999;
      if (aSeason != bSeason) return aSeason.compareTo(bSeason);

      final yearCmp = (a.year ?? 9999).compareTo(b.year ?? 9999);
      if (yearCmp != 0) return yearCmp;
    } else {
      final yearCmp = (a.year ?? 9999).compareTo(b.year ?? 9999);
      if (yearCmp != 0) return yearCmp;

      final kindCmp = aKind.index.compareTo(bKind.index);
      if (kindCmp != 0) return kindCmp;
    }

    final orderCmp = (a.seriesOrder ?? 99999).compareTo(b.seriesOrder ?? 99999);
    if (orderCmp != 0) return orderCmp;

    final titleCmp = stripReleaseNoise(
      a.title,
    ).toLowerCase().compareTo(stripReleaseNoise(b.title).toLowerCase());
    if (titleCmp != 0) return titleCmp;
    return a.id.compareTo(b.id);
  }

  /// 返回按时间线排序后的同系列成员列表。
  static List<Work> sortSeriesMembers(
    Iterable<Work> members, {
    bool respectLockedOrder = true,
  }) {
    final list = List<Work>.of(members);
    list.sort(
      (a, b) =>
          compareSeriesMembers(a, b, respectLockedOrder: respectLockedOrder),
    );
    return list;
  }

  /// 剥离与既定角色/季号前缀重复的前后缀词（杜绝 `第 2 季 · 第 2 季`、`剧场版 · 剧场版`）。
  static String stripDuplicateRolePrefix(
    String rawTitle, {
    required SeriesMemberKind kind,
    String? customPrefix,
  }) {
    var working = stripReleaseNoise(rawTitle);
    if (working.isEmpty) return '';

    if (kind == SeriesMemberKind.tvSeason) {
      working = SeasonNumberParser.splitSeasonSuffix(working).title;
      working = working
          .replaceFirst(_leadingSeasonTokenPattern, '')
          .replaceFirst(_trailingOrdinalSeasonPattern, '')
          .trim();
    } else if (kind == SeriesMemberKind.movie) {
      working = working
          .replaceFirst(_leadingMoviePrefixPattern, '')
          .replaceFirst(_trailingMovieSuffixPattern, '')
          .trim();
    } else if (kind == SeriesMemberKind.ova) {
      working = working
          .replaceFirst(_leadingOvaPrefixPattern, '')
          .replaceFirst(_trailingOvaSuffixPattern, '')
          .trim();
    } else if (kind == SeriesMemberKind.special) {
      working = working
          .replaceFirst(_leadingSpecialPrefixPattern, '')
          .replaceFirst(_trailingSpecialSuffixPattern, '')
          .trim();
    }

    if (customPrefix != null && customPrefix.isNotEmpty) {
      final escaped = RegExp.escape(customPrefix);
      working = working
          .replaceFirst(
            RegExp('^$escaped(?:[\\s·:：\\-_/]+|\$)', caseSensitive: false),
            '',
          )
          .trim();
    }

    return working
        .replaceAll(RegExp(r'^[\s·:：\-_/]+|[\s·:：\-_/]+$'), '')
        .trim();
  }

  /// 判断系列标签是否为空或通用角色预设（如 `第 1 季`、`剧场版`、`OVA`、`特别篇`）。
  static bool isGenericRoleLabel(String? rawLabel) {
    final trimmed = rawLabel?.trim() ?? '';
    return trimmed.isEmpty || _genericRoleLabelPattern.hasMatch(trimmed);
  }

  /// 解析并格式化单部系列成员的标准展示名称（如 `第 1 季 · <准确季名>`、`剧场版 · <准确片名>`、`OVA · <准确名称>`）。
  static String formatMemberLabel(
    Work member,
    Iterable<Work> allMembers, {
    SeriesGroup? seriesGroup,
    int? fallbackOrder,
  }) {
    final customRaw = member.seriesLabel?.trim() ?? '';
    final isGenericPreset = isGenericRoleLabel(customRaw);
    if (!isGenericPreset) {
      // 用户已手填具名角色标签（如 `剧场版 Code: White`），保留干净文本不画蛇添足。
      return customRaw.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
    }

    final kind = classifyMember(member);
    final rolePrefix = _resolveRolePrefix(
      member,
      kind: kind,
      customGeneric: customRaw,
      fallbackOrder: fallbackOrder,
    );

    final fallbackGroupTitle = seriesGroup?.title.trim();
    final accurateName = stripDuplicateRolePrefix(
      member.title,
      kind: kind,
      customPrefix: rolePrefix,
    );
    final resolvedName = accurateName.isNotEmpty
        ? accurateName
        : (fallbackGroupTitle != null && fallbackGroupTitle.isNotEmpty
              ? stripDuplicateRolePrefix(
                  fallbackGroupTitle,
                  kind: kind,
                  customPrefix: rolePrefix,
                )
              : '');

    if (rolePrefix.isEmpty) {
      return resolvedName.isNotEmpty ? resolvedName : member.title.trim();
    }
    if (resolvedName.isEmpty || resolvedName == rolePrefix) {
      return rolePrefix;
    }
    return '$rolePrefix · $resolvedName';
  }

  /// 解析系列下拉菜单单行的「主标题（纯净作品名）+ 副元信息（季号/类型 · 年份）」。
  ///
  /// - 若用户已手填具名角色标签（如 `剧场版 Code: White`），主行保留该标签、副行仅展示年份；
  /// - 常规条目主行展示去除重复季号/类型前缀后的作品名，副行展示 `第 N 季 · 2000` / `剧场版 · 2021` /
  ///   `特别篇 · 2012`，避免主副两行重复出现作品名或季号。
  static ({String title, String? meta}) formatMemberMenuParts(
    Work member,
    Iterable<Work> allMembers, {
    SeriesGroup? seriesGroup,
    int? fallbackOrder,
  }) {
    final customRaw = member.seriesLabel?.trim() ?? '';
    final yearText = member.year != null ? '${member.year}' : null;
    if (!isGenericRoleLabel(customRaw)) {
      return (
        title: customRaw.replaceAll(RegExp(r'\s{2,}'), ' ').trim(),
        meta: yearText,
      );
    }

    final kind = classifyMember(member);
    final rolePrefix = _resolveRolePrefix(
      member,
      kind: kind,
      customGeneric: customRaw,
      fallbackOrder: fallbackOrder,
    );
    final fallbackGroupTitle = seriesGroup?.title.trim();
    final accurateName = stripDuplicateRolePrefix(
      member.title,
      kind: kind,
      customPrefix: rolePrefix,
    );
    final resolvedName = accurateName.isNotEmpty
        ? accurateName
        : (fallbackGroupTitle != null && fallbackGroupTitle.isNotEmpty
              ? stripDuplicateRolePrefix(
                  fallbackGroupTitle,
                  kind: kind,
                  customPrefix: rolePrefix,
                )
              : '');

    final primaryTitle = resolvedName.isNotEmpty
        ? resolvedName
        : (rolePrefix.isNotEmpty ? rolePrefix : member.title.trim());
    final showRoleInMeta = rolePrefix.isNotEmpty && rolePrefix != primaryTitle;
    final metaParts = <String>[if (showRoleInMeta) rolePrefix, ?yearText];
    return (
      title: primaryTitle,
      meta: metaParts.isEmpty ? null : metaParts.join(' · '),
    );
  }

  static String _resolveRolePrefix(
    Work member, {
    required SeriesMemberKind kind,
    required String customGeneric,
    int? fallbackOrder,
  }) {
    if (customGeneric.isNotEmpty) {
      final parsedCustomSeason = SeasonNumberParser.splitSeasonSuffix(
        customGeneric,
      ).seasonNumber;
      if (parsedCustomSeason != null && parsedCustomSeason > 0) {
        return SeriesLabelPresets.seasonLabel(parsedCustomSeason);
      }
      if (kind == SeriesMemberKind.special && customGeneric == '特别篇') {
        return '特别篇';
      }
      if (kind == SeriesMemberKind.movie &&
          (customGeneric == '剧场版' || customGeneric == '电影')) {
        return '剧场版';
      }
      if (kind == SeriesMemberKind.ova) {
        return customGeneric.toUpperCase() == 'OAD' ? 'OAD' : 'OVA';
      }
    }

    switch (kind) {
      case SeriesMemberKind.tvSeason:
        final season =
            member.matchedSeason ??
            SeasonNumberParser.splitSeasonSuffix(member.title).seasonNumber;
        if (season != null && season > 0) {
          return SeriesLabelPresets.seasonLabel(season);
        }
        return '';
      case SeriesMemberKind.movie:
        return '剧场版';
      case SeriesMemberKind.ova:
        final upper = '${member.title} ${member.originalTitle ?? ''}'
            .toUpperCase();
        return upper.contains('OAD') ? 'OAD' : 'OVA';
      case SeriesMemberKind.special:
        return '特别篇';
    }
  }
}

/// 系列内条目角色标签快捷预设。
abstract final class SeriesLabelPresets {
  /// 默认快捷标签列表。
  static const List<String> presets = [
    '第 1 季',
    '第 2 季',
    '第 3 季',
    '第 4 季',
    '剧场版',
    '电影',
    'OVA',
    'OAD',
    '特别篇',
  ];

  /// 生成标准季标签文本。
  static String seasonLabel(int seasonNumber) =>
      seasonNumber == 0 ? '特别篇' : '第 $seasonNumber 季';

  /// 推断单个系列成员的基础角色/季标签（尚未叠加成员标题消歧）。
  static String resolveMemberBaseLabel(Work member, {int? fallbackOrder}) {
    final custom = member.seriesLabel?.trim();
    if (custom != null && custom.isNotEmpty) return custom;
    if (member.tmdbMediaType == TmdbMediaType.tv &&
        member.matchedSeason != null &&
        member.matchedSeason! > 0) {
      return seasonLabel(member.matchedSeason!);
    }
    if (member.tmdbMediaType == TmdbMediaType.movie) {
      return '剧场版';
    }
    if (member.matchedSeason == 0) {
      return '特别篇';
    }
    final parsedSeason = SeasonNumberParser.splitSeasonSuffix(
      member.title,
    ).seasonNumber;
    if (parsedSeason != null && parsedSeason > 0) {
      return seasonLabel(parsedSeason);
    }
    return member.title.trim();
  }

  /// 生成统一格式的系列成员展示标签（委托至 [SeriesSeasonFormatter] 单一真源）。
  static String formatDisambiguatedMemberLabel(
    Work member,
    Iterable<Work> allMembers, {
    SeriesGroup? seriesGroup,
    int? fallbackOrder,
  }) {
    return SeriesSeasonFormatter.formatMemberLabel(
      member,
      allMembers,
      seriesGroup: seriesGroup,
      fallbackOrder: fallbackOrder,
    );
  }
}
