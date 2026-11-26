import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/playback/lyric_version_matcher.dart';
import '../../domain/text/legacy_codepage_tables.dart';

/// 从音频容器头部字节中内存解析出的内嵌专辑封面数据（零全量落盘）。
class ExtractedAudioResources {
  const ExtractedAudioResources({
    this.embeddedCoverBytes,
    this.folderCoverBytes,
    this.cueSheet,
    this.lrcDocument,
  });

  /// 优先级 1：音轨内嵌 FLAC `PICTURE` 或 ID3v2 `APIC` 封面。
  final Uint8List? embeddedCoverBytes;

  /// 优先级 2：CD 同目录封面图字节（`cover/folder/front/booklet`）。
  final Uint8List? folderCoverBytes;

  /// 若源为 `.cue` 或存在同曲名 `.cue`，对应的分轨清单。
  final CueSheet? cueSheet;

  /// 匹配的 LRC 同步歌词文档。
  final LrcDocument? lrcDocument;
}

/// 纯内存音频内嵌封面解析与 CD `.cue`/`.lrc` 加载工具（严格流式定额读头部，原文件零落盘）。
class AudioAssetExtractor {
  AudioAssetExtractor._();

  /// 从音乐文件前缀字节（仅需头部 metadata 块，典型 <= 1.5 MiB）提取内嵌封面图字节。
  ///
  /// 支持：
  /// - **FLAC (`fLaC`)**：解析 Metadata Block Type 6 (`PICTURE`)；
  /// - **ID3v2 (`ID3` v2.2 / v2.3 / v2.4)**：解析 `APIC` 与 `PIC` 图片帧。
  static Uint8List? extractEmbeddedCoverFromHeaderBytes(Uint8List bytes) {
    if (bytes.length < 16) return null;
    if (bytes[0] == 0x66 &&
        bytes[1] == 0x4C &&
        bytes[2] == 0x61 &&
        bytes[3] == 0x43) {
      return _extractFlacPicture(bytes);
    }
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return _extractId3v2Picture(bytes);
    }
    return null;
  }

  static final RegExp _lrcTimestampProbe = RegExp(
    r'\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]',
  );

  /// 从音乐文件前缀字节提取内嵌歌词标签文本（优先带时间戳的同步歌词，其次纯文本歌词）。
  ///
  /// 支持：
  /// - **FLAC (`fLaC`)**：解析 Metadata Block Type 4 (`VORBIS_COMMENT`) 中的 `LYRICS`、`SYNCEDLYRICS`、`UNSYNCEDLYRICS`；
  /// - **ID3v2 (`ID3` v2.2 / v2.3 / v2.4)**：解析 `USLT` / `ULT` 与自定义 `TXXX`（描述为 `LYRICS` / `UNSYNCEDLYRICS`）。
  static String? extractEmbeddedLyricsFromHeaderBytes(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    if (bytes.length < 16) return null;
    if (bytes[0] == 0x66 &&
        bytes[1] == 0x4C &&
        bytes[2] == 0x61 &&
        bytes[3] == 0x43) {
      return _extractFlacVorbisLyrics(bytes);
    }
    if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
      return _extractId3v2Lyrics(bytes, legacyDecoder: legacyDecoder);
    }
    return null;
  }

  /// 从同一批头部字节中同时提取内嵌封面与内嵌歌词，避免重复解析或重复读取文件头部。
  static ({Uint8List? cover, String? lyrics})
  extractEmbeddedHeaderAssetsFromBytes(
    Uint8List bytes, {
    bool probeCover = true,
    bool probeLyrics = true,
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    return (
      cover: probeCover ? extractEmbeddedCoverFromHeaderBytes(bytes) : null,
      lyrics: probeLyrics
          ? extractEmbeddedLyricsFromHeaderBytes(
              bytes,
              legacyDecoder: legacyDecoder,
            )
          : null,
    );
  }

  static String? _extractFlacVorbisLyrics(Uint8List bytes) {
    var offset = 4;
    String? syncedBest;
    String? lyricsTag;
    String? unsyncedTag;

    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final isLast = (header & 0x80) != 0;
      final blockType = header & 0x7F;
      final length =
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      offset += 4;
      if (length <= 0 || offset + length > bytes.length) break;
      if (blockType == 4) {
        final block = Uint8List.sublistView(bytes, offset, offset + length);
        final found = _parseFlacVorbisCommentLyrics(block);
        if (found.synced != null) syncedBest ??= found.synced;
        if (found.lyrics != null) lyricsTag ??= found.lyrics;
        if (found.unsynced != null) unsyncedTag ??= found.unsynced;
      }
      offset += length;
      if (isLast) break;
    }
    return syncedBest ?? lyricsTag ?? unsyncedTag;
  }

  static ({String? synced, String? lyrics, String? unsynced})
  _parseFlacVorbisCommentLyrics(Uint8List block) {
    if (block.length < 8) return (synced: null, lyrics: null, unsynced: null);
    final vendorLen = _readUint32Le(block, 0);
    var cursor = 4 + vendorLen;
    if (cursor < 4 || cursor + 4 > block.length) {
      return (synced: null, lyrics: null, unsynced: null);
    }
    final count = _readUint32Le(block, cursor);
    cursor += 4;

    String? synced;
    String? lyrics;
    String? unsynced;
    for (var i = 0; i < count && cursor + 4 <= block.length; i++) {
      final len = _readUint32Le(block, cursor);
      cursor += 4;
      if (len <= 0 || cursor + len > block.length) break;
      final raw = utf8.decode(
        Uint8List.sublistView(block, cursor, cursor + len),
        allowMalformed: true,
      );
      cursor += len;
      final eq = raw.indexOf('=');
      if (eq <= 0) continue;
      final key = raw.substring(0, eq).trim().toUpperCase();
      final value = raw.substring(eq + 1).trim();
      if (value.isEmpty) continue;
      final isLyricKey =
          key == 'LYRICS' ||
          key == 'SYNCEDLYRICS' ||
          key == 'UNSYNCEDLYRICS' ||
          key == 'UNSYNCED LYRICS';
      if (!isLyricKey) continue;
      if (_lrcTimestampProbe.hasMatch(value)) {
        synced ??= value;
      } else if (key == 'LYRICS' || key == 'SYNCEDLYRICS') {
        lyrics ??= value;
      } else {
        unsynced ??= value;
      }
    }
    return (synced: synced, lyrics: lyrics, unsynced: unsynced);
  }

  /// 通用 ID3v2 帧遍历器（兼容 v2.2/v2.3/v2.4 扩展头与帧头长度），回调返回 `true` 时提前终止。
  static void _walkId3v2Frames(
    Uint8List bytes,
    bool Function({
      required int majorVersion,
      required String frameId,
      required int frameFlags2,
      required int dataOffset,
      required int frameSize,
    })
    onFrame,
  ) {
    if (bytes.length < 10) return;
    final majorVersion = bytes[3];
    final flags = bytes[5];
    final tagSize = _readSyncSafeInt(bytes, 6);
    var offset = 10;
    if ((flags & 0x40) != 0 && offset + 4 <= bytes.length) {
      final extSize = majorVersion >= 4
          ? _readSyncSafeInt(bytes, offset)
          : _readUint32Be(bytes, offset);
      offset += extSize + (majorVersion >= 4 ? 0 : 4);
    }
    final tagEnd = (10 + tagSize) <= bytes.length
        ? (10 + tagSize)
        : bytes.length;

    while (offset + (majorVersion == 2 ? 6 : 10) <= tagEnd) {
      if (bytes[offset] == 0) break;
      final String frameId;
      final int frameSize;
      final int headerLen;
      var frameFlags2 = 0;
      if (majorVersion == 2) {
        frameId = String.fromCharCodes(bytes.sublist(offset, offset + 3));
        frameSize =
            (bytes[offset + 3] << 16) |
            (bytes[offset + 4] << 8) |
            bytes[offset + 5];
        headerLen = 6;
      } else {
        frameId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
        frameSize = majorVersion >= 4
            ? _readSyncSafeInt(bytes, offset + 4)
            : _readUint32Be(bytes, offset + 4);
        frameFlags2 = bytes[offset + 9];
        headerLen = 10;
      }
      offset += headerLen;
      if (frameSize <= 0 || offset + frameSize > tagEnd) break;
      if (onFrame(
        majorVersion: majorVersion,
        frameId: frameId,
        frameFlags2: frameFlags2,
        dataOffset: offset,
        frameSize: frameSize,
      )) {
        break;
      }
      offset += frameSize;
    }
  }

  static String? _extractId3v2Lyrics(
    Uint8List bytes, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    String? syncedBest;
    String? plainBest;

    _walkId3v2Frames(bytes, ({
      required int majorVersion,
      required String frameId,
      required int frameFlags2,
      required int dataOffset,
      required int frameSize,
    }) {
      if (frameId != 'USLT' && frameId != 'ULT' && frameId != 'TXXX') {
        return false;
      }
      var payloadStart = dataOffset;
      // ID3v2.4 若开启数据长度指示标志，帧负载开头多出 4 字节同步安全整数。
      if (majorVersion >= 4 && (frameFlags2 & 0x01) != 0) {
        payloadStart += 4;
      }
      if (payloadStart < dataOffset + frameSize) {
        final frameData = Uint8List.sublistView(
          bytes,
          payloadStart,
          dataOffset + frameSize,
        );
        final text = frameId == 'TXXX'
            ? _parseId3TxxxLyrics(frameData, legacyDecoder: legacyDecoder)
            : _parseId3UsltPayload(frameData, legacyDecoder: legacyDecoder);
        if (text != null && text.trim().isNotEmpty) {
          final trimmed = text.trim();
          if (_lrcTimestampProbe.hasMatch(trimmed)) {
            syncedBest ??= trimmed;
          } else {
            plainBest ??= trimmed;
          }
        }
      }
      return false;
    });
    return syncedBest ?? plainBest;
  }

  static String? _parseId3UsltPayload(
    Uint8List frame, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    if (frame.length < 5) return null;
    final encoding = frame[0];
    // 跳过 3 字节语言码，再跳过按编码终止的描述文本。
    var cursor = 4;
    cursor = _skipId3EncodedString(frame, cursor, encoding);
    if (cursor >= frame.length) return null;
    return _decodeId3StringBytes(
      Uint8List.sublistView(frame, cursor),
      encoding,
      legacyDecoder: legacyDecoder,
    );
  }

  static String? _parseId3TxxxLyrics(
    Uint8List frame, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    if (frame.length < 3) return null;
    final encoding = frame[0];
    final valueStart = _skipId3EncodedString(frame, 1, encoding);
    if (valueStart >= frame.length) return null;
    final termLen = (encoding == 1 || encoding == 2) ? 2 : 1;
    final descEnd = (valueStart - termLen).clamp(1, frame.length);
    final desc = _decodeId3StringBytes(
      Uint8List.sublistView(frame, 1, descEnd),
      encoding,
      legacyDecoder: legacyDecoder,
    ).trim().toUpperCase();
    if (desc != 'LYRICS' &&
        desc != 'UNSYNCEDLYRICS' &&
        desc != 'UNSYNCED LYRICS' &&
        desc != 'SYNCEDLYRICS') {
      return null;
    }
    return _decodeId3StringBytes(
      Uint8List.sublistView(frame, valueStart),
      encoding,
      legacyDecoder: legacyDecoder,
    );
  }

  static int _skipId3EncodedString(Uint8List frame, int start, int encoding) {
    var cursor = start;
    if (encoding == 1 || encoding == 2) {
      while (cursor + 1 < frame.length) {
        if (frame[cursor] == 0 && frame[cursor + 1] == 0) {
          return cursor + 2;
        }
        cursor += 2;
      }
      return frame.length;
    }
    while (cursor < frame.length && frame[cursor] != 0) {
      cursor++;
    }
    return cursor < frame.length ? cursor + 1 : frame.length;
  }

  static String _decodeId3StringBytes(
    Uint8List bytes,
    int encoding, {
    LegacyCodePageDecoder? legacyDecoder,
  }) {
    if (bytes.isEmpty) return '';
    // 去掉尾部零填充字节，防止解码结果残留空字符。
    var end = bytes.length;
    if (encoding == 1 || encoding == 2) {
      while (end >= 2 && bytes[end - 1] == 0 && bytes[end - 2] == 0) {
        end -= 2;
      }
      final slice = Uint8List.sublistView(bytes, 0, end);
      return _decodeUtf16Bytes(slice, defaultBigEndian: encoding == 2);
    }
    while (end > 0 && bytes[end - 1] == 0) {
      end--;
    }
    final slice = Uint8List.sublistView(bytes, 0, end);
    if (encoding == 3) {
      return utf8.decode(slice, allowMalformed: true);
    }
    // 编码 0（标称 ISO-8859-1）在实际动漫曲库中常存放 GBK / Shift-JIS / UTF-8，交由多字节探测解码器兼容还原。
    return MultibyteTextDecoder.decodeBytes(
      slice,
      legacyDecoder: legacyDecoder,
    );
  }

  static String _decodeUtf16Bytes(
    Uint8List bytes, {
    required bool defaultBigEndian,
  }) {
    if (bytes.length < 2) return '';
    var offset = 0;
    var bigEndian = defaultBigEndian;
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      bigEndian = false;
      offset = 2;
    } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      bigEndian = true;
      offset = 2;
    }
    final codeUnits = <int>[];
    for (var i = offset; i + 1 < bytes.length; i += 2) {
      final unit = bigEndian
          ? ((bytes[i] << 8) | bytes[i + 1])
          : (bytes[i] | (bytes[i + 1] << 8));
      if (unit == 0) continue;
      codeUnits.add(unit);
    }
    return String.fromCharCodes(codeUnits);
  }

  static Uint8List? _extractFlacPicture(Uint8List bytes) {
    var offset = 4;
    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final isLast = (header & 0x80) != 0;
      final blockType = header & 0x7F;
      final length =
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      offset += 4;
      if (length <= 0 || offset + length > bytes.length) {
        break;
      }
      if (blockType == 6) {
        final block = bytes.sublist(offset, offset + length);
        final image = _parseFlacPictureBlock(block);
        if (image != null && image.isNotEmpty) {
          return image;
        }
      }
      offset += length;
      if (isLast) break;
    }
    return null;
  }

  static Uint8List? _parseFlacPictureBlock(Uint8List block) {
    if (block.length < 32) return null;
    // 跳过 4 字节图片类型枚举。
    var cursor = 4;
    if (cursor + 4 > block.length) return null;
    final mimeLen = _readUint32Be(block, cursor);
    cursor += 4 + mimeLen;
    if (cursor + 4 > block.length) return null;
    final descLen = _readUint32Be(block, cursor);
    // 跳过宽高、色深与索引色数共 16 字节。
    cursor += 4 + descLen + 16;
    if (cursor + 4 > block.length) return null;
    final dataLen = _readUint32Be(block, cursor);
    cursor += 4;
    if (dataLen <= 0 || cursor + dataLen > block.length) return null;
    return Uint8List.fromList(block.sublist(cursor, cursor + dataLen));
  }

  static Uint8List? _extractId3v2Picture(Uint8List bytes) {
    Uint8List? found;
    _walkId3v2Frames(bytes, ({
      required int majorVersion,
      required String frameId,
      required int frameFlags2,
      required int dataOffset,
      required int frameSize,
    }) {
      if (frameId != 'APIC' && frameId != 'PIC') return false;
      final frameData = bytes.sublist(dataOffset, dataOffset + frameSize);
      final img = _parseApicPayload(frameData, isV22: majorVersion == 2);
      if (img != null && img.isNotEmpty) {
        found = img;
        return true;
      }
      return false;
    });
    return found;
  }

  static Uint8List? _parseApicPayload(Uint8List frame, {required bool isV22}) {
    if (frame.length < 8) return null;
    final encoding = frame[0];
    var cursor = 1;
    if (isV22) {
      // 跳过 3 字节短格式标识（如 PNG/JPG）。
      cursor += 3;
    } else {
      while (cursor < frame.length && frame[cursor] != 0) {
        cursor++;
      }
      // 跳过 MIME 终止空字节。
      cursor++;
    }
    if (cursor >= frame.length) return null;
    // 跳过 1 字节图片类型枚举。
    cursor++;

    // 跳过以单 NUL（Latin1/UTF-8）或双 NUL（UTF-16）结尾的封面描述字符串。
    if (encoding == 1 || encoding == 2) {
      while (cursor + 1 < frame.length) {
        if (frame[cursor] == 0 && frame[cursor + 1] == 0) {
          cursor += 2;
          break;
        }
        cursor += 2;
      }
    } else {
      while (cursor < frame.length && frame[cursor] != 0) {
        cursor++;
      }
      if (cursor < frame.length) cursor++;
    }
    if (cursor >= frame.length) return null;
    return Uint8List.fromList(frame.sublist(cursor));
  }

  /// 仅探测内嵌歌词（不探测封面）时的首段读取上限（64 KiB，覆盖 Vorbis Comment 与常规 USLT）。
  static const int _fastEmbeddedLyricsOnlyProbeBytes = 64 * 1024;

  /// 两段式封面探测首段读取上限（256 KiB，覆盖大多数内嵌 JPEG 且大幅降低无封面文件的远程拉取量）。
  static const int _fastEmbeddedCoverProbeBytes = 256 * 1024;

  /// 两段式封面探测最大补读上限（2 MiB）。
  static const int _maxEmbeddedCoverProbeBytes = 2 * 1024 * 1024;

  /// 按有限字节上限从媒体源网关读取指定起点范围的小块数据。
  static Future<Uint8List?> readBoundedRange(
    ByteRangeReadableGateway gateway,
    String relativePath, {
    required int start,
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) return null;
    try {
      var end = start + maxBytes - 1;
      // 云盘网关严格校验字节范围，不像 HTTP 服务可能自动截断越界范围，因此先限制到文件末尾。
      if (gateway is CloudDriveGateway) {
        final length = await gateway.probeFileLength(relativePath);
        if (length == null || length <= start) return null;
        if (end >= length) end = length - 1;
      }
      final stream = await gateway.openByteRange(
        relativePath,
        start: start,
        endInclusive: end,
      );
      final chunks = <int>[];
      await for (final chunk in stream) {
        chunks.addAll(chunk);
        if (chunks.length >= maxBytes) break;
      }
      if (chunks.isEmpty) return null;
      if (chunks.length > maxBytes) {
        return Uint8List.fromList(chunks.sublist(0, maxBytes));
      }
      return Uint8List.fromList(chunks);
    } catch (_) {
      return null;
    }
  }

  /// 按有限字节上限从媒体源网关读取小文件（CUE/LRC/小图/音轨头部）。
  static Future<Uint8List?> readBoundedBytes(
    ByteRangeReadableGateway gateway,
    String relativePath, {
    int maxBytes = 1536 * 1024,
  }) => readBoundedRange(gateway, relativePath, start: 0, maxBytes: maxBytes);

  /// 探测音频头部并按需一次提取内嵌封面与内嵌歌词，无封面或只需歌词时绝不冗余拉流。
  static Future<({Uint8List? cover, String? lyrics})> readEmbeddedHeaderAssets(
    ByteRangeReadableGateway gateway,
    String relativePath, {
    required bool probeCover,
    required bool probeLyrics,
    LegacyCodePageDecoder? legacyDecoder,
  }) async {
    if (!probeCover && !probeLyrics) {
      return (cover: null, lyrics: null);
    }
    final initialLimit = probeCover
        ? _fastEmbeddedCoverProbeBytes
        : _fastEmbeddedLyricsOnlyProbeBytes;
    final head = await readBoundedRange(
      gateway,
      relativePath,
      start: 0,
      maxBytes: initialLimit,
    );
    if (head == null || head.length < 16) {
      return (cover: null, lyrics: null);
    }

    final firstPass = await _extractEmbeddedHeaderAssets(
      head,
      probeCover: probeCover,
      probeLyrics: probeLyrics,
      legacyDecoder: legacyDecoder,
      offload: head.length >= 64 * 1024 && legacyDecoder == null,
    );

    if (!probeCover ||
        (firstPass.cover != null && firstPass.cover!.isNotEmpty)) {
      return firstPass;
    }

    final requiredTotal = _estimateRequiredCoverHeaderBytes(head);
    if (requiredTotal <= head.length) {
      return firstPass;
    }
    final remaining = requiredTotal - head.length;
    final tail = await readBoundedRange(
      gateway,
      relativePath,
      start: head.length,
      maxBytes: remaining,
    );
    if (tail == null || tail.isEmpty) {
      return firstPass;
    }
    final merged = Uint8List(head.length + tail.length);
    merged.setRange(0, head.length, head);
    merged.setRange(head.length, merged.length, tail);
    final needLyricsRetry = probeLyrics && firstPass.lyrics == null;
    final secondPass = await _extractEmbeddedHeaderAssets(
      merged,
      probeCover: true,
      probeLyrics: needLyricsRetry,
      legacyDecoder: legacyDecoder,
      offload: legacyDecoder == null,
    );
    return (
      cover: secondPass.cover,
      lyrics: firstPass.lyrics ?? secondPass.lyrics,
    );
  }

  static Future<({Uint8List? cover, String? lyrics})>
  _extractEmbeddedHeaderAssets(
    Uint8List bytes, {
    required bool probeCover,
    required bool probeLyrics,
    required LegacyCodePageDecoder? legacyDecoder,
    required bool offload,
  }) async {
    ({Uint8List? cover, String? lyrics}) extract(Uint8List? archive) {
      if (archive != null) LegacyCodePageTables.usePrepared(archive);
      return extractEmbeddedHeaderAssetsFromBytes(
        bytes,
        probeCover: probeCover,
        probeLyrics: probeLyrics,
        legacyDecoder: (raw, encoding) {
          final text = legacyDecoder?.call(raw, encoding);
          if ((text == null || text.isEmpty) && archive == null) {
            throw const _LegacyLyricsNeedsTable();
          }
          return text;
        },
      );
    }

    try {
      return offload ? await Isolate.run(() => extract(null)) : extract(null);
    } on _LegacyLyricsNeedsTable {
      final archive = await LegacyCodePageTables.prepare();
      return offload ? Isolate.run(() => extract(archive)) : extract(archive);
    }
  }

  /// 探测音频头部所需精确字节数：先拉取 256 KiB，仅在确有更大封面块时按需续读余段，无封面文件零冗余拉流。
  static Future<Uint8List?> readEmbeddedCoverBytes(
    ByteRangeReadableGateway gateway,
    String relativePath,
  ) async {
    final res = await readEmbeddedHeaderAssets(
      gateway,
      relativePath,
      probeCover: true,
      probeLyrics: false,
    );
    return res.cover;
  }

  /// 根据首段 256 KiB 容器头部判断是否存在跨段未读完的封面块及所需总字节数；确认无封面时返回 `0`。
  static int _estimateRequiredCoverHeaderBytes(Uint8List head) {
    if (head.length < 16) return 0;
    // FLAC 容器：按块头长度精确定位 PICTURE 块结束位置。
    if (head[0] == 0x66 &&
        head[1] == 0x4C &&
        head[2] == 0x61 &&
        head[3] == 0x43) {
      var offset = 4;
      while (offset + 4 <= head.length) {
        final header = head[offset];
        final isLast = (header & 0x80) != 0;
        final blockType = header & 0x7F;
        final length =
            (head[offset + 1] << 16) |
            (head[offset + 2] << 8) |
            head[offset + 3];
        offset += 4;
        if (length <= 0) return 0;
        final blockEnd = offset + length;
        if (blockEnd > head.length) {
          if (blockType == 6) {
            return blockEnd <= _maxEmbeddedCoverProbeBytes
                ? blockEnd
                : _maxEmbeddedCoverProbeBytes;
          }
          if (isLast) return 0;
          final expanded = blockEnd + 65536;
          return expanded <= _maxEmbeddedCoverProbeBytes
              ? expanded
              : _maxEmbeddedCoverProbeBytes;
        }
        offset = blockEnd;
        if (isLast) return 0;
      }
      return _maxEmbeddedCoverProbeBytes;
    }
    // ID3v2 容器：直接依据标签总长度决定是否补读。
    if (head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33) {
      final tagTotal = 10 + _readSyncSafeInt(head, 6);
      if (tagTotal <= head.length) return 0;
      return tagTotal <= _maxEmbeddedCoverProbeBytes
          ? tagTotal
          : _maxEmbeddedCoverProbeBytes;
    }
    return 0;
  }

  /// 为当前 CD 曲目按需读取：1) 头部内嵌封面与内嵌歌词标签；2) 同目录封面图；3) 同名 `.lrc` 歌词。
  ///
  /// 外挂 `.lrc` 优先于内嵌歌词标签；支持传入 [cachedSiblings] 及 [probeEmbeddedCover] /
  /// [probeEmbeddedLyrics] / [probeFolderCover] 开关，避免同专辑或 `.cue` 切轨重复拉流。
  static Future<
    ({
      Uint8List? embeddedCover,
      Uint8List? folderCover,
      LrcDocument? lrc,
      List<ActiveSpanLyricLine> activeSpanLines,
      String? embeddedPlainLyrics,
      List<RemoteEntry>? siblings,
    })
  >
  loadTrackAuxiliaryAssets({
    required MediaSourceView source,
    required MediaVariantRecord variant,
    required MediaSourceGatewayFactoryPort gatewayFactory,
    String? cueTrackTitle,
    bool probeEmbeddedCover = true,
    bool probeEmbeddedLyrics = true,
    bool probeFolderCover = true,
    List<RemoteEntry>? cachedSiblings,
    LegacyCodePageDecoder? legacyDecoder,
  }) async {
    final gateway = await gatewayFactory.create(source);
    try {
      Uint8List? embeddedCover;
      String? embeddedRawLyrics;
      String? embeddedPlainLyrics;
      Uint8List? folderCover;
      LrcDocument? lrc;
      var activeSpanLines = const <ActiveSpanLyricLine>[];
      List<RemoteEntry>? siblings = cachedSiblings;

      if (gateway is ByteRangeReadableGateway) {
        final byteGateway = gateway as ByteRangeReadableGateway;
        if (probeEmbeddedCover || probeEmbeddedLyrics) {
          final embedded = await readEmbeddedHeaderAssets(
            byteGateway,
            variant.relativePath,
            probeCover: probeEmbeddedCover,
            probeLyrics: probeEmbeddedLyrics,
            legacyDecoder: legacyDecoder,
          );
          embeddedCover = embedded.cover;
          embeddedRawLyrics = embedded.lyrics;
        }

        // 查找同目录封面或歌词文件（优先复用缓存目录项，避免同专辑切歌重复列举）
        final dir = p.posix.dirname(variant.relativePath.replaceAll('\\', '/'));
        final dirRel = dir == '.' ? '' : dir;
        try {
          siblings ??= await gateway.listDirectory(dirRel);
          String? bestCoverPath;
          String? fallbackImagePath;
          String? trackTitleLrcPath;
          String? audioStemLrcPath;

          final audioStem = p
              .basenameWithoutExtension(variant.fileName)
              .toLowerCase();
          final normTrackTitle = (cueTrackTitle ?? '').trim().toLowerCase();

          for (final entry in siblings) {
            if (entry.isDirectory) continue;
            final nameLower = entry.name.toLowerCase();
            final ext = p.extension(nameLower);
            if (ext == '.lrc') {
              final stem = p.basenameWithoutExtension(nameLower);
              if (normTrackTitle.isNotEmpty && stem.contains(normTrackTitle)) {
                trackTitleLrcPath ??= entry.relativePath;
              } else if (stem == audioStem) {
                audioStemLrcPath ??= entry.relativePath;
              }
            } else if (probeFolderCover &&
                (ext == '.jpg' ||
                    ext == '.jpeg' ||
                    ext == '.png' ||
                    ext == '.webp')) {
              fallbackImagePath ??= entry.relativePath;
              if (bestCoverPath == null &&
                  (nameLower.contains('cover') ||
                      nameLower.contains('folder') ||
                      nameLower.contains('front') ||
                      nameLower.contains('jacket') ||
                      nameLower.contains('booklet'))) {
                bestCoverPath = entry.relativePath;
              }
            }
          }

          final matchedLrcPath = trackTitleLrcPath ?? audioStemLrcPath;
          if (probeEmbeddedLyrics && matchedLrcPath != null) {
            final lrcBytes = await readBoundedBytes(
              byteGateway,
              matchedLrcPath,
              maxBytes: 512 * 1024,
            );
            if (lrcBytes != null) {
              final decoded = await MultibyteTextDecoder.decodeWithInfoAsync(
                lrcBytes,
                legacyDecoder: legacyDecoder,
              );
              final lrcText = decoded.text;
              lrc = LrcParser.parseText(lrcText);
              if (LyricVersionMatcher.hasExplicitEnhancedTags(lrcText)) {
                activeSpanLines = LyricVersionMatcher.parseActiveSpanLines(
                  lrcText,
                );
              }
            }
          }

          if (probeFolderCover && embeddedCover == null) {
            final chosenCover = bestCoverPath ?? fallbackImagePath;
            if (chosenCover != null) {
              folderCover = await readBoundedBytes(
                byteGateway,
                chosenCover,
                maxBytes: 8 * 1024 * 1024,
              );
            }
          }
        } catch (error) {
          developer.log(
            '可恢复异常已记录',
            name: 'konata.audio_art_extractor',
            error: error,
          );
        }
      }

      // 若未找到同目录外挂 `.lrc` 且音轨自带内嵌歌词，按本地优先级回填同步歌词或保留纯文本。
      if ((lrc == null || lrc.lines.isEmpty) &&
          embeddedRawLyrics != null &&
          embeddedRawLyrics.trim().isNotEmpty) {
        final parsed = LrcParser.parseText(embeddedRawLyrics);
        if (parsed.lines.isNotEmpty) {
          lrc = parsed;
          if (LyricVersionMatcher.hasExplicitEnhancedTags(embeddedRawLyrics)) {
            activeSpanLines = LyricVersionMatcher.parseActiveSpanLines(
              embeddedRawLyrics,
            );
          }
        } else {
          embeddedPlainLyrics = embeddedRawLyrics.trim();
        }
      }

      return (
        embeddedCover: embeddedCover,
        folderCover: folderCover,
        lrc: lrc,
        activeSpanLines: activeSpanLines,
        embeddedPlainLyrics: embeddedPlainLyrics,
        siblings: siblings,
      );
    } finally {
      await gateway.close();
    }
  }

  /// 按关键字优先级（`folder`/`cover`/`front`/`jacket`/`booklet`）从目录项挑选封面相对路径。
  static String? _pickFolderCoverPath(List<RemoteEntry> siblings) {
    String? bestCoverPath;
    String? fallbackImagePath;
    for (final entry in siblings) {
      if (entry.isDirectory) continue;
      final nameLower = entry.name.toLowerCase();
      final ext = p.extension(nameLower);
      if (ext != '.jpg' && ext != '.jpeg' && ext != '.png' && ext != '.webp') {
        continue;
      }
      fallbackImagePath ??= entry.relativePath;
      if (bestCoverPath == null &&
          (nameLower.contains('folder') ||
              nameLower.contains('cover') ||
              nameLower.contains('front') ||
              nameLower.contains('jacket') ||
              nameLower.contains('booklet'))) {
        bestCoverPath = entry.relativePath;
      }
    }
    return bestCoverPath ?? fallbackImagePath;
  }

  /// 优先读取音频所属专辑目录封面（Folder/Cover/Front/Booklet/图片），其次读取内嵌封面；无专属图时返回 `null`。
  static Future<Uint8List?> resolveAlbumCoverBytes({
    required MediaSourceView source,
    required MediaVariantRecord variant,
    required MediaSourceGatewayFactoryPort gatewayFactory,
  }) async {
    final gateway = await gatewayFactory.create(source);
    try {
      if (gateway is! ByteRangeReadableGateway) return null;
      final byteGateway = gateway as ByteRangeReadableGateway;

      final normRel = variant.relativePath.replaceAll('\\', '/');
      final dir = p.posix.dirname(normRel);
      final dirRel = dir == '.' ? '' : dir;
      List<RemoteEntry> siblings = const [];
      try {
        siblings = await gateway.listDirectory(dirRel);
      } catch (error) {
        developer.log(
          '可恢复异常已记录',
          name: 'konata.audio_art_extractor',
          error: error,
        );
      }

      final chosenFolderCover = _pickFolderCoverPath(siblings);
      if (chosenFolderCover != null) {
        final bytes = await readBoundedBytes(
          byteGateway,
          chosenFolderCover,
          maxBytes: 8 * 1024 * 1024,
        );
        if (bytes != null && bytes.isNotEmpty) {
          return bytes;
        }
      }

      String? fallbackAudioPath;
      for (final entry in siblings) {
        if (entry.isDirectory) continue;
        final ext = p.extension(entry.name.toLowerCase());
        if (ext == '.flac' ||
            ext == '.mp3' ||
            ext == '.m4a' ||
            ext == '.alac' ||
            ext == '.wav') {
          fallbackAudioPath = entry.relativePath;
          break;
        }
      }

      final probeAudioPath =
          p.extension(normRel).toLowerCase() == '.cue' &&
              fallbackAudioPath != null
          ? fallbackAudioPath
          : normRel;
      final embedded = await readEmbeddedCoverBytes(
        byteGateway,
        probeAudioPath,
      );
      if (embedded != null && embedded.isNotEmpty) {
        return embedded;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      await gateway.close();
    }
  }

  /// 读取并解析 `.cue` 字节（若已知小文件精确大小则按实际长度读取，避免冗余越界范围）。
  static Future<CueSheet?> loadCueSheet({
    required MediaSourceView source,
    required String cueRelativePath,
    required MediaSourceGatewayFactoryPort gatewayFactory,
    int? knownFileSize,
    LegacyCodePageDecoder? legacyDecoder,
  }) async {
    final gateway = await gatewayFactory.create(source);
    try {
      if (gateway is! ByteRangeReadableGateway) return null;
      final byteGateway = gateway as ByteRangeReadableGateway;
      final effectiveMax =
          (knownFileSize != null &&
              knownFileSize > 0 &&
              knownFileSize < 1024 * 1024)
          ? knownFileSize
          : 1024 * 1024;
      final bytes = await readBoundedBytes(
        byteGateway,
        cueRelativePath,
        maxBytes: effectiveMax,
      );
      if (bytes == null) return null;
      final decoded = await MultibyteTextDecoder.decodeWithInfoAsync(
        bytes,
        legacyDecoder: legacyDecoder,
      );
      return CueParser.parseText(decoded.text);
    } finally {
      await gateway.close();
    }
  }

  static int _readUint32Be(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _readUint32Le(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  static int _readSyncSafeInt(Uint8List b, int o) =>
      ((b[o] & 0x7F) << 21) |
      ((b[o + 1] & 0x7F) << 14) |
      ((b[o + 2] & 0x7F) << 7) |
      (b[o + 3] & 0x7F);
}

final class _LegacyLyricsNeedsTable implements Exception {
  const _LegacyLyricsNeedsTable();
}
