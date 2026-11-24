import 'package:engine_scraping/engine_scraping.dart';

/// 媒体库海报墙排序字段枚举。
enum LibrarySortMode {
  /// 按中文拼音、英文字母与自然数字排序。
  title,

  /// 按放送或首映年份排序。
  year,

  /// 按 Bangumi / TMDB 综合评分排序。
  score,

  /// 按最近扫描入库顺序（兜底标题）排序。
  recent,
}

/// 媒体库海报墙排序方向枚举。
enum LibrarySortOrder {
  /// 升序。
  ascending,

  /// 降序。
  descending,
}

/// 媒体库海报墙聚合作品展示模型。
class WorkLibraryItem {
  /// 创建海报墙作品展示项。
  const WorkLibraryItem({
    required this.work,
    required this.variants,
    int? variantCount,
    String? firstVariantRelativePath,
    required this.episodeCount,
    required this.releaseGroups,
    this.maxEpisodeVariantCount = 1,
    this.sourceIds = const <String>[],
    this.primarySourceKind,
    this.primarySourceLabel,
    this.crossSourceBadgeLabel,
  }) : _storedVariantCount = variantCount,
       _storedFirstVariantRelativePath = firstVariantRelativePath;

  /// 核心作品元数据实体。
  final Work work;

  /// 关联的视频与媒体变体列表。
  final List<MediaVariant> variants;

  final int? _storedVariantCount;
  final String? _storedFirstVariantRelativePath;

  /// 物理媒体文件总数（支持空变体轻量模式下直接传入汇总计数）。
  int get variantCount => _storedVariantCount ?? variants.length;

  /// 首条代表性媒体文件的相对路径。
  String? get firstVariantRelativePath =>
      _storedFirstVariantRelativePath ??
      (variants.isNotEmpty ? variants.first.relativePath : null);

  /// 已识别分集数量。
  final int episodeCount;

  /// 提取出的字幕组 / 压制组列表。
  final List<String> releaseGroups;

  /// 单集最多并存的物理文件版本数。
  final int maxEpisodeVariantCount;

  /// 本作品关联的去重媒体源 ID 列表。
  final List<String> sourceIds;

  /// 主媒体源协议类型。
  final MediaSourceKind? primarySourceKind;

  /// 主媒体源显示名称。
  final String? primarySourceLabel;

  /// 仅当跨源存在同名重复条目时赋予的右上角来源角标文案。
  final String? crossSourceBadgeLabel;

  /// 返回附带跨来源角标文案的新展示副本。
  WorkLibraryItem withCrossSourceBadge(String? badgeLabel) {
    return WorkLibraryItem(
      work: work,
      variants: variants,
      variantCount: _storedVariantCount,
      firstVariantRelativePath: _storedFirstVariantRelativePath,
      episodeCount: episodeCount,
      releaseGroups: releaseGroups,
      maxEpisodeVariantCount: maxEpisodeVariantCount,
      sourceIds: sourceIds,
      primarySourceKind: primarySourceKind,
      primarySourceLabel: primarySourceLabel,
      crossSourceBadgeLabel: badgeLabel,
    );
  }
}

/// 识别并标注来自不同媒体源但属于同一动画的重复作品角标。
List<WorkLibraryItem> annotateCrossSourceBadges(List<WorkLibraryItem> items) {
  if (items.length < 2) return items;
  final buckets = <String, List<int>>{};
  for (var i = 0; i < items.length; i++) {
    final key = WorkWallEligibility.buildCrossSourceIdentityKey(items[i].work);
    buckets.putIfAbsent(key, () => <int>[]).add(i);
  }

  List<WorkLibraryItem>? updated;
  for (final indices in buckets.values) {
    if (indices.length < 2) continue;
    final distinctSources = <String>{};
    for (final idx in indices) {
      distinctSources.addAll(items[idx].sourceIds);
    }
    if (distinctSources.length < 2) continue;

    updated ??= List<WorkLibraryItem>.of(items);
    for (final idx in indices) {
      final item = updated[idx];
      final label = _formatSourceBadgeLabel(
        item.primarySourceKind,
        item.primarySourceLabel,
      );
      if (label != null && label.isNotEmpty) {
        updated[idx] = item.withCrossSourceBadge(label);
      }
    }
  }
  return updated == null ? items : List<WorkLibraryItem>.unmodifiable(updated);
}

String? _formatSourceBadgeLabel(MediaSourceKind? kind, String? label) {
  final clean = label?.trim() ?? '';
  if (clean.isNotEmpty) return clean;
  return switch (kind) {
    MediaSourceKind.local => '本地',
    MediaSourceKind.webdav => 'WebDAV',
    MediaSourceKind.smb => 'SMB',
    null => null,
  };
}

/// Bangumi 独立条目与 TMDB 母系列混搭混合绑定请求参数。
class HybridMatchRequest {
  /// 创建双源混合绑定请求。
  const HybridMatchRequest({
    required this.bangumiSubject,
    required this.tmdbDetail,
    required this.tmdbSeasonNumber,
    required this.startEpisodeNumber,
    this.customSlotsByVariantId,
  });

  /// 提供独立标题、封面、评分与简介的 Bangumi 条目。
  final BangumiSubjectCandidate bangumiSubject;

  /// 提供横版背景原画与分集剧照的 TMDB 母系列条目。
  final TmdbWorkDetail tmdbDetail;

  /// 对应的 TMDB 季号。
  final int tmdbSeasonNumber;

  /// 正片文件的起始 TMDB 映射集号。
  final int startEpisodeNumber;

  /// 可选按物理版本 ID 显式覆盖的季/集槽位映射。
  final Map<String, ({int season, int episode})>? customSlotsByVariantId;
}

/// 将源作品合并入目标作品后的迁移统计结果。
class WorkMergeOutcome {
  /// 创建作品合并结果快照。
  const WorkMergeOutcome({
    required this.targetWork,
    required this.movedVariantCount,
    required this.movedEpisodeCount,
    required this.sourceDeleted,
  });

  /// 合并接收方的目标作品。
  final Work targetWork;

  /// 迁移并锁定到目标作品下的物理文件数量。
  final int movedVariantCount;

  /// 合并迁移的分集记录数量。
  final int movedEpisodeCount;

  /// 源作品是否已清空并通过软删除墓碑移出主库。
  final bool sourceDeleted;
}

/// 待复核原因标识翻译与网络异常判别工具。
abstract final class ReviewReasonLabels {
  /// 将存储层的复核原因文案或编码转换为可读中文说明。
  static String format(String? rawReason) {
    final clean = rawReason?.trim() ?? '';
    if (clean.isEmpty) return '存在多条相似候选，建议人工核对';
    if (clean.startsWith('network_error:') || clean == 'network_error') {
      final detail = clean.contains(':')
          ? clean.substring(clean.indexOf(':') + 1).trim()
          : '';
      return detail.isEmpty ? '元数据网络请求异常，请检查网络或代理后重试' : '网络请求异常：$detail';
    }
    return switch (clean) {
      'ambiguous_candidates' => '存在多个近似候选，需人工确认唯一条目',
      'low_confidence' => '自动匹配置信度偏低，请核对封面与年份',
      'unmatched' => '未自动检索到高置信元数据，请手动搜索绑定',
      'mixed_season_hint' => '检测到跨季或混杂分集信号，建议复核集数归属',
      'season_ambiguous' => '季别归属不够明确，建议核对 TMDB 季号',
      _ => clean,
    };
  }

  /// 判断当前复核原因是否由网络、限流或证书错误导致（适合批量重试）。
  static bool isNetworkError(String? rawReason) {
    final clean = rawReason?.trim().toLowerCase() ?? '';
    if (clean.isEmpty) return false;
    return clean.startsWith('network_error') ||
        clean.contains('超时') ||
        clean.contains('socket') ||
        clean.contains('http ') ||
        clean.contains('429') ||
        clean.contains('连接');
  }
}

/// 媒体文件与标题展示通用格式化工具（零状态纯函数）。
abstract final class MediaDisplayFormatter {
  static final RegExp _hanziPattern = RegExp(r'[\u4E00-\u9FFF]');

  /// 判断副标题（原名）与主标题存在足够信息增量时才展示，避免冗余重复。
  static bool shouldShowOriginalSubtitle({
    required String title,
    required String? originalTitle,
  }) {
    final orig = originalTitle?.trim() ?? '';
    if (orig.isEmpty) return false;
    final cleanTitle = title.trim();
    if (orig.toLowerCase() == cleanTitle.toLowerCase()) return false;
    final titleHasHanzi = _hanziPattern.hasMatch(cleanTitle);
    final origHasHanzi = _hanziPattern.hasMatch(orig);
    if (!titleHasHanzi && !origHasHanzi) {
      return orig.toLowerCase() != cleanTitle.toLowerCase();
    }
    return true;
  }

  /// 将字节数格式化为人类可读的文件大小文案。
  static String formatBytes(int? bytes, {String emptyFallback = ''}) {
    if (bytes == null || bytes < 0) return emptyFallback;
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(2)} GB';
  }

  /// 提取文件大写扩展名。
  static String fileExtensionUpper(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot >= fileName.length - 1) return '';
    return fileName.substring(dot + 1).trim().toUpperCase();
  }

  /// 在长文件名符号附近插入零宽可断点，防止极窄视口出现溢出或乱行切断。
  static String formatWrappableFileName(String raw) {
    return raw
        .replaceAll('_', '_\u200B')
        .replaceAll('.', '.\u200B')
        .replaceAll('-', '-\u200B');
  }
}
