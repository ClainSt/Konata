/// 多源合集拆簇、本地盘点画像、Bangumi/TMDB 映射与上墙规则导出。
library;

import 'title_normalizer.dart' as scraping_tn;
import 'work_matcher.dart' as legacy_wm;

export 'artwork_ranker.dart';
export 'bangumi_models.dart';
export 'bangumi_tmdb_index.dart';
export 'bangumi_tmdb_map.dart';
export 'cloud_media_asset_presentation.dart';
export 'cloud_media_file_classifier.dart';
export 'collection_asset_router.dart';
export 'directory_analyzer.dart';
export 'match_difficulty_classifier.dart';
export 'multi_work_splitter.dart';
export 'personal_filename_parser.dart';
export 'scrape_domain_adapter.dart';
export 'search_query_sanitizer.dart';
export 'title_normalizer.dart'
    show PreparedKanaTarget, PreparedLocalAscii;
export 'work_matcher.dart'
    show MatchCandidate, MatchResult, MatchTier, ScoredCandidate, SeasonInfo;
export 'work_season.dart';
export 'work_wall_eligibility.dart';

/// 刮削期专用的假名/罗马音预处理标题归一化工具（与解析层 `TitleNormalizer` 消歧导出）。
typedef ScrapingTitleNormalizer = scraping_tn.TitleNormalizer;

/// 经典双源候选打分与季别消歧引擎（与匹配层 `WorkMatcher` 消歧导出）。
typedef LegacyWorkMatcher = legacy_wm.WorkMatcher;
