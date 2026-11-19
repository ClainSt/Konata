import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../domain/playback/ass_uue_font_decoder.dart';
import '../storage/atomic_file_writer.dart';
import '../storage/storage_root_provider.dart';

/// 字体集合解析来源模式。
enum FontSetResolutionKind {
  /// 本地媒体同级或父级 `Fonts/` 目录原位只读直挂（0 字节拷贝）。
  inPlaceSiblingDirectory,

  /// 单级 SHA-256 哈希池热集合租约目录（供 `Fonts.zip`、ASS `[Fonts]` 或远程字体包复用）。
  hashedPoolLease,
}

/// 可直接传递给 `libmpv` `sub-fonts-dir` 的已解析字体目录快照。
class ResolvedSubtitleFontSet {
  /// 创建字体目录解析结果。
  const ResolvedSubtitleFontSet({
    required this.directoryPath,
    required this.kind,
    required this.fontCount,
    this.setHash,
    this.reusedFromLease = false,
  });

  /// 传递给 `sub-fonts-dir` 的本地绝对目录路径。
  final String directoryPath;

  /// 解析方式（原位零拷贝或哈希池热租约）。
  final FontSetResolutionKind kind;

  /// 该目录内已核验合法的字体文件数量。
  final int fontCount;

  /// 哈希池集合标识（原位目录模式为 `null`）。
  final String? setHash;

  /// 本次是否直接命中既有热租约实现 0 ms 复用。
  final bool reusedFromLease;
}

/// 字幕字库原位直挂、单级哈希池（3 集合热租约）与系统 CJK 兜底字体发现管理器。
class SubtitleFontPoolManager {
  /// 创建字体池管理器。
  SubtitleFontPoolManager({
    StorageRootService? storageRoot,
    this.maxHotSetLeases = 3,
  }) : _storageRoot = storageRoot ?? const StorageRootService();

  /// 单级哈希池默认保留的最近热字体集合租约上限。
  final int maxHotSetLeases;

  /// 单个解压字体文件体积上限（32 MiB，防解压炸弹）。
  static const int maxSingleFontBytes = 32 * 1024 * 1024;

  /// 单个压缩包允许解压的总体积上限（128 MiB）。
  static const int maxTotalExtractBytes = 128 * 1024 * 1024;

  /// 单个压缩包允许的最大条目数上限。
  static const int maxZipEntries = 256;

  final StorageRootService _storageRoot;

  /// 内存热租约序列表（按最近访问顺序排列，尾部为最新访问，便于 0 ms 跨集复用与 LRU 驱逐）。
  final List<String> _leaseOrder = [];
  final Map<String, ResolvedSubtitleFontSet> _hotLeaseCache = {};

  /// 当前活跃在内存中的热租约集合哈希列表（按最旧到最新排列）。
  List<String> get activeLeaseHashes => List<String>.unmodifiable(_leaseOrder);

  /// 优先原位只读检测本地视频同级或上级目录的 `Fonts/` 目录（O(1) 精准探测，0 拷贝直挂，不改动刮削目录扫描规则）。
  Future<ResolvedSubtitleFontSet?> resolveInPlaceSiblingFontsDir(
    String localVideoAbsolutePath,
  ) async {
    final trimmed = localVideoAbsolutePath.trim();
    if (trimmed.isEmpty || !p.isAbsolute(trimmed)) return null;
    try {
      final videoDir = Directory(p.dirname(trimmed));
      if (!await videoDir.exists()) return null;
      final searchParents = <Directory>[
        videoDir,
        if (videoDir.parent.path != videoDir.path) videoDir.parent,
      ];

      const directNames = ['Fonts', 'fonts', 'Font', 'font'];
      final candidates = <Directory>[
        for (final parent in searchParents)
          for (final name in directNames) Directory(p.join(parent.path, name)),
      ];
      final existsList = await Future.wait(
        candidates.map((dir) => dir.exists()),
      );
      final seenPaths = <String>{};
      for (var i = 0; i < candidates.length; i++) {
        if (!existsList[i]) continue;
        final candidate = candidates[i];
        if (!seenPaths.add(candidate.path.toLowerCase())) continue;
        final validCount = await _countValidFontsInDirectory(candidate);
        if (validCount > 0) {
          return ResolvedSubtitleFontSet(
            directoryPath: candidate.path,
            kind: FontSetResolutionKind.inPlaceSiblingDirectory,
            fontCount: validCount,
            reusedFromLease: true,
          );
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 将 `Fonts.zip` 压缩包经 Zip-Slip 与体积炸弹安全校验后解包入单级哈希池（保留最近 3 集合热租约）。
  Future<ResolvedSubtitleFontSet> ingestFontZipBytes(
    Uint8List zipBytes,
  ) async {
    final setHash = sha256.convert(zipBytes).toString().substring(0, 16);
    final cached = await _tryReuseHotLease(setHash);
    if (cached != null) return cached;

    final entries = _parseAndValidateZipFonts(zipBytes);
    if (entries.isEmpty) {
      throw const FormatException('字体压缩包内未发现合法 SFNT 字体文件');
    }
    return _commitFontEntriesToPool(setHash: setHash, entries: entries);
  }

  /// 将 ASS `[Fonts]` UUEncode 内嵌字体提取并校验 SFNT 魔数后入单级哈希池。
  Future<ResolvedSubtitleFontSet?> ingestAssEmbeddedFonts(
    String assContent,
  ) async {
    final extracted = AssUueFontDecoder.extractEmbeddedFonts(assContent);
    if (extracted.isEmpty) return null;

    final validMap = <String, Uint8List>{};
    for (var i = 0; i < extracted.length; i++) {
      final entry = extracted[i];
      if (!AssUueFontDecoder.isValidFontMagic(entry.bytes)) continue;
      final safeName = _sanitizeFlatFontFileName(
        entry.fontName,
        fallbackIndex: i,
      );
      validMap[safeName] = entry.bytes;
    }
    if (validMap.isEmpty) return null;

    final setHash = _computeEntriesSetHash(validMap);
    final cached = await _tryReuseHotLease(setHash);
    if (cached != null) return cached;

    return _commitFontEntriesToPool(setHash: setHash, entries: validMap);
  }

  /// 将手动缓存的远程字体文件集合（`文件名 -> 原始字节`）校验后入单级哈希池。
  Future<ResolvedSubtitleFontSet> ingestRemoteFontFiles(
    Map<String, Uint8List> fontFilesByName,
  ) async {
    final validMap = <String, Uint8List>{};
    var idx = 0;
    for (final entry in fontFilesByName.entries) {
      final base = p.posix.basename(entry.key.replaceAll('\\', '/'));
      if (!AssUueFontDecoder.isSupportedFontFileName(base)) continue;
      if (entry.value.length > maxSingleFontBytes) {
        throw FormatException('字体文件体积超出上限: $base');
      }
      if (!AssUueFontDecoder.isValidFontMagic(entry.value)) continue;
      validMap[_sanitizeFlatFontFileName(base, fallbackIndex: idx++)] =
          entry.value;
    }
    if (validMap.isEmpty) {
      throw const FormatException('远程字体包中未包含合法 SFNT 字体');
    }
    final setHash = _computeEntriesSetHash(validMap);
    final cached = await _tryReuseHotLease(setHash);
    if (cached != null) return cached;

    return _commitFontEntriesToPool(setHash: setHash, entries: validMap);
  }

  /// 运行时实证扫描操作系统中真实存在、可读且通过 SFNT 魔数校验的 CJK 兜底字体列表。
  static Future<List<File>> discoverVerifiedSystemCjkFonts({
    List<Directory>? searchRootsOverride,
    int maxResults = 6,
  }) async {
    final roots =
        searchRootsOverride ??
        (Platform.isAndroid
            ? [
                Directory('/system/fonts'),
                Directory('/product/fonts'),
                Directory('/system_ext/fonts'),
              ]
            : Platform.isWindows
            ? [Directory(r'C:\Windows\Fonts')]
            : [Directory('/usr/share/fonts')]);

    final scored = <({File file, int priority})>[];
    final seenPaths = <String>{};

    for (final root in roots) {
      if (!await root.exists()) continue;
      try {
        await for (final entity in root.list(followLinks: false)) {
          if (entity is! File) continue;
          final baseName = p.basename(entity.path);
          if (!AssUueFontDecoder.isSupportedFontFileName(baseName)) continue;
          final priority = _scoreCjkFallbackFontName(baseName);
          if (priority <= 0) continue;
          if (!seenPaths.add(entity.path.toLowerCase())) continue;
          if (await _hasValidFontHeader(entity)) {
            scored.add((file: entity, priority: priority));
          }
        }
      } catch (_) {
        // 个别系统字体目录受限无权限时静默跳过，继续实证扫描其余路径。
      }
    }

    scored.sort((a, b) => b.priority.compareTo(a.priority));
    return scored
        .take(maxResults)
        .map((e) => e.file)
        .toList(growable: false);
  }

  Future<ResolvedSubtitleFontSet?> _tryReuseHotLease(String setHash) async {
    final poolRoot = await _storageRoot.ensureFontPoolDir();
    final setDir = Directory(p.join(poolRoot.path, setHash));
    if (!await setDir.exists()) {
      _hotLeaseCache.remove(setHash);
      _leaseOrder.remove(setHash);
      return null;
    }

    final cached = _hotLeaseCache[setHash];
    if (cached != null) {
      _touchLease(setHash);
      return ResolvedSubtitleFontSet(
        directoryPath: cached.directoryPath,
        kind: FontSetResolutionKind.hashedPoolLease,
        fontCount: cached.fontCount,
        setHash: setHash,
        reusedFromLease: true,
      );
    }

    final validCount = await _countValidFontsInDirectory(setDir);
    if (validCount <= 0) return null;

    final resolved = ResolvedSubtitleFontSet(
      directoryPath: setDir.path,
      kind: FontSetResolutionKind.hashedPoolLease,
      fontCount: validCount,
      setHash: setHash,
      reusedFromLease: true,
    );
    _hotLeaseCache[setHash] = resolved;
    _touchLease(setHash);
    await _evictOverflowLeases(poolRoot);
    return resolved;
  }

  Future<ResolvedSubtitleFontSet> _commitFontEntriesToPool({
    required String setHash,
    required Map<String, Uint8List> entries,
  }) async {
    final poolRoot = await _storageRoot.ensureFontPoolDir();
    final setDir = Directory(p.join(poolRoot.path, setHash));
    await setDir.create(recursive: true);

    var written = 0;
    for (final entry in entries.entries) {
      final destFile = File(p.join(setDir.path, entry.key));
      if (!await destFile.exists() ||
          await destFile.length() != entry.value.length) {
        final partFile = File(
          '${destFile.path}.part.${DateTime.now().microsecondsSinceEpoch}',
        );
        try {
          await partFile.writeAsBytes(entry.value, flush: true);
          await AtomicFileWriter.replaceFile(
            partFile,
            destFile,
            expectedLength: entry.value.length,
          );
        } finally {
          if (await partFile.exists()) {
            await partFile.delete().catchError((_) => partFile);
          }
        }
      }
      written += 1;
    }

    final resolved = ResolvedSubtitleFontSet(
      directoryPath: setDir.path,
      kind: FontSetResolutionKind.hashedPoolLease,
      fontCount: written,
      setHash: setHash,
      reusedFromLease: false,
    );
    _hotLeaseCache[setHash] = resolved;
    _touchLease(setHash);
    await _evictOverflowLeases(poolRoot);
    return resolved;
  }

  void _touchLease(String setHash) {
    _leaseOrder.remove(setHash);
    _leaseOrder.add(setHash);
  }

  Future<void> _evictOverflowLeases(Directory poolRoot) async {
    while (_leaseOrder.length > maxHotSetLeases) {
      final evictedHash = _leaseOrder.removeAt(0);
      _hotLeaseCache.remove(evictedHash);
      final evictedDir = Directory(p.join(poolRoot.path, evictedHash));
      if (await evictedDir.exists()) {
        await evictedDir.delete(recursive: true).catchError((_) => evictedDir);
      }
    }
  }

  /// 纯 Dart 安全 ZIP 解包器（零第三方依赖，校验 Zip-Slip 路径穿越与解压体积上限）。
  static Map<String, Uint8List> _parseAndValidateZipFonts(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const FormatException('ZIP 数据过短，缺少结束目录记录');
    }
    final bd = ByteData.sublistView(bytes);
    // 逆序搜索 End Of Central Directory 签名 0x06054b50。
    var eocdOffset = -1;
    final minSearch = (bytes.length - 65557) < 0 ? 0 : (bytes.length - 65557);
    for (var pos = bytes.length - 22; pos >= minSearch; pos--) {
      if (bd.getUint32(pos, Endian.little) == 0x06054b50) {
        eocdOffset = pos;
        break;
      }
    }
    if (eocdOffset < 0) {
      throw const FormatException('未找到合法 ZIP 中央目录结束标记');
    }

    final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
    final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
    if (entryCount > maxZipEntries) {
      throw FormatException('字体压缩包条目数超出安全上限 ($entryCount > $maxZipEntries)');
    }

    final result = <String, Uint8List>{};
    var totalExtractedBytes = 0;
    var cursor = cdOffset;

    for (var i = 0; i < entryCount; i++) {
      if (cursor + 46 > bytes.length ||
          bd.getUint32(cursor, Endian.little) != 0x02014b50) {
        throw const FormatException('ZIP 中央目录头损坏');
      }
      final compressionMethod = bd.getUint16(cursor + 10, Endian.little);
      final compressedSize = bd.getUint32(cursor + 20, Endian.little);
      final uncompressedSize = bd.getUint32(cursor + 24, Endian.little);
      final nameLen = bd.getUint16(cursor + 28, Endian.little);
      final extraLen = bd.getUint16(cursor + 30, Endian.little);
      final commentLen = bd.getUint16(cursor + 32, Endian.little);
      final localHeaderOffset = bd.getUint32(cursor + 42, Endian.little);

      final nameStart = cursor + 46;
      if (nameStart + nameLen > bytes.length) {
        throw const FormatException('ZIP 文件名越界');
      }
      final rawName = utf8.decode(
        bytes.sublist(nameStart, nameStart + nameLen),
        allowMalformed: false,
      );
      cursor = nameStart + nameLen + extraLen + commentLen;

      // 严格拦截 Zip-Slip 路径穿越、绝对路径与盘符注入。
      _assertSafeZipEntryPath(rawName);
      if (rawName.endsWith('/')) continue;

      final baseName = p.posix.basename(rawName.replaceAll('\\', '/'));
      if (!AssUueFontDecoder.isSupportedFontFileName(baseName)) continue;

      if (uncompressedSize > maxSingleFontBytes) {
        throw FormatException('压缩包内单字体体积超限: $baseName');
      }
      totalExtractedBytes += uncompressedSize;
      if (totalExtractedBytes > maxTotalExtractBytes) {
        throw const FormatException('字体压缩包总解压体积超出安全上限');
      }

      if (localHeaderOffset + 30 > bytes.length ||
          bd.getUint32(localHeaderOffset, Endian.little) != 0x04034b50) {
        throw const FormatException('ZIP 本地文件头损坏');
      }
      final localNameLen = bd.getUint16(localHeaderOffset + 26, Endian.little);
      final localExtraLen = bd.getUint16(localHeaderOffset + 28, Endian.little);
      final dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen;
      final dataEnd = dataStart + compressedSize;
      if (dataEnd > bytes.length) {
        throw const FormatException('ZIP 压缩数据体越界');
      }
      final compressedSlice = bytes.sublist(dataStart, dataEnd);

      Uint8List extracted;
      if (compressionMethod == 0) {
        extracted = Uint8List.fromList(compressedSlice);
      } else if (compressionMethod == 8) {
        final decoded = ZLibDecoder(raw: true).convert(compressedSlice);
        if (decoded.length > maxSingleFontBytes) {
          throw FormatException('解压后单字体实际体积超限: $baseName');
        }
        extracted = Uint8List.fromList(decoded);
      } else {
        continue;
      }

      if (!AssUueFontDecoder.isValidFontMagic(extracted)) continue;
      final flatName = _sanitizeFlatFontFileName(baseName, fallbackIndex: i);
      result[flatName] = extracted;
    }

    return result;
  }

  static void _assertSafeZipEntryPath(String rawName) {
    if (rawName.isEmpty) {
      throw const FormatException('ZIP 条目路径为空');
    }
    if (rawName.startsWith('/') ||
        rawName.startsWith('\\') ||
        rawName.contains(':')) {
      throw FormatException('拦截非法绝对路径或盘符 ZIP 条目: $rawName');
    }
    final normalized = rawName.replaceAll('\\', '/');
    for (final segment in normalized.split('/')) {
      if (segment == '..') {
        throw FormatException('拦截 Zip-Slip 目录穿越攻击条目: $rawName');
      }
    }
  }

  static String _sanitizeFlatFontFileName(
    String rawName, {
    required int fallbackIndex,
  }) {
    final base = p.posix.basename(rawName.replaceAll('\\', '/'));
    final cleaned = base.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    if (cleaned.isEmpty || !AssUueFontDecoder.isSupportedFontFileName(cleaned)) {
      return 'font_$fallbackIndex.ttf';
    }
    return cleaned;
  }

  static String _computeEntriesSetHash(Map<String, Uint8List> entries) {
    final sortedNames = entries.keys.toList()..sort();
    final sink = _Sha256SingleSink();
    final input = sha256.startChunkedConversion(sink);
    for (final name in sortedNames) {
      input.add(utf8.encode('$name\x00'));
      input.add(entries[name]!);
    }
    input.close();
    return (sink.digest ?? sha256.convert(const [])).toString().substring(0, 16);
  }

  static int _scoreCjkFallbackFontName(String baseName) {
    final lower = baseName.toLowerCase();
    if (lower.contains('notosanscjk') || lower.contains('sourcehansans')) {
      return 100;
    }
    if (lower.contains('notoserifcjk') || lower.contains('sourcehanserif')) {
      return 90;
    }
    if (lower.contains('notosanssc') || lower.contains('notosansjp')) {
      return 85;
    }
    if (lower.contains('msyh') ||
        lower.contains('yahei') ||
        lower.contains('misans') ||
        lower.contains('pingfang') ||
        lower.contains('harmonyos')) {
      return 80;
    }
    if (lower.contains('droidsansfallback') ||
        lower.contains('simhei') ||
        lower.contains('simsun') ||
        lower.contains('cjk')) {
      return 60;
    }
    return 0;
  }

  static Future<int> _countValidFontsInDirectory(Directory dir) async {
    var count = 0;
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!AssUueFontDecoder.isSupportedFontFileName(p.basename(entity.path))) {
          continue;
        }
        if (await _hasValidFontHeader(entity)) {
          count += 1;
        }
      }
    } catch (_) {}
    return count;
  }

  static Future<bool> _hasValidFontHeader(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final header = await raf.read(12);
      return AssUueFontDecoder.isValidFontMagic(header);
    } catch (_) {
      return false;
    } finally {
      await raf?.close().catchError((_) {});
    }
  }
}

class _Sha256SingleSink implements Sink<Digest> {
  Digest? digest;

  @override
  void add(Digest data) {
    digest = data;
  }

  @override
  void close() {}
}
