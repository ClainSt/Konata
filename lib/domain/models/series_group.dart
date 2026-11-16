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

  static final RegExp _genericRoleLabelPattern = RegExp(
    r'^(?:特别篇|特別篇|OVA|OAD|SP|剧场版|劇場版|电影|電影|总集篇|總集篇|番外|特典)$',
    caseSensitive: false,
  );

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
    if (fallbackOrder != null && fallbackOrder > 0) {
      return seasonLabel(fallbackOrder);
    }
    return member.title.trim();
  }

  /// 生成带防撞名消歧的系列成员展示标签。
  ///
  /// 当成员标签属于笼统角色预设（如 `特别篇`、`OVA`、`OAD`、`剧场版`）
  /// 或同系列存在多个同名标签时，自动拼接具体作品标题为
  /// `<季标签> · <成员作品名>`，避免多部特别篇或同类条目混为一谈；
  /// 若用户已为其命名专属不重名标签（如 `剧场版 Code: White`）或标准 `第 N 季`
  /// 且无撞名，则保留简洁原标签不冗余拼接。
  static String formatDisambiguatedMemberLabel(
    Work member,
    Iterable<Work> allMembers, {
    int? fallbackOrder,
  }) {
    final memberList = allMembers is List<Work>
        ? allMembers
        : allMembers.toList(growable: false);
    final baseLabel = resolveMemberBaseLabel(
      member,
      fallbackOrder: fallbackOrder,
    );
    final cleanTitle = member.title.trim();
    if (baseLabel.isEmpty || cleanTitle.isEmpty || baseLabel == cleanTitle) {
      return baseLabel.isNotEmpty ? baseLabel : cleanTitle;
    }

    var sameLabelCount = 0;
    for (var i = 0; i < memberList.length; i++) {
      final candidate = memberList[i];
      final order = candidate.id == member.id ? fallbackOrder : (i + 1);
      if (resolveMemberBaseLabel(candidate, fallbackOrder: order) ==
          baseLabel) {
        sameLabelCount++;
      }
    }

    final isGenericRole = _genericRoleLabelPattern.hasMatch(baseLabel);
    if ((isGenericRole || sameLabelCount > 1) &&
        !baseLabel.contains(cleanTitle)) {
      return '$baseLabel · $cleanTitle';
    }
    return baseLabel;
  }
}
