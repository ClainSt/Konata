import '../models/episode.dart';
import '../models/playback_record.dart';
import '../models/work.dart';

/// 剧集卡片与外部播放器可读标题统一格式化工具。
///
/// 负责统一处理：
/// 1. 单一正片视频（电影/剧场版/单集 OVA 或单集正片）免除多余 `01 ·` 前缀；
/// 2. 特典映像直接展示特典标题而不强加数字集号前缀；
/// 3. 为 MPV / PotPlayer 生成干净无 URL 编码的播放标题。
abstract final class EpisodeTitleFormatter {
  static final RegExp _genericEpisodePattern = RegExp(
    r'^(?:正片|第\s*0*\d+\s*[话集話]|(?:episode|ep)\s*0*\d+)$',
    caseSensitive: false,
  );

  /// 判断单集标题是否仅为默认占位文本（如 `第 1 话`、`第 01 话`、`正片`）。
  static bool isGenericEpisodePlaceholder(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    return _genericEpisodePattern.hasMatch(trimmed);
  }

  /// 判断当前正片条目是否属于单一正片视频（不展示 `01 ·` 集号前缀）。
  static bool isSingleMainVideo({
    required Episode episode,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
  }) {
    if (episode.category != EpisodeCategory.main) {
      return false;
    }
    if (workMediaType == TmdbMediaType.movie) {
      return true;
    }
    final epNum = episode.episodeNumber;
    if (epNum == null) {
      return mainEpisodeCount == 1;
    }
    return mainEpisodeCount == 1 && epNum <= 1;
  }

  /// 格式化详情页抽屉卡片中展示的剧集/特典标题。
  static String formatCardTitle({
    required Episode episode,
    String? workTitle,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
  }) {
    final rawTitle = episode.title?.trim();

    // 特典卡片：不加 `01 ·` / `02 ·` 序号前缀，直接展示特典名或默认标签。
    if (episode.category == EpisodeCategory.extra) {
      if (rawTitle != null && rawTitle.isNotEmpty) {
        return rawTitle;
      }
      final numStr = episode.episodeNumber?.toString().padLeft(2, '0');
      final kind = episode.extraType;
      if (kind != null) {
        return numStr == null
            ? kind.name.toUpperCase()
            : '${kind.name.toUpperCase()} $numStr';
      }
      return numStr == null ? '特典' : '特典 $numStr';
    }

    // 单一正片视频：移除 `01 ·` 前缀，占位标题时回退为作品主标题或 `正片`。
    if (isSingleMainVideo(
      episode: episode,
      workMediaType: workMediaType,
      mainEpisodeCount: mainEpisodeCount,
    )) {
      if (rawTitle != null &&
          rawTitle.isNotEmpty &&
          !isGenericEpisodePlaceholder(rawTitle)) {
        return rawTitle;
      }
      final trimmedWork = workTitle?.trim();
      if (trimmedWork != null && trimmedWork.isNotEmpty) {
        return trimmedWork;
      }
      return '正片';
    }

    // 标准多集番剧：保留 `01 · 单集标题` 格式，缺省标题使用 `第 01 话`；未识别集号不强行补 `01 ·`。
    final epNum = episode.episodeNumber;
    if (epNum == null) {
      if (rawTitle != null && rawTitle.isNotEmpty) {
        return rawTitle;
      }
      return '未分集';
    }
    final epNumStr = epNum.toString().padLeft(2, '0');
    if (rawTitle != null &&
        rawTitle.isNotEmpty &&
        !isGenericEpisodePlaceholder(rawTitle)) {
      return '$epNumStr · $rawTitle';
    }
    return '第 $epNumStr 话';
  }

  /// 格式化播放记录页的单集副标题（避免旧版 `S01E01` 或冗余重复，保持 `[集号] · [单集标题]` / 特典短标题）。
  static String formatHistorySubtitle({
    required PlaybackRecord record,
    Work? work,
    int? mainEpisodeCount,
  }) {
    final rawTitle = record.episodeTitle.trim();
    final isValidTitle =
        rawTitle.isNotEmpty && !RegExp(r'\bnull\b').hasMatch(rawTitle);

    // 季号为 0 对应特典/SP 资产：直接展示精简特典标题，绝不前置 `01 ·` 或 `S00E01`。
    if (record.seasonNumber == 0) {
      if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
        return rawTitle;
      }
      if (record.episodeNumber != null) {
        return 'SP${record.episodeNumber.toString().padLeft(2, '0')}';
      }
      return '特典';
    }

    // 单一正片（剧场版或仅 1 话单集作品）：直接展示单集标题或作品主标题，不前置 `01 ·`。
    final isSingleMain =
        work?.tmdbMediaType == TmdbMediaType.movie ||
        (mainEpisodeCount == 1 &&
            (record.episodeNumber == null || record.episodeNumber! <= 1));
    if (isSingleMain) {
      if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
        return rawTitle;
      }
      final trimmedWork = work?.title.trim();
      if (trimmedWork != null && trimmedWork.isNotEmpty) {
        return trimmedWork;
      }
      return '正片';
    }

    // 标准多集正片：格式统一为 `01 · 单集标题` 或 `第 01 话`。
    final epNum = record.episodeNumber;
    if (epNum == null) {
      if (isValidTitle) return rawTitle;
      final trimmedWork = work?.title.trim();
      return (trimmedWork != null && trimmedWork.isNotEmpty)
          ? trimmedWork
          : '未分集';
    }
    final epNumStr = epNum.toString().padLeft(2, '0');
    if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
      return '$epNumStr · $rawTitle';
    }
    return '第 $epNumStr 话';
  }

  /// 格式化传递给外部播放器（MPV `--force-media-title` / `--title`）的干净标题。
  static String formatPlayerMediaTitle({
    required Work work,
    required Episode episode,
    int? mainEpisodeCount,
    String? fallbackFileName,
  }) {
    final trimmedWork = work.title.trim();
    final rawEpTitle = episode.title?.trim();

    if (episode.category == EpisodeCategory.extra) {
      final extraTitle = formatCardTitle(
        episode: episode,
        workTitle: trimmedWork,
        workMediaType: work.tmdbMediaType,
        mainEpisodeCount: mainEpisodeCount,
      );
      return trimmedWork.isNotEmpty ? '$trimmedWork · $extraTitle' : extraTitle;
    }

    if (isSingleMainVideo(
      episode: episode,
      workMediaType: work.tmdbMediaType,
      mainEpisodeCount: mainEpisodeCount,
    )) {
      if (trimmedWork.isNotEmpty) {
        if (rawEpTitle != null &&
            rawEpTitle.isNotEmpty &&
            !isGenericEpisodePlaceholder(rawEpTitle) &&
            rawEpTitle != trimmedWork) {
          return '$trimmedWork · $rawEpTitle';
        }
        return trimmedWork;
      }
      if (rawEpTitle != null &&
          rawEpTitle.isNotEmpty &&
          !isGenericEpisodePlaceholder(rawEpTitle)) {
        return rawEpTitle;
      }
    } else {
      final cardTitle = formatCardTitle(
        episode: episode,
        workTitle: trimmedWork,
        workMediaType: work.tmdbMediaType,
        mainEpisodeCount: mainEpisodeCount,
      );
      if (trimmedWork.isNotEmpty) {
        return '$trimmedWork - $cardTitle';
      }
      return cardTitle;
    }

    // 极端兜底：确保即使仅剩文件名，也先做一次 URL 百分号解码并剥离多余编码字符。
    if (fallbackFileName != null && fallbackFileName.trim().isNotEmpty) {
      return _decodeFileNameSafely(fallbackFileName.trim());
    }
    return 'Konata';
  }

  static String _decodeFileNameSafely(String name) {
    try {
      return Uri.decodeComponent(name);
    } catch (_) {
      return name;
    }
  }
}
