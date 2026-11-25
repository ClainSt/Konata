import '../matching/directory_grouper.dart';
import '../matching/supplementary_folder_rules.dart';
import '../matching/supplementary_subclassifier.dart';
import '../matching/work_matcher.dart';
import '../models/episode.dart';
import '../models/media_variant.dart';
import '../models/tmdb_models.dart';
import '../models/work.dart';
import '../parsing/bdrip_parser.dart';
import '../parsing/media_tech_parser.dart';
import 'artwork_ranker.dart';
import 'bangumi_models.dart';
import 'bangumi_tmdb_index.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'collection_asset_router.dart';
import 'directory_analyzer.dart';
import 'match_difficulty_classifier.dart';
import 'multi_work_splitter.dart';
import 'personal_filename_parser.dart';
import 'search_query_sanitizer.dart';
import 'work_season.dart';

part 'scrape_candidate_ranking.dart';
part 'scrape_episode_resolution.dart';
part 'scrape_search_queries.dart';
part 'work_grouping_rules.dart';

final RegExp _categoryFolderPattern = RegExp(
  r'^(?:动画|番剧|电影|剧场版|劇場版|动漫|影视|日漫|国漫|美漫|'
  r'动画[-_]?单作品|动画[-_]?多作品|动画[-_]?天雪论坛|动画[-_]?系列作未收集|'
  r'天雪论坛|系列作未收集|未添加\s*tmdb(?:\s*id)?|'
  r'乱目录测试|测试目录?|待整理|未整理|临时|未分类|杂项|收藏夹?|'
  r'anime|movies?|tv|series|bdmv|bdrip|video|media|downloads?)$',
  caseSensitive: false,
);

final RegExp _genericSeasonName = RegExp(
  r'^(?:season\s*\d+|series\s*\d+|specials?|第\s*[0-9一二三四五六七八九十百]+\s*[季期部]|特别篇|特別編|特典)$',
  caseSensitive: false,
);

final RegExp _remasterPattern = RegExp(
  r'(?:HD\s*)?(?:重制版|重製版|Remaster(?:ed)?)|リマスター',
  caseSensitive: false,
);

bool _hasCjk(String s) => _reHot41.hasMatch(s);

int? _parseYear(String? raw) {
  if (raw == null || raw.isEmpty) return null;
  final m = _reHot56.firstMatch(raw);
  return m == null ? null : int.tryParse(m.group(0)!);
}

final RegExp _reHot8 = RegExp(r'\{[^}]*\}');

final RegExp _reHot9 = RegExp(r'\(\s*(?:19|20)\d{2}\s*\)');

final RegExp _reHot10 = RegExp(r'（\s*(?:19|20)\d{2}\s*）');

final RegExp _reHot11 = RegExp(r'\s+');

final RegExp _reHot24 = RegExp(r'\balternative\b', caseSensitive: false);

final RegExp _reHot25 = RegExp(
  r'\balternative\s+(?:one|two)\b',
  caseSensitive: false,
);

final RegExp _reHot29 = RegExp(r'[^a-z0-9\u3040-\u9fff]+');

final RegExp _reHot39 = RegExp(r'[^a-z0-9]+');

final RegExp _reHot41 = RegExp(r'[\u3040-\u9fff]');

final RegExp _reHot56 = RegExp(r'(19|20)\d{2}');
