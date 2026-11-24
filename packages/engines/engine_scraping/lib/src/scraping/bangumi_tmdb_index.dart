import 'dart:typed_data';

import '../models/work.dart';
import 'bangumi_tmdb_map.dart';

/// 单条 Bangumi 到 TMDB 的离线映射目标（含可选精确季号、TheTVDB 剧集 ID 与来源标志）。
class BangumiTmdbTarget {
  /// 创建单条映射目标。
  const BangumiTmdbTarget({
    required this.type,
    required this.id,
    this.season,
    this.flags = 0,
    this.tvdbId,
  });

  /// 来源标志位：来自 Wikidata CC0 快照。
  static const int flagWikidata = 1 << 0;

  /// 来源标志位：来自 `open-ani/bangumi-tmdb`（CC BY 4.0）快照。
  static const int flagOpenAni = 1 << 1;

  /// 来源标志位：来自 `Fribb/anime-lists`（MIT）补充的 TheTVDB 关联标识。
  static const int flagAnimeListsTvdb = 1 << 2;

  /// 来源标志位：来自 `Fribb/anime-lists`（MIT）补漏的 Bangumi ↔ TMDB 跨站映射。
  static const int flagAnimeListsMap = 1 << 3;

  /// 来源标志位：来自 `bangumi-data`（MIT）补充的新老番映射与季号线索。
  static const int flagBangumiData = 1 << 4;

  /// TMDB 媒体类型（剧集或电影）。
  final TmdbMediaType type;

  /// TMDB 条目数字 ID。
  final int id;

  /// 已知精确季号（`null` 表示仅作品级映射或电影）。
  final int? season;

  /// 来源位掩码标志。
  final int flags;

  /// 关联的 TheTVDB 剧集 ID（v2 映射表扩展字段，未知或电影条目为 `null`）。
  final int? tvdbId;

  /// TMDB 复合键（如 `tv:31724` / `movie:23150`）。
  String get key => '${type.name}:$id';

  /// 是否源自 Wikidata 公有领域快照。
  bool get isWikidata => (flags & flagWikidata) != 0;

  /// 是否源自 `open-ani/bangumi-tmdb` 社区核验快照。
  bool get isOpenAni => (flags & flagOpenAni) != 0;

  /// 是否源自 `Fribb/anime-lists` 补漏映射。
  bool get isAnimeListsMap => (flags & flagAnimeListsMap) != 0;
}

/// 由 TMDB 条目（及可选季号）离线反查得到的 Bangumi 关联条目。
class BangumiReverseMatch {
  /// 创建反向映射匹配记录。
  const BangumiReverseMatch({
    required this.bangumiId,
    this.season,
    this.flags = 0,
    this.tvdbId,
  });

  /// 关联的 Bangumi 条目 ID。
  final int bangumiId;

  /// 已知精确季号（`null` 表示作品级或电影）。
  final int? season;

  /// 来源位掩码标志。
  final int flags;

  /// 关联的 TheTVDB 剧集 ID（未知时为 `null`）。
  final int? tvdbId;

  /// 是否源自 `open-ani/bangumi-tmdb` 社区核验快照。
  bool get isOpenAni => (flags & BangumiTmdbTarget.flagOpenAni) != 0;
}

/// 用于离线编码二进制表的扁平记录条目。
class BangumiTmdbRecord {
  /// 创建单条待编码映射记录。
  const BangumiTmdbRecord({
    required this.bangumiId,
    required this.type,
    required this.tmdbId,
    this.season,
    this.flags = 0,
    this.tvdbId,
  });

  /// Bangumi 条目 ID。
  final int bangumiId;

  /// 目标 TMDB 媒体类型。
  final TmdbMediaType type;

  /// 目标 TMDB ID。
  final int tmdbId;

  /// 可选精确季号。
  final int? season;

  /// 来源标志位。
  final int flags;

  /// 可选 TheTVDB 剧集 ID（仅 v2 格式落盘）。
  final int? tvdbId;
}

/// 紧凑只读 Bangumi ↔ TMDB 离线二进制索引（不可变，可零拷贝跨 Isolate 传递）。
///
/// 二进制格式（小端序）：
/// - 24 字节文件头：`KTBM`(4B) + `version`(2B，支持 `1` 与 `2`) + `recordSize`(2B，v1 为 `12`，v2 为 `16`) +
///   `recordCount`(4B) + `uniqueBangumiCount`(4B) + `snapshotDateYyyymmdd`(4B) + `reserved`(4B)；
/// - 每条定长记录，按 `bangumiId` 升序排列：
///   `bangumiId`(uint32) + `packedTarget`(uint32，最高位 1 为电影/0 为剧集，低 31 位为 TMDB ID) +
///   `season`(int16，`-1` 表示未知) + `flags`(uint16) + [仅 v2：`tvdbId`(uint32，`0` 表示未知)]。
class BangumiTmdbIndex {
  BangumiTmdbIndex._({
    required Uint8List bytes,
    required this.version,
    required this.recordSize,
    required this.recordCount,
    required this.uniqueBangumiCount,
    required this.snapshotDateYyyymmdd,
  }) : _bytes = bytes,
       _view = ByteData.sublistView(bytes);

  /// 创建空索引（查询时可按需回退至内置静态 Wikidata 映射表）。
  factory BangumiTmdbIndex.empty() => BangumiTmdbIndex._(
    bytes: Uint8List(0),
    version: formatVersionV1,
    recordSize: recordBytesV1,
    recordCount: 0,
    uniqueBangumiCount: 0,
    snapshotDateYyyymmdd: 0,
  );

  /// 从二进制快照严格校验并解析索引（同时兼容 v1 12B 与 v2 16B）；损坏或版本不兼容时抛出 [FormatException]。
  factory BangumiTmdbIndex.fromBytes(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw const FormatException('映射表二进制头长度不足');
    }
    if (bytes[0] != _magic0 ||
        bytes[1] != _magic1 ||
        bytes[2] != _magic2 ||
        bytes[3] != _magic3) {
      throw const FormatException('映射表魔数校验失败');
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint16(4, Endian.little);
    final recSize = view.getUint16(6, Endian.little);
    final validV1 = version == formatVersionV1 && recSize == recordBytesV1;
    final validV2 = version == formatVersionV2 && recSize == recordBytesV2;
    if (!validV1 && !validV2) {
      throw FormatException('不支持的映射表格式版本($version)或记录长度($recSize)');
    }
    final recordCount = view.getUint32(8, Endian.little);
    final uniqueCount = view.getUint32(12, Endian.little);
    final snapshotDate = view.getUint32(16, Endian.little);
    final expectedLen = headerBytes + recordCount * recSize;
    if (bytes.length != expectedLen) {
      throw FormatException(
        '映射表字节长度与头声明不一致（实际 ${bytes.length}，期望 $expectedLen）',
      );
    }
    return BangumiTmdbIndex._(
      bytes: bytes,
      version: version,
      recordSize: recSize,
      recordCount: recordCount,
      uniqueBangumiCount: uniqueCount,
      snapshotDateYyyymmdd: snapshotDate,
    );
  }

  /// 将记录集合排序去重并编码为标准紧凑二进制字节流（自动识别或显式指定 v1 / v2 格式）。
  static Uint8List encode(
    Iterable<BangumiTmdbRecord> records, {
    required int snapshotDateYyyymmdd,
    int? formatVersionOverride,
  }) {
    final sorted =
        records
            .where((r) => r.bangumiId > 0 && r.tmdbId > 0 && r.tmdbId <= _maxTmdbId)
            .toList()
          ..sort((a, b) {
            final byBgm = a.bangumiId.compareTo(b.bangumiId);
            if (byBgm != 0) return byBgm;
            final byType = a.type.index.compareTo(b.type.index);
            if (byType != 0) return byType;
            final byTmdb = a.tmdbId.compareTo(b.tmdbId);
            if (byTmdb != 0) return byTmdb;
            return (a.season ?? -1).compareTo(b.season ?? -1);
          });

    final hasTvdb = sorted.any((r) => (r.tvdbId ?? 0) > 0);
    final targetVersion =
        formatVersionOverride ?? (hasTvdb ? formatVersionV2 : formatVersionV1);
    final targetRecordSize = targetVersion == formatVersionV2
        ? recordBytesV2
        : recordBytesV1;

    final uniqueBgmIds = <int>{for (final r in sorted) r.bangumiId};
    final out = Uint8List(headerBytes + sorted.length * targetRecordSize);
    out[0] = _magic0;
    out[1] = _magic1;
    out[2] = _magic2;
    out[3] = _magic3;
    final view = ByteData.sublistView(out);
    view.setUint16(4, targetVersion, Endian.little);
    view.setUint16(6, targetRecordSize, Endian.little);
    view.setUint32(8, sorted.length, Endian.little);
    view.setUint32(12, uniqueBgmIds.length, Endian.little);
    view.setUint32(16, snapshotDateYyyymmdd, Endian.little);
    view.setUint32(20, 0, Endian.little);

    for (var i = 0; i < sorted.length; i++) {
      final r = sorted[i];
      final off = headerBytes + i * targetRecordSize;
      final packed =
          (r.type == TmdbMediaType.movie ? _movieBitMask : 0) |
          (r.tmdbId & _maxTmdbId);
      final encodedSeason = (r.season != null && r.season! >= 0 && r.season! <= 32767)
          ? r.season!
          : -1;
      view.setUint32(off, r.bangumiId, Endian.little);
      view.setUint32(off + 4, packed, Endian.little);
      view.setInt16(off + 8, encodedSeason, Endian.little);
      view.setUint16(off + 10, r.flags & 0xFFFF, Endian.little);
      if (targetVersion == formatVersionV2) {
        final tvdb = (r.tvdbId != null && r.tvdbId! > 0) ? r.tvdbId! : 0;
        view.setUint32(off + 12, tvdb, Endian.little);
      }
    }
    return out;
  }

  /// 二进制文件头固定长度（24 字节）。
  static const int headerBytes = 24;

  /// v1 单条定长记录长度（12 字节）。
  static const int recordBytesV1 = 12;

  /// v2 单条定长记录长度（16 字节，含 `tvdbId`）。
  static const int recordBytesV2 = 16;

  /// 默认兼容常量别名（v1 记录长度与版本号）。
  static const int recordBytes = recordBytesV1;
  static const int formatVersionV1 = 1;
  static const int formatVersionV2 = 2;
  static const int formatVersion = formatVersionV1;

  static const int _magic0 = 0x4B; // 魔数第 1 字节（ASCII 字母 K）
  static const int _magic1 = 0x54; // 魔数第 2 字节（ASCII 字母 T）
  static const int _magic2 = 0x42; // 魔数第 3 字节（ASCII 字母 B）
  static const int _magic3 = 0x4D; // 魔数第 4 字节（ASCII 字母 M）
  static const int _movieBitMask = 0x80000000;
  static const int _maxTmdbId = 0x7FFFFFFF;

  final Uint8List _bytes;
  final ByteData _view;

  /// 按 `packedTarget` 升序排列的惰性反查键数组（仅在首次反查时按需构建，O(log N) 二分查询）。
  Uint32List? _reversePackedKeys;

  /// 与 [_reversePackedKeys] 对齐的原始记录下标数组。
  Uint32List? _reverseRecordIndices;

  /// 当前索引二进制版本号（`1` 或 `2`）。
  final int version;

  /// 当前索引每条记录字节数（`12` 或 `16`）。
  final int recordSize;

  /// 索引中的总目标记录条数。
  final int recordCount;

  /// 索引覆盖的独立 Bangumi 动画条目数。
  final int uniqueBangumiCount;

  /// 快照日期（`YYYYMMDD` 整数；未知时为 `0`）。
  final int snapshotDateYyyymmdd;

  /// 是否包含 v2 扩展的 `tvdbId` 字段。
  bool get supportsTvdbId => version >= formatVersionV2 && recordSize >= recordBytesV2;

  /// 原始只读字节视图（便于跨 Isolate 透传与持久化摘要计算）。
  Uint8List get rawBytes => _bytes;

  /// 是否为空索引。
  bool get isEmpty => recordCount == 0;

  /// 是否已载入有效映射记录。
  bool get isNotEmpty => recordCount > 0;

  /// 格式化为 `YYYY-MM-DD` 形式的可读快照日期；无日期时返回空串。
  String get formattedSnapshotDate {
    if (snapshotDateYyyymmdd < 19000101) return '';
    final y = snapshotDateYyyymmdd ~/ 10000;
    final m = (snapshotDateYyyymmdd % 10000) ~/ 100;
    final d = snapshotDateYyyymmdd % 100;
    return '${y.toString().padLeft(4, '0')}-'
        '${m.toString().padLeft(2, '0')}-'
        '${d.toString().padLeft(2, '0')}';
  }

  /// 二分查找指定 [bangumiId] 对应的全部 TMDB 映射目标（未命中返回空列表）。
  List<BangumiTmdbTarget> lookup(int bangumiId) {
    if (recordCount == 0 || bangumiId <= 0) return const [];
    // 二分定位首个 >= bangumiId 的下标（lower_bound）。
    var lo = 0;
    var hi = recordCount;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      final midId = _view.getUint32(
        headerBytes + mid * recordSize,
        Endian.little,
      );
      if (midId < bangumiId) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo >= recordCount) return const [];
    final firstId = _view.getUint32(
      headerBytes + lo * recordSize,
      Endian.little,
    );
    if (firstId != bangumiId) return const [];

    final targets = <BangumiTmdbTarget>[];
    for (var i = lo; i < recordCount; i++) {
      final off = headerBytes + i * recordSize;
      final curId = _view.getUint32(off, Endian.little);
      if (curId != bangumiId) break;
      final packed = _view.getUint32(off + 4, Endian.little);
      final rawSeason = _view.getInt16(off + 8, Endian.little);
      final flags = _view.getUint16(off + 10, Endian.little);
      final rawTvdb = supportsTvdbId
          ? _view.getUint32(off + 12, Endian.little)
          : 0;
      final isMovie = (packed & _movieBitMask) != 0;
      final tmdbId = packed & _maxTmdbId;
      targets.add(
        BangumiTmdbTarget(
          type: isMovie ? TmdbMediaType.movie : TmdbMediaType.tv,
          id: tmdbId,
          season: rawSeason >= 0 ? rawSeason : null,
          flags: flags,
          tvdbId: rawTvdb > 0 ? rawTvdb : null,
        ),
      );
    }
    return targets;
  }

  /// 按需惰性构建按 `packedTarget` 升序排列的紧凑反查索引（约 1ms 完成，支持双向 O(log N) 二分查找）。
  void _ensureReverseIndex() {
    if (_reversePackedKeys != null) return;
    if (recordCount == 0) {
      _reversePackedKeys = Uint32List(0);
      _reverseRecordIndices = Uint32List(0);
      return;
    }
    final rawPacked = Uint32List(recordCount);
    final order = List<int>.generate(recordCount, (i) => i, growable: false);
    for (var i = 0; i < recordCount; i++) {
      rawPacked[i] = _view.getUint32(
        headerBytes + i * recordSize + 4,
        Endian.little,
      );
    }
    order.sort((a, b) {
      final cmp = rawPacked[a].compareTo(rawPacked[b]);
      if (cmp != 0) return cmp;
      return a.compareTo(b);
    });
    final sortedKeys = Uint32List(recordCount);
    final sortedIndices = Uint32List(recordCount);
    for (var i = 0; i < recordCount; i++) {
      final recIdx = order[i];
      sortedKeys[i] = rawPacked[recIdx];
      sortedIndices[i] = recIdx;
    }
    _reversePackedKeys = sortedKeys;
    _reverseRecordIndices = sortedIndices;
  }

  /// 在惰性反查数组中定位首个 >= [desiredPacked] 的位置。
  int _reverseLowerBound(int desiredPacked) {
    final keys = _reversePackedKeys!;
    var lo = 0;
    var hi = keys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (keys[mid] < desiredPacked) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// 按 TMDB 媒体类型与 ID 以 O(log N) 二分反查离线映射表中的 TheTVDB ID（仅 v2 索引生效）。
  int? lookupTvdbIdByTmdb({
    required TmdbMediaType mediaType,
    required int tmdbId,
  }) {
    if (!supportsTvdbId || recordCount == 0 || tmdbId <= 0) return null;
    _ensureReverseIndex();
    final desiredPacked =
        (mediaType == TmdbMediaType.movie ? _movieBitMask : 0) |
        (tmdbId & _maxTmdbId);
    final keys = _reversePackedKeys!;
    final indices = _reverseRecordIndices!;
    final start = _reverseLowerBound(desiredPacked);
    for (var i = start; i < keys.length && keys[i] == desiredPacked; i++) {
      final off = headerBytes + indices[i] * recordSize;
      final tvdb = _view.getUint32(off + 12, Endian.little);
      if (tvdb > 0) return tvdb;
    }
    return null;
  }

  /// 按 TMDB 媒体类型、ID（与可选季号）以 O(log N) 离线反查精准 Bangumi 条目列表。
  ///
  /// - 传入 [season] 且 [strictSeason] 为 `true`（默认）时：优先返回精确命中该季号的记录；
  ///   若未找到精确季号但存在无季号作品级映射（`season == null`）且目标为第 1 季或电影，则返回该作品级映射；
  ///   若全部反查记录均明确指向其他冲突季号，返回空列表以回退关键词搜索，严防跨季错配。
  List<BangumiReverseMatch> lookupBangumiIdsByTmdb({
    required TmdbMediaType mediaType,
    required int tmdbId,
    int? season,
    bool strictSeason = true,
  }) {
    if (recordCount == 0 || tmdbId <= 0) return const [];
    _ensureReverseIndex();
    final desiredPacked =
        (mediaType == TmdbMediaType.movie ? _movieBitMask : 0) |
        (tmdbId & _maxTmdbId);
    final keys = _reversePackedKeys!;
    final indices = _reverseRecordIndices!;
    final start = _reverseLowerBound(desiredPacked);
    if (start >= keys.length || keys[start] != desiredPacked) {
      return const [];
    }

    final all = <BangumiReverseMatch>[];
    for (var i = start; i < keys.length && keys[i] == desiredPacked; i++) {
      final off = headerBytes + indices[i] * recordSize;
      final bgmId = _view.getUint32(off, Endian.little);
      final rawSeason = _view.getInt16(off + 8, Endian.little);
      final flags = _view.getUint16(off + 10, Endian.little);
      final rawTvdb = supportsTvdbId
          ? _view.getUint32(off + 12, Endian.little)
          : 0;
      all.add(
        BangumiReverseMatch(
          bangumiId: bgmId,
          season: rawSeason >= 0 ? rawSeason : null,
          flags: flags,
          tvdbId: rawTvdb > 0 ? rawTvdb : null,
        ),
      );
    }

    int sourceRank(int flags) {
      if ((flags & BangumiTmdbTarget.flagOpenAni) != 0) return 0;
      if ((flags & BangumiTmdbTarget.flagBangumiData) != 0) return 1;
      if ((flags & BangumiTmdbTarget.flagWikidata) != 0) return 2;
      if ((flags & BangumiTmdbTarget.flagAnimeListsMap) != 0) return 3;
      return 4;
    }

    if (season != null && mediaType == TmdbMediaType.tv) {
      final exact = all.where((m) => m.season == season).toList();
      if (exact.isNotEmpty) {
        exact.sort((a, b) {
          final bySrc = sourceRank(a.flags).compareTo(sourceRank(b.flags));
          return bySrc != 0 ? bySrc : a.bangumiId.compareTo(b.bangumiId);
        });
        return exact;
      }
      if (strictSeason) {
        // 未标注具体季号的作品级记录仅在查询第 1 季时作为安全兜底，避免第 2/3 季误绑初代条目。
        if (season == 1) {
          final unseasoned = all.where((m) => m.season == null).toList();
          if (unseasoned.isNotEmpty) {
            unseasoned.sort((a, b) {
              final bySrc = sourceRank(a.flags).compareTo(sourceRank(b.flags));
              return bySrc != 0 ? bySrc : a.bangumiId.compareTo(b.bangumiId);
            });
            return unseasoned;
          }
        }
        return const [];
      }
    }

    all.sort((a, b) {
      final aExact = season != null && a.season == season ? 0 : 1;
      final bExact = season != null && b.season == season ? 0 : 1;
      if (aExact != bExact) return aExact.compareTo(bExact);
      final aUnseasoned = a.season == null ? 0 : 1;
      final bUnseasoned = b.season == null ? 0 : 1;
      if (aUnseasoned != bUnseasoned) return aUnseasoned.compareTo(bUnseasoned);
      final bySrc = sourceRank(a.flags).compareTo(sourceRank(b.flags));
      return bySrc != 0 ? bySrc : a.bangumiId.compareTo(b.bangumiId);
    });
    return all;
  }

  /// 优先从当前二进制索引查询；若当前索引为空（如纯离线单测），自动回退静态内置 Wikidata 映射表。
  List<BangumiTmdbTarget> lookupWithStaticFallback(int bangumiId) {
    if (isNotEmpty) {
      return lookup(bangumiId);
    }
    return [
      for (final m in BangumiTmdbMap.lookup(bangumiId))
        BangumiTmdbTarget(
          type: m.type,
          id: m.id,
          flags: BangumiTmdbTarget.flagWikidata,
        ),
    ];
  }

  /// 统一查询入口：当注入了非空 [index] 时走其二进制表，否则回退静态内置 Wikidata 映射表。
  static List<BangumiTmdbTarget> resolveTargets(
    int bangumiId, {
    BangumiTmdbIndex? index,
  }) {
    if (index != null && index.isNotEmpty) {
      return index.lookup(bangumiId);
    }
    return [
      for (final m in BangumiTmdbMap.lookup(bangumiId))
        BangumiTmdbTarget(
          type: m.type,
          id: m.id,
          flags: BangumiTmdbTarget.flagWikidata,
        ),
    ];
  }
}

/// 当前生效映射表的数据来源层级。
enum BangumiTmdbMapSource {
  /// 来自用户便携数据目录的热更新二进制表。
  localHotUpdate,

  /// 来自随安装包内置的离线二进制表。
  bundledAsset,

  /// 回退至静态编译的 Wikidata 公有领域映射表。
  staticFallback,
}

/// 当前已加载的 Bangumi ↔ TMDB 离线映射表只读快照。
class BangumiTmdbSnapshot {
  /// 创建映射表快照对象。
  const BangumiTmdbSnapshot({
    required this.index,
    required this.source,
    required this.snapshotDate,
    required this.sha256Hex,
    this.etag,
    this.lastCheckedAt,
    this.lastMirrorBase,
  });

  /// 只读二分索引实例（空索引时表示回退静态 Wikidata 表）。
  final BangumiTmdbIndex index;

  /// 当前索引数据来源。
  final BangumiTmdbMapSource source;

  /// 可读快照日期（`YYYY-MM-DD`，未知时为空串）。
  final String snapshotDate;

  /// 当前生效二进制索引的小写 SHA-256 摘要（静态回退时为空串）。
  final String sha256Hex;

  /// 上次清单校验记录的 HTTP ETag。
  final String? etag;

  /// 最近一次完成远程检查的时间戳。
  final DateTime? lastCheckedAt;

  /// 记录 [etag] 时对应的镜像根地址，切换镜像时避免跨节点误用 ETag。
  final String? lastMirrorBase;

  /// 覆盖的独立 Bangumi 动画条目数量。
  int get uniqueBangumiCount =>
      index.isNotEmpty ? index.uniqueBangumiCount : BangumiTmdbMap.count;

  /// 索引内包含的目标映射总记录数。
  int get recordCount =>
      index.isNotEmpty ? index.recordCount : BangumiTmdbMap.count;

  /// 面向界面的中文来源标签。
  String get sourceLabel {
    switch (source) {
      case BangumiTmdbMapSource.localHotUpdate:
        return '热更新';
      case BangumiTmdbMapSource.bundledAsset:
        return '内置快照';
      case BangumiTmdbMapSource.staticFallback:
        return '内置基础表';
    }
  }

  /// 复制快照并替换检查元信息。
  BangumiTmdbSnapshot copyWith({
    BangumiTmdbIndex? index,
    BangumiTmdbMapSource? source,
    String? snapshotDate,
    String? sha256Hex,
    String? etag,
    DateTime? lastCheckedAt,
    String? lastMirrorBase,
  }) {
    return BangumiTmdbSnapshot(
      index: index ?? this.index,
      source: source ?? this.source,
      snapshotDate: snapshotDate ?? this.snapshotDate,
      sha256Hex: sha256Hex ?? this.sha256Hex,
      etag: etag ?? this.etag,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
      lastMirrorBase: lastMirrorBase ?? this.lastMirrorBase,
    );
  }
}

/// 单次映射表更新检查的结果状态。
enum BangumiTmdbUpdateState {
  /// 已成功下载校验并原子切换为新快照。
  updated,

  /// 远程版本与本地一致，无需下载。
  upToDate,

  /// 距离上次检查不足自动冷却周期，静默跳过网络请求。
  skippedNotDue,

  /// 所有镜像节点均不可达或校验失败，已安全保留现有快照。
  failed,
}

/// 单次映射表更新检查的强类型回报。
class BangumiTmdbUpdateResult {
  /// 创建更新回报。
  const BangumiTmdbUpdateResult({
    required this.state,
    required this.snapshot,
    required this.message,
    this.mirrorUsed,
  });

  /// 更新结果状态。
  final BangumiTmdbUpdateState state;

  /// 检查完成后的当前生效快照。
  final BangumiTmdbSnapshot snapshot;

  /// 面向设置页或日志的中文状态摘要。
  final String message;

  /// 本次命中成功的镜像根地址（失败或跳过时为空）。
  final String? mirrorUsed;
}
