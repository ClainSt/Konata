import 'dart:math' as math;

/// 歌词行内单个音拍分段的字符区间与归一化进度范围。
class MoraCharacterSegment {
  /// 创建音拍字符分段。
  const MoraCharacterSegment({
    required this.startOffset,
    required this.endOffset,
    required this.startFraction,
    required this.endFraction,
    required this.moraWeight,
  });

  /// UTF-16 字符起始下标（含）。
  final int startOffset;

  /// UTF-16 字符结束下标（不含）。
  final int endOffset;

  /// 该分段在整行累计音拍中的起始比例（`0.0 ~ 1.0`）。
  final double startFraction;

  /// 该分段在整行累计音拍中的结束比例（`0.0 ~ 1.0`）。
  final double endFraction;

  /// 该分段占用的音拍权重（逗号停顿等纯停顿段可对应标点区间）。
  final double moraWeight;
}

/// 歌词行的音拍权重分布（用于整行 LRC 按音拍而非像素匀速推进扫白）。
class MoraLineProfile {
  /// 创建行音拍分布。
  const MoraLineProfile({
    required this.totalMora,
    required this.segments,
  });

  /// 整行有效音拍总数（已结合罗马音音节校准或按字符规则累加）。
  final double totalMora;

  /// 按文本顺序排列、进度单调递增的字符音拍分段列表。
  final List<MoraCharacterSegment> segments;
}

/// 日中英混合歌词音拍（Mora）估算器与行级演唱时长模型（纯领域无状态算法）。
///
/// 规则：
/// - 常规假名、长音 `ー` 与促音 `っ`/`ッ` 各计 `1.0` 拍；
/// - 小写拗音假名（`ゃゅょぁぃぅぇぉゎ` 等）权重为 `0.0`，与前导假名并入同一扫白单元；
/// - 日文语境下汉字按平均读音计 `1.7` 拍，纯中文语境下汉字计 `1.0` 拍；
/// - 拉丁单词按元音组数计拍；行内逗号/顿号停顿额外计 `0.3` 拍；
/// - 当行内存在有效罗马音注音时，优先按罗马音音节数校准整行精确音拍数。
abstract final class MoraPaceEstimator {
  /// 默认每音拍演唱耗时（秒，样本不足时的兜底曲速）。
  static const double defaultSecondsPerMora = 0.18;

  /// 句间常规换气余量（秒），用于扣除参考句间距中的换气停顿与句尾收尾留白。
  static const double breathMarginSeconds = 0.22;

  /// 估算演唱时长允许的弹性系数（允许略慢于中位曲速的自然拖音）。
  static const double vocalStretchFactor = 1.15;

  /// 单行有效音拍估算下限与上限时长（秒）。
  static const double minVocalDurationSeconds = 1.20;
  static const double maxVocalDurationSeconds = 8.50;

  static const Set<int> _smallYoonRunes = <int>{
    0x3041, // 小写平假名 ぁ
    0x3043, // 小写平假名 ぃ
    0x3045, // 小写平假名 ぅ
    0x3047, // 小写平假名 ぇ
    0x3049, // 小写平假名 ぉ
    0x3083, // 小写平假名 ゃ
    0x3085, // 小写平假名 ゅ
    0x3087, // 小写平假名 ょ
    0x308E, // 小写平假名 ゎ
    0x30A1, // 小写片假名 ァ
    0x30A3, // 小写片假名 ィ
    0x30A5, // 小写片假名 ゥ
    0x30A7, // 小写片假名 ェ
    0x30A9, // 小写片假名 ォ
    0x30E3, // 小写片假名 ャ
    0x30E5, // 小写片假名 ュ
    0x30E7, // 小写片假名 ョ
    0x30EE, // 小写片假名 ヮ
    0x30F5, // 小写片假名 ヵ
    0x30F6, // 小写片假名 ヶ
  };

  static const Set<int> _pausePunctRunes = <int>{
    0x002C, // 半角逗号
    0xFF0C, // 全角逗号
    0x3001, // 顿号
    0x003B, // 半角分号
    0xFF1B, // 全角分号
    0x2026, // 省略号
    0x2014, // 破折号
  };

  static final RegExp _kanaRegex = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
  static final RegExp _latinWordRegex = RegExp(r"[A-Za-zÀ-ÖØ-öø-ÿ']+");
  static final RegExp _vowelGroupRegex = RegExp(
    r'[aeiouyāīūēōâîûêôáíúéóàìùèòäïüëö]+',
    caseSensitive: false,
  );
  static final RegExp _romajiMoraTokenRegex = RegExp(
    r'(?:aa|ii|uu|ee|oo|ou|ei|[aeiouāīūēōâîûêô])',
    caseSensitive: false,
  );
  static final RegExp _romajiMoraicNRegex = RegExp(
    r'n(?![aeiouyāīūēōâîûêô])',
    caseSensitive: false,
  );
  static final RegExp _romajiGeminateRegex = RegExp(
    r'(?:kk|tt|pp|ss|cc|gg|dd|bb|zz)',
    caseSensitive: false,
  );

  /// 判断整首歌词集合是否属于日文语境（任意有效行含假名即视为日文歌曲，避免纯汉字行按中文 1.0 估算）。
  static bool detectJapaneseSong(Iterable<String> lines) {
    for (final line in lines) {
      if (_kanaRegex.hasMatch(line)) return true;
    }
    return false;
  }

  /// 估算单行歌词的总音拍数；若携带有效罗马音，则以罗马音音节数在合理范围内校准。
  static double estimateLineMora(
    String text, {
    String romajiText = '',
    bool? isJapaneseSong,
  }) {
    final profile = buildLineProfile(
      text,
      romajiText: romajiText,
      isJapaneseSong: isJapaneseSong,
    );
    return profile.totalMora;
  }

  /// 构建歌词行的逐字符音拍权重分布（确保进度从 `0.0` 单调连续推进至 `1.0`）。
  static MoraLineProfile buildLineProfile(
    String text, {
    String romajiText = '',
    bool? isJapaneseSong,
  }) {
    if (text.isEmpty) {
      return const MoraLineProfile(totalMora: 0.0, segments: []);
    }
    final treatAsJapanese = isJapaneseSong ?? _kanaRegex.hasMatch(text);
    final rawUnits = <({int start, int end, double weight})>[];

    var i = 0;
    final len = text.length;
    while (i < len) {
      final codeUnit = text.codeUnitAt(i);
      // 处理拉丁英文/罗马音单词，按元音组计拍后作为一个平滑词元或按字符切分。
      if (_isAsciiLetter(codeUnit)) {
        final match = _latinWordRegex.matchAsPrefix(text, i);
        if (match != null) {
          final word = match.group(0)!;
          final syllables = _countLatinWordSyllables(word);
          rawUnits.add((
            start: match.start,
            end: match.end,
            weight: syllables.toDouble(),
          ));
          i = match.end;
          continue;
        }
      }

      // 正确读取 UTF-16 代理对，保证字符切片始终落在合法代码点边界。
      final int rune;
      final int nextIdx;
      if (codeUnit >= 0xD800 &&
          codeUnit <= 0xDBFF &&
          i + 1 < len &&
          text.codeUnitAt(i + 1) >= 0xDC00 &&
          text.codeUnitAt(i + 1) <= 0xDFFF) {
        rune =
            0x10000 +
            ((codeUnit - 0xD800) << 10) +
            (text.codeUnitAt(i + 1) - 0xDC00);
        nextIdx = i + 2;
      } else {
        rune = codeUnit;
        nextIdx = i + 1;
      }

      // 小写拗音假名（非促音 っ/ッ）权重为 0，并入前一个假名单元避免扫白突然卡顿。
      if (_isSmallYoon(rune)) {
        if (rawUnits.isNotEmpty) {
          final prev = rawUnits.removeLast();
          rawUnits.add((start: prev.start, end: nextIdx, weight: prev.weight));
        } else {
          rawUnits.add((start: i, end: nextIdx, weight: 0.0));
        }
        i = nextIdx;
        continue;
      }

      final w = _weightForRune(rune, treatAsJapanese: treatAsJapanese);
      rawUnits.add((start: i, end: nextIdx, weight: w));
      i = nextIdx;
    }

    var heuristicTotal = 0.0;
    for (final u in rawUnits) {
      heuristicTotal += u.weight;
    }
    if (heuristicTotal <= 0.0) {
      // 全为无权重符号时按字符数均分兜底。
      final count = rawUnits.length;
      if (count == 0) {
        return const MoraLineProfile(totalMora: 0.0, segments: []);
      }
      final fallbackSegments = <MoraCharacterSegment>[];
      for (var idx = 0; idx < count; idx++) {
        final u = rawUnits[idx];
        fallbackSegments.add(
          MoraCharacterSegment(
            startOffset: u.start,
            endOffset: u.end,
            startFraction: idx / count,
            endFraction: (idx + 1) / count,
            moraWeight: 1.0,
          ),
        );
      }
      return MoraLineProfile(
        totalMora: count.toDouble(),
        segments: List<MoraCharacterSegment>.unmodifiable(fallbackSegments),
      );
    }

    var calibratedTotal = heuristicTotal;
    if (romajiText.trim().isNotEmpty) {
      final romajiMora = countRomajiMora(romajiText);
      if (romajiMora >= 2.0 &&
          romajiMora >= heuristicTotal * 0.5 &&
          romajiMora <= heuristicTotal * 2.2) {
        calibratedTotal = romajiMora;
      }
    }

    final scale = calibratedTotal / heuristicTotal;
    final segments = <MoraCharacterSegment>[];
    var cursor = 0.0;
    for (final u in rawUnits) {
      final segWeight = u.weight * scale;
      final startFrac = (cursor / calibratedTotal).clamp(0.0, 1.0);
      cursor += segWeight;
      final endFrac = (cursor / calibratedTotal).clamp(0.0, 1.0);
      segments.add(
        MoraCharacterSegment(
          startOffset: u.start,
          endOffset: u.end,
          startFraction: startFrac,
          endFraction: endFrac,
          moraWeight: segWeight,
        ),
      );
    }

    return MoraLineProfile(
      totalMora: calibratedTotal,
      segments: List<MoraCharacterSegment>.unmodifiable(segments),
    );
  }

  /// 统计罗马音行对应的精确音拍数（计入长元音双拍、拨音 `n` 与促音双辅音）。
  static double countRomajiMora(String romajiText) {
    final cleaned = romajiText.trim();
    if (cleaned.isEmpty) return 0.0;
    var count = 0.0;
    for (final m in _romajiMoraTokenRegex.allMatches(cleaned)) {
      final token = m.group(0)!;
      count += token.length >= 2 ? 2.0 : 1.0;
    }
    count += _romajiMoraicNRegex.allMatches(cleaned).length;
    count += _romajiGeminateRegex.allMatches(cleaned).length;
    return count;
  }

  /// 结合相邻正常句估算整首歌词的曲速（秒/音拍，使用样本中位数抗间奏异常值干扰）。
  static double estimateSongSecondsPerMora(
    List<({double startSeconds, String primaryText, String romajiText})> lines, {
    bool? isJapaneseSong,
  }) {
    if (lines.length < 2) return defaultSecondsPerMora;
    final isJa =
        isJapaneseSong ?? detectJapaneseSong(lines.map((l) => l.primaryText));
    final samples = <double>[];
    for (var i = 0; i + 1 < lines.length; i++) {
      final cur = lines[i];
      final next = lines[i + 1];
      final gap = next.startSeconds - cur.startSeconds;
      if (gap < 0.8 || gap > 8.0) continue;
      final mora = estimateLineMora(
        cur.primaryText,
        romajiText: cur.romajiText,
        isJapaneseSong: isJa,
      );
      if (mora < 3.0) continue;
      final singingSpan = math.max(0.35, gap - breathMarginSeconds);
      final pace = singingSpan / mora;
      if (pace >= 0.06 && pace <= 0.55) {
        samples.add(pace);
      }
    }
    if (samples.length < 2) return defaultSecondsPerMora;
    samples.sort();
    final mid = samples.length >> 1;
    final median = samples.length.isOdd
        ? samples[mid]
        : (samples[mid - 1] + samples[mid]) * 0.5;
    return median.clamp(0.10, 0.36);
  }

  /// 计算整行 LRC 歌词的实际扫白演唱时长：
  /// `min(下一行开始 - 换气余量, 本行音拍数 × 曲速 × 1.15)`。
  static double estimateVocalDurationSeconds({
    required double lineStartSeconds,
    required double? nextLineStartSeconds,
    required String text,
    String romajiText = '',
    required double secondsPerMora,
    bool? isJapaneseSong,
  }) {
    final mora = estimateLineMora(
      text,
      romajiText: romajiText,
      isJapaneseSong: isJapaneseSong,
    );
    final safeMora = math.max(1.0, mora);
    final estVocal = (safeMora * secondsPerMora * vocalStretchFactor).clamp(
      minVocalDurationSeconds,
      maxVocalDurationSeconds,
    );
    if (nextLineStartSeconds == null ||
        nextLineStartSeconds <= lineStartSeconds) {
      return estVocal;
    }
    final gap = nextLineStartSeconds - lineStartSeconds;
    if (gap <= 0.35) return 0.35;
    final availableBeforeBreath = math.max(0.35, gap - breathMarginSeconds);
    return math.min(availableBeforeBreath, estVocal);
  }

  static bool _isSmallYoon(int rune) {
    if (rune == 0x3063 || rune == 0x30C3) return false;
    return _smallYoonRunes.contains(rune);
  }

  static double _weightForRune(int rune, {required bool treatAsJapanese}) {
    // 促音 っ / ッ 与长音符 ー 各占 1 拍。
    if (rune == 0x3063 || rune == 0x30C3 || rune == 0x30FC) {
      return 1.0;
    }
    // 平假名与片假名主体各占 1 拍。
    if ((rune >= 0x3040 && rune <= 0x309F) ||
        (rune >= 0x30A0 && rune <= 0x30FF)) {
      return 1.0;
    }
    // 汉字：日文行按平均读音 1.7 拍，中文行按单音节 1.0 拍。
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF) ||
        (rune >= 0xF900 && rune <= 0xFAFF)) {
      return treatAsJapanese ? 1.7 : 1.0;
    }
    // 韩文音节块计 1.0 拍。
    if (rune >= 0xAC00 && rune <= 0xD7AF) {
      return 1.0;
    }
    // 阿拉伯数字计 1.0 拍。
    if (rune >= 0x30 && rune <= 0x39) {
      return 1.0;
    }
    // 行内逗号 / 顿号 / 省略号等停顿标点计 0.3 拍，使扫白在停顿处短暂停留。
    if (_pausePunctRunes.contains(rune)) {
      return 0.3;
    }
    return 0.0;
  }

  static bool _isAsciiLetter(int codeUnit) =>
      (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
      (codeUnit >= 0x61 && codeUnit <= 0x7A);

  static int _countLatinWordSyllables(String word) {
    var groups = _vowelGroupRegex.allMatches(word).length;
    // 英文末尾不发音的哑音 e 折减一拍（仅对长度 >= 4 且多于 1 组元音的词生效）。
    if (groups > 1 &&
        word.length >= 4 &&
        word.toLowerCase().endsWith('e') &&
        !word.toLowerCase().endsWith('le')) {
      groups--;
    }
    return math.max(1, groups);
  }
}
