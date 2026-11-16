import 'dart:convert';
import 'dart:typed_data';

/// 传统东亚多字节文本编码类型（面向日文与中文 BD CUE / LRC）。
enum LegacyTextEncoding {
  /// 日文 Shift-JIS / CP932。
  shiftJis,

  /// 简体中文 GBK / CP936。
  gbk,
}

/// 可选外部代码页解码桥接签名（由基础设施层按需注入 Win32 CP932/CP936 解码器）。
typedef LegacyCodePageDecoder =
    String? Function(List<int> bytes, LegacyTextEncoding encoding);

/// CUE 虚拟音轨实体（带 `[startSeconds, endSeconds]` 精确切片区间）。
class CueTrack {
  /// 创建 CUE 分轨条目。
  const CueTrack({
    required this.trackNumber,
    required this.title,
    this.performer = '',
    this.fileName = '',
    required this.startSeconds,
    this.endSeconds,
    this.pregapIndex00Seconds,
  });

  /// 音轨编号（1..99）。
  final int trackNumber;

  /// 曲目标题。
  final String title;

  /// 单曲演唱者或艺术家。
  final String performer;

  /// 对应的物理音频文件名（`FILE "..."` 声明）。
  final String fileName;

  /// `INDEX 01` 起始秒数。
  final double startSeconds;

  /// 下一曲 `INDEX 01` 起始时间或音频总时长推算的结束秒数（若可确定）。
  final double? endSeconds;

  /// 可选 `INDEX 00` 间奏前隙起始秒数。
  final double? pregapIndex00Seconds;

  /// 当前分轨时长（秒）。
  double? get durationSeconds {
    if (endSeconds == null) return null;
    final diff = endSeconds! - startSeconds;
    return diff > 0 ? diff : 0.0;
  }
}

/// 解析后的 CUE 整轨分轨清单。
class CueSheet {
  /// 创建 CUE 分轨清单。
  const CueSheet({
    this.title = '',
    this.performer = '',
    required this.tracks,
  });

  /// 专辑标题。
  final String title;

  /// 专辑艺术家。
  final String performer;

  /// 分轨列表（已按轨号与起始时间规范化）。
  final List<CueTrack> tracks;
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

  /// 触发起始时间（秒，已叠加 `[offset:]` 并校准 >= 0）。
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

  /// 全局时间偏移（毫秒，正值延后、负值提前）。
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
}

/// 纯 Dart 多编码探测与解码器（UTF-8 / UTF-16LE / UTF-16BE / Shift-JIS / GBK）。
class PlaybackTextDecoder {
  PlaybackTextDecoder._();

  /// 将原始字节解码为字符串；遇到非 UTF-8 字节时识别 Shift-JIS 与 GBK。
  static String decodeBytes(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    if (bytes.isEmpty) return '';

    // 1. BOM 优先判定
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _decodeUtf16(bytes.sublist(2), littleEndian: false);
    }

    // 2. 严格 UTF-8 尝试
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {}

    // 3. 启发式区分 Shift-JIS 与 GBK
    final encoding = detectLegacyEncoding(bytes);
    if (legacyDecoder != null) {
      final decoded = legacyDecoder(bytes, encoding);
      if (decoded != null && decoded.isNotEmpty) {
        return decoded;
      }
    }

    if (encoding == LegacyTextEncoding.shiftJis) {
      return _decodeShiftJisPureDart(bytes);
    }
    return _decodeGbkFallbackPureDart(bytes);
  }

  /// 基于字节文法统计判断传统文本偏向 Shift-JIS 还是 GBK。
  static LegacyTextEncoding detectLegacyEncoding(List<int> bytes) {
    var sjisHits = 0;
    var sjisExclusiveHits = 0;
    var gbkHits = 0;

    for (var i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b < 0x80) continue;

      // 半角片假名 (0xA1..0xDF)
      if (b >= 0xA1 && b <= 0xDF && i + 1 < bytes.length) {
        final next = bytes[i + 1];
        if (next < 0x80 || (next >= 0xA1 && next <= 0xDF)) {
          sjisExclusiveHits += 2;
          sjisHits += 2;
          continue;
        }
      }

      // Shift-JIS 首字节独占区间 0x81..0x9F（后接 0x40..0x7E 或 0x80..0xFC）
      if ((b >= 0x81 && b <= 0x9F) && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC)) {
          sjisExclusiveHits += 3;
          sjisHits += 3;
          // 高频平假名/片假名段 (0x82 / 0x83) 权重更高
          if (b == 0x82 || b == 0x83) {
            sjisExclusiveHits += 4;
          }
          i++;
          continue;
        }
      }

      if ((b >= 0xE0 && b <= 0xEF) && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if ((b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC)) {
          sjisHits += 1;
        }
      }

      // GBK 典型双高字节汉字区 (0xB0..0xF7 + 0xA1..0xFE)
      if ((b >= 0xA1 && b <= 0xF7) && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        if (b2 >= 0xA1 && b2 <= 0xFE) {
          gbkHits += (b >= 0xB0) ? 3 : 1;
          i++;
          continue;
        }
      }
    }

    if (sjisExclusiveHits > 0 && sjisHits + sjisExclusiveHits >= gbkHits) {
      return LegacyTextEncoding.shiftJis;
    }
    return gbkHits > sjisHits
        ? LegacyTextEncoding.gbk
        : LegacyTextEncoding.shiftJis;
  }

  static String _decodeUtf16(List<int> bytes, {required bool littleEndian}) {
    final codeUnits = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final lo = littleEndian ? bytes[i] : bytes[i + 1];
      final hi = littleEndian ? bytes[i + 1] : bytes[i];
      codeUnits.add((hi << 8) | lo);
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _decodeShiftJisPureDart(List<int> bytes) {
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final b1 = bytes[i];
      if (b1 < 0x80) {
        out.writeCharCode(b1);
        continue;
      }
      // 半角片假名 0xA1..0xDF -> U+FF61..U+FF9F
      if (b1 >= 0xA1 && b1 <= 0xDF) {
        out.writeCharCode(0xFF61 + (b1 - 0xA1));
        continue;
      }
      if (((b1 >= 0x81 && b1 <= 0x9F) || (b1 >= 0xE0 && b1 <= 0xFC)) &&
          i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        i++;
        final mapped = _mapShiftJisKanaOrSymbol(b1, b2);
        if (mapped != null) {
          out.writeCharCode(mapped);
        } else {
          out.write('\uFFFD');
        }
        continue;
      }
      out.write('\uFFFD');
    }
    return out.toString();
  }

  static int? _mapShiftJisKanaOrSymbol(int b1, int b2) {
    if (b1 == 0x81) {
      return switch (b2) {
        0x40 => 0x3000, // 全角空格
        0x41 => 0x3001, // 、
        0x42 => 0x3002, // 。
        0x43 => 0xFF0C, // ，
        0x44 => 0xFF0E, // ．
        0x45 => 0x30FB, // ・
        0x46 => 0xFF1A, // ：
        0x47 => 0xFF1B, // ；
        0x48 => 0xFF1F, // ？
        0x49 => 0xFF01, // ！
        0x5B => 0x30FC, // ー
        0x60 => 0x301C, // 〜
        0x69 => 0xFF08, // （
        0x6A => 0xFF09, // ）
        0x75 => 0x300C, // 「
        0x76 => 0x300D, // 」
        0x77 => 0x300E, // 『
        0x78 => 0x300F, // 』
        _ => null,
      };
    }
    // 平假名 0x829F..0x82F1 -> U+3041..U+3093
    if (b1 == 0x82) {
      if (b2 >= 0x4F && b2 <= 0x58) return 0xFF10 + (b2 - 0x4F);
      if (b2 >= 0x60 && b2 <= 0x79) return 0xFF21 + (b2 - 0x60);
      if (b2 >= 0x81 && b2 <= 0x9A) return 0xFF41 + (b2 - 0x81);
      if (b2 >= 0x9F && b2 <= 0xF1) return 0x3041 + (b2 - 0x9F);
    }
    // 片假名 0x8340..0x8396（跳过 0x7F 间隙）-> U+30A1..U+30F6
    if (b1 == 0x83 && b2 >= 0x40 && b2 <= 0x96 && b2 != 0x7F) {
      final offset = b2 < 0x7F ? (b2 - 0x40) : (b2 - 0x41);
      return 0x30A1 + offset;
    }
    return null;
  }

  static String _decodeGbkFallbackPureDart(List<int> bytes) {
    final out = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      final b1 = bytes[i];
      if (b1 < 0x80) {
        out.writeCharCode(b1);
        continue;
      }
      if (b1 >= 0x81 && b1 <= 0xFE && i + 1 < bytes.length) {
        i++;
      }
      out.write('\uFFFD');
    }
    return out.toString();
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

  /// 从已解码文本解析 CUE 清单，并计算各分轨 `[startSeconds, endSeconds]` 区间。
  static CueSheet parseText(String content, {double? totalDurationSeconds}) {
    var albumTitle = '';
    var albumPerformer = '';
    var currentFile = '';

    int? currentTrackNum;
    var currentTrackTitle = '';
    var currentTrackPerformer = '';
    var currentTrackFile = '';
    double? currentIndex00;
    double? currentIndex01;

    final rawTracks = <_PendingCueTrack>[];

    void flushCurrentTrack() {
      if (currentTrackNum == null || currentIndex01 == null) return;
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
          startSeconds: currentIndex01,
          pregapIndex00Seconds: currentIndex00,
        ),
      );
    }

    for (final rawLine in content.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.toUpperCase().startsWith('REM ')) continue;

      final fileMatch = _fileRegex.firstMatch(line);
      if (fileMatch != null) {
        currentFile = (fileMatch.group(1) ?? fileMatch.group(2) ?? '').trim();
        continue;
      }

      final trackMatch = _trackRegex.firstMatch(line);
      if (trackMatch != null) {
        flushCurrentTrack();
        currentTrackNum = int.tryParse(trackMatch.group(1) ?? '');
        currentTrackTitle = '';
        currentTrackPerformer = '';
        currentTrackFile = currentFile;
        currentIndex00 = null;
        currentIndex01 = null;
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
        final seconds = mm * 60.0 + ss + (ff / 75.0);
        if (idxNum == 0) {
          currentIndex00 = seconds;
        } else if (idxNum == 1) {
          currentIndex01 = seconds;
        }
      }
    }
    flushCurrentTrack();

    final tracks = <CueTrack>[];
    for (var i = 0; i < rawTracks.length; i++) {
      final item = rawTracks[i];
      double? endSeconds;
      if (i + 1 < rawTracks.length && rawTracks[i + 1].fileName == item.fileName) {
        endSeconds = rawTracks[i + 1].pregapIndex00Seconds ??
            rawTracks[i + 1].startSeconds;
      } else if (totalDurationSeconds != null &&
          totalDurationSeconds.isFinite &&
          totalDurationSeconds > item.startSeconds) {
        endSeconds = totalDurationSeconds;
      }
      if (endSeconds != null && endSeconds < item.startSeconds) {
        endSeconds = item.startSeconds;
      }
      tracks.add(
        CueTrack(
          trackNumber: item.trackNumber,
          title: item.title,
          performer: item.performer,
          fileName: item.fileName,
          startSeconds: item.startSeconds,
          endSeconds: endSeconds,
          pregapIndex00Seconds: item.pregapIndex00Seconds,
        ),
      );
    }

    return CueSheet(
      title: albumTitle.trim(),
      performer: albumPerformer.trim(),
      tracks: tracks,
    );
  }
}

class _PendingCueTrack {
  const _PendingCueTrack({
    required this.trackNumber,
    required this.title,
    required this.performer,
    required this.fileName,
    required this.startSeconds,
    this.pregapIndex00Seconds,
  });

  final int trackNumber;
  final String title;
  final String performer;
  final String fileName;
  final double startSeconds;
  final double? pregapIndex00Seconds;
}

/// 纯 Dart LRC 同步歌词解析器（支持多时间戳复用与同时间戳多语种多行聚合）。
class LrcParser {
  LrcParser._();

  static final RegExp _timeTagRegex = RegExp(
    r'\[(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _metaTagRegex = RegExp(
    r'^\[([a-zA-Z]+):(.*)\]$',
  );

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

      final lyricText = line.replaceAll(_timeTagRegex, '').trim();
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
            timeSeconds: (e.timeSeconds + offsetSeconds) < 0
                ? 0.0
                : (e.timeSeconds + offsetSeconds),
            text: e.text,
          ),
        )
        .toList()
      ..sort((a, b) => a.timeSeconds.compareTo(b.timeSeconds));

    // 将同一时间戳（50ms 内）多行歌词聚合成主行 + 译文/注音附行
    const groupTolerance = 0.05;
    final grouped = <LrcCueLine>[];
    for (final entry in adjusted) {
      if (grouped.isNotEmpty &&
          (entry.timeSeconds - grouped.last.startSeconds).abs() <=
              groupTolerance) {
        final prev = grouped.last;
        if (entry.text != prev.primaryText &&
            !prev.secondaryLines.contains(entry.text)) {
          grouped[grouped.length - 1] = LrcCueLine(
            startSeconds: prev.startSeconds,
            primaryText: prev.primaryText,
            secondaryLines: [...prev.secondaryLines, entry.text],
          );
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
