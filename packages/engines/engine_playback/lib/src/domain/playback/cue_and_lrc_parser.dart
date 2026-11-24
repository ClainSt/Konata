import 'dart:typed_data';

import '../text/multibyte_text_decoder.dart';
import 'cue_lyric_alignment_helper.dart';
import 'lyric_version_matcher.dart';
import 'mora_pace_estimator.dart';

export '../text/multibyte_text_decoder.dart'
    show
        DetectedTextCharset,
        DecodedTextResult,
        LegacyCodePageDecoder,
        LegacyTextEncoding,
        MultibyteTextDecoder;

/// CUE 虚拟音轨实体（全程保留整数光盘扇区 `1/75 s`，消除浮点累计漂移与整秒截断）。
class CueTrack {
  /// CD-DA 标准每秒光盘扇区帧数（75 帧/秒）。
  static const int sectorsPerSecond = 75;

  /// 创建 CUE 分轨条目（支持编译期常量构造，优先保留精确整数光盘扇区）。
  const CueTrack({
    required this.trackNumber,
    required this.title,
    this.performer = '',
    this.fileName = '',
    int? startSectorFrames,
    int? endSectorFrames,
    int? pregapIndex00SectorFrames,
    double startSeconds = 0.0,
    double? endSeconds,
    double? pregapIndex00Seconds,
  }) : _sectorStart = startSectorFrames,
       _sectorEnd = endSectorFrames,
       _sectorPregap = pregapIndex00SectorFrames,
       _fallbackStartSeconds = startSeconds,
       _fallbackEndSeconds = endSeconds,
       _fallbackPregapSeconds = pregapIndex00Seconds;

  /// 音轨编号（1..99）。
  final int trackNumber;

  /// 曲目标题。
  final String title;

  /// 单曲演唱者或艺术家。
  final String performer;

  /// 对应的物理音频文件名（`FILE "..."` 声明）。
  final String fileName;

  final int? _sectorStart;
  final int? _sectorEnd;
  final int? _sectorPregap;
  final double _fallbackStartSeconds;
  final double? _fallbackEndSeconds;
  final double? _fallbackPregapSeconds;

  /// `INDEX 01` 精确整数光盘扇区偏移（1 扇区 = `1/75 s`）。
  int get startSectorFrames =>
      _sectorStart ?? (_fallbackStartSeconds * sectorsPerSecond).round();

  /// 精确整数结束光盘扇区（来自下一曲 `INDEX 00/01` 或总时长换算）。
  int? get endSectorFrames =>
      _sectorEnd ??
      (_fallbackEndSeconds != null
          ? (_fallbackEndSeconds * sectorsPerSecond).round()
          : null);

  /// 可选 `INDEX 00` 间奏前隙精确整数扇区。
  int? get pregapIndex00SectorFrames =>
      _sectorPregap ??
      (_fallbackPregapSeconds != null
          ? (_fallbackPregapSeconds * sectorsPerSecond).round()
          : null);

  /// `INDEX 01` 精确起始秒数（由整数扇区直接相除得出）。
  double get startSeconds =>
      _sectorStart != null ? _sectorStart / sectorsPerSecond : _fallbackStartSeconds;

  /// 精确结束秒数（由整数扇区直接相除，或来自显式音频总时长）。
  double? get endSeconds =>
      _sectorEnd != null ? _sectorEnd / sectorsPerSecond : _fallbackEndSeconds;

  /// 可选 `INDEX 00` 间奏前隙精确秒数。
  double? get pregapIndex00Seconds => _sectorPregap != null
      ? _sectorPregap / sectorsPerSecond
      : _fallbackPregapSeconds;

  /// 当前分轨时长（秒）。
  double? get durationSeconds {
    final end = endSeconds;
    if (end == null) return null;
    final diff = end - startSeconds;
    return diff > 0 ? diff : 0.0;
  }

  /// 校验 CUE `FILE` 声明路径是否安全停留在授权源目录内（严禁绝对路径、盘符、UNC 或 `..` 穿越）。
  static bool isSafeRelativeFileReference(String rawFileName) {
    final trimmed = rawFileName.trim();
    if (trimmed.isEmpty) return false;
    if (trimmed.startsWith('/') ||
        trimmed.startsWith('\\') ||
        trimmed.contains(':') ||
        trimmed.contains('\x00')) {
      return false;
    }
    final normalized = trimmed.replaceAll('\\', '/');
    for (final segment in normalized.split('/')) {
      if (segment == '..') return false;
    }
    return true;
  }
}

/// 解析后的 CUE 整轨分轨清单。
class CueSheet {
  /// 创建 CUE 分轨清单。
  const CueSheet({
    this.title = '',
    this.performer = '',
    required this.tracks,
    this.rejectedUnsafeFileCount = 0,
  });

  /// 专辑标题。
  final String title;

  /// 专辑艺术家。
  final String performer;

  /// 分轨列表（已按轨号与精确整数扇区规范化）。
  final List<CueTrack> tracks;

  /// 解析期间被安全拦截的越权 `FILE` 路径声明数量。
  final int rejectedUnsafeFileCount;
}

/// 同时间戳聚合的多行歌词条目（支持日文原文 + 中文翻译 + 独立罗马音注音 + 原生逐字/和声时间片段）。
class LrcCueLine {
  /// 创建聚合歌词行。
  const LrcCueLine({
    required this.startSeconds,
    this.endSeconds,
    required this.primaryText,
    this.secondaryLines = const [],
    this.romajiText = '',
    this.words = const [],
    this.harmonyWords = const [],
  });

  /// 触发起始时间（秒，已按 `[offset:]` 校正并钳制 >= 0）。
  final double startSeconds;

  /// 结束时间（由下一行触发时间推导，末行可为空）。
  final double? endSeconds;

  /// 主行文本（同时间戳首行原文）。
  final String primaryText;

  /// 附加翻译行文本列表（不包含独立罗马音注音与 `bg:` 和声层）。
  final List<String> secondaryLines;

  /// 独立罗马音注音文本（由设置开关控制显隐，避免与译文混排）。
  final String romajiText;

  /// 主唱逐字时间片段列表（携带精确起止时间；普通行级 LRC 为空）。
  final List<TimedLyricSpan> words;

  /// 和声 / 背景人声逐字片段列表（来自 `bg:` 行；无和声时为空）。
  final List<TimedLyricSpan> harmonyWords;

  /// 是否携带主唱或和声逐字时间数据。
  bool get hasWordTiming => words.isNotEmpty || harmonyWords.isNotEmpty;

  /// 复制并补充结束时间、译文、注音或逐字片段。
  LrcCueLine copyWith({
    double? endSeconds,
    String? primaryText,
    List<String>? secondaryLines,
    String? romajiText,
    List<TimedLyricSpan>? words,
    List<TimedLyricSpan>? harmonyWords,
  }) {
    return LrcCueLine(
      startSeconds: startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
      primaryText: primaryText ?? this.primaryText,
      secondaryLines: secondaryLines ?? this.secondaryLines,
      romajiText: romajiText ?? this.romajiText,
      words: words ?? this.words,
      harmonyWords: harmonyWords ?? this.harmonyWords,
    );
  }
}

/// 解析后的 LRC 同步歌词文档（曲速与语境在解析期一次性预计算，视口构建期零重复计算）。
class LrcDocument {
  /// 样本不足时的默认每字演唱秒数。
  static const double defaultSecondsPerChar = 0.24;

  /// 创建 LRC 文档对象。
  const LrcDocument({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.offsetMillis = 0,
    required this.lines,
    this.estimatedSecondsPerChar = defaultSecondsPerChar,
    this.secondsPerMora = MoraPaceEstimator.defaultSecondsPerMora,
    this.isJapaneseSong = false,
  });

  /// 曲目名称 `[ti:]`。
  final String title;

  /// 艺术家 `[ar:]`。
  final String artist;

  /// 专辑名称 `[al:]`。
  final String album;

  /// 全局时间偏移 `[offset:]`（毫秒，按 LRC 通行约定正值使歌词提前、负值使歌词延后）。
  final int offsetMillis;

  /// 按时间升序排列且同时间戳已分组的多行歌词列表。
  final List<LrcCueLine> lines;

  /// 解析期预计算的每字中位演唱秒数（兼容外部测试与传统语速参考）。
  final double estimatedSecondsPerChar;

  /// 解析期预计算的曲速（秒/音拍，供音拍加权扫白与演唱时长估算 O(1) 读取）。
  final double secondsPerMora;

  /// 当前歌词集合是否属于日文语境（供全汉字行仍按日文 1.7 音拍准确估算）。
  final bool isJapaneseSong;

  /// 文档内任意行是否携带逐字时间数据。
  bool get hasWordTiming => lines.any((l) => l.hasWordTiming);

  /// 使用二分查找定位指定播放时间点（秒）对应的当前歌词行索引；尚未开唱或无歌词返回 `-1`。
  int activeIndexAt(double positionSeconds) {
    if (lines.isEmpty || !positionSeconds.isFinite) return -1;
    final target = positionSeconds + 0.05;
    if (target < lines.first.startSeconds) return -1;
    var low = 0;
    var high = lines.length - 1;
    var best = 0;
    while (low <= high) {
      final mid = (low + high) >> 1;
      if (lines[mid].startSeconds <= target) {
        best = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return best;
  }

  /// 基于相邻正常句的中位语速一次性计算每字平均演唱秒数（解析期调用，避免渲染热路径重算）。
  static double computeEstimatedSecondsPerChar(List<LrcCueLine> lines) {
    final whitespaceRegex = RegExp(r'\s+');
    final samples = <double>[];
    for (var i = 0; i + 1 < lines.length; i++) {
      final cur = lines[i];
      final next = lines[i + 1];
      final gap = next.startSeconds - cur.startSeconds;
      if (gap < 0.8 || gap > 8.0) continue;
      final charCount = cur.primaryText
          .replaceAll(whitespaceRegex, '')
          .runes
          .length;
      if (charCount < 3) continue;
      final pace = gap / charCount;
      if (pace >= 0.08 && pace <= 0.65) {
        samples.add(pace);
      }
    }
    if (samples.length < 2) {
      return defaultSecondsPerChar;
    }
    samples.sort();
    final mid = samples.length >> 1;
    final median = samples.length.isOdd
        ? samples[mid]
        : (samples[mid - 1] + samples[mid]) * 0.5;
    return median.clamp(0.14, 0.34);
  }
}

/// 播放领域统一多编码探测与解码入口（直接复用全仓唯一的 `MultibyteTextDecoder`）。
class PlaybackTextDecoder {
  PlaybackTextDecoder._();

  /// 将原始字节解码为字符串（支持 UTF-8 / UTF-16LE/BE / CP932 / GB18030 / Big5）。
  static String decodeBytes(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    return MultibyteTextDecoder.decodeBytes(
      bytes,
      legacyDecoder: legacyDecoder,
    );
  }

  /// 基于字节文法统计判断传统文本偏向 Shift-JIS、GB18030/GBK 还是 Big5。
  static LegacyTextEncoding detectLegacyEncoding(List<int> bytes) {
    return MultibyteTextDecoder.detectLegacyEncoding(bytes);
  }
}

/// 纯 Dart CUE 分轨清单解析器。
class CueParser {
  CueParser._();

  static final RegExp _fileRegex = RegExp(
    r'^\s*FILE\s+(?:"([^"]+)"|(\S+))',
    caseSensitive: false,
  );
  static final RegExp _trackRegex = RegExp(
    r'^\s*TRACK\s+(\d+)\s+AUDIO\b',
    caseSensitive: false,
  );
  static final RegExp _indexRegex = RegExp(
    r'^\s*INDEX\s+(\d+)\s+(\d+):(\d+):(\d+)',
    caseSensitive: false,
  );
  static final RegExp _titleRegex = RegExp(
    r'^\s*TITLE\s+(?:"([^"]*)"|(.+))$',
    caseSensitive: false,
  );
  static final RegExp _performerRegex = RegExp(
    r'^\s*PERFORMER\s+(?:"([^"]*)"|(.+))$',
    caseSensitive: false,
  );

  /// 从原始字节解析 CUE 清单。
  static CueSheet parseBytes(
    Uint8List bytes, {
    double? totalDurationSeconds,
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    final text = PlaybackTextDecoder.decodeBytes(
      bytes,
      legacyDecoder: legacyDecoder,
    );
    return parseText(text, totalDurationSeconds: totalDurationSeconds);
  }

  /// 从已解码文本解析 CUE 清单，全程保留整数光盘扇区（`1/75 s`）并拦截越权 `FILE` 路径。
  static CueSheet parseText(String content, {double? totalDurationSeconds}) {
    var albumTitle = '';
    var albumPerformer = '';
    var currentFile = '';
    var currentFileSafe = true;
    var rejectedUnsafeFileCount = 0;

    int? currentTrackNum;
    var currentTrackTitle = '';
    var currentTrackPerformer = '';
    var currentTrackFile = '';
    var currentTrackFileSafe = true;
    int? currentIndex00Sectors;
    int? currentIndex01Sectors;

    final rawTracks = <_PendingCueTrack>[];

    void flushCurrentTrack() {
      if (currentTrackNum == null || currentIndex01Sectors == null) return;
      if (!currentTrackFileSafe) return;
      rawTracks.add(
        _PendingCueTrack(
          trackNumber: currentTrackNum,
          title: currentTrackTitle.trim().isNotEmpty
              ? currentTrackTitle.trim()
              : 'Track ${currentTrackNum.toString().padLeft(2, '0')}',
          performer: currentTrackPerformer.trim().isNotEmpty
              ? currentTrackPerformer.trim()
              : albumPerformer.trim(),
          fileName: currentTrackFile,
          startSectorFrames: currentIndex01Sectors,
          pregapIndex00SectorFrames: currentIndex00Sectors,
        ),
      );
    }

    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.toUpperCase().startsWith('REM ')) continue;

      final fileMatch = _fileRegex.firstMatch(line);
      if (fileMatch != null) {
        final declared = (fileMatch.group(1) ?? fileMatch.group(2) ?? '').trim();
        if (CueTrack.isSafeRelativeFileReference(declared)) {
          currentFile = declared;
          currentFileSafe = true;
        } else {
          currentFile = '';
          currentFileSafe = false;
          rejectedUnsafeFileCount += 1;
        }
        continue;
      }

      final trackMatch = _trackRegex.firstMatch(line);
      if (trackMatch != null) {
        flushCurrentTrack();
        currentTrackNum = int.tryParse(trackMatch.group(1) ?? '');
        currentTrackTitle = '';
        currentTrackPerformer = '';
        currentTrackFile = currentFile;
        currentTrackFileSafe = currentFileSafe;
        currentIndex00Sectors = null;
        currentIndex01Sectors = null;
        continue;
      }

      final titleMatch = _titleRegex.firstMatch(line);
      if (titleMatch != null) {
        final value = (titleMatch.group(1) ?? titleMatch.group(2) ?? '').trim();
        if (currentTrackNum == null) {
          albumTitle = value;
        } else {
          currentTrackTitle = value;
        }
        continue;
      }

      final performerMatch = _performerRegex.firstMatch(line);
      if (performerMatch != null) {
        final value =
            (performerMatch.group(1) ?? performerMatch.group(2) ?? '').trim();
        if (currentTrackNum == null) {
          albumPerformer = value;
        } else {
          currentTrackPerformer = value;
        }
        continue;
      }

      final indexMatch = _indexRegex.firstMatch(line);
      if (indexMatch != null && currentTrackNum != null) {
        final idxNum = int.tryParse(indexMatch.group(1) ?? '');
        final mm = int.tryParse(indexMatch.group(2) ?? '0') ?? 0;
        final ss = int.tryParse(indexMatch.group(3) ?? '0') ?? 0;
        final ff = int.tryParse(indexMatch.group(4) ?? '0') ?? 0;
        final sectorFrames =
            (mm * 60 + ss) * CueTrack.sectorsPerSecond + ff;
        if (idxNum == 0) {
          currentIndex00Sectors = sectorFrames;
        } else if (idxNum == 1) {
          currentIndex01Sectors = sectorFrames;
        }
      }
    }
    flushCurrentTrack();

    final tracks = <CueTrack>[];
    for (var i = 0; i < rawTracks.length; i++) {
      final item = rawTracks[i];
      int? endSectors;
      double? explicitEndSeconds;
      if (i + 1 < rawTracks.length && rawTracks[i + 1].fileName == item.fileName) {
        endSectors =
            rawTracks[i + 1].pregapIndex00SectorFrames ??
            rawTracks[i + 1].startSectorFrames;
        if (endSectors < item.startSectorFrames) {
          endSectors = item.startSectorFrames;
        }
      } else if (totalDurationSeconds != null &&
          totalDurationSeconds.isFinite &&
          totalDurationSeconds > item.startSeconds) {
        explicitEndSeconds = totalDurationSeconds;
      }
      tracks.add(
        CueTrack(
          trackNumber: item.trackNumber,
          title: item.title,
          performer: item.performer,
          fileName: item.fileName,
          startSectorFrames: item.startSectorFrames,
          endSectorFrames: endSectors,
          pregapIndex00SectorFrames: item.pregapIndex00SectorFrames,
          endSeconds: explicitEndSeconds,
        ),
      );
    }

    return CueSheet(
      title: albumTitle.trim(),
      performer: albumPerformer.trim(),
      tracks: tracks,
      rejectedUnsafeFileCount: rejectedUnsafeFileCount,
    );
  }
}

class _PendingCueTrack {
  const _PendingCueTrack({
    required this.trackNumber,
    required this.title,
    required this.performer,
    required this.fileName,
    required this.startSectorFrames,
    this.pregapIndex00SectorFrames,
  });

  final int trackNumber;
  final String title;
  final String performer;
  final String fileName;
  final int startSectorFrames;
  final int? pregapIndex00SectorFrames;

  double get startSeconds => startSectorFrames / CueTrack.sectorsPerSecond;
}

/// 纯 Dart LRC 同步歌词解析器（支持多时间戳复用与同时间戳多语种多行聚合）。
class LrcParser {
  LrcParser._();

  static final RegExp _timeTagRegex = RegExp(
    r'\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _kanaRegex = RegExp(r'[\u3040-\u309F\u30A0-\u30FF]');
  static final RegExp _cjkHanRegex = RegExp(r'[\u4E00-\u9FFF]');
  static final RegExp _metaTagRegex = RegExp(
    r'^\[([a-zA-Z]+):(.*)\]$',
  );

  /// 判断单行文本是否更像日文/外文原文而非中文译文，防止双语翻译因毫秒偏移倒挂为主行。
  static bool _isLikelyOriginalOverChineseTranslation(
    String candidate,
    String existingPrimary,
  ) {
    final candTrim = candidate.trim();
    final primTrim = existingPrimary.trim();
    if (candTrim.isEmpty || primTrim.isEmpty) return false;
    if (candTrim.startsWith('bg:')) return false;
    final candHasKana = _kanaRegex.hasMatch(candTrim);
    final primHasKana = _kanaRegex.hasMatch(primTrim);
    // 含假名的日文原文始终优先于不含假名的中文译文。
    if (candHasKana && !primHasKana && _cjkHanRegex.hasMatch(primTrim)) {
      return true;
    }
    return false;
  }

  /// 从原始字节解析 LRC 文档。
  static LrcDocument parseBytes(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    final text = PlaybackTextDecoder.decodeBytes(
      bytes,
      legacyDecoder: legacyDecoder,
    );
    return parseText(text);
  }

  /// 从文本解析 LRC 文档：分离 `roma:` 独立注音与 `bg:` 和声，绑定逐字片段并预计算曲速。
  static LrcDocument parseText(String content) {
    final decoded = CueLyricAlignmentHelper.decodeHtmlEntities(content);
    var title = '';
    var artist = '';
    var album = '';
    var offsetMillis = 0;

    final rawEntries =
        <({double timeSeconds, String text, String rawBody, bool isRomaji, bool isHarmony})>[];

    for (final rawLine in decoded.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final timeMatches = _timeTagRegex.allMatches(line).toList();
      if (timeMatches.isEmpty) {
        final meta = _metaTagRegex.firstMatch(line);
        if (meta != null) {
          final key = (meta.group(1) ?? '').trim().toLowerCase();
          final value = (meta.group(2) ?? '').trim();
          switch (key) {
            case 'ti':
              title = value;
            case 'ar':
              artist = value;
            case 'al':
              album = value;
            case 'offset':
              offsetMillis = int.tryParse(value) ?? offsetMillis;
          }
        }
        continue;
      }

      var rawBody = line.replaceAll(_timeTagRegex, '').trim();
      if (rawBody.isEmpty) continue;

      final isRomaji = rawBody.startsWith('roma:');
      final isHarmony = !isRomaji && rawBody.startsWith('bg:');
      if (isRomaji) {
        rawBody = rawBody.substring(5).trim();
      } else if (isHarmony) {
        rawBody = rawBody.substring(3).trim();
      }
      final lyricText = LyricVersionMatcher.stripInlineWordTags(rawBody).trim();
      if (lyricText.isEmpty) continue;

      for (final match in timeMatches) {
        final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
        final mins = int.tryParse(match.group(2) ?? '0') ?? 0;
        final secs = int.tryParse(match.group(3) ?? '0') ?? 0;
        final fracRaw = match.group(4) ?? '0';
        final fracSeconds = switch (fracRaw.length) {
          1 => (int.tryParse(fracRaw) ?? 0) / 10.0,
          2 => (int.tryParse(fracRaw) ?? 0) / 100.0,
          _ =>
            (int.tryParse(fracRaw.padRight(3, '0').substring(0, 3)) ?? 0) /
                1000.0,
        };
        final baseTime = hours * 3600.0 + mins * 60.0 + secs + fracSeconds;
        rawEntries.add((
          timeSeconds: baseTime,
          text: lyricText,
          rawBody: rawBody,
          isRomaji: isRomaji,
          isHarmony: isHarmony,
        ));
      }
    }

    if (rawEntries.isEmpty) {
      return LrcDocument(
        title: title,
        artist: artist,
        album: album,
        offsetMillis: offsetMillis,
        lines: const [],
      );
    }

    final offsetSeconds = offsetMillis / 1000.0;
    final romajiEntries = <CueTimedLyricEntry>[];
    final harmonyEntries = <({double timeSeconds, List<TimedLyricSpan> spans})>[];
    final bodyEntries = <CueTimedLyricEntry>[];
    for (final e in rawEntries) {
      final t = (e.timeSeconds - offsetSeconds) < 0
          ? 0.0
          : (e.timeSeconds - offsetSeconds);
      if (e.isRomaji) {
        romajiEntries.add(CueTimedLyricEntry(timeSeconds: t, text: e.text));
      } else if (e.isHarmony) {
        final spans = LyricVersionMatcher.parseInlineWordSpans(
          e.rawBody,
          lineStart: t,
          isHarmony: true,
          offsetSeconds: offsetSeconds,
        );
        harmonyEntries.add((timeSeconds: t, spans: spans));
      } else {
        bodyEntries.add(
          CueTimedLyricEntry(timeSeconds: t, text: e.text, rawBody: e.rawBody),
        );
      }
    }

    if (bodyEntries.isEmpty && harmonyEntries.isEmpty) {
      return LrcDocument(
        title: title,
        artist: artist,
        album: album,
        offsetMillis: offsetMillis,
        lines: const [],
      );
    }

    // 检测是否属于“前半段全文原文 + 后半段全文译文”的分块拼接形态（存在明显单次时间回卷）。
    final splitIndex = _detectTwoBlockTrackSplit(bodyEntries);
    final List<LrcCueLine> grouped;
    if (splitIndex != null) {
      final firstTrack = _collapseExactSlot(bodyEntries.sublist(0, splitIndex));
      final secondTrack = _collapseExactSlot(bodyEntries.sublist(splitIndex));
      final aligned = CueLyricAlignmentHelper.alignTrackWithDp(firstTrack, secondTrack);
      grouped = <LrcCueLine>[];
      for (var i = 0; i < firstTrack.length; i++) {
        final primary = firstTrack[i];
        final primaryWords = _extractLeadWords(
          primary,
          offsetSeconds: offsetSeconds,
        );
        final paired = aligned[i]?.trim();
        final sameAsPrimary =
            paired == null ||
            paired.isEmpty ||
            _normalizeDupKey(paired) == _normalizeDupKey(primary.text);
        if (sameAsPrimary) {
          grouped.add(
            LrcCueLine(
              startSeconds: primary.timeSeconds,
              primaryText: primary.text,
              words: primaryWords,
            ),
          );
        } else if (primaryWords.isEmpty &&
            _isLikelyOriginalOverChineseTranslation(paired, primary.text)) {
          grouped.add(
            LrcCueLine(
              startSeconds: primary.timeSeconds,
              primaryText: paired,
              secondaryLines: [primary.text],
            ),
          );
        } else {
          grouped.add(
            LrcCueLine(
              startSeconds: primary.timeSeconds,
              primaryText: primary.text,
              secondaryLines: [paired],
              words: primaryWords,
            ),
          );
        }
      }
    } else {
      grouped = _groupInterleavedLines(
        bodyEntries,
        offsetSeconds: offsetSeconds,
      );
    }

    // 挂载 `bg:` 和声片段至对应时间槽的主唱行；若该槽仅存在和声则独立成行。
    if (harmonyEntries.isNotEmpty) {
      harmonyEntries.sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
      for (final h in harmonyEntries) {
        var bestIdx = -1;
        var bestDelta = CueLyricAlignmentHelper.tightMatchToleranceSeconds;
        for (var i = 0; i < grouped.length; i++) {
          final dt = (grouped[i].startSeconds - h.timeSeconds).abs();
          if (dt <= bestDelta) {
            bestDelta = dt;
            bestIdx = i;
          }
        }
        if (bestIdx >= 0) {
          final target = grouped[bestIdx];
          grouped[bestIdx] = target.copyWith(
            harmonyWords: List<TimedLyricSpan>.unmodifiable([
              ...target.harmonyWords,
              ...h.spans,
            ]),
          );
        } else {
          final plain = h.spans.map((s) => s.text).join().trim();
          grouped.add(
            LrcCueLine(
              startSeconds: h.timeSeconds,
              primaryText: plain,
              harmonyWords: List<TimedLyricSpan>.unmodifiable(h.spans),
            ),
          );
        }
      }
      grouped.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
    }

    // 通过 DP 将独立 `roma:` 罗马音行对齐挂载到对应行的 `romajiText` 字段。
    if (romajiEntries.isNotEmpty && grouped.isNotEmpty) {
      romajiEntries.sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
      final mainAnchors = [
        for (final g in grouped)
          CueTimedLyricEntry(timeSeconds: g.startSeconds, text: g.primaryText),
      ];
      final romaAligned = CueLyricAlignmentHelper.alignTrackWithDp(
        mainAnchors,
        romajiEntries,
      );
      for (final kv in romaAligned.entries) {
        final line = grouped[kv.key];
        final roma = kv.value.trim();
        if (roma.isNotEmpty &&
            _normalizeDupKey(roma) != _normalizeDupKey(line.primaryText)) {
          grouped[kv.key] = line.copyWith(romajiText: roma);
        }
      }
    }

    final finalized = <LrcCueLine>[];
    for (var i = 0; i < grouped.length; i++) {
      final nextStart = i + 1 < grouped.length
          ? grouped[i + 1].startSeconds
          : null;
      finalized.add(grouped[i].copyWith(endSeconds: nextStart));
    }

    final isJapaneseSong = MoraPaceEstimator.detectJapaneseSong(
      finalized.map((l) => l.primaryText),
    );
    final secondsPerMora = MoraPaceEstimator.estimateSongSecondsPerMora([
      for (final l in finalized)
        (
          startSeconds: l.startSeconds,
          primaryText: l.primaryText,
          romajiText: l.romajiText,
        ),
    ], isJapaneseSong: isJapaneseSong);
    final estimatedSecondsPerChar = LrcDocument.computeEstimatedSecondsPerChar(
      finalized,
    );

    return LrcDocument(
      title: title,
      artist: artist,
      album: album,
      offsetMillis: offsetMillis,
      lines: finalized,
      estimatedSecondsPerChar: estimatedSecondsPerChar,
      secondsPerMora: secondsPerMora,
      isJapaneseSong: isJapaneseSong,
    );
  }

  static List<TimedLyricSpan> _extractLeadWords(
    CueTimedLyricEntry entry, {
    required double offsetSeconds,
  }) {
    if (!LyricVersionMatcher.hasInlineWordTags(entry.rawBody)) {
      return const <TimedLyricSpan>[];
    }
    return List<TimedLyricSpan>.unmodifiable(
      LyricVersionMatcher.parseInlineWordSpans(
        entry.rawBody,
        lineStart: entry.timeSeconds,
        isHarmony: false,
        offsetSeconds: offsetSeconds,
      ),
    );
  }

  static String _normalizeDupKey(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// 探测文本是否由两个完整的单调时间轴轨道前后拼接而成（如原文整段 + 译文整段）。
  static int? _detectTwoBlockTrackSplit(List<CueTimedLyricEntry> entries) {
    if (entries.length < 6) return null;
    int? dropIndex;
    for (var i = 1; i < entries.length; i++) {
      if (entries[i].timeSeconds + 5.0 < entries[i - 1].timeSeconds) {
        if (dropIndex != null) return null;
        dropIndex = i;
      }
    }
    if (dropIndex == null) return null;
    final leftCount = dropIndex;
    final rightCount = entries.length - dropIndex;
    if (leftCount < 3 || rightCount < 3) return null;
    // 确保第二段内部基本单调递增，避免把多时间戳复用的标准 LRC 误判为双轨。
    var rightDrops = 0;
    for (var i = dropIndex + 1; i < entries.length; i++) {
      if (entries[i].timeSeconds + 0.5 < entries[i - 1].timeSeconds) {
        rightDrops++;
      }
    }
    if (rightDrops > rightCount * 0.1) return null;
    return dropIndex;
  }

  static List<CueTimedLyricEntry> _collapseExactSlot(
    List<CueTimedLyricEntry> track,
  ) {
    final sorted = [...track]
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));
    final out = <CueTimedLyricEntry>[];
    for (final entry in sorted) {
      if (out.isNotEmpty &&
          (entry.timeSeconds - out.last.timeSeconds).abs() <= 0.05 &&
          _normalizeDupKey(entry.text) == _normalizeDupKey(out.last.text)) {
        continue;
      }
      out.add(entry);
    }
    return out;
  }

  /// 归并交错排列的双语行：同时间戳（<=50ms）直接聚合；<=150ms 且属于不同语种（原文+译文）时同步聚合，保留逐字片段。
  static List<LrcCueLine> _groupInterleavedLines(
    List<CueTimedLyricEntry> rawBody, {
    required double offsetSeconds,
  }) {
    final adjusted = [...rawBody]
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));

    const exactTolerance = 0.05;
    const crossLangTolerance = CueLyricAlignmentHelper.tightMatchToleranceSeconds;
    final grouped = <LrcCueLine>[];

    for (final entry in adjusted) {
      final entryWords = _extractLeadWords(
        entry,
        offsetSeconds: offsetSeconds,
      );
      if (grouped.isNotEmpty) {
        final prev = grouped.last;
        final dt = (entry.timeSeconds - prev.startSeconds).abs();
        final shouldMerge =
            dt <= exactTolerance ||
            (dt <= crossLangTolerance &&
                _isCrossLanguagePair(entry.text, prev.primaryText));
        if (shouldMerge) {
          final entryKey = _normalizeDupKey(entry.text);
          final prevPrimaryKey = _normalizeDupKey(prev.primaryText);
          final alreadyInSecondary = prev.secondaryLines.any(
            (s) => _normalizeDupKey(s) == entryKey,
          );
          if (entryKey == prevPrimaryKey) {
            if (prev.words.isEmpty && entryWords.isNotEmpty) {
              grouped[grouped.length - 1] = prev.copyWith(words: entryWords);
            }
          } else if (!alreadyInSecondary) {
            final upgradeAsLead =
                (entryWords.isNotEmpty && prev.words.isEmpty) ||
                (prev.words.isEmpty &&
                    _isLikelyOriginalOverChineseTranslation(
                      entry.text,
                      prev.primaryText,
                    ));
            if (upgradeAsLead) {
              grouped[grouped.length - 1] = prev.copyWith(
                primaryText: entry.text,
                secondaryLines: [prev.primaryText, ...prev.secondaryLines],
                words: entryWords.isNotEmpty ? entryWords : prev.words,
              );
            } else {
              grouped[grouped.length - 1] = prev.copyWith(
                secondaryLines: [...prev.secondaryLines, entry.text],
              );
            }
          }
          continue;
        }
      }
      grouped.add(
        LrcCueLine(
          startSeconds: entry.timeSeconds,
          primaryText: entry.text,
          words: entryWords,
        ),
      );
    }
    return grouped;
  }

  static bool _isCrossLanguagePair(String a, String b) {
    final aKana = _kanaRegex.hasMatch(a);
    final bKana = _kanaRegex.hasMatch(b);
    final aHan = _cjkHanRegex.hasMatch(a);
    final bHan = _cjkHanRegex.hasMatch(b);
    if (aKana != bKana && (aHan || bHan)) return true;
    final aLatin = RegExp(r'[A-Za-z]{3,}').hasMatch(a);
    final bLatin = RegExp(r'[A-Za-z]{3,}').hasMatch(b);
    if ((aLatin && !aHan && bHan && !bKana) ||
        (bLatin && !bHan && aHan && !aKana)) {
      return true;
    }
    return false;
  }
}

/// 扩展播放列表单条曲目输入条目（供无状态生成带 `#EXTINF` 的 `.m3u8` 文本）。
class ExtendedM3uTrackEntry {
  /// 创建扩展播放列表曲目条目。
  const ExtendedM3uTrackEntry({
    required this.targetUriOrPath,
    required this.title,
    this.performer = '',
    this.durationSeconds = -1,
  });

  /// 目标流地址或本地绝对路径。
  final String targetUriOrPath;

  /// 曲目展示标题。
  final String title;

  /// 演唱者或艺术家。
  final String performer;

  /// 曲目整秒时长（未知时传 `-1`）。
  final int durationSeconds;
}

/// 归一化 `.cue` 分轨清单与扩展 `.m3u8` 播放列表纯领域序列化器。
abstract final class CueSheetSerializer {
  /// UTF-8 字节顺序标记（供外部播放器如 `foobar2000` 强制按 UTF-8 解析日文/中文曲名，彻底避免系统 ANSI 代码页乱码）。
  static const List<int> utf8BomBytes = <int>[0xEF, 0xBB, 0xBF];

  /// 生成已修正真实 `FILE` 引用且保留精确整数光盘扇区（`1/75 s`）的标准 `.cue` 文本。
  static String buildNormalizedCueText({
    required CueSheet sheet,
    required Map<int, String> resolvedFileByTrackNumber,
    String fallbackAlbumTitle = '',
    String fallbackAlbumPerformer = '',
  }) {
    final buf = StringBuffer();
    final albumPerformer = sheet.performer.trim().isNotEmpty
        ? sheet.performer.trim()
        : fallbackAlbumPerformer.trim();
    final albumTitle = sheet.title.trim().isNotEmpty
        ? sheet.title.trim()
        : fallbackAlbumTitle.trim();

    if (albumPerformer.isNotEmpty) {
      buf.writeln('PERFORMER "${_escapeCueQuoted(albumPerformer)}"');
    }
    if (albumTitle.isNotEmpty) {
      buf.writeln('TITLE "${_escapeCueQuoted(albumTitle)}"');
    }

    var activeFileRef = '';
    for (final track in sheet.tracks) {
      final targetFile =
          (resolvedFileByTrackNumber[track.trackNumber] ?? track.fileName)
              .trim();
      if (targetFile.isEmpty) continue;
      if (targetFile != activeFileRef) {
        activeFileRef = targetFile;
        buf.writeln('FILE "${_escapeCueQuoted(activeFileRef)}" WAVE');
      }
      final trackNo = track.trackNumber.clamp(1, 99).toString().padLeft(2, '0');
      buf.writeln('  TRACK $trackNo AUDIO');
      final trackTitle = track.title.trim().isNotEmpty
          ? track.title.trim()
          : 'Track $trackNo';
      buf.writeln('    TITLE "${_escapeCueQuoted(trackTitle)}"');
      final trackPerformer = track.performer.trim().isNotEmpty
          ? track.performer.trim()
          : albumPerformer;
      if (trackPerformer.isNotEmpty) {
        buf.writeln('    PERFORMER "${_escapeCueQuoted(trackPerformer)}"');
      }
      final pregap = track.pregapIndex00SectorFrames;
      if (pregap != null && pregap >= 0 && pregap <= track.startSectorFrames) {
        buf.writeln('    INDEX 00 ${_formatSectorTimestamp(pregap)}');
      }
      buf.writeln(
        '    INDEX 01 ${_formatSectorTimestamp(track.startSectorFrames)}',
      );
    }
    return buf.toString();
  }

  /// 将归一化 `.cue` 文本编码为带 UTF-8 BOM 的字节数组。
  static Uint8List encodeCueWithUtf8Bom(String cueText) {
    final body = List<int>.from(cueText.codeUnits.isEmpty ? const <int>[] : _utf8Encode(cueText));
    final out = Uint8List(utf8BomBytes.length + body.length);
    out.setRange(0, utf8BomBytes.length, utf8BomBytes);
    out.setRange(utf8BomBytes.length, out.length, body);
    return out;
  }

  /// 生成包含 `#EXTINF` 标题与时长元数据的 `.m3u8` 播放列表文本（防止外部播放器后台并发扫描全部 WebDAV 远程流触发风控）。
  static String buildExtendedM3u8Text(Iterable<ExtendedM3uTrackEntry> entries) {
    final buf = StringBuffer('#EXTM3U\r\n');
    for (final entry in entries) {
      final target = entry.targetUriOrPath.trim();
      if (target.isEmpty) continue;
      final dur = entry.durationSeconds > 0 ? entry.durationSeconds : -1;
      final cleanTitle = _sanitizeSingleLine(entry.title);
      final cleanPerformer = _sanitizeSingleLine(entry.performer);
      final display = cleanPerformer.isNotEmpty
          ? '$cleanPerformer - $cleanTitle'
          : cleanTitle;
      buf.writeln('#EXTINF:$dur,$display\r');
      buf.writeln('$target\r');
    }
    return buf.toString();
  }

  static String _formatSectorTimestamp(int sectorFrames) {
    final safe = sectorFrames < 0 ? 0 : sectorFrames;
    final totalSeconds = safe ~/ CueTrack.sectorsPerSecond;
    final frames = safe % CueTrack.sectorsPerSecond;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    final ff = frames.toString().padLeft(2, '0');
    return '$mm:$ss:$ff';
  }

  static String _escapeCueQuoted(String raw) {
    return raw
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll('"', "'")
        .trim();
  }

  static String _sanitizeSingleLine(String raw) {
    return raw.replaceAll('\r', ' ').replaceAll('\n', ' ').trim();
  }

  static List<int> _utf8Encode(String input) {
    final bytes = <int>[];
    for (final rune in input.runes) {
      if (rune <= 0x7F) {
        bytes.add(rune);
      } else if (rune <= 0x7FF) {
        bytes.add(0xC0 | ((rune >> 6) & 0x1F));
        bytes.add(0x80 | (rune & 0x3F));
      } else if (rune <= 0xFFFF) {
        bytes.add(0xE0 | ((rune >> 12) & 0x0F));
        bytes.add(0x80 | ((rune >> 6) & 0x3F));
        bytes.add(0x80 | (rune & 0x3F));
      } else {
        bytes.add(0xF0 | ((rune >> 18) & 0x07));
        bytes.add(0x80 | ((rune >> 12) & 0x3F));
        bytes.add(0x80 | ((rune >> 6) & 0x3F));
        bytes.add(0x80 | (rune & 0x3F));
      }
    }
    return bytes;
  }
}
