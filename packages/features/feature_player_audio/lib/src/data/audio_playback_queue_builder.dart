import 'dart:math' as math;

import 'package:engine_playback/engine_playback.dart';
import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';
import 'package:path/path.dart' as p;

import 'audio_playback_models.dart';

/// 基于路径层级的轻量 CD 专辑分组结果。
class AudioAlbumGroupInfo {
  /// 创建 CD 专辑分组描述。
  const AudioAlbumGroupInfo({
    required this.albumKey,
    required this.chipLabel,
    this.discLabel,
  });

  /// 稳定的小写化路径分组键。
  final String albumKey;

  /// 用于界面的精简专辑标题。
  final String chipLabel;

  /// 若位于多碟子目录（如 `CD1`/`Disc 2`），记录碟片标签。
  final String? discLabel;
}

/// 纯函数音频播放队列构建器（支持普通音轨、孤立 `.cue` 与伴随 `.cue` 动态分轨展开/收起）。
abstract final class AudioPlaybackQueueBuilder {
  static final RegExp _trackNumPrefixRegex = RegExp(
    r'^(?:\d{1,2}[-.]\d{1,3}|\d{1,3})[\s._-]+',
  );
  static final RegExp _genericTrackStemRegex = RegExp(
    r'^(?:track|tr|disc|cd)?[\s._-]*\d{1,3}$',
    caseSensitive: false,
  );
  static final RegExp _discFolderRegex = RegExp(
    r'^(?:disc|cd|disk)\s*(\d+)$',
    caseSensitive: false,
  );
  static final RegExp _containerFolderRegex = RegExp(
    r'^(?:cd|cds|music|ost|soundtrack|bgm|scans?|booklet|extras?|specials?|sp|bonus)$',
    caseSensitive: false,
  );

  /// 剥离音轨文件名前置曲目编号（例如 `01. Track` -> `Track`）。
  static String stripAudioTrackNumberPrefix(String fileName) {
    final stem = p.basenameWithoutExtension(fileName).trim();
    final stripped = stem.replaceFirst(_trackNumPrefixRegex, '').trim();
    return stripped.isEmpty ? stem : stripped;
  }

  /// 判断剥去后缀与编号后的纯文本是否仅剩下通用轨道代号（如 `Track01`）。
  static bool isGenericTrackStem(String stem) {
    final trimmed = stem.trim();
    if (trimmed.isEmpty) return true;
    return _genericTrackStemRegex.hasMatch(trimmed);
  }

  /// 从变体相对路径提炼专辑键与展示标题，避免跨目录串碟。
  static AudioAlbumGroupInfo resolveAlbumGroup(
    String relativePath, {
    required String fallbackAlbumTitle,
  }) {
    final normalized = normalizeQueuePath(relativePath);
    final dirPath = p.posix.dirname(normalized);
    if (dirPath.isEmpty || dirPath == '.') {
      return AudioAlbumGroupInfo(
        albumKey: 'root',
        chipLabel: fallbackAlbumTitle,
      );
    }
    final segments = dirPath
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return AudioAlbumGroupInfo(
        albumKey: 'root',
        chipLabel: fallbackAlbumTitle,
      );
    }

    String? discLabel;
    final trimmed = List<String>.from(segments);
    final discMatch = _discFolderRegex.firstMatch(trimmed.last.trim());
    if (discMatch != null && trimmed.length >= 2) {
      discLabel = 'Disc ${discMatch.group(1)}';
      trimmed.removeLast();
    }

    while (trimmed.length > 1 && _containerFolderRegex.hasMatch(trimmed.last)) {
      trimmed.removeLast();
    }

    final rawAlbum = trimmed.last.trim();
    final albumKey = trimmed.map((s) => s.toLowerCase()).join('/');
    return AudioAlbumGroupInfo(
      albumKey: albumKey.isEmpty ? 'root' : albumKey,
      chipLabel: rawAlbum.isEmpty ? fallbackAlbumTitle : rawAlbum,
      discLabel: discLabel,
    );
  }

  /// 标准化队列路径（统一正斜杠并消除前导斜杠）。
  static String normalizeQueuePath(String raw) {
    final normalized = raw.replaceAll('\\', '/').trim();
    return normalized.startsWith('/') ? normalized.substring(1) : normalized;
  }

  /// 根据队列条目计算友好的展示曲目标题（兼容泛化文件名并保留扩展多碟信息）。
  static String resolveAudioTrackTitle({
    required String fileName,
    required String relativePath,
    required String albumTitle,
    String? cueTrackTitle,
  }) {
    if (cueTrackTitle != null && cueTrackTitle.trim().isNotEmpty) {
      return cueTrackTitle.trim();
    }
    final baseStem = p.basenameWithoutExtension(fileName);
    final stripped = stripAudioTrackNumberPrefix(fileName);
    if (!isGenericTrackStem(stripped)) {
      return stripped;
    }
    final group = resolveAlbumGroup(
      relativePath,
      fallbackAlbumTitle: albumTitle,
    );
    return group.discLabel != null
        ? '${group.chipLabel} · ${group.discLabel} · $baseStem'
        : baseStem;
  }

  /// 获取某队列条目真实对应的物理音频文件相对路径。
  static String resolvePhysicalMediaPath(AudioQueueItem item) {
    return item.variant.relativePath;
  }

  /// 判断路径后缀是否为 `.cue` 分轨索引清单。
  static bool isCueManifestPath(String relativePath) {
    return p.extension(relativePath).toLowerCase() == '.cue';
  }

  /// 判断两条队列项目是否指向同一媒体源与同一物理流（用于分轨天然连续接力）。
  static bool isSamePhysicalStream(AudioQueueItem? a, AudioQueueItem? b) {
    if (a == null || b == null) return false;
    return a.sourceId == b.sourceId &&
        normalizeQueuePath(resolvePhysicalMediaPath(a)) ==
            normalizeQueuePath(resolvePhysicalMediaPath(b));
  }

  /// 从已解析 `.cue` 清单提取位于同目录的候选音频兄弟路径列表（小写去重）。
  static List<String> extractDirectCueSiblingPaths(
    CueSheet sheet,
    String cueRelativePath,
  ) {
    final cueDir = p.posix.dirname(normalizeQueuePath(cueRelativePath));
    final seen = <String>{};
    final result = <String>[];
    for (final track in sheet.tracks) {
      final rawFile = track.fileName.trim();
      if (rawFile.isEmpty) continue;
      final candidateName = p.posix.basename(rawFile.replaceAll('\\', '/'));
      if (candidateName.isEmpty) continue;
      final joined = cueDir == '.' || cueDir.isEmpty
          ? candidateName
          : '$cueDir/$candidateName';
      final lower = joined.toLowerCase();
      if (seen.add(lower)) {
        result.add(joined);
      }
    }
    return result;
  }

  /// 根据专辑音乐变体列表构建音频队列，自动整合或隐身配对 `.cue` 清单头。
  static List<AudioQueueItem> buildInitialQueue({
    required WorkRecord work,
    required List<MediaVariantRecord> variants,
    required Map<String, MediaSourceView> sourceById,
    MediaVariantRecord? initialVariant,
    CueSheet? initialCueSheet,
    int? initialCueTrackIndex,
    String? activeAlbumKey,
  }) {
    final cdVariants = variants
        .where((v) => v.assetKind == AssetKind.cdAlbum)
        .toList();
    if (cdVariants.isEmpty) return const [];

    final filtered = _filterVariantsByAlbumKey(
      work: work,
      cdVariants: cdVariants,
      activeAlbumKey: activeAlbumKey,
    );
    final sorted = List<MediaVariantRecord>.from(filtered)
      ..sort(
        (a, b) => a.relativePath.toLowerCase().compareTo(
          b.relativePath.toLowerCase(),
        ),
      );

    final pairedCueByAudioPath = <String, MediaVariantRecord>{};
    final orphanCueVariants = <MediaVariantRecord>[];
    final playableAudioVariants = <MediaVariantRecord>[];

    final cues = <MediaVariantRecord>[];
    final audios = <MediaVariantRecord>[];
    for (final v in sorted) {
      if (p.extension(v.fileName).toLowerCase() == '.cue') {
        cues.add(v);
      } else {
        audios.add(v);
      }
    }

    final audioByLowerPath = <String, MediaVariantRecord>{
      for (final a in audios) normalizeQueuePath(a.relativePath).toLowerCase(): a,
    };

    for (final cue in cues) {
      final pair = _findPairedAudioVariant(cue, audios, audioByLowerPath);
      if (pair != null) {
        pairedCueByAudioPath.putIfAbsent(
          normalizeQueuePath(pair.relativePath).toLowerCase(),
          () => cue,
        );
      } else {
        orphanCueVariants.add(cue);
      }
    }
    playableAudioVariants.addAll(audios);

    final initialRelLower = initialVariant == null
        ? null
        : normalizeQueuePath(initialVariant.relativePath).toLowerCase();

    final items = <AudioQueueItem>[];
    for (final v in playableAudioVariants) {
      final source = sourceById[v.sourceId.value];
      if (source == null) continue;
      final relLower = normalizeQueuePath(v.relativePath).toLowerCase();
      final pairedCue = pairedCueByAudioPath[relLower];
      final group = resolveAlbumGroup(
        v.relativePath,
        fallbackAlbumTitle: work.title,
      );

      final isSingleAutoExpandCue =
          pairedCue != null &&
          initialCueSheet != null &&
          initialCueSheet.tracks.isNotEmpty &&
          (initialRelLower == relLower ||
              initialRelLower ==
                  normalizeQueuePath(pairedCue.relativePath).toLowerCase());

      if (isSingleAutoExpandCue) {
        items.addAll(
          _buildExpandedCueTrackItems(
            work: work,
            audioVariant: v,
            audioSource: source,
            cueRelativePath: pairedCue.relativePath,
            sheet: initialCueSheet,
            albumTitle: group.chipLabel,
            albumKey: group.albumKey,
          ),
        );
      } else {
        items.add(
          AudioQueueItem(
            itemId: v.id.value,
            workId: work.id,
            sourceId: v.sourceId,
            variantId: v.id,
            title: resolveAudioTrackTitle(
              fileName: v.fileName,
              relativePath: v.relativePath,
              albumTitle: group.chipLabel,
            ),
            artist: '',
            album: group.chipLabel,
            albumKey: group.albumKey,
            fileName: v.fileName,
            relativePath: v.relativePath,
            source: source,
            variant: v,
            cueSheetPath: pairedCue?.relativePath,
            knownFileSize: v.fileSize,
            posterRef: work.posterRef,
            posterFallback: work.posterFallback,
            bangumiSubjectId: work.bangumiId,
          ),
        );
      }
    }

    for (final orphanCue in orphanCueVariants) {
      final source = sourceById[orphanCue.sourceId.value];
      if (source == null) continue;
      final group = resolveAlbumGroup(
        orphanCue.relativePath,
        fallbackAlbumTitle: work.title,
      );
      items.add(
        AudioQueueItem(
          itemId: orphanCue.id.value,
          workId: work.id,
          sourceId: orphanCue.sourceId,
          variantId: orphanCue.id,
          title: resolveAudioTrackTitle(
            fileName: orphanCue.fileName,
            relativePath: orphanCue.relativePath,
            albumTitle: group.chipLabel,
          ),
          artist: '',
          album: group.chipLabel,
          albumKey: group.albumKey,
          fileName: orphanCue.fileName,
          relativePath: orphanCue.relativePath,
          source: source,
          variant: orphanCue,
          cueSheetPath: orphanCue.relativePath,
          knownFileSize: orphanCue.fileSize,
          posterRef: work.posterRef,
          posterFallback: work.posterFallback,
          bangumiSubjectId: work.bangumiId,
        ),
      );
    }

    if (initialCueTrackIndex != null && items.isNotEmpty) {
      // 仅用于确认分轨定位；实际下标由 resolveTargetQueueIndex 处理。
    }
    return items;
  }

  /// 在队列中定位初始起播索引（优先匹配目标轨号、其次匹配初始变体）。
  static int resolveTargetQueueIndex({
    required List<AudioQueueItem> queue,
    MediaVariantRecord? initialVariant,
    int? initialCueTrackIndex,
  }) {
    if (queue.isEmpty) return -1;
    if (initialVariant != null) {
      final targetLower = normalizeQueuePath(
        initialVariant.relativePath,
      ).toLowerCase();
      if (initialCueTrackIndex != null) {
        final trackHit = queue.indexWhere(
          (item) =>
              item.cueTrackIndex == initialCueTrackIndex &&
              (item.variantId == initialVariant.id ||
                  normalizeQueuePath(item.cueSheetPath ?? '').toLowerCase() ==
                      targetLower ||
                  normalizeQueuePath(item.relativePath).toLowerCase() ==
                      targetLower),
        );
        if (trackHit >= 0) return trackHit;
      }
      final exactHit = queue.indexWhere(
        (item) =>
            item.variantId == initialVariant.id ||
            normalizeQueuePath(item.cueSheetPath ?? '').toLowerCase() ==
                targetLower ||
            normalizeQueuePath(item.relativePath).toLowerCase() == targetLower,
      );
      if (exactHit >= 0) return exactHit;
    }
    return 0;
  }

  /// 生成当前队列的物理播放顺序表（支持顺序模式与确定起点随机洗牌）。
  static List<int> buildPlayOrder({
    required int length,
    required int currentIndex,
    required bool shuffle,
    math.Random? random,
  }) {
    if (length <= 0) return const [];
    final indices = List<int>.generate(length, (i) => i);
    if (!shuffle) return indices;
    final rng = random ?? math.Random();
    if (currentIndex >= 0 && currentIndex < length) {
      final rest = List<int>.from(indices)..remove(currentIndex);
      rest.shuffle(rng);
      return [currentIndex, ...rest];
    }
    indices.shuffle(rng);
    return indices;
  }

  /// 针对队列中的未展开 `.cue` 清单头或伴随清单，就地替换展开虚拟分轨列表。
  static ({List<AudioQueueItem> queue, int insertedStart, int insertedCount})
  expandCueTracksInQueue({
    required List<AudioQueueItem> queue,
    required int targetIndex,
    required WorkRecord work,
    required AudioQueueItem resolvedAudioHost,
    required CueSheet sheet,
    required String cueRelativePath,
  }) {
    if (targetIndex < 0 ||
        targetIndex >= queue.length ||
        sheet.tracks.isEmpty) {
      return (queue: queue, insertedStart: targetIndex, insertedCount: 0);
    }

    final hostItem = queue[targetIndex];
    final expandedItems = _buildExpandedCueTrackItems(
      work: work,
      audioVariant: resolvedAudioHost.variant,
      audioSource: resolvedAudioHost.source,
      cueRelativePath: cueRelativePath,
      sheet: sheet,
      albumTitle: hostItem.album,
      albumKey: hostItem.albumKey,
    );
    if (expandedItems.isEmpty) {
      return (queue: queue, insertedStart: targetIndex, insertedCount: 0);
    }

    final nextQueue = List<AudioQueueItem>.from(queue);
    nextQueue.replaceRange(targetIndex, targetIndex + 1, expandedItems);
    return (
      queue: nextQueue,
      insertedStart: targetIndex,
      insertedCount: expandedItems.length,
    );
  }

  /// 收起某 `.cue` 清单已展开的所有子轨并还原单个代表清单项（非当前播放碟片安全折叠）。
  static ({List<AudioQueueItem> queue, int newCurrentIndex})
  collapseCueTracksInQueue({
    required List<AudioQueueItem> queue,
    required int currentIndex,
    required String cueRelativePath,
  }) {
    final normTarget = normalizeQueuePath(cueRelativePath).toLowerCase();
    final firstIdx = queue.indexWhere(
      (item) =>
          item.isCueTrack &&
          normalizeQueuePath(item.cueSheetPath ?? '').toLowerCase() ==
              normTarget,
    );
    if (firstIdx < 0) {
      return (queue: queue, newCurrentIndex: currentIndex);
    }
    final lastIdx = queue.lastIndexWhere(
      (item) =>
          item.isCueTrack &&
          normalizeQueuePath(item.cueSheetPath ?? '').toLowerCase() ==
              normTarget,
    );

    final firstTrack = queue[firstIdx];
    final currentWasInsideGroup =
        currentIndex >= firstIdx && currentIndex <= lastIdx;
    final collapsedHeader = AudioQueueItem(
      itemId: firstTrack.variantId.value,
      workId: firstTrack.workId,
      sourceId: firstTrack.sourceId,
      variantId: firstTrack.variantId,
      title: resolveAudioTrackTitle(
        fileName: firstTrack.fileName,
        relativePath: firstTrack.relativePath,
        albumTitle: firstTrack.album,
      ),
      artist: firstTrack.artist,
      album: firstTrack.album,
      albumKey: firstTrack.albumKey,
      fileName: firstTrack.fileName,
      relativePath: firstTrack.relativePath,
      source: firstTrack.source,
      variant: firstTrack.variant,
      cueSheetPath: cueRelativePath,
      knownFileSize: firstTrack.knownFileSize,
      cueExpanded: false,
      posterRef: firstTrack.posterRef,
      posterFallback: firstTrack.posterFallback,
      bangumiSubjectId: firstTrack.bangumiSubjectId,
    );

    final removedCount = lastIdx - firstIdx;
    final nextQueue = List<AudioQueueItem>.from(queue);
    nextQueue.replaceRange(firstIdx, lastIdx + 1, [collapsedHeader]);
    int nextIndex = currentIndex;
    if (currentWasInsideGroup) {
      nextIndex = firstIdx;
    } else if (currentIndex > lastIdx) {
      nextIndex = currentIndex - removedCount;
    }
    return (queue: nextQueue, newCurrentIndex: nextIndex);
  }

  /// 生成用于展示层渲染的列表行，支持分轨组插入统一列表头。
  static List<AudioQueueDisplayRow> buildDisplayRows({
    required List<AudioQueueItem> queue,
    required int currentIndex,
  }) {
    final rows = <AudioQueueDisplayRow>[];
    String? activeCueGroup;
    for (var i = 0; i < queue.length; i++) {
      final item = queue[i];
      if (!item.isCueTrack) {
        activeCueGroup = null;
        rows.add(
          AudioQueueDisplayRow(
            kind: item.cueSheetPath != null
                ? AudioQueueDisplayRowKind.cueHeader
                : AudioQueueDisplayRowKind.singleTrack,
            queueIndex: i,
            item: item,
            isActive: i == currentIndex,
          ),
        );
        continue;
      }

      final cueGroupKey =
          normalizeQueuePath(item.cueSheetPath ?? item.relativePath)
              .toLowerCase();
      if (cueGroupKey != activeCueGroup) {
        activeCueGroup = cueGroupKey;
        rows.add(
          AudioQueueDisplayRow(
            kind: AudioQueueDisplayRowKind.cueHeader,
            queueIndex: i,
            item: item,
            isActive: false,
          ),
        );
      }
      rows.add(
        AudioQueueDisplayRow(
          kind: AudioQueueDisplayRowKind.cueTrack,
          queueIndex: i,
          item: item,
          isActive: i == currentIndex,
        ),
      );
    }
    return rows;
  }

  static List<MediaVariantRecord> _filterVariantsByAlbumKey({
    required WorkRecord work,
    required List<MediaVariantRecord> cdVariants,
    required String? activeAlbumKey,
  }) {
    if (activeAlbumKey == null || activeAlbumKey.trim().isEmpty) {
      return cdVariants;
    }
    final targetKey = activeAlbumKey.trim().toLowerCase();
    final matched = cdVariants.where((v) {
      final group = resolveAlbumGroup(
        v.relativePath,
        fallbackAlbumTitle: work.title,
      );
      return group.albumKey == targetKey;
    }).toList();
    return matched.isNotEmpty ? matched : cdVariants;
  }

  static MediaVariantRecord? _findPairedAudioVariant(
    MediaVariantRecord cue,
    List<MediaVariantRecord> audios,
    Map<String, MediaVariantRecord> audioByLowerPath,
  ) {
    final cueNorm = normalizeQueuePath(cue.relativePath);
    final cueDir = p.posix.dirname(cueNorm);
    final cueStem = p.basenameWithoutExtension(cueNorm).toLowerCase();

    for (final ext in const ['.flac', '.wav', '.ape', '.wv', '.m4a', '.mp3']) {
      final exactCandidate = cueDir == '.'
          ? '$cueStem$ext'
          : '${cueDir.toLowerCase()}/$cueStem$ext';
      final exact = audioByLowerPath[exactCandidate];
      if (exact != null) return exact;
    }

    final sameDirAudios = audios.where((a) {
      final aDir = p.posix.dirname(normalizeQueuePath(a.relativePath));
      return aDir.toLowerCase() == cueDir.toLowerCase();
    }).toList();
    if (sameDirAudios.length == 1) {
      return sameDirAudios.first;
    }
    return null;
  }

  static List<AudioQueueItem> _buildExpandedCueTrackItems({
    required WorkRecord work,
    required MediaVariantRecord audioVariant,
    required MediaSourceView audioSource,
    required String cueRelativePath,
    required CueSheet sheet,
    required String albumTitle,
    required String albumKey,
  }) {
    final resolvedAlbum = sheet.title.trim().isNotEmpty
        ? sheet.title.trim()
        : albumTitle;
    final items = <AudioQueueItem>[];
    for (var i = 0; i < sheet.tracks.length; i++) {
      final track = sheet.tracks[i];
      final startSec = track.startSeconds;
      double? endSec = track.endSeconds;
      double estDurationSec = track.durationSeconds ?? 0.0;
      if (endSec == null && i + 1 < sheet.tracks.length) {
        final nextStart = sheet.tracks[i + 1].startSeconds;
        if (nextStart > startSec) {
          endSec = nextStart;
          estDurationSec = nextStart - startSec;
        }
      }
      final trackTitle = track.title.trim().isNotEmpty
          ? track.title.trim()
          : 'Track ${track.trackNumber.toString().padLeft(2, '0')}';
      final trackArtist = track.performer.trim().isNotEmpty
          ? track.performer.trim()
          : sheet.performer;

      items.add(
        AudioQueueItem(
          itemId: '${audioVariant.id.value}#cue:${track.trackNumber}',
          workId: work.id,
          sourceId: audioVariant.sourceId,
          variantId: audioVariant.id,
          title: trackTitle,
          artist: trackArtist,
          album: resolvedAlbum,
          albumKey: albumKey,
          fileName: audioVariant.fileName,
          relativePath: audioVariant.relativePath,
          source: audioSource,
          variant: audioVariant,
          isCueTrack: true,
          cueSheetPath: cueRelativePath,
          cueTrackIndex: track.trackNumber,
          cueTrackTitle: trackTitle,
          startSeconds: startSec,
          endSeconds: endSec,
          durationSeconds: estDurationSec,
          knownFileSize: audioVariant.fileSize,
          cueExpanded: true,
          posterRef: work.posterRef,
          posterFallback: work.posterFallback,
          bangumiSubjectId: work.bangumiId,
        ),
      );
    }
    return items;
  }
}
