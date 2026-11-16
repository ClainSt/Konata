import '../parsing/bdrip_folder_cleaner.dart';
import '../parsing/bdrip_parser.dart';

/// 跨数据源（Bangumi / TMDB）统一搜索词净化与多级渐进回退查询构造器。
///
/// 解决以下线上实测痛点：
/// 1. 清除装饰性连字符与分隔符（如 `86 -不存在的战区- 第2部分` 中 `<空格>-` 触发 Bangumi 排除语法导致 0 命中）；
/// 2. 在完整查询无果或缺少母系列条目时，按「净化原词 -> 去分部/季后缀 -> 核心主标识/副标题」生成去重分级回退查询词；
/// 3. 从原始视频文件名及父目录名提取一键可填入的清洗关键词（如 `EIGHTY SIX`）。
abstract final class SearchQuerySanitizer {
  static final RegExp _decorativeDashOrTilde = RegExp(
    r'(?<!\d)[-–—―~～]|[-–—―~～](?!\d)',
  );
  static final RegExp _decorativePunct = RegExp(r'[:：/／|｜・･]+');
  static final RegExp _trailingPartOrSeason = RegExp(
    r'(?:\s+|^)(?:'
    r'第\s*(?:[0-9]{1,2}|[一二三四五六七八九十]+)\s*(?:部分|部|季|期|クール|幕|章)|'
    r'(?:part|season|cour|series)\s*(?:[0-9]{1,2}|i{1,4}|one|two|three|four)|'
    r'[0-9]+(?:st|nd|rd|th)\s*(?:season|cour|part)|'
    r's0*[1-9]|'
    r'後[半篇編章]|后[半篇章]|下篇|'
    r'新章|続編|续篇'
    r')\s*$',
    caseSensitive: false,
  );
  static final RegExp _leadingAsciiWithCjkTail = RegExp(
    r'^([0-9]{2,4}|[A-Za-z][A-Za-z0-9\s]{1,24}?)\s+([\u3040-\u9fff].+)$',
  );
  static final RegExp _cjkChar = RegExp(r'[\u4e00-\u9fff]');

  /// 将输入检索词中的装饰性连字符（除纯数字区间外）与分隔符替换为空格并折叠多余空白。
  ///
  /// 示例：`86 -不存在的战区- 第2部分` -> `86 不存在的战区 第2部分`。
  static String sanitize(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return '';
    return trimmed
        .replaceAll(_decorativeDashOrTilde, ' ')
        .replaceAll(_decorativePunct, ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// 剥离末尾的分割放送/季度后缀（如 `第2部分`、`Part 2`、`Season 2`、`第2クール` 等）。
  static String stripPartAndSeasonSuffix(String query) {
    var current = sanitize(query);
    if (current.isEmpty) return '';
    while (true) {
      final next = current.replaceFirst(_trailingPartOrSeason, '').trim();
      if (next.isEmpty || next == current) break;
      current = next;
    }
    return current;
  }

  /// 生成按优先级排序的 Bangumi 多级去重渐进搜索词列表：
  /// 1. 净化标点后的查询词；
  /// 2. 剥离季度 / 分割部后缀的系列基础词；
  /// 3. 混合前缀+中文副标题拆分提取的核心主词条与副标题词。
  static List<String> buildBangumiFallbackQueries(String rawQuery) {
    final out = <String>[];
    final seen = <String>{};

    void addTerm(String candidate) {
      final clean = sanitize(candidate);
      if (clean.isEmpty) return;
      final key = clean.toLowerCase();
      if (seen.add(key)) {
        out.add(clean);
      }
    }

    final level1 = sanitize(rawQuery);
    if (level1.isEmpty) return const [];
    addTerm(level1);

    final level2 = stripPartAndSeasonSuffix(level1);
    if (level2.isNotEmpty && level2 != level1) {
      addTerm(level2);
    }

    final stemSource = level2.isNotEmpty ? level2 : level1;
    final splitMatch = _leadingAsciiWithCjkTail.firstMatch(stemSource);
    if (splitMatch != null) {
      final lead = splitMatch.group(1)!.trim();
      final tail = splitMatch.group(2)!.trim();
      if (lead.length >= 2) {
        addTerm(lead);
      }
      if (_cjkChar.allMatches(tail).length >= 3) {
        addTerm(tail);
      }
    } else {
      final tokens = stemSource
          .split(RegExp(r'\s+'))
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      if (tokens.length >= 2) {
        final first = tokens.first;
        if (first.length >= 2 &&
            (RegExp(r'^\d+$').hasMatch(first) ||
                _cjkChar.hasMatch(first) ||
                first.length >= 3)) {
          addTerm(first);
        }
      }
    }

    return out;
  }

  /// 从原始视频文件名及相对路径目录段提取可供手动纠错一键填入的清洗关键词胶囊。
  static List<String> buildQuickSourceTerms(
    Iterable<({String fileName, String relativePath})> files, {
    String? excludeQuery,
    int limit = 4,
  }) {
    final out = <String>[];
    final seen = <String>{};
    final excludeKey = excludeQuery == null
        ? ''
        : sanitize(excludeQuery).toLowerCase();

    void addCandidate(String raw) {
      final clean = sanitize(raw);
      if (clean.length < 2) return;
      final key = clean.toLowerCase();
      if (key == excludeKey) return;
      if (seen.add(key)) {
        out.add(clean);
      }
    }

    for (final item in files) {
      final fileTitle = BdripParser.parseFileName(
        item.fileName,
        relativePath: item.relativePath,
      ).cleanTitle;
      if (fileTitle.trim().isNotEmpty) {
        addCandidate(fileTitle);
      }
      final normPath = item.relativePath.replaceAll('\\', '/');
      final segments = normPath
          .split('/')
          .where((s) => s.trim().isNotEmpty)
          .toList(growable: false);
      if (segments.length >= 2) {
        for (var i = segments.length - 2; i >= 0 && out.length < limit; i--) {
          final folderTitle = BdripFolderCleaner.parseFolderName(
            segments[i],
          ).cleanTitle;
          if (folderTitle.trim().isNotEmpty) {
            addCandidate(folderTitle);
          }
        }
      }
      if (out.length >= limit) break;
    }

    return out.take(limit).toList(growable: false);
  }
}
