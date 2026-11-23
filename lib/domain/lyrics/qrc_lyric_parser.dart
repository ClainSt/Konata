import 'dart:math' as math;

import 'package:xml/xml.dart';

import '../playback/lyric_version_matcher.dart';
import 'lyric_cleaner.dart';
import 'ttml_lyric_converter.dart';

/// QQ 音乐逐字歌词（QRC）解析结果。
class QrcParseResult {
  /// 创建 QRC 解析结果。
  const QrcParseResult({
    required this.lrcContent,
    required this.hasWordTiming,
    required this.credits,
    required this.validLineCount,
  });

  /// 携带精确结束时间（`<mm:ss.xxx-mm:ss.xxx>`）的增强 LRC 正文；无效或占位时为空。
  final String lrcContent;

  /// 是否包含有效逐字时间戳。
  final bool hasWordTiming;

  /// 清洗提取的制作人员署名列表。
  final List<String> credits;

  /// 清洗后的有效演唱行数。
  final int validLineCount;
}

/// QQ 音乐 QRC 逐字歌词解析器（纯领域算法，解密由基础设施层 `QrcDecryptor` 完成）。
///
/// 支持解析：
/// - XML 外壳 `<QrcInfos><LyricInfo><Lyric_1 LyricContent="..."/></LyricInfo></QrcInfos>` 或裸 QRC 文本；
/// - 逐字行 `[lineStartMs,lineDurMs]字(wordStartMs,wordDurMs)...` 与 `[offset:]` 全局偏移。
abstract final class QrcLyricParser {
  static const QrcParseResult _empty = QrcParseResult(
    lrcContent: '',
    hasWordTiming: false,
    credits: [],
    validLineCount: 0,
  );

  static final RegExp _lineRegex = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final RegExp _wordTokenRegex = RegExp(r'\((\d+),(\d+)\)');
  static final RegExp _offsetTagRegex = RegExp(
    r'^\[offset\s*:\s*([+-]?\d+)\s*\]$',
    caseSensitive: false,
  );
  static final RegExp _lyricContentAttrRegex = RegExp(
    r'LyricContent="([\s\S]*?)"',
  );

  /// 解析已解密的 QRC XML 或 QRC 正文为保留精确逐字结束时间的增强 LRC。
  static QrcParseResult parse(String decryptedQrc) {
    final content = _extractLyricContent(decryptedQrc);
    if (content.trim().isEmpty) return _empty;

    final decoded = LyricCleaner.decodeHtmlEntities(content);
    var offsetMillis = 0;
    final rawLines = <({int startMs, int durMs, String body})>[];

    for (final rawLine in decoded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final offsetMatch = _offsetTagRegex.firstMatch(line);
      if (offsetMatch != null) {
        offsetMillis = int.tryParse(offsetMatch.group(1)!) ?? offsetMillis;
        continue;
      }
      final lineMatch = _lineRegex.firstMatch(line);
      if (lineMatch == null) continue;
      final startMs = int.tryParse(lineMatch.group(1)!) ?? 0;
      final durMs = int.tryParse(lineMatch.group(2)!) ?? 0;
      final body = lineMatch.group(3) ?? '';
      if (body.trim().isEmpty) continue;
      rawLines.add((startMs: startMs, durMs: durMs, body: body));
    }

    if (rawLines.isEmpty) return _empty;

    final offsetSec = offsetMillis / 1000.0;
    final credits = <String>[];
    final out = StringBuffer();
    var validLineCount = 0;
    var hasWordTiming = false;
    var passedLeadSection = false;
    var sawExplicitPlaceholder = false;

    for (final item in rawLines) {
      final lineStartSec = math.max(0.0, item.startMs / 1000.0 - offsetSec);
      final lineEndSec = item.durMs > 0
          ? math.max(lineStartSec, (item.startMs + item.durMs) / 1000.0 - offsetSec)
          : lineStartSec;

      final tokenMatches = _wordTokenRegex.allMatches(item.body).toList();
      final plainBuf = StringBuffer();
      final lineBuf = StringBuffer();
      var lineHasWord = false;

      if (tokenMatches.isEmpty) {
        final plain = item.body.trim();
        if (plain.isEmpty) continue;
        plainBuf.write(plain);
        lineBuf.write(plain);
      } else {
        var cursor = 0;
        for (var i = 0; i < tokenMatches.length; i++) {
          final cur = tokenMatches[i];
          final piece = item.body.substring(cursor, cur.start);
          cursor = cur.end;
          if (piece.isEmpty) continue;

          final wordStartMs = int.tryParse(cur.group(1)!) ?? item.startMs;
          final wordDurMs = int.tryParse(cur.group(2)!) ?? 0;
          final wordStartSec = math.max(0.0, wordStartMs / 1000.0 - offsetSec);
          final double wordEndSec;
          if (wordDurMs > 0) {
            wordEndSec = math.max(
              wordStartSec,
              (wordStartMs + wordDurMs) / 1000.0 - offsetSec,
            );
          } else if (i + 1 < tokenMatches.length) {
            final nextStartMs =
                int.tryParse(tokenMatches[i + 1].group(1)!) ?? wordStartMs;
            wordEndSec = math.max(
              wordStartSec,
              nextStartMs / 1000.0 - offsetSec,
            );
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
        if (cursor < item.body.length) {
          final tail = item.body.substring(cursor);
          if (tail.isNotEmpty) {
            plainBuf.write(tail);
            lineBuf.write(tail);
          }
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
      return QrcParseResult(
        lrcContent: '',
        hasWordTiming: false,
        credits: credits,
        validLineCount: 0,
      );
    }

    return QrcParseResult(
      lrcContent: out.toString().trimRight(),
      hasWordTiming: hasWordTiming,
      credits: credits,
      validLineCount: validLineCount,
    );
  }

  /// 从 QRC XML 外壳提取 `LyricContent` 属性；若 XML 内含未转义特殊字符则降级正则提取。
  static String _extractLyricContent(String raw) {
    final trimmed = raw.trim();
    if (!trimmed.contains('<Lyric_') && !trimmed.contains('LyricContent=')) {
      return trimmed;
    }
    try {
      final doc = XmlDocument.parse(trimmed);
      for (final el in doc.descendantElements) {
        final content = el.getAttribute('LyricContent');
        if (content != null && content.trim().isNotEmpty) {
          return content;
        }
      }
      return _lyricContentAttrRegex.firstMatch(trimmed)?.group(1) ?? trimmed;
    } on XmlException {
      // QRC 正文偶发包含未转义特殊字符，回退至属性边界提取。
      return _lyricContentAttrRegex.firstMatch(trimmed)?.group(1) ?? trimmed;
    }
  }
}
