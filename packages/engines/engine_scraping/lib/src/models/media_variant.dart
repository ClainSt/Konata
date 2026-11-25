import 'package:konata_contracts/konata_contracts.dart';

export 'package:konata_contracts/konata_contracts.dart'
    show AssetKind, SupplementaryAssetScope;

/// 物理文件与多版本规格领域实体。
class MediaVariant {
  /// 创建物理版本记录实例。
  const MediaVariant({
    required this.id,
    required this.workId,
    this.episodeId,
    required this.sourceId,
    required this.relativePath,
    required this.fileName,
    required this.fileSize,
    this.remoteFileId,
    this.assetKind = AssetKind.video,
    this.releaseGroup,
    this.subtitleGroup,
    this.videoCodec,
    this.bitDepth,
    this.resolution,
    this.audioCodec,
    this.externalSubtitles = const [],
    this.mappingLocked = false,
    this.workLocked = false,
    this.assetScope = SupplementaryAssetScope.workExclusive,
    this.scopeLocked = false,
  });

  /// 文件记录主键。
  final String id;

  /// 所属作品 ID。
  final String workId;

  /// 关联的逻辑剧集 ID（尚未映射或未分集时可空）。
  final String? episodeId;

  /// 所属媒体源 ID。
  final String sourceId;

  /// 相对于媒体源根目录的路径。
  final String relativePath;

  /// 文件名（含扩展名）。
  final String fileName;

  /// 文件字节大小。
  final int fileSize;

  /// 云盘文件稳定标识；非云盘或未知时为空。
  final String? remoteFileId;

  /// 资产类型（视频 / CD 专辑 / 扫图）。
  final AssetKind assetKind;

  /// 压制组名称（如 `VCB-Studio`、`ANK-Raws`）。
  final String? releaseGroup;

  /// 字幕组名称（如 `澄空学园`、`SweetSub`）。
  final String? subtitleGroup;

  /// 视频编码（如 `HEVC`、`AVC`、`AV1`）。
  final String? videoCodec;

  /// 色深（如 `10bit`、`8bit`）。
  final String? bitDepth;

  /// 分辨率（如 `1080p`、`2160p`）。
  final String? resolution;

  /// 音频编码（如 `FLAC`、`AAC`、`OPUS`）。
  final String? audioCodec;

  /// 关联的外挂字幕相对路径列表。
  final List<String> externalSubtitles;

  /// 该文件到逻辑剧集/特典槽位的映射是否已被人工锁定（防止重扫或刷新重置）。
  final bool mappingLocked;

  /// 该物理文件的作品归属是否已被人工锁定（拆分后重扫或刷新严禁合并回原作品）。
  final bool workLocked;

  /// 该物理文件作为附属资源在系列内的可见范围（独享或全系列共享）。
  final SupplementaryAssetScope assetScope;

  /// 该文件在系列内的可见作用域是否已被人工锁定。
  final bool scopeLocked;

  /// 复制并按需替换物理版本字段。
  MediaVariant copyWith({
    String? workId,
    String? episodeId,
    bool clearEpisodeId = false,
    String? relativePath,
    String? fileName,
    AssetKind? assetKind,
    bool? mappingLocked,
    bool? workLocked,
    SupplementaryAssetScope? assetScope,
    bool? scopeLocked,
  }) {
    return MediaVariant(
      id: id,
      workId: workId ?? this.workId,
      episodeId: clearEpisodeId ? null : (episodeId ?? this.episodeId),
      sourceId: sourceId,
      relativePath: relativePath ?? this.relativePath,
      fileName: fileName ?? this.fileName,
      fileSize: fileSize,
      remoteFileId: remoteFileId,
      assetKind: assetKind ?? this.assetKind,
      releaseGroup: releaseGroup,
      subtitleGroup: subtitleGroup,
      videoCodec: videoCodec,
      bitDepth: bitDepth,
      resolution: resolution,
      audioCodec: audioCodec,
      externalSubtitles: externalSubtitles,
      mappingLocked: mappingLocked ?? this.mappingLocked,
      workLocked: workLocked ?? this.workLocked,
      assetScope: assetScope ?? this.assetScope,
      scopeLocked: scopeLocked ?? this.scopeLocked,
    );
  }
}
