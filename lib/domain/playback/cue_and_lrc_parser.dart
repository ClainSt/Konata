import 'dart:typed_data';

import '../text/multibyte_text_decoder.dart';

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

/// 同时间戳聚合的多行歌词条目（支持日文原文 + 罗马音 + 中文翻译多语种同步展示）。
class LrcCueLine {
  /// 创建聚合歌词行。
  const LrcCueLine({
    required this.startSeconds,
    this.endSeconds,
    required this.primaryText,
    this.secondaryLines = const [],
  });

  /// 触发起始时间（秒，已按 `[offset:]` 校正并钳制 >= 0）。
  final double startSeconds;

  /// 结束时间（由下一行触发时间推导，末行可为空）。
  final double? endSeconds;

  /// 主行文本（同时间戳首行原文）。
  final String primaryText;

  /// 附加翻译或注音行文本列表。
  final List<String> secondaryLines;

  /// 复制并补充结束时间。
  LrcCueLine copyWith({double? endSeconds}) {
    return LrcCueLine(
      startSeconds: startSeconds,
      endSeconds: endSeconds ?? this.endSeconds,
      primaryText: primaryText,
      secondaryLines: secondaryLines,
    );
  }
}

/// 解析后的 LRC 同步歌词文档。
class LrcDocument {
  /// 创建 LRC 文档对象。
  const LrcDocument({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.offsetMillis = 0,
    required this.lines,
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

  /// 基于当前曲目正常相邻句的中位语速估算每字平均演唱秒数（剔除极短句与间奏长停顿）。
  ///
  /// 用于行级 LRC 遇到副歌后长间奏或末句时自动适配快慢歌节奏，避免扫白滞后或提前卡住。
  double get estimatedSecondsPerChar {
    final samples = <double>[];
    for (var i = 0; i + 1 < lines.length; i++) {
      final cur = lines[i];
      final next = lines[i + 1];
      final gap = next.startSeconds - cur.startSeconds;
      if (gap < 0.8 || gap > 8.0) continue;
      final charCount = cur.primaryText
          .replaceAll(RegExp(r'\s+'), '')
          .runes
          .length;
      if (charCount < 3) continue;
      final pace = gap / charCount;
      if (pace >= 0.08 && pace <= 0.65) {
        samples.add(pace);
      }
    }
    if (samples.length < 2) {
      return 0.24;
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
  static final RegExp _inlineWordTagRegex = RegExp(
    r'<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>',
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

  /// 从文本解析 LRC 文档，按时间戳排序并合并同时间戳（<=50ms）的原文/翻译多行。
  static LrcDocument parseText(String content) {
    var title = '';
    var artist = '';
    var album = '';
    var offsetMillis = 0;

    final entries = <({double timeSeconds, String text})>[];

    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
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

      final lyricText = line
          .replaceAll(_timeTagRegex, '')
          .replaceAll(_inlineWordTagRegex, '')
          .trim();
      if (lyricText.isEmpty) continue;

      for (final match in timeMatches) {
        final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
        final mins = int.tryParse(match.group(2) ?? '0') ?? 0;
        final secs = int.tryParse(match.group(3) ?? '0') ?? 0;
        final fracRaw = match.group(4) ?? '0';
        final fracSeconds = switch (fracRaw.length) {
          1 => (int.tryParse(fracRaw) ?? 0) / 10.0,
          2 => (int.tryParse(fracRaw) ?? 0) / 100.0,
          _ => (int.tryParse(fracRaw.padRight(3, '0').substring(0, 3)) ?? 0) /
              1000.0,
        };
        final baseTime = hours * 3600.0 + mins * 60.0 + secs + fracSeconds;
        entries.add((timeSeconds: baseTime, text: lyricText));
      }
    }

    if (entries.isEmpty) {
      return LrcDocument(
        title: title,
        artist: artist,
        album: album,
        offsetMillis: offsetMillis,
        lines: const [],
      );
    }

    final offsetSeconds = offsetMillis / 1000.0;
    final adjusted = entries
        .map(
          (e) => (
            timeSeconds: (e.timeSeconds - offsetSeconds) < 0
                ? 0.0
                : (e.timeSeconds - offsetSeconds),
            text: e.text,
          ),
        )
        .toList()
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));

    // 将同一时间戳（50ms 内）多行歌词聚合成主行 + 译文/注音附行，并保证日文原文稳居主行、中文译文居副行。
    const groupTolerance = 0.05;
    final grouped = <LrcCueLine>[];
    String normalizeDupKey(String text) =>
        text.trim().replaceAll(RegExp(r'\s+'), ' ');
    for (final entry in adjusted) {
      if (grouped.isNotEmpty &&
          (entry.timeSeconds - grouped.last.startSeconds).abs() <=
              groupTolerance) {
        final prev = grouped.last;
        final entryKey = normalizeDupKey(entry.text);
        final prevPrimaryKey = normalizeDupKey(prev.primaryText);
        final alreadyInSecondary = prev.secondaryLines.any(
          (s) => normalizeDupKey(s) == entryKey,
        );
        if (entryKey != prevPrimaryKey && !alreadyInSecondary) {
          if (_isLikelyOriginalOverChineseTranslation(
            entry.text,
            prev.primaryText,
          )) {
            grouped[grouped.length - 1] = LrcCueLine(
              startSeconds: prev.startSeconds,
              primaryText: entry.text,
              secondaryLines: [prev.primaryText, ...prev.secondaryLines],
            );
          } else {
            grouped[grouped.length - 1] = LrcCueLine(
              startSeconds: prev.startSeconds,
              primaryText: prev.primaryText,
              secondaryLines: [...prev.secondaryLines, entry.text],
            );
          }
        }
      } else {
        grouped.add(
          LrcCueLine(
            startSeconds: entry.timeSeconds,
            primaryText: entry.text,
          ),
        );
      }
    }

    final finalized = <LrcCueLine>[];
    for (var i = 0; i < grouped.length; i++) {
      final nextStart = i + 1 < grouped.length ? grouped[i + 1].startSeconds : null;
      finalized.add(grouped[i].copyWith(endSeconds: nextStart));
    }

    return LrcDocument(
      title: title,
      artist: artist,
      album: album,
      offsetMillis: offsetMillis,
      lines: finalized,
    );
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
