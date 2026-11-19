import 'dart:math' as math;

/// 离线时间轴重映射支持的文本字幕格式。
enum SubtitleTextFormat {
  /// 特效文本字幕格式（`.ass` / `.ssa`）。
  ass,

  /// 常见纯文本字幕格式（`.srt`）。
  srt,

  /// 网页规范文本字幕格式（`.vtt`）。
  vtt,

  /// 未识别或二进制图形字幕格式。
  unknown,
}

/// 分段线性字幕时间轴重映射参数：$t' = \max(0, k \cdot t + d)$。
class SubtitleTimelineTransform {
  /// 创建时间轴重映射参数。
  const SubtitleTimelineTransform({
    this.rateScale = 1.0,
    this.offsetSeconds = 0.0,
    this.isPausedAlignment = false,
    this.reactionCompensationSeconds = 0.0,
  });

  /// 恒等变换（无需重写时间轴）。
  static const SubtitleTimelineTransform identity = SubtitleTimelineTransform();

  /// 时间缩放斜率 $k$（默认 `1.0`，例如 23.976 -> 25.000 或漂移校准）。
  final double rateScale;

  /// 基础时间平移偏移（秒，正值延后、负值提前）。
  final double offsetSeconds;

  /// 是否处于暂停帧对齐模式；为 `true` 时反应补偿强制归零，避免静止画面对齐产生人为偏置。
  final bool isPausedAlignment;

  /// 播放态人工按键反应补偿（秒）。
  final double reactionCompensationSeconds;

  /// 生效的反应补偿（暂停对齐态严格为 `0.0`）。
  double get effectiveReactionCompensation =>
      isPausedAlignment ? 0.0 : reactionCompensationSeconds;

  /// 生效的总平移量 $d$（秒）。
  double get effectiveOffsetSeconds =>
      offsetSeconds + effectiveReactionCompensation;

  /// 是否为恒等变换（`k == 1` 且 `d == 0`）。
  bool get isIdentity =>
      (rateScale - 1.0).abs() < 1e-9 && effectiveOffsetSeconds.abs() < 1e-9;

  /// 将原始绝对时间（秒）映射为目标绝对时间（秒），保证结果非负。
  double mapSeconds(double originalSeconds) {
    final mapped = rateScale * originalSeconds + effectiveOffsetSeconds;
    return mapped <= 0.0 ? 0.0 : mapped;
  }

  /// 将相对持续时长（毫秒）按斜率 $k$ 缩放并四舍五入为非负整数毫秒。
  int scaleDurationMs(int originalMs) {
    if (originalMs <= 0) return 0;
    return math.max(0, (originalMs * rateScale).round());
  }

  /// 将允许取负值的相对毫秒时间戳（如 ASS `\fade` 的 `t1`）按斜率 $k$ 保号缩放。
  int scaleSignedMs(int originalMs) {
    return (originalMs * rateScale).round();
  }
}

/// 离线分段线性字幕时间轴重映射引擎（纯领域算法，支持 ASS / SRT / WebVTT）。
///
/// 核心保真约束：
/// - 凡 `k != 1 || d != 0` 均按 $t' = \max(0, k \cdot t + d)$ 重算绝对时间戳；
/// - ASS `\fade(a1,a2,a3,t1,t2,t3,t4)` 仅缩放后 4 个毫秒时间参数，严格保留前 3 个 Alpha 参数；
/// - ASS `\t(t1,t2,accel,...)` 仅缩放 `t1,t2`，严格保留非线性加速度参数 `accel`；
/// - ASS 卡拉 OK 厘秒标签 `\k` / `\kf` / `\ko` / `\K` 采用累计边界差分
///   $c'_i = \operatorname{round}(k \cdot C_i) - \operatorname{round}(k \cdot C_{i-1})$，消除长句累积误差（总误差 <= 5 ms）；
/// - WebVTT 同步变换 Cue 头时间戳与行内 `<HH:MM:SS.mmm>` 逐词时间戳。
class SubtitleTimelineRemapper {
  SubtitleTimelineRemapper._();

  static final RegExp _assTimeRegex = RegExp(
    r'^(\d+):(\d{2}):(\d{2})\.(\d{2})$',
  );
  static final RegExp _srtCueRegex = RegExp(
    r'^(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})(\s*-->\s*)(\d{1,2}):(\d{2}):(\d{2})[,.](\d{3})(.*)$',
  );
  static final RegExp _vttCueRegex = RegExp(
    r'^((?:\d{1,2}:)?\d{2}:\d{2}\.\d{3})(\s*-->\s*)((?:\d{1,2}:)?\d{2}:\d{2}\.\d{3})(.*)$',
  );
  static final RegExp _vttInlineTimeRegex = RegExp(
    r'<((?:\d{1,2}:)?\d{2}:\d{2}\.\d{3})>',
  );
  static final RegExp _assOverrideBlockRegex = RegExp(r'\{([^}]*)\}');
  static final RegExp _fade7Regex = RegExp(
    r'\\fade\(\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)',
  );
  static final RegExp _fad2Regex = RegExp(
    r'\\fad\(\s*(-?\d+)\s*,\s*(-?\d+)\s*\)',
  );
  static final RegExp _move6Regex = RegExp(
    r'\\move\(\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*([^,]+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)',
  );
  static final RegExp _karaokeRegex = RegExp(r'\\(kf|ko|k|K)(-?\d+)');

  /// 探测文本字幕格式。
  static SubtitleTextFormat detectFormat(String content, {String? fileName}) {
    final lowerName = (fileName ?? '').toLowerCase();
    if (lowerName.endsWith('.ass') || lowerName.endsWith('.ssa')) {
      return SubtitleTextFormat.ass;
    }
    if (lowerName.endsWith('.vtt')) {
      return SubtitleTextFormat.vtt;
    }
    if (lowerName.endsWith('.srt')) {
      return SubtitleTextFormat.srt;
    }
    final trimmed = content.trimLeft();
    if (trimmed.startsWith('WEBVTT')) {
      return SubtitleTextFormat.vtt;
    }
    if (content.contains('[Script Info]') ||
        content.contains('[Events]') ||
        RegExp(r'^\s*Dialogue:', multiLine: true).hasMatch(content)) {
      return SubtitleTextFormat.ass;
    }
    if (RegExp(r'\d{2}:\d{2}:\d{2},\d{3}\s*-->').hasMatch(content)) {
      return SubtitleTextFormat.srt;
    }
    return SubtitleTextFormat.unknown;
  }

  /// 对整份字幕文本执行离线时间轴重映射。
  static String remap({
    required String content,
    required SubtitleTimelineTransform transform,
    SubtitleTextFormat? format,
    String? fileName,
  }) {
    if (transform.isIdentity || content.isEmpty) {
      return content;
    }
    final resolved = format ?? detectFormat(content, fileName: fileName);
    return switch (resolved) {
      SubtitleTextFormat.ass => _remapAss(content, transform),
      SubtitleTextFormat.srt => _remapSrt(content, transform),
      SubtitleTextFormat.vtt => _remapVtt(content, transform),
      SubtitleTextFormat.unknown => content,
    };
  }

  static ({int startIdx, int endIdx, int textIdx}) _parseAssEventsFormat(
    String formatLine,
  ) {
    final colonIdx = formatLine.indexOf(':');
    if (colonIdx < 0) {
      return (startIdx: 1, endIdx: 2, textIdx: 9);
    }
    final cols = formatLine
        .substring(colonIdx + 1)
        .split(',')
        .map((c) => c.trim().toLowerCase())
        .toList(growable: false);
    final startIdx = cols.indexOf('start');
    final endIdx = cols.indexOf('end');
    final textIdx = cols.indexOf('text');
    if (startIdx < 0 || endIdx < 0 || textIdx < 0) {
      return (startIdx: 1, endIdx: 2, textIdx: 9);
    }
    return (startIdx: startIdx, endIdx: endIdx, textIdx: textIdx);
  }

  static String _remapAss(
    String content,
    SubtitleTimelineTransform transform,
  ) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final scaleChanged = (transform.rateScale - 1.0).abs() >= 1e-9;
    final out = <String>[];
    var inEventsSection = false;
    var startIdx = 1;
    var endIdx = 2;
    var textIdx = 9;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        inEventsSection = trimmed.toLowerCase() == '[events]';
        out.add(line);
        continue;
      }
      if (inEventsSection && trimmed.toLowerCase().startsWith('format:')) {
        final layout = _parseAssEventsFormat(trimmed);
        startIdx = layout.startIdx;
        endIdx = layout.endIdx;
        textIdx = layout.textIdx;
        out.add(line);
        continue;
      }

      final isDialogue = line.startsWith('Dialogue:');
      final isComment = line.startsWith('Comment:');
      if (!isDialogue && !isComment) {
        out.add(line);
        continue;
      }
      final colonIdx = line.indexOf(':');
      final header = line.substring(0, colonIdx + 1);
      final rest = line.substring(colonIdx + 1);

      // 按 `[Events] Format:` 动态列序切分字段，保留 Text 列内所有逗号。
      final requiredCommas = math.max(textIdx, math.max(startIdx, endIdx));
      final commaPositions = <int>[];
      for (var i = 0; i < rest.length; i++) {
        if (rest.codeUnitAt(i) == 0x2C) {
          commaPositions.add(i);
          if (commaPositions.length == requiredCommas) break;
        }
      }
      if (commaPositions.length < requiredCommas) {
        out.add(line);
        continue;
      }

      // 拆分为 `requiredCommas + 1` 段原始切片（含最后一段完整 Text）。
      final fields = <String>[];
      var segStart = 0;
      for (final commaPos in commaPositions) {
        fields.add(rest.substring(segStart, commaPos));
        segStart = commaPos + 1;
      }
      fields.add(rest.substring(segStart));

      final startSec = _parseAssTimeSeconds(fields[startIdx].trim());
      final endSec = _parseAssTimeSeconds(fields[endIdx].trim());
      if (startSec == null || endSec == null) {
        out.add(line);
        continue;
      }

      final unclampedStart =
          transform.rateScale * startSec + transform.effectiveOffsetSeconds;
      final mappedStart = transform.mapSeconds(startSec);
      final mappedEnd = math.max(mappedStart, transform.mapSeconds(endSec));
      final clippedHeadMs = (unclampedStart < 0.0 && mappedEnd > 0.0)
          ? (-unclampedStart * 1000.0).round()
          : 0;
      final mappedDurationMs = math.max(
        0,
        ((mappedEnd - mappedStart) * 1000.0).round(),
      );

      final startLeadingSpace = fields[startIdx].startsWith(' ') ? ' ' : '';
      final endLeadingSpace = fields[endIdx].startsWith(' ') ? ' ' : '';
      fields[startIdx] = '$startLeadingSpace${_formatAssTimeSeconds(mappedStart)}';
      fields[endIdx] = '$endLeadingSpace${_formatAssTimeSeconds(mappedEnd)}';

      if (scaleChanged || clippedHeadMs > 0) {
        fields[textIdx] = _remapAssInlineEffects(
          fields[textIdx],
          transform,
          clippedHeadMs: clippedHeadMs,
          mappedDurationMs: mappedDurationMs,
        );
      }

      out.add('$header${fields.join(',')}');
    }

    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static String _remapAssInlineEffects(
    String text,
    SubtitleTimelineTransform transform, {
    int clippedHeadMs = 0,
    int? mappedDurationMs,
  }) {
    // 卡拉 OK 厘秒采用跨整行累计边界差分，并同步扣除跨零点截断的头部厘秒。
    final clippedHeadCs = (clippedHeadMs / 10.0).round();
    var cumulativeOriginalCs = 0;
    var cumulativeMappedCs = 0;

    return text.replaceAllMapped(_assOverrideBlockRegex, (blockMatch) {
      var inner = blockMatch.group(1)!;

      // 1. \fade(a1,a2,a3,t1,t2,t3,t4)：仅变换后 4 个毫秒时间参数，严格保留前 3 个 Alpha 参数及合法负 t1。
      inner = inner.replaceAllMapped(_fade7Regex, (m) {
        final a1 = m.group(1)!;
        final a2 = m.group(2)!;
        final a3 = m.group(3)!;
        final t1 = transform.scaleSignedMs(int.parse(m.group(4)!)) - clippedHeadMs;
        final t2 = transform.scaleSignedMs(int.parse(m.group(5)!)) - clippedHeadMs;
        final t3 = transform.scaleSignedMs(int.parse(m.group(6)!)) - clippedHeadMs;
        final t4 = transform.scaleSignedMs(int.parse(m.group(7)!)) - clippedHeadMs;
        return '\\fade($a1,$a2,$a3,$t1,$t2,$t3,$t4)';
      });

      // 2. \fad(t1,t2)：缩放渐入/渐出毫秒并在头部跨零截断时同步裁剪渐入时长 t1。
      inner = inner.replaceAllMapped(_fad2Regex, (m) {
        final scaledT1 = transform.scaleDurationMs(int.parse(m.group(1)!));
        final scaledT2 = transform.scaleDurationMs(int.parse(m.group(2)!));
        final t1 = math.max(0, scaledT1 - clippedHeadMs);
        final t2 = (clippedHeadMs > 0 && mappedDurationMs != null)
            ? math.min(scaledT2, mappedDurationMs)
            : scaledT2;
        return '\\fad($t1,$t2)';
      });

      // 3. \move(x1,y1,x2,y2,t1,t2)：保留坐标，缩放起止时间并扣除头部跨零截断偏移。
      inner = inner.replaceAllMapped(_move6Regex, (m) {
        final t1 = math.max(
          0,
          transform.scaleDurationMs(int.parse(m.group(5)!)) - clippedHeadMs,
        );
        final t2 = math.max(
          0,
          transform.scaleDurationMs(int.parse(m.group(6)!)) - clippedHeadMs,
        );
        return '\\move(${m.group(1)!.trim()},${m.group(2)!.trim()},${m.group(3)!.trim()},${m.group(4)!.trim()},$t1,$t2)';
      });

      // 4. \t([t1,t2,[accel,]]modifiers)：支持嵌套括号，保留 accel 原值并扣除头部跨零截断偏移。
      inner = _remapAssTransformTags(
        inner,
        transform,
        clippedHeadMs: clippedHeadMs,
      );

      // 5. 卡拉 OK \k / \kf / \ko / \K 厘秒累计边界差分（同步扣除头部跨零截断厘秒）。
      inner = inner.replaceAllMapped(_karaokeRegex, (m) {
        final tag = m.group(1)!;
        final origCs = int.parse(m.group(2)!);
        if (origCs <= 0) {
          return '\\$tag$origCs';
        }
        cumulativeOriginalCs += origCs;
        final nextMappedCumulative = math.max(
          0,
          (cumulativeOriginalCs * transform.rateScale).round() - clippedHeadCs,
        );
        final deltaCs = math.max(0, nextMappedCumulative - cumulativeMappedCs);
        cumulativeMappedCs = nextMappedCumulative;
        return '\\$tag$deltaCs';
      });

      return '{$inner}';
    });
  }

  static String _remapAssTransformTags(
    String inner,
    SubtitleTimelineTransform transform, {
    int clippedHeadMs = 0,
  }) {
    final out = StringBuffer();
    var i = 0;
    while (i < inner.length) {
      if (i + 2 < inner.length &&
          inner.codeUnitAt(i) == 0x5C &&
          inner.codeUnitAt(i + 1) == 0x74 &&
          inner.codeUnitAt(i + 2) == 0x28) {
        // 找到与 \t( 匹配的闭合括号（支持内部嵌套如 \clip(...)）。
        var depth = 1;
        var j = i + 3;
        while (j < inner.length && depth > 0) {
          final cu = inner.codeUnitAt(j);
          if (cu == 0x28) depth++;
          if (cu == 0x29) depth--;
          j++;
        }
        if (depth == 0) {
          final argsStr = inner.substring(i + 3, j - 1);
          out.write(
            '\\t(${_remapSingleTransformArgs(argsStr, transform, clippedHeadMs: clippedHeadMs)})',
          );
          i = j;
          continue;
        }
      }
      out.writeCharCode(inner.codeUnitAt(i));
      i++;
    }
    return out.toString();
  }

  static String _remapSingleTransformArgs(
    String argsStr,
    SubtitleTimelineTransform transform, {
    int clippedHeadMs = 0,
  }) {
    final parts = _splitTopLevelCommas(argsStr);
    if (parts.length < 3) {
      return argsStr;
    }
    final t1 = int.tryParse(parts[0].trim());
    final t2 = int.tryParse(parts[1].trim());
    if (t1 == null || t2 == null) {
      return argsStr;
    }
    final s1 = math.max(0, transform.scaleDurationMs(t1) - clippedHeadMs);
    final s2 = math.max(0, transform.scaleDurationMs(t2) - clippedHeadMs);
    if (parts.length == 3) {
      return '$s1,$s2,${parts[2].trim()}';
    }
    // 4 段及以上：\t(t1, t2, accel, modifiers...) — 严格保留 accel 原值不变。
    final accel = parts[2].trim();
    final rest = parts.sublist(3).join(',');
    return '$s1,$s2,$accel,$rest';
  }

  static List<String> _splitTopLevelCommas(String input) {
    final result = <String>[];
    var depth = 0;
    var start = 0;
    for (var i = 0; i < input.length; i++) {
      final cu = input.codeUnitAt(i);
      if (cu == 0x28) {
        depth++;
      } else if (cu == 0x29 && depth > 0) {
        depth--;
      } else if (cu == 0x2C && depth == 0) {
        result.add(input.substring(start, i));
        start = i + 1;
      }
    }
    result.add(input.substring(start));
    return result;
  }

  static String _remapSrt(
    String content,
    SubtitleTimelineTransform transform,
  ) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (final line in lines) {
      final m = _srtCueRegex.firstMatch(line);
      if (m == null) {
        out.add(line);
        continue;
      }
      final startSec = _hmsMsToSeconds(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
      );
      final endSec = _hmsMsToSeconds(
        int.parse(m.group(6)!),
        int.parse(m.group(7)!),
        int.parse(m.group(8)!),
        int.parse(m.group(9)!),
      );
      final mappedStart = transform.mapSeconds(startSec);
      final mappedEnd = math.max(mappedStart, transform.mapSeconds(endSec));
      out.add(
        '${_formatSrtTimeSeconds(mappedStart)}${m.group(5)}${_formatSrtTimeSeconds(mappedEnd)}${m.group(10)}',
      );
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static String _remapVtt(
    String content,
    SubtitleTimelineTransform transform,
  ) {
    final usesCrlf = content.contains('\r\n');
    final lines = content.split(RegExp(r'\r?\n'));
    final out = <String>[];
    for (final line in lines) {
      final cue = _vttCueRegex.firstMatch(line);
      if (cue != null) {
        final startRaw = cue.group(1)!;
        final endRaw = cue.group(3)!;
        final startSec = _parseVttTimeSeconds(startRaw);
        final endSec = _parseVttTimeSeconds(endRaw);
        if (startSec != null && endSec != null) {
          final mappedStart = transform.mapSeconds(startSec);
          final mappedEnd = math.max(mappedStart, transform.mapSeconds(endSec));
          final startHasHours = startRaw.split(':').length == 3;
          final endHasHours = endRaw.split(':').length == 3;
          out.add(
            '${_formatVttTimeSeconds(mappedStart, forceHours: startHasHours)}${cue.group(2)}${_formatVttTimeSeconds(mappedEnd, forceHours: endHasHours)}${cue.group(4)}',
          );
          continue;
        }
      }
      // 同步重映射 WebVTT 文本行内的 `<HH:MM:SS.mmm>` / `<MM:SS.mmm>` 逐词时间戳。
      if (line.contains('<')) {
        final mappedLine = line.replaceAllMapped(_vttInlineTimeRegex, (m) {
          final raw = m.group(1)!;
          final sec = _parseVttTimeSeconds(raw);
          if (sec == null) return m.group(0)!;
          final hasHours = raw.split(':').length == 3;
          return '<${_formatVttTimeSeconds(transform.mapSeconds(sec), forceHours: hasHours)}>';
        });
        out.add(mappedLine);
      } else {
        out.add(line);
      }
    }
    return out.join(usesCrlf ? '\r\n' : '\n');
  }

  static double? _parseAssTimeSeconds(String raw) {
    final m = _assTimeRegex.firstMatch(raw);
    if (m == null) return null;
    final h = int.parse(m.group(1)!);
    final min = int.parse(m.group(2)!);
    final sec = int.parse(m.group(3)!);
    final cs = int.parse(m.group(4)!);
    return h * 3600.0 + min * 60.0 + sec + cs / 100.0;
  }

  static String _formatAssTimeSeconds(double seconds) {
    final totalCs = math.max(0, (seconds * 100.0).round());
    final cs = totalCs % 100;
    final totalSec = totalCs ~/ 100;
    final sec = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final min = totalMin % 60;
    final h = totalMin ~/ 60;
    return '$h:${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}.${cs.toString().padLeft(2, '0')}';
  }

  static double _hmsMsToSeconds(int h, int m, int s, int ms) {
    return h * 3600.0 + m * 60.0 + s + ms / 1000.0;
  }

  static String _formatSrtTimeSeconds(double seconds) {
    final totalMs = math.max(0, (seconds * 1000.0).round());
    final ms = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final s = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final m = totalMin % 60;
    final h = totalMin ~/ 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')},${ms.toString().padLeft(3, '0')}';
  }

  static double? _parseVttTimeSeconds(String raw) {
    final parts = raw.split(':');
    if (parts.length != 2 && parts.length != 3) return null;
    final secParts = parts.last.split('.');
    if (secParts.length != 2) return null;
    final sec = int.tryParse(secParts[0]);
    final ms = int.tryParse(secParts[1]);
    final min = int.tryParse(parts[parts.length - 2]);
    final hour = parts.length == 3 ? int.tryParse(parts[0]) : 0;
    if (sec == null || ms == null || min == null || hour == null) return null;
    return _hmsMsToSeconds(hour, min, sec, ms);
  }

  static String _formatVttTimeSeconds(
    double seconds, {
    required bool forceHours,
  }) {
    final totalMs = math.max(0, (seconds * 1000.0).round());
    final ms = totalMs % 1000;
    final totalSec = totalMs ~/ 1000;
    final s = totalSec % 60;
    final totalMin = totalSec ~/ 60;
    final m = totalMin % 60;
    final h = totalMin ~/ 60;
    if (forceHours || h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${ms.toString().padLeft(3, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${ms.toString().padLeft(3, '0')}';
  }
}
