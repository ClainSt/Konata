import 'dart:typed_data';

import '../models/work.dart';
import 'bangumi_tmdb_map.dart';

/// 单条 Bangumi 到 TMDB 的离线映射目标（含可选精确季号与来源标志）。
class BangumiTmdbTarget {
  /// 创建单条映射目标。
  const BangumiTmdbTarget({
    required this.type,
    required this.id,
    this.season,
    this.flags = 0,
  });

  /// 来源标志位：来自 Wikidata CC0 快照。
  static const int flagWikidata = 1 << 0;

  /// 来源标志位：来自 `open-ani/bangumi-tmdb`（CC BY 4.0）快照。
  static const int flagOpenAni = 1 << 1;

  /// TMDB 媒体类型（剧集或电影）。
  final TmdbMediaType type;

  /// TMDB 条目数字 ID。
  final int id;

  /// 已知精确季号（`null` 表示仅作品级映射或电影）。
  final int? season;

  /// 来源位掩码标志。
  final int flags;

  /// TMDB 复合键（如 `tv:31724` / `movie:23150`）。
  String get key => '${type.name}:$id';

  /// 是否源自 Wikidata 公有领域快照。
  bool get isWikidata => (flags & flagWikidata) != 0;

  /// 是否源自 `open-ani/bangumi-tmdb` 社区核验快照。
  bool get isOpenAni => (flags & flagOpenAni) != 0;
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
}

/// 紧凑只读 Bangumi ↔ TMDB 离线二进制索引（不可变，可零拷贝跨 Isolate 传递）。
///
/// 二进制格式（小端序）：
/// - 24 字节文件头：`KTBM`(4B) + `version=1`(2B) + `recordSize=12`(2B) +
///   `recordCount`(4B) + `uniqueBangumiCount`(4B) + `snapshotDateYyyymmdd`(4B) + `reserved`(4B)；
/// - 每条 12 字节定长记录，按 `bangumiId` 升序排列：
///   `bangumiId`(uint32) + `packedTarget`(uint32，最高位 1 为电影/0 为剧集，低 31 位为 TMDB ID) +
///   `season`(int16，`-1` 表示未知) + `flags`(uint16)。
class BangumiTmdbIndex {
  BangumiTmdbIndex._({
    required Uint8List bytes,
    required this.recordCount,
    required this.uniqueBangumiCount,
    required this.snapshotDateYyyymmdd,
  }) : _bytes = bytes,
       _view = ByteData.sublistView(bytes);

  /// 创建空索引（查询时可按需回退至内置静态 Wikidata 映射表）。
  factory BangumiTmdbIndex.empty() => BangumiTmdbIndex._(
    bytes: Uint8List(0),
    recordCount: 0,
    uniqueBangumiCount: 0,
    snapshotDateYyyymmdd: 0,
  );

  /// 从二进制快照严格校验并解析索引；格式损坏或版本不兼容时抛出 [FormatException]。
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
    if (version != formatVersion || recSize != recordBytes) {
      throw FormatException('不支持的映射表格式版本($version)或记录长度($recSize)');
    }
    final recordCount = view.getUint32(8, Endian.little);
    final uniqueCount = view.getUint32(12, Endian.little);
    final snapshotDate = view.getUint32(16, Endian.little);
    final expectedLen = headerBytes + recordCount * recordBytes;
    if (bytes.length != expectedLen) {
      throw FormatException(
        '映射表字节长度与头声明不一致（实际 ${bytes.length}，期望 $expectedLen）',
      );
    }
    return BangumiTmdbIndex._(
      bytes: bytes,
      recordCount: recordCount,
      uniqueBangumiCount: uniqueCount,
      snapshotDateYyyymmdd: snapshotDate,
    );
  }

  /// 将记录集合排序去重并编码为标准紧凑二进制字节流。
  static Uint8List encode(
    Iterable<BangumiTmdbRecord> records, {
    required int snapshotDateYyyymmdd,
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

    final uniqueBgmIds = <int>{for (final r in sorted) r.bangumiId};
    final out = Uint8List(headerBytes + sorted.length * recordBytes);
    out[0] = _magic0;
    out[1] = _magic1;
    out[2] = _magic2;
    out[3] = _magic3;
    final view = ByteData.sublistView(out);
    view.setUint16(4, formatVersion, Endian.little);
    view.setUint16(6, recordBytes, Endian.little);
    view.setUint32(8, sorted.length, Endian.little);
    view.setUint32(12, uniqueBgmIds.length, Endian.little);
    view.setUint32(16, snapshotDateYyyymmdd, Endian.little);
    view.setUint32(20, 0, Endian.little);

    for (var i = 0; i < sorted.length; i++) {
      final r = sorted[i];
      final off = headerBytes + i * recordBytes;
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
    }
    return out;
  }

  /// 二进制文件头固定长度（24 字节）。
  static const int headerBytes = 24;

  /// 单条定长记录长度（12 字节）。
  static const int recordBytes = 12;

  /// 当前支持的二进制格式版本号。
  static const int formatVersion = 1;

  static const int _magic0 = 0x4B; // 魔数第 1 字节（ASCII 字母 K）
  static const int _magic1 = 0x54; // 魔数第 2 字节（ASCII 字母 T）
  static const int _magic2 = 0x42; // 魔数第 3 字节（ASCII 字母 B）
  static const int _magic3 = 0x4D; // 魔数第 4 字节（ASCII 字母 M）
  static const int _movieBitMask = 0x80000000;
  static const int _maxTmdbId = 0x7FFFFFFF;

  final Uint8List _bytes;
  final ByteData _view;

  /// 索引中的总目标记录条数。
  final int recordCount;

  /// 索引覆盖的独立 Bangumi 动画条目数。
  final int uniqueBangumiCount;

  /// 快照日期（`YYYYMMDD` 整数；未知时为 `0`）。
  final int snapshotDateYyyymmdd;

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
        headerBytes + mid * recordBytes,
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
      headerBytes + lo * recordBytes,
      Endian.little,
    );
    if (firstId != bangumiId) return const [];

    final targets = <BangumiTmdbTarget>[];
    for (var i = lo; i < recordCount; i++) {
      final off = headerBytes + i * recordBytes;
      final curId = _view.getUint32(off, Endian.little);
      if (curId != bangumiId) break;
      final packed = _view.getUint32(off + 4, Endian.little);
      final rawSeason = _view.getInt16(off + 8, Endian.little);
      final flags = _view.getUint16(off + 10, Endian.little);
      final isMovie = (packed & _movieBitMask) != 0;
      final tmdbId = packed & _maxTmdbId;
      targets.add(
        BangumiTmdbTarget(
          type: isMovie ? TmdbMediaType.movie : TmdbMediaType.tv,
          id: tmdbId,
          season: rawSeason >= 0 ? rawSeason : null,
          flags: flags,
        ),
      );
    }
    return targets;
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
