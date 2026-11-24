import 'opencc_dictionaries.dart';

/// 字幕内嵌/外挂字体子集化三态分类。
enum SubtitleSubsetState {
  /// 未子集化：常规字库名与标准 Unicode 文本。
  unsubsetted,

  /// 可还原映射子集：存在子集别名或 `[Fonts]` 嵌入，但对白码位仍为正常 Unicode（可安全读取与展示）。
  restorableMappedSubset,

  /// 码位混淆不透明子集：字形被重映射至私用区（PUA）或乱码拉丁/符号位；
  /// 自动繁简转换模式严禁改写该类文本，避免破坏特效字幕字形映射。
  opaqueObfuscatedSubset,
}

/// OpenCC 繁简转换目标模式。
enum SubtitleOpenCcMode {
  /// 保持原文不做转换。
  none,

  /// 转换为简体中文（繁转简）。
  toSimplified,

  /// 转换为繁体中文（简转繁）。
  toTraditional,
}

/// 字幕内容处理策略结果。
class SubtitleContentProcessResult {
  /// 创建字幕处理结果。
  const SubtitleContentProcessResult({
    required this.content,
    required this.subsetState,
    required this.converted,
    this.skipReason,
  });

  /// 处理后的最终字幕文本。
  final String content;

  /// 探测到的字幕字体子集三态分类。
  final SubtitleSubsetState subsetState;

  /// 本次是否实际执行了 OpenCC 片段转换。
  final bool converted;

  /// 若自动模式下因保护规则跳过转换，则记录跳过原因。
  final String? skipReason;
}

/// 双语字幕片段语种分类。
enum _SegmentScript {
  japaneseKanaDominant,
  chineseHan,
  latinOrNeutral,
}

/// 字幕三态子集保护与双语 ASS 可逆片段 OpenCC 转换器（纯领域算法）。
class SubtitleContentProcessor {
  SubtitleContentProcessor._();

  static final RegExp _subsetAliasFontRegex = RegExp(
    r'(?:^|[,\\fn])([A-Za-z0-9]{6,12})\+|[_\-](?:subset|subfont)|subsetted',
    caseSensitive: false,
  );
  static final RegExp _assOverrideBlockRegex = RegExp(r'\{[^}]*\}');
  static final RegExp _assDrawingEnableRegex = RegExp(r'\\p[1-9]\d*');
  static final RegExp _assDrawingDisableRegex = RegExp(r'\\p0(?:\D|$)');
  static final RegExp _assLineBreakRegex = RegExp(r'(\\[Nnh])');

  /// 识别 ASS / SRT / VTT 文本的字体子集三态分类。
  static SubtitleSubsetState classifySubsetState(String content) {
    final hasFontsSection = RegExp(
      r'^\s*\[Fonts\]\s*$',
      multiLine: true,
      caseSensitive: false,
    ).hasMatch(content);
    final hasSubsetFontHints =
        hasFontsSection || _subsetAliasFontRegex.hasMatch(content);

    var puaCount = 0;
    var cjkCount = 0;
    var suspiciousObfuscatedRuns = 0;
    var inEvents = false;
    var textColIndex = 9;

    for (final rawLine in content.split('\n')) {
      final line = rawLine.trimRight();
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inEvents = trimmed.toLowerCase() == '[events]';
        continue;
      }
      if (inEvents && trimmed.toLowerCase().startsWith('format:')) {
        final parsed = _parseEventsTextColumnIndex(trimmed);
        if (parsed != null) textColIndex = parsed;
        continue;
      }
      if (!line.startsWith('Dialogue:') && !line.startsWith('Comment:')) {
        continue;
      }
      final payload = _extractAssDialoguePayload(line, textColIndex: textColIndex);
      if (payload == null) continue;
      final plain = _stripAssOverrideAndDrawing(payload);
      if (plain.isEmpty) continue;

      var lineAsciiWeird = 0;
      var linePua = 0;
      for (final rune in plain.runes) {
        if ((rune >= 0xE000 && rune <= 0xF8FF) ||
            (rune >= 0xF0000 && rune <= 0xFFFFD)) {
          puaCount++;
          linePua++;
        } else if (_isCjkIdeograph(rune)) {
          cjkCount++;
        } else if (rune >= 0x00A1 && rune <= 0x024F) {
          lineAsciiWeird++;
        }
      }
      if (linePua >= 2) {
        suspiciousObfuscatedRuns++;
      } else if (hasSubsetFontHints &&
          lineAsciiWeird >= 6 &&
          cjkCount == 0 &&
          !plain.contains(' ')) {
        suspiciousObfuscatedRuns++;
      }
    }

    if (puaCount >= 2 || suspiciousObfuscatedRuns > 0) {
      return SubtitleSubsetState.opaqueObfuscatedSubset;
    }
    if (hasSubsetFontHints) {
      return SubtitleSubsetState.restorableMappedSubset;
    }
    return SubtitleSubsetState.unsubsetted;
  }

  /// 执行带三态子集保护的双语 ASS / SRT / VTT 可逆 OpenCC 转换。
  ///
  /// - 自动模式（`forceOverrideSubsetGuard == false`）遇 `opaqueObfuscatedSubset` 立即跳过转换，防止毁字；
  /// - 双语 ASS 行按 `\N` 与 `{...}` 样式片段独立识别语种，含日文假名的片段保持原样不误转；
  /// - 仅在跨样式边界满足位置可逆映射时合并相邻中文片段进行词组转换。
  static SubtitleContentProcessResult process({
    required String content,
    required SubtitleOpenCcMode mode,
    bool forceOverrideSubsetGuard = false,
  }) {
    final subsetState = classifySubsetState(content);
    if (mode == SubtitleOpenCcMode.none) {
      return SubtitleContentProcessResult(
        content: content,
        subsetState: subsetState,
        converted: false,
      );
    }

    if (!forceOverrideSubsetGuard &&
        subsetState == SubtitleSubsetState.opaqueObfuscatedSubset) {
      return SubtitleContentProcessResult(
        content: content,
        subsetState: subsetState,
        converted: false,
        skipReason: 'opaque_obfuscated_subset_protected',
      );
    }

    final isAss =
        content.contains('[Events]') ||
        RegExp(r'^\s*Dialogue:', multiLine: true).hasMatch(content);
    final transformed = isAss
        ? _convertAssContent(content, mode)
        : _convertPlainSubtitleLines(content, mode);

    return SubtitleContentProcessResult(
      content: transformed,
      subsetState: subsetState,
      converted: transformed != content,
    );
  }

  static String _convertAssContent(String content, SubtitleOpenCcMode mode) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    var inEvents = false;
    var textColIndex = 9;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inEvents = trimmed.toLowerCase() == '[events]';
        out.add(line);
        continue;
      }
      if (inEvents && trimmed.toLowerCase().startsWith('format:')) {
        final parsed = _parseEventsTextColumnIndex(trimmed);
        if (parsed != null) textColIndex = parsed;
        out.add(line);
        continue;
      }
      if (!line.startsWith('Dialogue:')) {
        out.add(line);
        continue;
      }
      final splitIdx = _findAssTextStartIndex(line, textColIndex: textColIndex);
      if (splitIdx < 0) {
        out.add(line);
        continue;
      }
      final prefix = line.substring(0, splitIdx);
      final payload = line.substring(splitIdx);
      out.add('$prefix${_convertAssDialoguePayload(payload, mode)}');
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static String _convertAssDialoguePayload(
    String payload,
    SubtitleOpenCcMode mode,
  ) {
    // 1. 按 \N / \n / \h 切分物理双语视觉段，各段独立判断是否为日文假名主段。
    final parts = <String>[];
    var cursor = 0;
    for (final match in _assLineBreakRegex.allMatches(payload)) {
      if (match.start > cursor) {
        parts.add(
          _convertSingleAssVisualSegment(
            payload.substring(cursor, match.start),
            mode,
          ),
        );
      }
      parts.add(match.group(0)!);
      cursor = match.end;
    }
    if (cursor < payload.length) {
      parts.add(_convertSingleAssVisualSegment(payload.substring(cursor), mode));
    }
    return parts.join();
  }

  static String _convertSingleAssVisualSegment(
    String segment,
    SubtitleOpenCcMode mode,
  ) {
    final stripped = _stripAssOverrideAndDrawing(segment);
    if (_classifySegmentScript(stripped) != _SegmentScript.chineseHan) {
      return segment;
    }

    // 拆分为「覆写标签 / 绘图区」与「可见纯文本」交替令牌，仅在字符级一一可逆时跨标签合并词组转换。
    final tokens = <({String text, bool convertible})>[];
    var drawingActive = false;
    var cursor = 0;
    for (final m in _assOverrideBlockRegex.allMatches(segment)) {
      if (m.start > cursor) {
        tokens.add((
          text: segment.substring(cursor, m.start),
          convertible: !drawingActive,
        ));
      }
      final tag = m.group(0)!;
      if (_assDrawingDisableRegex.hasMatch(tag)) {
        drawingActive = false;
      } else if (_assDrawingEnableRegex.hasMatch(tag)) {
        drawingActive = true;
      }
      tokens.add((text: tag, convertible: false));
      cursor = m.end;
    }
    if (cursor < segment.length) {
      tokens.add((
        text: segment.substring(cursor),
        convertible: !drawingActive,
      ));
    }

    // 尝试将相邻可转换文本合并分词；仅在长度完全等长（位置一一可逆）时回填各片段，否则逐片段安全转换。
    final convertibleIndices = <int>[];
    final mergedBuffer = StringBuffer();
    final lengths = <int>[];
    for (var i = 0; i < tokens.length; i++) {
      if (!tokens[i].convertible) continue;
      convertibleIndices.add(i);
      mergedBuffer.write(tokens[i].text);
      lengths.add(tokens[i].text.length);
    }

    if (convertibleIndices.isEmpty) return segment;

    final mergedOriginal = mergedBuffer.toString();
    final mergedConverted = _applyOpenCcText(mergedOriginal, mode);
    if (mergedConverted.length == mergedOriginal.length) {
      var offset = 0;
      final outTokens = List<String>.generate(
        tokens.length,
        (i) => tokens[i].text,
      );
      for (var k = 0; k < convertibleIndices.length; k++) {
        final len = lengths[k];
        outTokens[convertibleIndices[k]] = mergedConverted.substring(
          offset,
          offset + len,
        );
        offset += len;
      }
      return outTokens.join();
    }

    // 不可逆（长度变化）时回退至单段独立转换，确保不跨标签错位。
    final fallbackOut = StringBuffer();
    for (final token in tokens) {
      if (token.convertible) {
        fallbackOut.write(_applyOpenCcText(token.text, mode));
      } else {
        fallbackOut.write(token.text);
      }
    }
    return fallbackOut.toString();
  }

  static String _convertPlainSubtitleLines(
    String content,
    SubtitleOpenCcMode mode,
  ) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed == 'WEBVTT' ||
          trimmed.contains('-->') ||
          RegExp(r'^\d+$').hasMatch(trimmed)) {
        out.add(line);
        continue;
      }
      if (_classifySegmentScript(line) == _SegmentScript.chineseHan) {
        out.add(_applyOpenCcText(line, mode));
      } else {
        out.add(line);
      }
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static _SegmentScript _classifySegmentScript(String text) {
    var kana = 0;
    var han = 0;
    for (final rune in text.runes) {
      if ((rune >= 0x3040 && rune <= 0x309F) ||
          (rune >= 0x30A0 && rune <= 0x30FF) ||
          (rune >= 0xFF66 && rune <= 0xFF9F)) {
        kana++;
      } else if (_isCjkIdeograph(rune)) {
        han++;
      }
    }
    if (kana > 0) return _SegmentScript.japaneseKanaDominant;
    if (han > 0) return _SegmentScript.chineseHan;
    return _SegmentScript.latinOrNeutral;
  }

  static bool _isCjkIdeograph(int rune) {
    return (rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0x20000 && rune <= 0x2CEAF);
  }

  static int? _parseEventsTextColumnIndex(String formatLine) {
    final colon = formatLine.indexOf(':');
    if (colon < 0) return null;
    final cols = formatLine
        .substring(colon + 1)
        .split(',')
        .map((c) => c.trim().toLowerCase())
        .toList(growable: false);
    final idx = cols.indexOf('text');
    return idx >= 0 ? idx : null;
  }

  static int _findAssTextStartIndex(
    String dialogueLine, {
    int textColIndex = 9,
  }) {
    final colon = dialogueLine.indexOf(':');
    if (colon < 0) return -1;
    if (textColIndex <= 0) return colon + 1;
    var commas = 0;
    for (var i = colon + 1; i < dialogueLine.length; i++) {
      if (dialogueLine.codeUnitAt(i) == 0x2C) {
        commas++;
        if (commas == textColIndex) {
          return i + 1;
        }
      }
    }
    return -1;
  }

  static String? _extractAssDialoguePayload(
    String line, {
    int textColIndex = 9,
  }) {
    final idx = _findAssTextStartIndex(line, textColIndex: textColIndex);
    return idx < 0 ? null : line.substring(idx);
  }

  static String _stripAssOverrideAndDrawing(String payload) {
    final buf = StringBuffer();
    var drawing = false;
    var cursor = 0;
    for (final m in _assOverrideBlockRegex.allMatches(payload)) {
      if (!drawing && m.start > cursor) {
        buf.write(payload.substring(cursor, m.start));
      }
      final tag = m.group(0)!;
      if (_assDrawingDisableRegex.hasMatch(tag)) {
        drawing = false;
      } else if (_assDrawingEnableRegex.hasMatch(tag)) {
        drawing = true;
      }
      cursor = m.end;
    }
    if (!drawing && cursor < payload.length) {
      buf.write(payload.substring(cursor));
    }
    return buf.toString().replaceAll(_assLineBreakRegex, '');
  }

  static String _applyOpenCcText(String text, SubtitleOpenCcMode mode) {
    return OpenCcDictionaries.convert(
      text,
      toSimplified: mode == SubtitleOpenCcMode.toSimplified,
    );
  }
}
