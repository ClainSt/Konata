import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../domain/models/media_source.dart';
import '../../domain/models/media_variant.dart';
import '../../domain/playback/cue_and_lrc_parser.dart';
import '../../domain/repositories/file_system_gateway.dart';
import '../sources/byte_stream_source_gateway.dart';
import '../sources/source_gateway_factory.dart';
import 'libmpv_ffi.dart';

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
    var cursor = 4; // skip picture type
    if (cursor + 4 > block.length) return null;
    final mimeLen = _readUint32Be(block, cursor);
    cursor += 4 + mimeLen;
    if (cursor + 4 > block.length) return null;
    final descLen = _readUint32Be(block, cursor);
    cursor += 4 + descLen + 16; // width, height, depth, indexed colors
    if (cursor + 4 > block.length) return null;
    final dataLen = _readUint32Be(block, cursor);
    cursor += 4;
    if (dataLen <= 0 || cursor + dataLen > block.length) return null;
    return Uint8List.fromList(block.sublist(cursor, cursor + dataLen));
  }

  static Uint8List? _extractId3v2Picture(Uint8List bytes) {
    if (bytes.length < 10) return null;
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
        headerLen = 10;
      }
      offset += headerLen;
      if (frameSize <= 0 || offset + frameSize > tagEnd) {
        break;
      }

      if (frameId == 'APIC' || frameId == 'PIC') {
        final frameData = bytes.sublist(offset, offset + frameSize);
        final img = _parseApicPayload(frameData, isV22: majorVersion == 2);
        if (img != null && img.isNotEmpty) {
          return img;
        }
      }
      offset += frameSize;
    }
    return null;
  }

  static Uint8List? _parseApicPayload(Uint8List frame, {required bool isV22}) {
    if (frame.length < 8) return null;
    final encoding = frame[0];
    var cursor = 1;
    if (isV22) {
      cursor += 3; // 3-byte image format e.g. PNG/JPG
    } else {
      while (cursor < frame.length && frame[cursor] != 0) {
        cursor++;
      }
      cursor++; // skip NUL
    }
    if (cursor >= frame.length) return null;
    cursor++; // skip picture type byte

    // Skip description terminated by single NUL (latin1/utf8) or double NUL (UTF-16)
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

  /// 按有限字节上限从媒体源网关读取小文件（CUE/LRC/小图/音轨头部）。
  static Future<Uint8List?> readBoundedBytes(
    ByteRangeReadableGateway gateway,
    String relativePath, {
    int maxBytes = 1536 * 1024,
  }) async {
    try {
      final stream = await gateway.openByteRange(
        relativePath,
        start: 0,
        endInclusive: maxBytes - 1,
      );
      final chunks = <int>[];
      await for (final chunk in stream) {
        chunks.addAll(chunk);
        if (chunks.length >= maxBytes) break;
      }
      if (chunks.isEmpty) return null;
      return Uint8List.fromList(chunks);
    } catch (_) {
      return null;
    }
  }

  /// 为当前 CD 曲目按需读取：1) 头部内嵌封面；2) 同目录封面图；3) 同名 `.lrc` 歌词。
  ///
  /// 支持传入 [cachedSiblings] 及 [probeEmbeddedCover] / [probeFolderCover] 开关，
  /// 供同专辑或同母文件 `.cue` 切轨时跳过重复头部/目录图下载，零阻塞仅探测本轨 `.lrc`。
  static Future<
    ({
      Uint8List? embeddedCover,
      Uint8List? folderCover,
      LrcDocument? lrc,
      List<RemoteEntry>? siblings,
    })
  >
  loadTrackAuxiliaryAssets({
    required MediaSource source,
    required MediaVariant variant,
    required MediaSourceGatewayFactory gatewayFactory,
    String? cueTrackTitle,
    bool probeEmbeddedCover = true,
    bool probeFolderCover = true,
    List<RemoteEntry>? cachedSiblings,
  }) async {
    final gateway = await gatewayFactory.create(source);
    try {
      Uint8List? embeddedCover;
      Uint8List? folderCover;
      LrcDocument? lrc;
      List<RemoteEntry>? siblings = cachedSiblings;

      if (gateway is ByteRangeReadableGateway) {
        final byteGateway = gateway as ByteRangeReadableGateway;
        if (probeEmbeddedCover) {
          final headerBytes = await readBoundedBytes(
            byteGateway,
            variant.relativePath,
            maxBytes: 1536 * 1024,
          );
          if (headerBytes != null) {
            embeddedCover = extractEmbeddedCoverFromHeaderBytes(headerBytes);
          }
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
          if (matchedLrcPath != null) {
            final lrcBytes = await readBoundedBytes(
              byteGateway,
              matchedLrcPath,
              maxBytes: 512 * 1024,
            );
            if (lrcBytes != null) {
              lrc = LrcParser.parseBytes(
                lrcBytes,
                legacyDecoder: WindowsCodePageDecoder.decode,
              );
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
        } catch (_) {}
      }

      return (
        embeddedCover: embeddedCover,
        folderCover: folderCover,
        lrc: lrc,
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
    required MediaSource source,
    required MediaVariant variant,
    required MediaSourceGatewayFactory gatewayFactory,
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
      } catch (_) {}

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
      final headerBytes = await readBoundedBytes(
        byteGateway,
        probeAudioPath,
        maxBytes: 1536 * 1024,
      );
      if (headerBytes != null) {
        final embedded = extractEmbeddedCoverFromHeaderBytes(headerBytes);
        if (embedded != null && embedded.isNotEmpty) {
          return embedded;
        }
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
    required MediaSource source,
    required String cueRelativePath,
    required MediaSourceGatewayFactory gatewayFactory,
    int? knownFileSize,
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
      return CueParser.parseBytes(
        bytes,
        legacyDecoder: WindowsCodePageDecoder.decode,
      );
    } finally {
      await gateway.close();
    }
  }

  static int _readUint32Be(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _readSyncSafeInt(Uint8List b, int o) =>
      ((b[o] & 0x7F) << 21) |
      ((b[o + 1] & 0x7F) << 14) |
      ((b[o + 2] & 0x7F) << 7) |
      (b[o + 3] & 0x7F);
}
