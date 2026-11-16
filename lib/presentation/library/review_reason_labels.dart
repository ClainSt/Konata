/// `WorkMatcher` 全部匹配信号原因码的简体中文可读标签映射。
///
/// 覆盖正向、负向与冲突信号 key（包含历史旧 key 与 Phase 4 规范化新 key），
/// 彻底杜绝向 UI 裸露英文 snake_case 原因码。
class ReviewReasonLabels {
  const ReviewReasonLabels._();

  static const Map<String, String> _labels = {
    'explicit_tmdb_match': '显式 TMDB 编号一致',
    'explicit_tmdb_mismatch': '与目录显式 TMDB 编号冲突',
    'explicit_id_mismatch': '与显式指定的 TMDB ID 不符',
    'explicit_id': '显式 TMDB 编号锁定',
    'bangumi_tmdb_mapping': 'Bangumi 跨库映射匹配',
    'bangumi_cross_match': 'Bangumi 原名与别名一致',
    'exact_title': '标题精确匹配',
    'exact_title_match': '标题精确匹配',
    'alias_exact_match': '别名精确匹配',
    'high_title_similarity': '标题高度相似',
    'partial_title_similarity': '标题部分相似',
    'low_title_similarity': '标题相似度偏低',
    'romaji_similarity': '假名 / 罗马音音译一致',
    'year_exact': '年份吻合',
    'year_exact_match': '年份吻合',
    'year_near': '年份相近（±1 年）',
    'year_close_match': '年份相近（±1 年）',
    'year_span_tolerance': '跨年连载容差（±2 年）',
    'year_mismatch': '年份跨度差异较大',
    'remaster_match': '重制版对应原作匹配',
    'merged_sequel_year': '多季连续条目年份吻合',
    'season_year_match': '对应季度开播年份匹配',
    'season_episode_match': '季度集数匹配',
    'cumulative_offset_match': '跨季连续集数匹配',
    'incomplete_season_offset': '集数偏移范围差异',
    'special_season_match': '特别篇 / 短篇季度匹配',
    'series_structure_match': '剧集结构一致',
    'season_name_match': '命中对应季度番号',
    'subtitle_conflict': '副标题文本存在差异',
    'missing_sequel_number': '续集数字或季号与候选不匹配',
    'partial_latin_prefix': '英文多词仅前缀重合',
    'media_type_match': '类型一致',
    'media_type_mismatch': '剧集 / 剧场版类型冲突',
    'media_type_conflict': '剧集 / 剧场版类型冲突',
    'anthology_conflict': '目录含多作品合集冲突',
    'short_ova_vs_long_tv': '短篇 OVA 与长篇 TV 冲突',
    'ex_missing_special_slot': 'EX 番外缺少特别篇季度',
    'tv_vs_movie_hint': '片源类型与剧集推测不符',
    'close_candidates': '多个候选分数接近，需人工核实',
    'low_confidence': '整体匹配置信度不足',
    'high_confidence': '高置信度自动匹配',
    'no_match': '候选得分过低，需手动指定',
    'no_candidates': '未找到匹配候选',
  };

  /// 将内部原因码映射为简洁中文标签；支持兼容带分值的原始 `WorkMatcher` 描述串并去兜底重复。
  static String format(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return '匹配信号特征';
    final direct = _labels[trimmed];
    if (direct != null) return direct;

    // 兼容历史库中可能残留的 `+45 title` / `+15 year` 等原始格式
    final scored = RegExp(r'^([+-]?\d+)\s+(.+)$').firstMatch(trimmed);
    if (scored != null) {
      final points = int.tryParse(scored.group(1)!) ?? 0;
      final label = scored.group(2)!.trim();
      switch (label) {
        case 'title':
          return points >= 42
              ? '标题精确匹配'
              : (points >= 34 ? '标题高度相似' : '标题部分相似');
        case 'season name':
          return '命中对应季度番号';
        case 'year':
        case 'year (via Bangumi)':
          return points > 0 ? '年份吻合' : '年份跨度差异较大';
        case 'feature':
        case 'folder says movie':
        case 'file says movie':
          return '类型一致';
        case 'series':
          return '剧集结构一致';
        case 'season count':
        case 'all seasons count':
          return '季度集数匹配';
        case 'bangumi agrees':
          return 'Bangumi 原名与别名一致';
        case 'movie vs tv':
        case 'feature vs tv':
        case 'series vs movie':
          return '剧集 / 剧场版类型冲突';
        case 'conflicting subtitle':
          return '副标题文本存在差异';
        case 'partial latin token match':
          return '英文多词仅前缀重合';
      }
    }
    return '综合匹配特征参考';
  }

  /// 对 `reasons` 列表去重并转换为中文标签列表。
  static List<String> formatAll(List<String> codes) {
    final result = <String>[];
    for (final raw in codes) {
      result.add(format(raw));
    }
    return result.toSet().toList(growable: false);
  }
}
