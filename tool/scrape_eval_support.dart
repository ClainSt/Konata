import 'dart:io';

import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/domain/scraping/scrape_domain_adapter.dart';
import 'package:konata/infrastructure/sources/directory_scanner.dart';

/// 读取清单并经真实扫描器与归组拆分器得到作品分组，同时返回扫描与归组耗时（毫秒）。
Future<({List<GroupedWorkFolder> groups, int files, int scanMs, int groupMs})>
groupListing(
  String listingPath, {
  List<String> roots = const [],
  bool detectLocalCovers = false,
}) async {
  final gateway = ListingGateway.fromListing(
    File(listingPath).readAsLinesSync(),
  );
  final clock = Stopwatch()..start();
  final scan = await const DirectoryScanner().scan(
    gateway,
    scanRoots: roots,
    detectLocalCovers: detectLocalCovers,
  );
  final scanMs = clock.elapsedMilliseconds;
  final groups = ScrapeDomainAdapter.groupAndSplitFiles(
    sourceId: 'eval',
    files: scan.files,
    nfoByFolder: scan.nfoByFolder,
    localCoverByFolder: detectLocalCovers ? scan.localCoverByFolder : const {},
  );
  return (
    groups: groups,
    files: scan.files.length,
    scanMs: scanMs,
    groupMs: clock.elapsedMilliseconds - scanMs,
  );
}

/// 把单个作品分组导出为评测用 JSON（含逐文件分类、季、集、特典类型与系列主干）。
Map<String, Object?> dumpGroup(GroupedWorkFolder g) {
  final slots = g.slotAssignmentsByPath;
  // 正片逻辑条目的系列标题主干（用于识别不同系列主干被误并为同集多版本）。
  final stems = <String, String>{};
  for (final item in g.inventory?.main ?? const []) {
    for (var i = 0; i < item.files.length; i++) {
      stems[item.files[i].replaceAll(r'\', '/')] = i < item.titles.length
          ? item.titles[i]
          : item.title;
    }
  }
  String? stemOf(String relativePath) {
    for (final e in stems.entries) {
      if (relativePath == e.key || relativePath.endsWith('/${e.key}')) {
        return e.value;
      }
    }
    return null;
  }

  return {
    'folder': g.folderRelativePath,
    'physical': g.physicalRootFolder,
    'name': g.folderName,
    'title': g.cleanTitle,
    'year': g.year,
    'searchYear': ScrapeDomainAdapter.extractSearchYear(g),
    'season': g.seasonHint,
    'tmdb': g.explicitTmdbId,
    'tmdbType': g.explicitMediaType?.name,
    'movie': g.isMovieHint,
    'split': g.isSplitCluster,
    'titleHints': g.titleHints,
    'fileHints': g.fileHints,
    'extraQueries': g.extraSearchQueries,
    'queries': ScrapeDomainAdapter.buildSearchQueries(g),
    'mainEps': g.mainEpisodeNumbers,
    'files': [
      for (final v in g.variants)
        {
          'p': v.relativePath,
          'k': v.assetKind.name,
          'z': v.fileSize,
          if (v.externalSubtitles.isNotEmpty) 'sub': v.externalSubtitles,
          if (slots[v.relativePath] case final s?) ...{
            'c': s.category == EpisodeCategory.main ? 'main' : 'extra',
            's': s.seasonNumber,
            'e': s.episodeNumber,
            if (s.episodeEnd != null) 'ee': s.episodeEnd,
            if (s.fractionalLabel != null) 'f': s.fractionalLabel,
            if (s.extraType != null) 'x': s.extraType!.name,
            if (s.extraTitleHint != null) 't': s.extraTitleHint,
            if (s.category == EpisodeCategory.main)
              'st': ?stemOf(v.relativePath),
          },
        },
    ],
  };
}

/// 由静态清单构建的只读内存目录树网关。
class ListingGateway implements MediaSourceGateway {
  ListingGateway._(this._children);

  /// 从 `路径	字节数` 清单行构建目录树。
  factory ListingGateway.fromListing(List<String> lines) {
    final children = <String, Map<String, RemoteEntry>>{};
    for (final raw in lines) {
      final line = raw.replaceFirst('﻿', '').trimRight();
      if (line.isEmpty) continue;
      final tab = line.lastIndexOf('\t');
      final path = (tab < 0 ? line : line.substring(0, tab))
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'^/+'), '');
      final size = tab < 0 ? 0 : int.tryParse(line.substring(tab + 1)) ?? 0;
      final segs = path.split('/');
      var parent = '';
      for (var i = 0; i < segs.length; i++) {
        final rel = parent.isEmpty ? segs[i] : '$parent/${segs[i]}';
        final isDir = i < segs.length - 1;
        children
            .putIfAbsent(parent, () => {})
            .putIfAbsent(
              segs[i],
              () => RemoteEntry(
                name: segs[i],
                relativePath: rel,
                isDirectory: isDir,
                size: isDir ? 0 : size,
              ),
            );
        parent = rel;
      }
    }
    return ListingGateway._(children);
  }

  final Map<String, Map<String, RemoteEntry>> _children;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async =>
      _children[relativePath]?.values.toList(growable: false) ?? const [];

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 262144,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}
