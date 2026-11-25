import 'package:engine_sources/engine_sources.dart';

import '../matching/supplementary_folder_rules.dart';
import '../parsing/bdrip_parser.dart';
import '../scraping/personal_filename_parser.dart';

/// 为共享扫描器注入刮削的完整集号解析与附属目录判定。
final class ScrapeDirectoryScanner extends DirectoryScanner {
  /// 创建按刮削语义解析的共享扫描器。
  const ScrapeDirectoryScanner({super.profile})
    : super(
        subtitleEpisodeParser: _parseEpisode,
        isSupplementaryDirectory: SupplementaryFolderRules.isSupplementarySegment,
        extractExplicitTmdbId: PersonalFilenameParser.tmdbId,
      );

  static SubtitleEpisodeProbe _parseEpisode(
    String fileName, {
    String? relativePath,
  }) {
    final parsed = BdripParser.parseFileName(fileName, relativePath: relativePath);
    return SubtitleEpisodeProbe(
      category: parsed.category,
      season: parsed.season,
      episode: parsed.episode,
    );
  }
}

/// 刮削入口所用的共享目录快照存储。
typedef ScrapeDirectoryScanSnapshotStore = DirectoryScanSnapshotStore;
