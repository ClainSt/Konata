import 'dart:typed_data';

import '../text/multibyte_text_decoder.dart';

export '../text/multibyte_text_decoder.dart'
    show
        DetectedTextCharset,
        DecodedTextResult,
        LegacyCodePageDecoder,
        LegacyTextEncoding,
        MultibyteTextDecoder;

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
