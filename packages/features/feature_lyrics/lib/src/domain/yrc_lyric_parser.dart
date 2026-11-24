import 'dart:convert';
import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';

import 'lyric_cleaner.dart';
import 'ttml_lyric_converter.dart';

/// 网易云逐字歌词（YRC）解析结果。
class YrcParseResult {
  /// 创建逐字歌词解析结果。
  const YrcParseResult({
    required this.lrcContent,
    required this.hasWordTiming,
    required this.credits,
    required this.validLineCount,
  });

  /// 携带精确结束时间（`<mm:ss.xxx-mm:ss.xxx>`）的增强 LRC 正文；无效或占位时为空。
  final String lrcContent;

  /// 是否包含有效逐字时间戳。
  final bool hasWordTiming;

  /// 从头部 JSON 元数据或署名行提取的制作人员信息。
  final List<String> credits;

  /// 清洗后的有效演唱行数。
  final int validLineCount;
}

/// 网易云 YRC 逐字歌词解析器（纯领域算法）。
///
/// 支持解析：
/// - 头部或尾部 JSON 元数据行并提取制作人员署名；
/// - 逐字行 `[lineStartMs,lineDurMs](wordStartMs,wordDurMs,0)字...`，完整保留每个字的结束时间。
abstract final class YrcLyricParser {
  static const YrcParseResult _empty = YrcParseResult(
    lrcContent: '',
    hasWordTiming: false,
    credits: [],
    validLineCount: 0,
  );

  static final RegExp _lineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final RegExp _wordTokenRegex = RegExp(
    r'\((-?\d+),(-?\d+)(?:,-?\d+)?\)',
  );

  /// 将网易云 YRC 原文转换为保留精确逐字结束时间的增强 LRC。
  static YrcParseResult parse(String rawYrc) {
    final decoded = LyricCleaner.decodeHtmlEntities(rawYrc).trim();
    if (decoded.isEmpty) return _empty;

    final credits = <String>[];
    final out = StringBuffer();
    var validLineCount = 0;
    var hasWordTiming = false;
    var passedLeadSection = false;
    var sawExplicitPlaceholder = false;

    for (final rawLine in decoded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('{') && line.endsWith('}')) {
        final jsonText = _extractJsonMetadataLine(line);
        if (jsonText != null &&
            jsonText.isNotEmpty &&
            !LyricCleaner.isContributorOrNoiseLine(jsonText) &&
            !credits.contains(jsonText)) {
          credits.add(jsonText);
        }
        continue;
      }

      final lineMatch = _lineRegex.firstMatch(line);
      if (lineMatch == null) continue;
      final lineStartMs = int.tryParse(lineMatch.group(1)!) ?? 0;
      final lineDurMs = int.tryParse(lineMatch.group(2)!) ?? 0;
      final body = lineMatch.group(3) ?? '';
      if (body.trim().isEmpty) continue;

      final lineStartSec = math.max(0.0, lineStartMs / 1000.0);
      final lineEndSec = lineDurMs > 0
          ? (lineStartMs + lineDurMs) / 1000.0
          : lineStartSec;

      final tokenMatches = _wordTokenRegex.allMatches(body).toList();
      final plainBuf = StringBuffer();
      final lineBuf = StringBuffer();
      var lineHasWord = false;

      if (tokenMatches.isEmpty) {
        final plain = body.trim();
        if (plain.isEmpty) continue;
        plainBuf.write(plain);
        lineBuf.write(plain);
      } else {
        for (var i = 0; i < tokenMatches.length; i++) {
          final cur = tokenMatches[i];
          final textStart = cur.end;
          final textEnd = i + 1 < tokenMatches.length
              ? tokenMatches[i + 1].start
              : body.length;
          final piece = body.substring(textStart, textEnd);
          if (piece.isEmpty) continue;

          final wordStartMs = int.tryParse(cur.group(1)!) ?? lineStartMs;
          final wordDurMs = int.tryParse(cur.group(2)!) ?? 0;
          final wordStartSec = math.max(0.0, wordStartMs / 1000.0);
          final double wordEndSec;
          if (wordDurMs > 0) {
            wordEndSec = (wordStartMs + wordDurMs) / 1000.0;
          } else if (i + 1 < tokenMatches.length) {
            final nextStartMs =
                int.tryParse(tokenMatches[i + 1].group(1)!) ?? wordStartMs;
            wordEndSec = math.max(wordStartSec, nextStartMs / 1000.0);
          } else {
            wordEndSec = math.max(wordStartSec, lineEndSec);
          }

          plainBuf.write(piece);
          lineBuf.write(
            LyricVersionMatcher.formatWordSpanTag(wordStartSec, wordEndSec),
          );
          lineBuf.write(piece);
          lineHasWord = true;
        }
      }

      final plainText = plainBuf.toString().trim();
      if (plainText.isEmpty) continue;
      if (LyricCleaner.isPlaceholderLine(plainText)) {
        sawExplicitPlaceholder = true;
        continue;
      }
      if (LyricCleaner.isContributorOrNoiseLine(plainText)) continue;
      if (LyricCleaner.isCreditLine(
        plainText,
        timeSeconds: lineStartSec,
        isLeadingSection: !passedLeadSection,
      )) {
        if (!credits.contains(plainText)) credits.add(plainText);
        continue;
      }

      passedLeadSection = true;
      validLineCount++;
      hasWordTiming = hasWordTiming || lineHasWord;
      final lineTag = TtmlLyricConverter.formatLrcTag(lineStartSec);
      out.writeln('[$lineTag]${lineBuf.toString().trim()}');
    }

    if (validLineCount < LyricCleaner.minValidLyricLines ||
        (sawExplicitPlaceholder &&
            validLineCount <= LyricCleaner.minValidLyricLines)) {
      return YrcParseResult(
        lrcContent: '',
        hasWordTiming: false,
        credits: credits,
        validLineCount: 0,
      );
    }

    return YrcParseResult(
      lrcContent: out.toString().trimRight(),
      hasWordTiming: hasWordTiming,
      credits: credits,
      validLineCount: validLineCount,
    );
  }

  /// 提取网易云 YRC 首尾 JSON 署名对象中的拼接文本。
  static String? _extractJsonMetadataLine(String rawJson) {
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is! Map) return null;
      final chunks = decoded['c'];
      if (chunks is! List) return null;
      final buf = StringBuffer();
      for (final item in chunks) {
        if (item is Map && item['tx'] is String) {
          buf.write(item['tx'] as String);
        }
      }
      final joined = buf.toString().trim();
      return joined.isEmpty ? null : joined;
    } on FormatException {
      return null;
    }
  }
}
