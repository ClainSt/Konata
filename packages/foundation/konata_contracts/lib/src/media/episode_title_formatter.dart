import '../ports/read_query_ports.dart';
import '../value_objects/domain_enums.dart';

/// 全仓唯一的剧集卡片、播放记录与外部播放器标题格式化工具。
///
/// 收口于 `konata_contracts` 底座，统一供刮削引擎、播放引擎、详情页、播放记录页与视频播放器复用：
/// 1. 单一正片视频（剧场版/单集 OVA 或单集正片）免除多余 `01 ·` 前缀；
/// 2. 特典映像直接展示特典标题而不强加数字集号前缀；
/// 3. 为 MPV / PotPlayer 生成干净无 URL 编码的可读播放标题。
abstract final class EpisodeTitleFormatter {
  static final RegExp _genericEpisodePattern = RegExp(
    r'^(?:正片|第\s*0*\d+(?:\s*[-～~]\s*0*\d+)?\s*[话集話]|(?:episode|ep)\s*0*\d+)$',
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

  /// 按基础字段判断当前正片条目是否属于单一正片视频。
  static bool isSingleMainVideoFields({
    required EpisodeCategory category,
    required int seasonNumber,
    int? episodeNumber,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
  }) {
    if (category != EpisodeCategory.main) {
      return false;
    }
    if (workMediaType == TmdbMediaType.movie) {
      return episodeNumber == null ||
          (mainEpisodeCount == 1 && episodeNumber <= 1);
    }
    if (seasonNumber == 0 && mainEpisodeCount == 1) {
      return true;
    }
    return episodeNumber == null && mainEpisodeCount == 1;
  }

  /// 判断 [EpisodeSummaryView] 是否属于单一正片视频（单篇剧场版、单集特别篇/OVA 或无分集号单体视频均省略集号前缀）。
  static bool isSingleMainVideo({
    required EpisodeSummaryView episode,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
  }) {
    return isSingleMainVideoFields(
      category: episode.category,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      workMediaType: workMediaType,
      mainEpisodeCount: mainEpisodeCount,
    );
  }

  /// 判断同一作品的正片剧集是否跨越 2 个及以上有效季号（`seasonNumber > 0`），用于开启 `S1E01`/`S2E01` 季前缀消歧。
  static bool hasMultipleMainSeasons(Iterable<EpisodeSummaryView> episodes) {
    int? firstSeason;
    for (final ep in episodes) {
      if (ep.category != EpisodeCategory.main || ep.seasonNumber <= 0) {
        continue;
      }
      if (firstSeason == null) {
        firstSeason = ep.seasonNumber;
      } else if (firstSeason != ep.seasonNumber) {
        return true;
      }
    }
    return false;
  }

  /// 按基础字段格式化详情页抽屉卡片中展示的剧集或特典标题。
  static String formatCardTitleFields({
    required EpisodeCategory category,
    required int seasonNumber,
    int? episodeNumber,
    int? episodeNumberEnd,
    ExtraKind? extraType,
    String? title,
    String? workTitle,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
    bool showSeasonPrefix = false,
  }) {
    final rawTitle = title?.trim();

    // 特典卡片：不加数字集号前缀，直接展示特典名或类型兜底标签。
    if (category == EpisodeCategory.extra) {
      if (rawTitle != null && rawTitle.isNotEmpty) {
        return rawTitle;
      }
      final numStr = episodeNumber?.toString().padLeft(2, '0');
      if (extraType != null) {
        return numStr == null
            ? extraType.name.toUpperCase()
            : '${extraType.name.toUpperCase()} $numStr';
      }
      return numStr == null ? '特典' : '特典 $numStr';
    }

    // 单一正片视频：免除 `01 ·` 前缀，占位标题回退为作品主标题或 `正片`。
    if (isSingleMainVideoFields(
      category: category,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
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

    if (episodeNumber == null) {
      if (rawTitle != null && rawTitle.isNotEmpty) {
        return rawTitle;
      }
      return '未分集';
    }
    final epNumStr = formatEpisodeNumberLabel(episodeNumber, episodeNumberEnd);
    final useSeasonTag = showSeasonPrefix && seasonNumber > 0;
    if (rawTitle != null &&
        rawTitle.isNotEmpty &&
        !isGenericEpisodePlaceholder(rawTitle)) {
      return useSeasonTag
          ? 'S${seasonNumber}E$epNumStr · $rawTitle'
          : '$epNumStr · $rawTitle';
    }
    return useSeasonTag ? 'S$seasonNumber 第 $epNumStr 话' : '第 $epNumStr 话';
  }

  /// 格式化详情页抽屉卡片与播放器选集中展示的剧集/特典标题。
  static String formatCardTitle({
    required EpisodeSummaryView episode,
    String? workTitle,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
    bool showSeasonPrefix = false,
  }) {
    return formatCardTitleFields(
      category: episode.category,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeNumberEnd: episode.episodeNumberEnd,
      extraType: episode.extraType,
      title: episode.title,
      workTitle: workTitle,
      workMediaType: workMediaType,
      mainEpisodeCount: mainEpisodeCount,
      showSeasonPrefix: showSeasonPrefix,
    );
  }

  /// 集号文本：单集为 `01`，多集合并区间为 `01-02`。
  static String formatEpisodeNumberLabel(int episodeNumber, int? episodeEnd) {
    final start = episodeNumber.toString().padLeft(2, '0');
    if (episodeEnd == null || episodeEnd <= episodeNumber) {
      return start;
    }
    return '$start-${episodeEnd.toString().padLeft(2, '0')}';
  }

  /// 按基础字段格式化播放记录页的单集副标题（保持 `[集号] · [单集标题]` / 特典短标题）。
  static String formatHistorySubtitleFields({
    required String episodeTitle,
    required bool isAudioRecord,
    required int seasonNumber,
    int? episodeNumber,
    String? workTitle,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
  }) {
    final rawTitle = episodeTitle.trim();
    final isValidTitle =
        rawTitle.isNotEmpty && !RegExp(r'\bnull\b').hasMatch(rawTitle);

    if (isAudioRecord) {
      if (isValidTitle) {
        return _cleanAudioHistoryTitle(rawTitle);
      }
      return 'CD 音轨';
    }

    if (seasonNumber == 0) {
      if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
        return rawTitle;
      }
      if (episodeNumber != null) {
        return 'SP${episodeNumber.toString().padLeft(2, '0')}';
      }
      return '特典';
    }

    final isSingleMain =
        workMediaType == TmdbMediaType.movie ||
        (mainEpisodeCount == 1 && episodeNumber == null);
    if (isSingleMain) {
      if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
        return rawTitle;
      }
      final trimmedWork = workTitle?.trim();
      if (trimmedWork != null && trimmedWork.isNotEmpty) {
        return trimmedWork;
      }
      return '正片';
    }

    if (episodeNumber == null) {
      if (isValidTitle) {
        return rawTitle;
      }
      final trimmedWork = workTitle?.trim();
      return (trimmedWork != null && trimmedWork.isNotEmpty)
          ? trimmedWork
          : '未分集';
    }
    final epNumStr = episodeNumber.toString().padLeft(2, '0');
    if (isValidTitle && !isGenericEpisodePlaceholder(rawTitle)) {
      // 历史快照可能已由公共卡片格式化器生成，保留对应集号及合并区间。
      final existingPrefix = RegExp('^$epNumStr(?:-[0-9]+)? · ');
      if (existingPrefix.hasMatch(rawTitle)) return rawTitle;
      return '$epNumStr · $rawTitle';
    }
    return '第 $epNumStr 话';
  }

  /// 按基础字段格式化传递给外部播放器（MPV `--force-media-title` / `--title`）的干净标题。
  static String formatPlayerMediaTitleFields({
    required String workTitle,
    required EpisodeCategory category,
    required int seasonNumber,
    TmdbMediaType? workMediaType,
    int? episodeNumber,
    int? episodeNumberEnd,
    ExtraKind? extraType,
    String? episodeTitle,
    int? mainEpisodeCount,
    String? fallbackFileName,
  }) {
    final trimmedWork = workTitle.trim();
    final rawEpTitle = episodeTitle?.trim();

    if (category == EpisodeCategory.extra) {
      final extraTitle = formatCardTitleFields(
        category: category,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeNumberEnd: episodeNumberEnd,
        extraType: extraType,
        title: rawEpTitle,
        workTitle: trimmedWork,
        workMediaType: workMediaType,
        mainEpisodeCount: mainEpisodeCount,
      );
      return trimmedWork.isNotEmpty ? '$trimmedWork · $extraTitle' : extraTitle;
    }

    if (isSingleMainVideoFields(
      category: category,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      workMediaType: workMediaType,
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
      final cardTitle = formatCardTitleFields(
        category: category,
        seasonNumber: seasonNumber,
        episodeNumber: episodeNumber,
        episodeNumberEnd: episodeNumberEnd,
        extraType: extraType,
        title: rawEpTitle,
        workTitle: trimmedWork,
        workMediaType: workMediaType,
        mainEpisodeCount: mainEpisodeCount,
      );
      if (trimmedWork.isNotEmpty) {
        return '$trimmedWork - $cardTitle';
      }
      return cardTitle;
    }

    if (fallbackFileName != null && fallbackFileName.trim().isNotEmpty) {
      return _decodeFileNameSafely(fallbackFileName.trim());
    }
    return 'Konata';
  }

  /// 基于 [EpisodeSummaryView] 格式化传递给外部播放器的干净标题。
  static String formatPlayerMediaTitle({
    required String workTitle,
    required EpisodeSummaryView episode,
    TmdbMediaType? workMediaType,
    int? mainEpisodeCount,
    String? fallbackFileName,
  }) {
    return formatPlayerMediaTitleFields(
      workTitle: workTitle,
      workMediaType: workMediaType,
      category: episode.category,
      seasonNumber: episode.seasonNumber,
      episodeNumber: episode.episodeNumber,
      episodeNumberEnd: episode.episodeNumberEnd,
      extraType: episode.extraType,
      episodeTitle: episode.title,
      mainEpisodeCount: mainEpisodeCount,
      fallbackFileName: fallbackFileName,
    );
  }

  static String _cleanAudioHistoryTitle(String raw) {
    var text = raw.trim();
    text = text.replaceFirst(
      RegExp(
        r'\.(?:flac|mp3|wav|m4a|aac|ogg|opus|ape|alac|tak|tta|dsf|dff|mka|wma)$',
        caseSensitive: false,
      ),
      '',
    );
    final stripped = text
        .replaceFirst(
          RegExp(
            r'^(?:(?:disc|cd)?\s*\d{1,2}\s*[-_.]\s*)?\d{1,3}\s*(?:[.\-_·:：、]+|\s+)\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
    return stripped.isNotEmpty ? stripped : text.trim();
  }

  static String _decodeFileNameSafely(String name) {
    try {
      return Uri.decodeComponent(name);
    } catch (_) {
      return name;
    }
  }
}
