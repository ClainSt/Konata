import 'package:engine_scraping/engine_scraping.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 作品扫图画廊查询数据集（包含自身扫图、同系列共享扫图与关联媒体源）。
final class ScanWorkDataset {
  /// 创建扫图查询数据集。
  const ScanWorkDataset({
    required this.work,
    required this.scanVariants,
    required this.sourcesById,
    required this.sourceViewsById,
    required this.scanSummary,
    required this.showSeriesSharedBadge,
  });

  /// 空数据集常量。
  static const ScanWorkDataset empty = ScanWorkDataset(
    work: null,
    scanVariants: <MediaVariant>[],
    sourcesById: <String, MediaSourceRecord>{},
    sourceViewsById: <String, MediaSourceView>{},
    scanSummary: ScanVolumeGroupSummary(
      chips: <({String key, String label, int count})>[],
      byVariantId: <String, ScanVolumeGroupingResult>{},
      hasMultipleSubdirs: false,
    ),
    showSeriesSharedBadge: false,
  );

  /// 目标作品记录（未找到或已软删除时为 `null`）。
  final WorkRecord? work;

  /// 按当前作品优先与相对路径排序的可用扫图变体列表。
  final List<MediaVariant> scanVariants;

  /// 全量有效媒体源持久化记录字典（键为 `sourceId`）。
  final Map<String, MediaSourceRecord> sourcesById;

  /// 全量有效媒体源只读视图字典（键为 `sourceId`）。
  final Map<String, MediaSourceView> sourceViewsById;

  /// 二级分卷与子目录分组汇总。
  final ScanVolumeGroupSummary scanSummary;

  /// 当前作品所在系列是否存在 2 个及以上成员（用于控制「系列共用」角标展示）。
  final bool showSeriesSharedBadge;
}

/// 基于 `KonataDatabaseBundle` 查询作品及其同系列 `seriesShared` 扫图资产的纯数据仓储。
abstract final class ScanGalleryRepository {
  /// 将存储层持久化记录投影为领域实体模型供分卷聚合与调度器复用。
  static MediaVariant toDomainVariant(MediaVariantRecord record) {
    return MediaVariant(
      id: record.id.value,
      workId: record.workId.value,
      episodeId: record.episodeId?.value,
      sourceId: record.sourceId.value,
      relativePath: record.relativePath,
      fileName: record.fileName,
      fileSize: record.fileSize,
      assetKind: record.assetKind,
      releaseGroup: record.releaseGroup,
      subtitleGroup: record.subtitleGroup,
      videoCodec: record.videoCodec,
      bitDepth: record.bitDepth,
      resolution: record.resolution,
      audioCodec: record.audioCodec,
      externalSubtitles: record.externalSubtitles,
      mappingLocked: record.mappingLocked,
      workLocked: record.workLocked,
      assetScope: record.assetScope,
      scopeLocked: record.scopeLocked,
    );
  }

  /// 快速统计作品下可见的扫图总张数（含同系列 `seriesShared` 扫图变体）。
  static int countScansForWork(
    KonataDatabaseBundle databases,
    WorkId workId,
  ) {
    return _collectVisibleScanRecords(databases, workId).records.length;
  }

  /// 快速判断作品下是否存在可用扫图资产（供详情页动态控制「扫图」标签显示）。
  static bool hasScansForWork(
    KonataDatabaseBundle databases,
    WorkId workId,
  ) {
    final work = databases.library.works.findById(workId);
    if (work == null) return false;

    final ownVariants = databases.library.mediaVariants.listByWork(workId);
    for (final v in ownVariants) {
      if (v.assetKind == AssetKind.scanGallery) return true;
    }

    final seriesId = work.seriesId;
    if (seriesId == null) return false;
    final members = databases.library.works.listBySeries(seriesId);
    for (final member in members) {
      if (member.id == work.id || _isSameInstallment(work, member)) {
        continue;
      }
      final memberVariants = databases.library.mediaVariants.listByWork(
        member.id,
      );
      for (final v in memberVariants) {
        if (v.assetKind == AssetKind.scanGallery &&
            v.assetScope == SupplementaryAssetScope.seriesShared) {
          return true;
        }
      }
    }
    return false;
  }

  /// 查询指定作品可见的全部扫图变体、同系列共享变体及所属媒体源映射。
  static ScanWorkDataset loadWorkDataset(
    KonataDatabaseBundle databases,
    WorkId workId, {
    PhotosStorage? photosStorage,
  }) {
    final collected = _collectVisibleScanRecords(
      databases,
      workId,
      photosStorage: photosStorage,
    );
    final work = collected.work;
    if (work == null) return ScanWorkDataset.empty;

    final sources = databases.library.mediaSources.listAll();
    final sourcesById = <String, MediaSourceRecord>{
      for (final src in sources) src.id.value: src,
    };
    final sourceViewsById = <String, MediaSourceView>{
      for (final src in sources) src.id.value: src.toReadView(),
    };

    final variants = collected.records
        .map(toDomainVariant)
        .toList(growable: false);
    final scanSummary = SupplementarySubclassifier.groupScanVariants(variants);

    return ScanWorkDataset(
      work: work,
      scanVariants: List<MediaVariant>.unmodifiable(variants),
      sourcesById: Map<String, MediaSourceRecord>.unmodifiable(sourcesById),
      sourceViewsById: Map<String, MediaSourceView>.unmodifiable(sourceViewsById),
      scanSummary: scanSummary,
      showSeriesSharedBadge: collected.seriesMemberCount >= 2,
    );
  }

  static ({
    WorkRecord? work,
    List<MediaVariantRecord> records,
    int seriesMemberCount,
  })
  _collectVisibleScanRecords(
    KonataDatabaseBundle databases,
    WorkId workId, {
    PhotosStorage? photosStorage,
  }) {
    final work = databases.library.works.findById(workId);
    if (work == null) {
      return (work: null, records: const <MediaVariantRecord>[], seriesMemberCount: 0);
    }
    photosStorage?.cacheWorkTitle(work.id.value, work.title);

    final ownVariants = databases.library.mediaVariants.listByWork(workId);
    final seenPaths = <String>{};
    final scanRecords = <MediaVariantRecord>[];

    for (final v in ownVariants) {
      if (v.assetKind != AssetKind.scanGallery) continue;
      final pathKey = '${v.sourceId.value}::${v.relativePath.toLowerCase()}';
      if (seenPaths.add(pathKey)) {
        scanRecords.add(v);
      }
    }

    var memberCount = 1;
    final seriesId = work.seriesId;
    if (seriesId != null) {
      final members = databases.library.works.listBySeries(seriesId);
      memberCount = members.isEmpty ? 1 : members.length;
      for (final member in members) {
        photosStorage?.cacheWorkTitle(member.id.value, member.title);
        if (member.id == work.id || _isSameInstallment(work, member)) {
          continue;
        }
        final memberVariants = databases.library.mediaVariants.listByWork(
          member.id,
        );
        for (final v in memberVariants) {
          if (v.assetKind != AssetKind.scanGallery ||
              v.assetScope != SupplementaryAssetScope.seriesShared) {
            continue;
          }
          final pathKey =
              '${v.sourceId.value}::${v.relativePath.toLowerCase()}';
          if (seenPaths.add(pathKey)) {
            scanRecords.add(v);
          }
        }
      }
    }

    scanRecords.sort((a, b) {
      final aOwn = a.workId == work.id;
      final bOwn = b.workId == work.id;
      if (aOwn != bOwn) return aOwn ? -1 : 1;
      return a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      );
    });

    return (
      work: work,
      records: scanRecords,
      seriesMemberCount: memberCount,
    );
  }

  static bool _isSameInstallment(WorkRecord current, WorkRecord candidate) {
    return current.tmdbId != null &&
        candidate.tmdbId == current.tmdbId &&
        candidate.tmdbMediaType == current.tmdbMediaType &&
        candidate.matchedSeason == current.matchedSeason;
  }
}
