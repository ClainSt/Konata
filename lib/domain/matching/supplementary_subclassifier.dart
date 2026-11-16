import '../models/episode.dart';
import '../models/media_variant.dart';

/// CD 二级分类提取结果（聚合至专辑层，不因 Disc 1 / Disc 2 拆碎二级筛选标签）。
class CdAlbumGroupingResult {
  /// 创建 CD 专辑分组结果。
  const CdAlbumGroupingResult({
    required this.albumKey,
    required this.chipLabel,
    this.discLabel,
    this.directSubdirShort,
    this.versionTag,
  });

  /// 用于分组归并的规范化专辑目录键（不含最末 `Disc 1 / CD1` 层）。
  final String albumKey;

  /// 二级筛选胶囊展示的精简可读专辑短名（同名多版本时自动附带版本后缀）。
  final String chipLabel;

  /// 若位于多碟子目录（如 `disc 1` / `CD2`），记录规范化碟片名（如 `Disc 1`）。
  final String? discLabel;

  /// 若展示卡片位于「全部」筛选下且存在多目录分层时的直接子目录短名。
  final String? directSubdirShort;

  /// 从专辑目录名提炼出的版本/规格标签（如 `24bit/48kHz`、`初回限定盤`、`FLAC+WebP`）。
  final String? versionTag;

  /// 复制并更新消歧后的标签与版本标识。
  CdAlbumGroupingResult copyWith({
    String? chipLabel,
    String? directSubdirShort,
    String? versionTag,
  }) {
    return CdAlbumGroupingResult(
      albumKey: albumKey,
      chipLabel: chipLabel ?? this.chipLabel,
      discLabel: discLabel,
      directSubdirShort: directSubdirShort ?? this.directSubdirShort,
      versionTag: versionTag ?? this.versionTag,
    );
  }
}

/// CD 音轨批量分组汇总。
class CdAlbumGroupSummary {
  /// 创建 CD 分组汇总。
  const CdAlbumGroupSummary({
    required this.chips,
    required this.byVariantId,
    required this.hasMultipleSubdirs,
  });

  /// 按自然序排列的 `(albumKey, chipLabel, count)` 列表。
  final List<({String key, String label, int count})> chips;

  /// 每个 CD `MediaVariant.id` 对应的分组详情。
  final Map<String, CdAlbumGroupingResult> byVariantId;

  /// 当前作品 CD 资产是否跨多个子目录/分碟存放。
  final bool hasMultipleSubdirs;
}

/// Scan 分卷二级标签提取结果。
class ScanVolumeGroupingResult {
  /// 创建 Scan 分卷分组结果。
  const ScanVolumeGroupingResult({
    this.volumeKey,
    this.chipLabel,
    this.directSubdirShort,
  });

  /// 规范化分卷键；若全部扫图平铺在单一根 `Scans/` 下则为 `null`。
  final String? volumeKey;

  /// 二级筛选胶囊展示的分卷/画册短名；平铺时为 `null`。
  final String? chipLabel;

  /// 卡片副标题展示的直接所属子目录短名；平铺时为 `null`。
  final String? directSubdirShort;
}

/// Scan 扫图批量分组汇总。
class ScanVolumeGroupSummary {
  /// 创建 Scan 分组汇总。
  const ScanVolumeGroupSummary({
    required this.chips,
    required this.byVariantId,
    required this.hasMultipleSubdirs,
  });

  /// 按自然序排列的 `(volumeKey, chipLabel, count)` 列表。
  final List<({String key, String label, int count})> chips;

  /// 每个 Scan `MediaVariant.id` 对应的分卷分组详情。
  final Map<String, ScanVolumeGroupingResult> byVariantId;

  /// 当前作品 Scan 是否存在多个分卷/分册子目录。
  final bool hasMultipleSubdirs;
}

/// 基于全量真实云盘样本拟定并获批的「特典 / CD / Scan」纯领域二级分类与标题提炼器（零 IO）。
abstract final class SupplementarySubclassifier {
  /// 特典 7 大标准二级分类的固定展示顺序。
  static const List<ExtraKind> extraKindDisplayOrder = <ExtraKind>[
    ExtraKind.ncop,
    ExtraKind.nced,
    ExtraKind.pv,
    ExtraKind.menu,
    ExtraKind.mv,
    ExtraKind.ova,
    ExtraKind.sp,
  ];

  /// 返回特典标准二级分类中文名称。
  static String extraKindLabel(ExtraKind kind) {
    return switch (kind) {
      ExtraKind.ncop => '无字幕片头',
      ExtraKind.nced => '无字幕片尾',
      ExtraKind.pv => '预告宣传',
      ExtraKind.menu => '光盘菜单',
      ExtraKind.mv => '音乐映像',
      ExtraKind.ova => 'OVA / OAD',
      ExtraKind.sp => '特别篇与花絮',
    };
  }

  // ===== 决策点 1：显式文件名语义正则（优先于父目录与 MV 词根）=====

  static const String _promoQualifierPrefixPattern =
      r'(?:character|char|teaser|main|climax|story|world|concept|action|'
      r'cast|final|new|launch|release|special|sp|web|bd|blu-?ray|tv|dvd|'
      r'\d{1,2}(?:st|nd|rd|th)|第\s*\d{1,2}\s*[弾弹]|先行|本[篇編]?|番宣|主題歌|'
      r'キャラクター|ティザー|メイン|クライマックス)';

  static final RegExp _explicitNcopFileRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:'
    r'nc[\s._-]*op(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?(?:[\s._-]*(?:ver|v\d+))?|[\s._-]*(?:ver|v\d+))?|'
    r'clean[\s._-]*(?:op|opening)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'creditless[\s._-]*(?:op|opening)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'ノンクレジット[\s._-]*(?:op|opening)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'ノンテロップ[\s._-]*(?:op|opening)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?'
    r')(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _explicitNcedFileRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:'
    r'nc[\s._-]*ed(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?(?:[\s._-]*(?:ver|v\d+))?|[\s._-]*(?:ver|v\d+))?|'
    r'clean[\s._-]*(?:ed|ending)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'creditless[\s._-]*(?:ed|ending)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'chorei[\s._-]*ending(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'ノンクレジット[\s._-]*(?:ed|ending)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?|'
    r'ノンテロップ[\s._-]*(?:ed|ending)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?)?'
    r')(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  /// 显式花絮/Making/访谈/评论词：优先级高于 `[MV]` 标签与 `MV/MVs/` 父目录。
  static final RegExp _explicitSpMakingFileRegex = RegExp(
    r'メイキング|making|behind[\s._-]*the[\s._-]*scenes?|花絮|制作[過过]程|'
    r'interviews?|インタビュー|访谈|訪談|舞台挨拶|振り付け|choreograph\w*|'
    r'cast[\s._-]*talk|オーディオコメンタリー|audio[\s._-]*commentary|commentary|'
    r'picture[\s._-]*drama|ピクチャードラマ|総集編|总集篇|'
    r'(?:^|[\s._\-\[\(【])iv[\s._-]*\d+(?=$|[\s._\-\]\)】])|'
    r'[\[\(【]\s*iv(?:\s*\d+)?\s*[\]\)】]',
    caseSensitive: false,
  );

  // 注意：包含显式 PV/CM/Trailer/Preview 及其语义限定前缀（如 Character PV / Teaser PV / Main PV / Climax PV / BD CM / TV CM）时归入预告宣传。
  static final RegExp _explicitPvCmFileRegex = RegExp(
    '(?:^|[\\s._\\-\\[\\(【])(?:'
    '(?:$_promoQualifierPrefixPattern(?:[\\s._-]*$_promoQualifierPrefixPattern)*[\\s._-]*)?(?:'
    r'web[\s._-]*previews?[\s._-]*\d*|'
    r'previews?[\s._-]*\d*|'
    r'trailers?[\s._-]*\d*|'
    r'teasers?[\s._-]*\d*|'
    r'pv(?:[\s._-]*cm)?[\s._-]*\d*|'
    r'cm[\s._-]*\d*|'
    r'(?:tv|web)[\s._-]*spots?[\s._-]*\d*|'
    r'spots?[\s._-]*\d*'
    r')|'
    r'-?sample'
    r')(?=$|[\s._\-\]\)】])|番宣|特報|予告|告知|PV集|CM集',
    caseSensitive: false,
  );

  static final RegExp _explicitMenuFileRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:'
    r'menus?(?:[\s._-]*ex)?[\s._-]*\d*|'
    r'bd[\s._-]*menus?[\s._-]*\d*|'
    r'dvd[\s._-]*menus?[\s._-]*\d*|'
    r'top[\s._-]*menu'
    r')(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _explicitOvaFileRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:ova|oad)[\s._-]*\d*(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _explicitMvFileRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:'
    r'mv[\s._-]*\d*|'
    r'music[\s._-]*(?:video|clip)s?[\s._-]*\d*'
    r')(?=$|[\s._\-\]\)】])|ミュージッククリップ|実写[\s._-]*mv',
    caseSensitive: false,
  );

  // ===== 父目录回退正则 =====

  static final RegExp _mvDirSeg = RegExp(
    r'^(?:mv|mvs|music[\s._-]*videos?|music[\s._-]*clips?|ミュージックビデオ)$',
    caseSensitive: false,
  );
  static final RegExp _menuDirSeg = RegExp(
    r'^(?:menus?|bd[\s._-]*menus?|dvd[\s._-]*menus?)$',
    caseSensitive: false,
  );
  static final RegExp _ncopDirSeg = RegExp(
    r'^(?:nc[\s._-]*op|op|opening|openings)$',
    caseSensitive: false,
  );
  static final RegExp _ncedDirSeg = RegExp(
    r'^(?:nc[\s._-]*ed|ed|ending|endings)$',
    caseSensitive: false,
  );
  static final RegExp _ncGenericDirSeg = RegExp(
    r'^(?:nc|creditless|textless|creditless[\s._-]*op[\s._-]*eds?)$',
    caseSensitive: false,
  );
  static final RegExp _pvDirSeg = RegExp(
    r'^(?:pv|pvs|cm|cms|previews?|web[\s._-]*previews?|trailers?|teasers?|予告|预告)$',
    caseSensitive: false,
  );
  static final RegExp _ovaDirSeg = RegExp(
    r'^(?:ova|ovas|oad|oads)$',
    caseSensitive: false,
  );

  static final RegExp _ncChildOpHint = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:nc[\s._-]*)?(?:op|opening)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?(?:[\s._-]*(?:ver|v\d+))?|[\s._-]*(?:ver|v\d+))?(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );
  static final RegExp _ncChildEdHint = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:nc[\s._-]*)?(?:ed|ending)(?:[\s._-]*\d+(?:[\s._-]*(?!v\d|ver\b)[a-z])?(?:[\s._-]*(?:ver|v\d+))?|[\s._-]*(?:ver|v\d+))?(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  /// 判断视频文件名前缀语义是否命中显式强分类规则（排除纯泛化归属）。
  ///
  /// 严格遵循决策点 1：当文件名明确包含 `メイキング / Making / 花絮 / Interview / 访谈 / [IV]`
  /// 等花絮访谈词时，优先归入 [ExtraKind.sp]（即使处于 `MVs/` 目录或文件名带有 `実写MV`）；
  /// 仅当文件名不含显式类型词时（如纯歌名 `Garden ~(K)NoW_NAME~.mkv`），回退由调用方按父目录判定。
  static ExtraKind? detectExplicitExtraKindFromFileName(String fileName) {
    final stem = _stripExtension(fileName);
    if (stem.isEmpty) return null;
    if (_explicitNcopFileRegex.hasMatch(stem)) return ExtraKind.ncop;
    if (_explicitNcedFileRegex.hasMatch(stem)) return ExtraKind.nced;
    if (_explicitSpMakingFileRegex.hasMatch(stem)) return ExtraKind.sp;
    if (_explicitMenuFileRegex.hasMatch(stem)) return ExtraKind.menu;
    if (_explicitPvCmFileRegex.hasMatch(stem)) return ExtraKind.pv;
    if (_explicitOvaFileRegex.hasMatch(stem)) return ExtraKind.ova;
    if (_explicitMvFileRegex.hasMatch(stem)) return ExtraKind.mv;
    return null;
  }

  /// 对特典视频执行标准 7 类二级归类（统一供扫描入库与详情页动态筛选调用）。
  static ExtraKind classifyExtraVideo({
    required String fileName,
    String? relativePath,
    ExtraKind? fallbackExtraType,
  }) {
    final explicitFromFile = detectExplicitExtraKindFromFileName(fileName);
    if (explicitFromFile != null) return explicitFromFile;

    final path = (relativePath ?? '').replaceAll('\\', '/').trim();
    if (path.isNotEmpty) {
      final segs = path
          .split('/')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      if (segs.length > 1) {
        final stem = _stripExtension(fileName);
        final parentSegs = segs.sublist(0, segs.length - 1);
        for (var i = parentSegs.length - 1; i >= 0; i--) {
          final seg = _stripTrailingTechBrackets(parentSegs[i]);
          if (seg.isEmpty) continue;
          if (_mvDirSeg.hasMatch(seg)) return ExtraKind.mv;
          if (_menuDirSeg.hasMatch(seg)) return ExtraKind.menu;
          if (_ncopDirSeg.hasMatch(seg)) return ExtraKind.ncop;
          if (_ncedDirSeg.hasMatch(seg)) return ExtraKind.nced;
          if (_pvDirSeg.hasMatch(seg)) return ExtraKind.pv;
          if (_ovaDirSeg.hasMatch(seg)) return ExtraKind.ova;
          if (_ncGenericDirSeg.hasMatch(seg)) {
            if (_ncChildOpHint.hasMatch(stem)) return ExtraKind.ncop;
            if (_ncChildEdHint.hasMatch(stem)) return ExtraKind.nced;
          }
        }
      }
    }

    return fallbackExtraType ?? ExtraKind.sp;
  }

  // ===== CD 路径与专辑短名清洗（决策点 2 与 CD 二级筛选共用）=====

  static final RegExp _cdRootContainerSeg = RegExp(
    r'^(?:cds?|ost|soundtracks?|original[\s._-]*soundtracks?|music)$',
    caseSensitive: false,
  );
  static final RegExp _cdDiscSubdirSeg = RegExp(
    r'^(?:dis[ck]|cd)[\s._-]*0*(\d{1,2})(?:\s*[\(\[（【][^)\]）】]*[\)\]）】])?$',
    caseSensitive: false,
  );
  static final RegExp _cdVideoContainerSubdirSeg = RegExp(
    r'^(?:bdrip|dvdrip|bdmv|video_ts|stream|sps?|extras?|bonus|mv|mvs|dvd|bd)$',
    caseSensitive: false,
  );
  static final RegExp _cdAlbumWrapperHint = RegExp(
    r'(?:\[(?:EAC|FLAC|HQCD|MP3|WAV|AAC|ALAC|Hi-?Res)\]|'
    r'[\[(（【]\s*(?:19|20)?\d{2}[01]\d[0-3]\d\s*[\])）】]|'
    r'\(\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|alac)[^)]*\))',
    caseSensitive: false,
  );
  static final RegExp _seasonShellSeg = RegExp(
    r'^(?:s\d{1,2}|season[\s._-]*\d{1,2}|第[0-9一二三四五六七八九十百]+[季期])$',
    caseSensitive: false,
  );
  static final RegExp _meaninglessStreamStem = RegExp(
    r'^(?:0+\d*|\d{5}|VTS_\d+(?:_\d+)?|VIDEO_TS|STREAM|BDMV|TITLE_?\d+|CHAPTER_?\d+|TRACK_?\d+)$',
    caseSensitive: false,
  );

  static bool _isCdVideoDiscOrAlbumSeg(String seg) {
    final trimmed = seg.trim();
    if (trimmed.isEmpty) return false;
    return _cdRootContainerSeg.hasMatch(trimmed) ||
        _cdAlbumWrapperHint.hasMatch(trimmed);
  }

  /// 判断一个特典视频是否附属于某个 CD / 单曲 / OST 目录（决策点 2）。
  static bool isCdBundledExtraVideo(
    String relativePath, {
    List<MediaVariant> allWorkVariants = const <MediaVariant>[],
  }) {
    return _isCdBundledExtraPath(
      relativePath.replaceAll('\\', '/'),
      cdAlbumPaths: allWorkVariants
          .where((v) => v.assetKind == AssetKind.cdAlbum)
          .map((v) => v.relativePath),
    );
  }

  /// 为详情页「特典」卡片生成展示标题，落实施行决策点 2（CD 附带视频前缀拼接）。
  static String formatExtraDisplayTitle({
    required Episode episode,
    required List<MediaVariant> episodeVariants,
    required List<MediaVariant> allWorkVariants,
    required String? defaultFormattedTitle,
  }) {
    if (episode.category != EpisodeCategory.extra || episodeVariants.isEmpty) {
      return defaultFormattedTitle ?? (episode.title ?? '特典');
    }
    final primaryVariant = episodeVariants.first;
    final relPath = primaryVariant.relativePath.replaceAll('\\', '/');
    if (!isCdBundledExtraVideo(relPath, allWorkVariants: allWorkVariants)) {
      return defaultFormattedTitle ?? (episode.title ?? '特典');
    }

    return _formatCdBundledTitleCore(
      fileName: primaryVariant.fileName,
      relativePath: relPath,
      workVideoEntries: allWorkVariants
          .where((v) => v.assetKind == AssetKind.video)
          .map((v) => (fileName: v.fileName, relativePath: v.relativePath)),
      cdAlbumPaths: allWorkVariants
          .where((v) => v.assetKind == AssetKind.cdAlbum)
          .map((v) => v.relativePath),
      fallbackTitle: defaultFormattedTitle ?? (episode.title ?? '特典'),
    )!;
  }

  /// 为入库扫描管线提供的 CD 附带特典视频标题格式化（决策点 2）。
  ///
  /// 仅当该视频属于 CD/单曲/OST 目录附带映像时返回拼接前缀后的标题，否则返回 `null`。
  static String? formatCdBundledExtraTitleFromRaw({
    required String fileName,
    required String relativePath,
    Iterable<({String fileName, String relativePath})> workVideoEntries =
        const <({String fileName, String relativePath})>[],
    Iterable<String> cdAlbumPaths = const <String>[],
  }) {
    return _formatCdBundledTitleCore(
      fileName: fileName,
      relativePath: relativePath,
      workVideoEntries: workVideoEntries,
      cdAlbumPaths: cdAlbumPaths,
      fallbackTitle: null,
    );
  }

  static String? _formatCdBundledTitleCore({
    required String fileName,
    required String relativePath,
    required Iterable<({String fileName, String relativePath})>
    workVideoEntries,
    required Iterable<String> cdAlbumPaths,
    required String? fallbackTitle,
  }) {
    final relPath = relativePath.replaceAll('\\', '/');
    if (!_isCdBundledExtraPath(relPath, cdAlbumPaths: cdAlbumPaths)) {
      return fallbackTitle;
    }

    final albumGroup = extractCdAlbumGroup(relativePath: relPath);
    final albumShort = albumGroup.chipLabel.trim();
    if (albumShort.isEmpty || albumShort == 'CD') {
      return fallbackTitle;
    }

    final stem = _stripExtension(fileName);
    final isMeaninglessStream = _meaninglessStreamStem.hasMatch(stem.trim());

    final discDir = _parentDirKey(relPath);
    if (isMeaninglessStream) {
      var meaninglessCountInDisc = 0;
      for (final candidate in workVideoEntries) {
        final cPath = candidate.relativePath.replaceAll('\\', '/');
        if (_parentDirKey(cPath) != discDir) continue;
        final cStem = _stripExtension(candidate.fileName);
        if (_meaninglessStreamStem.hasMatch(cStem.trim())) {
          meaninglessCountInDisc++;
        }
      }
      if (meaninglessCountInDisc <= 1) {
        return '$albumShort · 特典映像';
      }
      return '$albumShort / $stem';
    }

    final cleanStem = _cleanVideoTitleStem(stem);
    final displayRight = cleanStem.isEmpty ? stem : cleanStem;
    return '$albumShort / $displayRight';
  }

  static bool _isCdBundledExtraPath(
    String relativePath, {
    Iterable<String> cdAlbumPaths = const <String>[],
  }) {
    final segs = _parentSegments(relativePath);
    if (segs.isEmpty) return false;
    if (segs.any(_isCdVideoDiscOrAlbumSeg)) {
      return true;
    }
    final albumRoot = _findCdAlbumRootFromSegments(segs);
    if (albumRoot != null) {
      final prefix = '${albumRoot.toLowerCase()}/';
      for (final cdPath in cdAlbumPaths) {
        final normalized = cdPath.replaceAll('\\', '/').toLowerCase();
        if (normalized.startsWith(prefix)) return true;
      }
    }
    return false;
  }

  /// 对单个 CD 路径提炼简洁可读的二级筛选专辑标签。
  static String extractCdAlbumChipLabel(
    String relativePath, {
    Set<String>? duplicateBaseNames,
  }) {
    return extractCdAlbumGroup(
      relativePath: relativePath,
      duplicateBaseNames: duplicateBaseNames,
    ).chipLabel;
  }

  /// 对单个 CD 路径提炼专辑键、精简展示标签、多碟分组名与直接子目录名。
  static CdAlbumGroupingResult extractCdAlbumGroup({
    required String relativePath,
    Set<String>? duplicateBaseNames,
  }) {
    final segs = _parentSegments(relativePath);
    if (segs.isEmpty) {
      return const CdAlbumGroupingResult(albumKey: 'root', chipLabel: 'CD');
    }

    var containerIdx = -1;
    for (var i = 0; i < segs.length; i++) {
      if (_cdRootContainerSeg.hasMatch(segs[i])) {
        containerIdx = i;
      }
    }

    final directSubdir = _cleanDirectSubdirName(segs.last);

    // 解析直属于 CD 容器之后的路径层级
    List<String> albumChain;
    if (containerIdx >= 0) {
      albumChain = segs.sublist(containerIdx + 1);
    } else {
      // 未显式命名为 CDs/Soundtrack 的情况：定位包含 [EAC]/[YYMMDD] 等特征的专辑层
      var albumHintIdx = -1;
      for (var i = 0; i < segs.length; i++) {
        if (_cdAlbumWrapperHint.hasMatch(segs[i])) {
          albumHintIdx = i;
        }
      }
      if (albumHintIdx >= 0) {
        albumChain = segs.sublist(albumHintIdx);
      } else {
        albumChain = <String>[segs.last];
      }
    }

    // 剥离尾部纯视频流壳（仅在 CD 附带视频场景出现，例如 BDRip / BDMV / STREAM）
    final trimmedForAlbum = List<String>.of(albumChain);
    while (trimmedForAlbum.length > 1 &&
        _cdVideoContainerSubdirSeg.hasMatch(trimmedForAlbum.last)) {
      trimmedForAlbum.removeLast();
    }

    // 检查尾部是否是多碟子目录（disc 1 / CD2），确保二级筛选停留在专辑层
    String? discLabel;
    if (trimmedForAlbum.length >= 2) {
      final discMatch = _cdDiscSubdirSeg.firstMatch(trimmedForAlbum.last);
      if (discMatch != null) {
        final upperLast = trimmedForAlbum.last.trim().toUpperCase();
        final discNum = discMatch.group(1)!;
        final prev = trimmedForAlbum[trimmedForAlbum.length - 2];
        // 若上一级仅是纯季壳 `S1`，则无独立专辑包装层，合并为 `S1 · CD1`
        if (_seasonShellSeg.hasMatch(prev) && trimmedForAlbum.length == 2) {
          final seasonUpper = prev.trim().toUpperCase();
          final cdTag = upperLast.startsWith('CD')
              ? 'CD$discNum'
              : 'Disc $discNum';
          final key = trimmedForAlbum.map((e) => e.toLowerCase()).join('/');
          return CdAlbumGroupingResult(
            albumKey: key,
            chipLabel: '$seasonUpper · $cdTag',
            discLabel: cdTag,
            directSubdirShort: directSubdir,
          );
        }
        discLabel = 'Disc $discNum';
        trimmedForAlbum.removeLast();
      }
    }

    if (trimmedForAlbum.isEmpty) {
      final fallbackLabel = containerIdx >= 0
          ? _cleanSingleAlbumLabel(
              segs[containerIdx],
              duplicateBaseNames: duplicateBaseNames,
            )
          : 'CD';
      return CdAlbumGroupingResult(
        albumKey: segs.map((e) => e.toLowerCase()).join('/'),
        chipLabel: fallbackLabel,
        discLabel: discLabel,
        directSubdirShort: directSubdir,
      );
    }

    // 若前段是季壳 `S1` 后接具体专辑文件夹，剥离季壳（仅以专辑名归并，保留完整 key 防串）
    final rawAlbumSeg = trimmedForAlbum.last;
    final albumKey = _buildStableAlbumKey(segs, trimmedForAlbum);
    final label = _cleanSingleAlbumLabel(
      rawAlbumSeg,
      duplicateBaseNames: duplicateBaseNames,
    );

    final verTag = extractCdVersionTag(rawAlbumSeg);
    return CdAlbumGroupingResult(
      albumKey: albumKey,
      chipLabel: label,
      discLabel: discLabel,
      directSubdirShort: directSubdir,
      versionTag: verTag,
    );
  }

  static final RegExp _hiResSpecRegex = RegExp(
    r'(\d{2})bit[_/\-\s]*(\d{2,3}(?:\.\d+)?)\s*khz',
    caseSensitive: false,
  );
  static final RegExp _hiResWordRegex = RegExp(
    r'\bhi-?res\b',
    caseSensitive: false,
  );
  static final RegExp _editionLabelRegex = RegExp(
    r'[\[(（【]\s*('
    r'(?:期間生産限定|初回生産限定|完全生産限定|初回限定|期間限定|初回|通常|アニメ|限定)[^\]\)）】]{0,14}(?:盤|盘|版)|'
    r'(?:CD\s*\+\s*(?:BD|DVD|Blu-?ray))'
    r')\s*[\])）】]',
    caseSensitive: false,
  );
  static final RegExp _catalogExtractRegex = RegExp(
    r'\b([A-Z]{2,5}-\d{3,6}(?:~\d+)?)\b',
  );
  static final RegExp _formatPackExtractRegex = RegExp(
    r'[\[(（【]\s*((?:flac|aac|mp3|wav|ape|alac|m4a|opus)(?:\s*[+&]\s*(?:flac|aac|mp3|wav|webp|jpg|png|bk|scans?|cue|dvd|bd))+)\s*[\])）】]',
    caseSensitive: false,
  );
  static final RegExp _singleFormatParenRegex = RegExp(
    r'[\[(（【]\s*(flac|aac|mp3|wav|ape|alac|m4a|opus)\s*[\])）】]\s*$',
    caseSensitive: false,
  );

  /// 从 CD 专辑文件夹名提炼高辨识度的版本或规格标签（如 `24bit/48kHz`、`期間生産限定盤`、`ANZX-15872`、`FLAC+WebP`）。
  static String? extractCdVersionTag(String rawAlbumSegment) {
    final text = rawAlbumSegment.trim();
    if (text.isEmpty) return null;

    final hiRes = _hiResSpecRegex.firstMatch(text);
    if (hiRes != null) {
      return '${hiRes.group(1)}bit/${hiRes.group(2)}kHz';
    }
    if (_hiResWordRegex.hasMatch(text)) {
      return 'Hi-Res';
    }
    final edition = _editionLabelRegex.firstMatch(text);
    if (edition != null) {
      return edition.group(1)!.trim();
    }
    final cat = _catalogExtractRegex.firstMatch(text);
    if (cat != null) {
      return cat.group(1)!.trim();
    }
    final pack = _formatPackExtractRegex.firstMatch(text);
    if (pack != null) {
      return pack
          .group(1)!
          .replaceAll(RegExp(r'\s+'), '')
          .toUpperCase()
          .replaceAll('WEBP', 'WebP');
    }
    final singleFmt = _singleFormatParenRegex.firstMatch(text);
    if (singleFmt != null) {
      return singleFmt.group(1)!.toUpperCase();
    }
    return null;
  }

  /// 提取并剥离音频文件名开头的冗余轨号前缀（如 `01. 65535` -> `(1, '65535')`，保护纯数字歌名本身不被误删）。
  static ({int? trackNumber, String cleanTitle}) stripAudioTrackNumberPrefix(
    String rawStem,
  ) {
    final trimmed = rawStem.trim();
    if (trimmed.isEmpty) return (trackNumber: null, cleanTitle: rawStem);

    final bracketMatch = RegExp(r'^\[(\d{1,2})\]\s*(.+)$').firstMatch(trimmed);
    if (bracketMatch != null) {
      final num = int.tryParse(bracketMatch.group(1)!);
      final rest = bracketMatch.group(2)!.trim();
      if (num != null && num >= 1 && num <= 60 && rest.isNotEmpty) {
        return (trackNumber: num, cleanTitle: rest);
      }
    }

    final sepMatch = RegExp(
      r'^(?:track\s*)?(?:\d{1,2}\s*[-_]\s*)?(\d{1,2})\s*(?:[.\-–—_、]\s*|\)\s+)(.+)$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (sepMatch != null) {
      final num = int.tryParse(sepMatch.group(1)!);
      final rest = sepMatch.group(2)!.trim();
      if (num != null && num >= 1 && num <= 60 && rest.isNotEmpty) {
        return (trackNumber: num, cleanTitle: rest);
      }
    }

    final zeroSpaceMatch = RegExp(r'^(0\d)\s+(.+)$').firstMatch(trimmed);
    if (zeroSpaceMatch != null) {
      final num = int.tryParse(zeroSpaceMatch.group(1)!);
      final rest = zeroSpaceMatch.group(2)!.trim();
      if (num != null && num >= 1 && rest.isNotEmpty) {
        return (trackNumber: num, cleanTitle: rest);
      }
    }

    return (trackNumber: null, cleanTitle: trimmed);
  }

  static String _rawAlbumFolderForPath(String relativePath) {
    final segs = _parentSegments(relativePath);
    if (segs.isEmpty) return '';
    var idx = segs.length - 1;
    while (idx > 0 &&
        (_cdVideoContainerSubdirSeg.hasMatch(segs[idx]) ||
            _cdDiscSubdirSeg.hasMatch(segs[idx]))) {
      idx--;
    }
    return segs[idx];
  }

  /// 对作品下的全部 CD 变体执行批量分组，自动对同名专辑按「日期 -> 规格/盘种/番号/封装」多级消歧。
  static CdAlbumGroupSummary groupCdVariants(List<MediaVariant> cdVariants) {
    if (cdVariants.isEmpty) {
      return const CdAlbumGroupSummary(
        chips: <({String key, String label, int count})>[],
        byVariantId: <String, CdAlbumGroupingResult>{},
        hasMultipleSubdirs: false,
      );
    }

    final firstPass = <String, CdAlbumGroupingResult>{};
    final baseCounts = <String, Set<String>>{};
    final rawFolderByAlbumKey = <String, String>{};

    for (final v in cdVariants) {
      final g = extractCdAlbumGroup(relativePath: v.relativePath);
      firstPass[v.id] = g;
      rawFolderByAlbumKey.putIfAbsent(
        g.albumKey,
        () => _rawAlbumFolderForPath(v.relativePath),
      );
      final base = _normalizedBaseTitleForDisambig(g.chipLabel);
      baseCounts.putIfAbsent(base, () => <String>{}).add(g.albumKey);
    }

    final duplicates = <String>{
      for (final e in baseCounts.entries)
        if (e.value.length > 1) e.key,
    };

    final resolvedByVariantId = <String, CdAlbumGroupingResult>{};
    final chipMeta = <String, String>{};
    final chipCount = <String, int>{};

    for (final v in cdVariants) {
      final g = duplicates.isEmpty
          ? firstPass[v.id]!
          : extractCdAlbumGroup(
              relativePath: v.relativePath,
              duplicateBaseNames: duplicates,
            );
      resolvedByVariantId[v.id] = g;
      chipMeta.putIfAbsent(g.albumKey, () => g.chipLabel);
      chipCount[g.albumKey] = (chipCount[g.albumKey] ?? 0) + 1;
    }

    // 第二阶段深度消歧：若同日发售的多个版本在附加日期后仍然重名（如普通版 vs 24bit_48kHz 版），按版本/规格后缀精准区分
    final keysByChipLabel = <String, List<String>>{};
    for (final entry in chipMeta.entries) {
      keysByChipLabel.putIfAbsent(entry.value, () => <String>[]).add(entry.key);
    }

    final refinedLabelByKey = <String, String>{};
    final refinedVersionByKey = <String, String>{};

    for (final collision in keysByChipLabel.entries) {
      final collidingKeys = collision.value;
      if (collidingKeys.length < 2) continue;

      final sampleFirst = firstPass.values.firstWhere(
        (e) => e.albumKey == collidingKeys.first,
      );
      final cleanBase = _truncateMiddleOrEnd(sampleFirst.chipLabel, 22);

      final extractedTags = <String, String?>{
        for (final k in collidingKeys)
          k: extractCdVersionTag(rawFolderByAlbumKey[k] ?? ''),
      };
      final hasHiResSibling = extractedTags.values.any(
        (t) => t != null && (t.contains('bit') || t == 'Hi-Res'),
      );

      final usedLabels = <String>{};
      var seq = 1;
      for (final k in collidingKeys) {
        var tag = extractedTags[k];
        if ((tag == null || tag == 'FLAC') && hasHiResSibling) {
          tag = '标准版';
        }
        tag ??= '版本 $seq';
        var candidate = '$cleanBase · $tag';
        while (!usedLabels.add(candidate)) {
          seq++;
          candidate = '$cleanBase · $tag ($seq)';
        }
        refinedLabelByKey[k] = candidate;
        refinedVersionByKey[k] = tag;
        chipMeta[k] = candidate;
        seq++;
      }
    }

    final distinctSubdirs = <String>{};
    for (final v in cdVariants) {
      var g = resolvedByVariantId[v.id]!;
      final refinedLabel = refinedLabelByKey[g.albumKey];
      final refinedVer = refinedVersionByKey[g.albumKey];
      if (refinedLabel != null) {
        g = g.copyWith(
          chipLabel: refinedLabel,
          directSubdirShort: refinedVer ?? g.directSubdirShort,
          versionTag: refinedVer ?? g.versionTag,
        );
        resolvedByVariantId[v.id] = g;
      }
      if (g.directSubdirShort != null && g.directSubdirShort!.isNotEmpty) {
        distinctSubdirs.add(g.directSubdirShort!.toLowerCase());
      }
    }

    final chips = chipMeta.entries
        .map((e) => (key: e.key, label: e.value, count: chipCount[e.key] ?? 0))
        .toList(growable: false);

    return CdAlbumGroupSummary(
      chips: chips,
      byVariantId: resolvedByVariantId,
      hasMultipleSubdirs: distinctSubdirs.length >= 2 || chips.length >= 2,
    );
  }

  // ===== Scan 分卷提取与季壳剥离 =====

  static final RegExp _scanContainerSeg = RegExp(
    r'^(?:bd[\s._-]*scans?|scans?|bk|booklets?|gallery|galleries|illustrations?|artworks?|endcards?)'
    r'(?:[\s._-]*s\d{1,2})?'
    r'(?:\s*[\(（]?\s*((?:vol|v|bd|part)[\s._-]*\d{1,3})\s*[\)）]?)?$',
    caseSensitive: false,
  );

  /// 对单个 Scan 路径提取分卷二级标签；平铺无子目录时返回 `null`。
  static String? extractScanVolumeChipLabel(
    String relativePath, {
    bool keepSeasonShell = false,
  }) {
    return extractScanVolumeGroup(
      relativePath,
      keepSeasonShell: keepSeasonShell,
    ).chipLabel;
  }

  /// 对单个 Scan 路径提取分卷键、二级标签与直接子目录短名；平铺时 `chipLabel == null`。
  static ScanVolumeGroupingResult extractScanVolumeGroup(
    String relativePath, {
    bool keepSeasonShell = false,
  }) {
    final segs = _parentSegments(relativePath);
    if (segs.isEmpty) return const ScanVolumeGroupingResult();

    var containerIdx = -1;
    RegExpMatch? containerMatch;
    for (var i = 0; i < segs.length; i++) {
      final m = _scanContainerSeg.firstMatch(segs[i]);
      if (m != null) {
        if (containerIdx >= 0 && i == segs.length - 1) {
          continue;
        }
        containerIdx = i;
        containerMatch = m;
      }
    }

    // 检查是否容器自身已携卷号（如 `Scan (Vol.1)`）
    final selfVol = containerMatch?.group(1)?.trim();
    if (selfVol != null && selfVol.isNotEmpty) {
      final normalized = _cleanScanSegmentLabel(selfVol);
      return ScanVolumeGroupingResult(
        volumeKey: normalized.toLowerCase(),
        chipLabel: normalized,
        directSubdirShort: normalized,
      );
    }

    if (containerIdx < 0) {
      // 未显式匹配容器名时的保底：检查直接父目录是否本身就是 Vol/Booklet
      final lastSeg = segs.last.trim();
      if (_isVolumeLikeScanSeg(lastSeg)) {
        final cleaned = _cleanScanSegmentLabel(lastSeg);
        return ScanVolumeGroupingResult(
          volumeKey: cleaned.toLowerCase(),
          chipLabel: cleaned,
          directSubdirShort: cleaned,
        );
      }
      return const ScanVolumeGroupingResult();
    }

    final after = segs.sublist(containerIdx + 1);
    if (after.isEmpty) {
      // 平铺在单一 Scans/ 下无子文件夹
      return const ScanVolumeGroupingResult();
    }

    var filtered = after;
    if (!keepSeasonShell &&
        filtered.length >= 2 &&
        _seasonShellSeg.hasMatch(filtered.first)) {
      filtered = filtered.sublist(1);
    }
    if (filtered.isEmpty) return const ScanVolumeGroupingResult();

    final cleanParts = filtered
        .map(_cleanScanSegmentLabel)
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (cleanParts.isEmpty) return const ScanVolumeGroupingResult();

    final chipLabel = cleanParts.join(' · ');
    final directShort = _cleanScanSegmentLabel(after.last);
    return ScanVolumeGroupingResult(
      volumeKey: cleanParts.map((s) => s.toLowerCase()).join('/'),
      chipLabel: chipLabel,
      directSubdirShort: directShort.isEmpty ? chipLabel : directShort,
    );
  }

  /// 对作品下全部 Scan 变体分组：多季共存保留季前缀，单季自动剥离 `Scan S3` 外壳，全平铺返回空列表。
  static ScanVolumeGroupSummary groupScanVariants(
    List<MediaVariant> scanVariants,
  ) {
    if (scanVariants.isEmpty) {
      return const ScanVolumeGroupSummary(
        chips: <({String key, String label, int count})>[],
        byVariantId: <String, ScanVolumeGroupingResult>{},
        hasMultipleSubdirs: false,
      );
    }

    // 检查是否在 Scan 容器内部存在多个不同季壳（如同条目下既有 S1/Vol1 又有 S2/Vol1）
    final seasonShells = <String>{};
    for (final v in scanVariants) {
      final segs = _parentSegments(v.relativePath);
      final idx = segs.lastIndexWhere(_scanContainerSeg.hasMatch);
      if (idx >= 0 && idx + 2 < segs.length + 1) {
        final candidate = segs[idx + 1];
        if (_seasonShellSeg.hasMatch(candidate)) {
          seasonShells.add(candidate.trim().toLowerCase());
        }
      }
    }
    final keepSeason = seasonShells.length >= 2;

    final byVariantId = <String, ScanVolumeGroupingResult>{};
    final chipMeta = <String, String>{};
    final chipCount = <String, int>{};

    for (final v in scanVariants) {
      final g = extractScanVolumeGroup(
        v.relativePath,
        keepSeasonShell: keepSeason,
      );
      byVariantId[v.id] = g;
      if (g.volumeKey != null && g.chipLabel != null) {
        chipMeta.putIfAbsent(g.volumeKey!, () => g.chipLabel!);
        chipCount[g.volumeKey!] = (chipCount[g.volumeKey!] ?? 0) + 1;
      }
    }

    final chips = chipMeta.entries
        .map((e) => (key: e.key, label: e.value, count: chipCount[e.key] ?? 0))
        .toList(growable: false);

    return ScanVolumeGroupSummary(
      chips: chips,
      byVariantId: byVariantId,
      hasMultipleSubdirs: chips.length >= 2,
    );
  }

  /// 从相对路径提取简洁的直接子目录短名（绝不返回最外层作品根路径）。
  static String? resolveDirectSubdirShort(
    String relativePath, {
    required AssetKind kind,
  }) {
    if (kind == AssetKind.cdAlbum) {
      return extractCdAlbumGroup(relativePath: relativePath).directSubdirShort;
    }
    if (kind == AssetKind.scanGallery) {
      return extractScanVolumeGroup(relativePath).directSubdirShort;
    }
    final segs = _parentSegments(relativePath);
    if (segs.isEmpty) return null;
    return _cleanDirectSubdirName(segs.last);
  }

  // ===== 内部清洗辅助 =====

  static List<String> _parentSegments(String relativePath) {
    final norm = relativePath.replaceAll('\\', '/').trim();
    if (norm.isEmpty) return const <String>[];
    final parts = norm
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) return const <String>[];
    return parts.sublist(0, parts.length - 1);
  }

  static String _parentDirKey(String normPath) {
    final idx = normPath.lastIndexOf('/');
    return idx > 0 ? normPath.substring(0, idx).toLowerCase() : '';
  }

  static String? _findCdAlbumRootFromSegments(List<String> segs) {
    for (var i = segs.length - 1; i >= 0; i--) {
      if (_cdAlbumWrapperHint.hasMatch(segs[i])) {
        return segs.sublist(0, i + 1).join('/');
      }
    }
    return null;
  }

  static String _buildStableAlbumKey(
    List<String> allParentSegs,
    List<String> trimmedAlbumChain,
  ) {
    final prefixLen =
        allParentSegs.length -
        _countRemovedFromEnd(allParentSegs, trimmedAlbumChain);
    final keyParts = allParentSegs.sublist(0, prefixLen > 0 ? prefixLen : 1);
    return keyParts.map((s) => s.toLowerCase()).join('/');
  }

  static int _countRemovedFromEnd(
    List<String> allParentSegs,
    List<String> trimmedAlbumChain,
  ) {
    if (trimmedAlbumChain.isEmpty) return 0;
    final lastKept = trimmedAlbumChain.last;
    final idx = allParentSegs.lastIndexOf(lastKept);
    if (idx < 0) return 0;
    return allParentSegs.length - 1 - idx;
  }

  static final RegExp _sourcePrefixBracket = RegExp(
    r'^\s*(?:\[(?:EAC|FLAC|HQCD|MP3|WAV|AAC|ALAC|BD|CD|DVD|Hi-?Res)\]\s*)+',
    caseSensitive: false,
  );
  static final RegExp _dateBracket = RegExp(
    r'[\[(（【]\s*((?:19|20)?\d{2}[01]\d[0-3]\d)\s*[\])）】]',
  );
  static final RegExp _editionSpecBracket = RegExp(
    r'[\[(（【]\s*(?:'
    r'(?:CD|DVD|BD|Blu-?Ray)[^\]\)）】]{0,24}(?:盤|盘|版|付き)|'
    r'(?:初回|通常|完全|期間|アニメ|限定)[^\]\)）】]{0,20}(?:盤|盘|版)|'
    r'\d+bit[_/\s]*\d+(?:\.\d+)?kHz|Hi-?Res|'
    r'(?:flac|aac|mp3|wav|ape|tta|tak|opus|alac|m4a|mkv|mp4|png|webp|jpg|bk|scans?|cue|rr\d*)'
    r'(?:\s*[+&x/／,，_-]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|alac|m4a|mkv|mp4|png|webp|jpg|bk|scans?|cue|dvd|bd|rr\d*|\d+))*'
    r')\s*[\])）】]',
    caseSensitive: false,
  );
  static final RegExp _catalogToken = RegExp(
    r'[\[(（【]\s*[A-Z]{2,5}-\d{3,6}\s*[\])）】]|^\s*[A-Z]{2,5}-\d{3,6}[\s._-]+',
  );
  static final RegExp _trailingMediaFormatParen = RegExp(
    r'\s*[\[(（【]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|alac|m4a|webp|jpg|png|mkv|mp4|cue|bk|scans?)(?:[^\]\)）】]*)\s*[\])）】]\s*$',
    caseSensitive: false,
  );

  static String _normalizedBaseTitleForDisambig(String label) {
    final low = label.trim().toLowerCase();
    if (low == 'original soundtrack' || low == 'ost') {
      return 'original soundtrack';
    }
    return low;
  }

  static String _cleanSingleAlbumLabel(
    String rawSegment, {
    Set<String>? duplicateBaseNames,
  }) {
    var text = rawSegment.trim();
    if (text.isEmpty) return 'CD';

    String? dateToken;
    final dateMatch = _dateBracket.firstMatch(text);
    if (dateMatch != null) {
      dateToken = dateMatch.group(1);
    }

    text = text.replaceFirst(_sourcePrefixBracket, '');
    text = text.replaceAll(_dateBracket, ' ');
    text = text.replaceAll(_catalogToken, ' ');
    text = text.replaceAll(_editionSpecBracket, ' ');
    while (_trailingMediaFormatParen.hasMatch(text)) {
      final next = text.replaceFirst(_trailingMediaFormatParen, '');
      if (next == text) break;
      text = next;
    }

    text = text
        .replaceAll('｢', '「')
        .replaceAll('｣', '」')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAll(RegExp(r'\s*／\s*'), '／')
        .trim();

    if (text.isEmpty) {
      text = dateToken != null ? 'CD ($dateToken)' : rawSegment.trim();
    }

    final isOstExact = RegExp(
      r'^original[\s._-]*soundtrack$',
      caseSensitive: false,
    ).hasMatch(text);

    if (isOstExact) {
      final hasDup =
          duplicateBaseNames?.contains('original soundtrack') == true;
      if (hasDup && dateToken != null) {
        return 'OST ($dateToken)';
      }
      return 'Original Soundtrack';
    }

    // 长度超过 28 字符时若存在同名消歧需要附日期，其余适度浓缩
    final baseKey = _normalizedBaseTitleForDisambig(text);
    if (duplicateBaseNames?.contains(baseKey) == true && dateToken != null) {
      final compact = _truncateMiddleOrEnd(text, 22);
      return '$compact ($dateToken)';
    }

    return _truncateMiddleOrEnd(text, 28);
  }

  static String _truncateMiddleOrEnd(String input, int maxChars) {
    if (input.length <= maxChars) return input;
    return '${input.substring(0, maxChars - 1).trimRight()}…';
  }

  static String? _cleanDirectSubdirName(String seg) {
    var s = seg.trim();
    if (s.isEmpty) return null;
    if (_cdDiscSubdirSeg.hasMatch(s)) {
      final m = _cdDiscSubdirSeg.firstMatch(s)!;
      final upper = s.toUpperCase();
      return upper.startsWith('CD') ? 'CD${m.group(1)}' : 'Disc ${m.group(1)}';
    }
    if (_cdRootContainerSeg.hasMatch(s) || _scanContainerSeg.hasMatch(s)) {
      final m = _scanContainerSeg.firstMatch(s);
      if (m != null && m.group(1) != null) {
        return _cleanScanSegmentLabel(m.group(1)!);
      }
      return s;
    }
    s = _cleanScanSegmentLabel(s);
    if (s.length > 26) {
      s = _cleanSingleAlbumLabel(seg);
    }
    return s.isEmpty ? null : s;
  }

  static bool _isVolumeLikeScanSeg(String seg) {
    return RegExp(
      r'^(?:vol(?:ume)?[\s._-]*\d+|v\d{1,2}|bd[\s._-]*\d+|booklet|bk|box)',
      caseSensitive: false,
    ).hasMatch(seg);
  }

  static String _cleanScanSegmentLabel(String raw) {
    var s = _stripTrailingTechBrackets(raw.trim());
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _stripTrailingTechBrackets(String input) {
    var s = input.trim();
    final trailingTech = RegExp(
      r'\s*[\[(（【]\s*(?:BD|BDRip|DVD|DVDRip|Web|1080p|720p|4K|Ma10p|Hi10p|FLAC|AAC|MP3|WebP|PNG|JPG)\s*[\])）】]\s*$',
      caseSensitive: false,
    );
    while (trailingTech.hasMatch(s)) {
      final next = s.replaceFirst(trailingTech, '').trim();
      if (next == s || next.isEmpty) break;
      s = next;
    }
    return s;
  }

  static String _cleanVideoTitleStem(String stem) {
    var s = stem.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)'),
      (m) {
        final inner = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
        if (RegExp(
          r'^(?:\d{3,4}p|\d{3,4}x\d{3,4}|(?:x|h)\.?26[45]|hevc|avc|av1|'
          r'(?:ma|hi)?\d{1,2}p|\d{1,2}bit|yuv\w*|flac\w*|aac\w*|opus|'
          r'bdrip|dvdrip|web-?dl|[0-9a-f]{8}|chs|cht|jpn|eng)$',
          caseSensitive: false,
        ).hasMatch(inner)) {
          return ' ';
        }
        return ' $inner ';
      },
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static final RegExp _leadingBracketGroupRegex = RegExp(
    r'^\s*(?:\[([^\]]+)\]|【([^】]+)】)\s*(?=\S)',
  );

  static final RegExp _mergeKeyProtectedBracketRegex = RegExp(
    r'^(?:vol(?:ume)?|disc|bd|dvd|cd|part|sp|ova|oad|\d+)\b',
    caseSensitive: false,
  );

  static final RegExp _releaseGroupSuffixRegex = RegExp(
    r'(?:字幕组|字幕組|压制组|壓製組|(?:^|[-_ ])(?:Raws?|Subs?|Subtitles?|Rip|Encode|Studio))$',
    caseSensitive: false,
  );

  static String _cleanStemForMergeKey(String stem) {
    var working = stem.trim();
    // 剥离句首连续的压制组/字幕组方括号，保留带特典标识或分卷数字的标签
    while (true) {
      final m = _leadingBracketGroupRegex.firstMatch(working);
      if (m == null) break;
      final inner = (m.group(1) ?? m.group(2) ?? '').trim();
      if (inner.isEmpty ||
          _canonicalTokenRegex.hasMatch(inner) ||
          _mergeKeyProtectedBracketRegex.hasMatch(inner)) {
        break;
      }
      working = working.substring(m.end).trimLeft();
    }

    var s = working.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)'),
      (m) {
        final inner = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
        if (inner.isEmpty) return ' ';
        final parts = inner
            .split(RegExp(r'[\s_/&+,]+'))
            .where((p) => p.isNotEmpty)
            .toList(growable: false);
        final allTechOrRelease =
            parts.isNotEmpty && parts.every(_techOrReleaseSegRegex.hasMatch);
        final isReleaseGroup =
            !_canonicalTokenRegex.hasMatch(inner) &&
            !_mergeKeyProtectedBracketRegex.hasMatch(inner) &&
            _releaseGroupSuffixRegex.hasMatch(inner);
        if (allTechOrRelease || isReleaseGroup) {
          return ' ';
        }
        return ' $inner ';
      },
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  static String _stripExtension(String name) {
    final trimmed = name.trim();
    final dot = trimmed.lastIndexOf('.');
    return dot > 0 ? trimmed.substring(0, dot) : trimmed;
  }

  // ===== 特典限定前缀 / 子变体提取与规范化归组键 =====

  static final RegExp _techOrReleaseSegRegex = RegExp(
    r'^(?:\d{3,4}p|\d{3,4}x\d{3,4}|[248]k|(?:ma|hi)?\d{1,2}p|\d{1,2}bits?|'
    r'yuv\w*|x26[45]|h\.?26[45]|hevc\d*|avc\d*|av1|\d*flac\w*|\d*aac\w*|'
    r'opus|dts\w*|ac3|eac3|ddp|truehd|atmos|l?pcm|alac|mp3|ogg|bdrip|'
    r'bdremux|bdmv|bluray|blu-ray|uhd|web-?dl|webrip|dvdrip|remux|raws?|'
    r'hdr\d*|sdr|dv|chs|cht|gb|big5|sc|tc|jp|jpn|chi|eng|subs?|ass|ssa|srt|'
    r'sup|pgs|jpsc|jptc|jpchs|jpcht|[0-9a-f]{8}|vcb-studio|sweetsub|moozzi2|'
    r'snow-raws|lilith-raws|lolihouse|ai-raws|ank-raws|u2-rip|reinforce)$',
    caseSensitive: false,
  );

  static final RegExp _qualifiedPromoInBracketRegex = RegExp(
    '^($_promoQualifierPrefixPattern(?:[\\s._-]+$_promoQualifierPrefixPattern)*)'
    r'[\s._-]*(pv[\s._-]*cm|pv|cm|trailers?|teasers?|previews?|spots?)'
    r'(?:[\s._-]*(\d{1,3}(?:[._-]?(?!v\d|ver\b)[a-z])?))?$',
    caseSensitive: false,
  );

  static final RegExp _qualifiedPromoBoundaryRegex = RegExp(
    '(?:^|[\\s._\\-\\[\\(【])'
    '($_promoQualifierPrefixPattern(?:[\\s._]+$_promoQualifierPrefixPattern)*)'
    r'[\s._]*(pv[\s._]*cm|pv|cm|trailers?|teasers?|previews?|spots?)'
    r'(?:[\s._]*(\d{1,3}(?:[._-]?(?!v\d|ver\b)[a-z])?))?(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _explicitNcSubVariantRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:'
    r'nc[\s._-]*(op|ed)|'
    r'(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean|ノンクレジット|ノンクレ|ノンテロップ)[\s._-]*(opening|ending|op|ed)'
    r')[\s._-]*(\d{1,3})[\s._-]*((?!v\d|ver\b)[a-z])(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _bareNcSubVariantRegex = RegExp(
    r'(?:^|[\s._\-\[\(【])(op|ed)[\s._-]*(\d{1,3})[\s._-]*((?!v\d|ver\b)[a-z])(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _canonicalTokenRegex = RegExp(
    '(?:^|[\\s._\\-\\[\\(【])('
    '(?:(?:$_promoQualifierPrefixPattern)(?:[\\s._-]+$_promoQualifierPrefixPattern)*[\\s._-]*)?'
    r'(?:nc[\s._-]*op[\s._-]*ed|nc[\s._-]*op|nc[\s._-]*ed|'
    r'(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean)[\s._-]*(?:opening|ending|op|ed)|'
    r'pv[\s._-]*cm|pv|cm|trailers?|teasers?|previews?|spots?|'
    r'menu(?:[\s._-]*ex)?|music[\s._-]*(?:video|clip)|mv|ova|oad|sp|info(?:rmation)?|iv|interview|making|digest|event)'
    r')(?:[\s._-]*(\d{1,3})(?:[\s._-]*((?!v\d|ver\b)[a-z]))?)?(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _legacyTruncatedExtraTitleRegex = RegExp(
    r'^(?:PV|CM|TVCM|BDCM|PVCM|TEASER|TRAILER|PREVIEW|SPOT|NCOP|NCED|NCOPED|'
    r'MENU|MENUEX|MV|SP|OVA|OAD|INFO|IV|MAKING|DIGEST|EVENT|EXTRA|预告宣传|'
    r'特别篇|番外|音乐视频|预告|予告|特典)\s*\d{0,3}$',
    caseSensitive: false,
  );

  static String _formatPromoQualifierToken(String raw) {
    final lower = raw.toLowerCase();
    return switch (lower) {
      'tv' => 'TV',
      'bd' => 'BD',
      'dvd' => 'DVD',
      'sp' => 'SP',
      'web' => 'Web',
      'char' || 'character' => 'Character',
      'teaser' => 'Teaser',
      'main' => 'Main',
      'climax' => 'Climax',
      'story' => 'Story',
      'world' => 'World',
      'concept' => 'Concept',
      'action' => 'Action',
      'cast' => 'Cast',
      'final' => 'Final',
      'new' => 'New',
      'launch' => 'Launch',
      'release' => 'Release',
      'special' => 'Special',
      'blu-ray' || 'bluray' => 'Blu-ray',
      _ => () {
        if (RegExp(
          r'^\d+(?:st|nd|rd|th)$',
          caseSensitive: false,
        ).hasMatch(raw)) {
          return lower;
        }
        if (RegExp(r'^[a-z]+$').hasMatch(lower)) {
          return '${lower[0].toUpperCase()}${lower.substring(1)}';
        }
        return raw;
      }(),
    };
  }

  static String _formatPromoMainType(String raw) {
    final compact = raw.toLowerCase().replaceAll(RegExp(r'[\s._-]+'), '');
    return switch (compact) {
      'pvcm' => 'PVCM',
      'pv' => 'PV',
      'cm' => 'CM',
      'trailer' || 'trailers' => 'Trailer',
      'teaser' || 'teasers' => 'Teaser',
      'preview' || 'previews' => 'Preview',
      'spot' || 'spots' => 'Spot',
      _ => compact.toUpperCase(),
    };
  }

  static String? _formatQualifiedPromoMatch(
    String rawPrefix,
    String rawType,
    String? rawNum,
  ) {
    final prefixParts = rawPrefix
        .trim()
        .split(RegExp(r'[\s._]+'))
        .where((s) => s.isNotEmpty)
        .map(_formatPromoQualifierToken)
        .toList(growable: false);
    if (prefixParts.isEmpty) return null;
    final formattedType = _formatPromoMainType(rawType);
    // 防止同义词重复拼接（如 Teaser + Teaser）
    if (prefixParts.length == 1 &&
        prefixParts.first.toLowerCase() == formattedType.toLowerCase()) {
      return null;
    }
    final cleanNum = (rawNum ?? '').replaceAll(RegExp(r'[\s._-]+'), '');
    final base = '${prefixParts.join(' ')} $formattedType';
    if (cleanNum.isEmpty) return base;
    final numMatch = RegExp(
      r'^(\d+)([a-z])?$',
      caseSensitive: false,
    ).firstMatch(cleanNum);
    if (numMatch != null && numMatch.group(2) != null) {
      return '$base ${numMatch.group(1)}${numMatch.group(2)!.toLowerCase()}';
    }
    return '$base $cleanNum';
  }

  static List<String> _extractBracketSegments(String stem) {
    final segments = <String>[];
    for (final m in RegExp(
      r'\[([^\]]*)\]|【([^】]*)】|\(([^)]*)\)',
    ).allMatches(stem)) {
      final raw = (m.group(1) ?? m.group(2) ?? m.group(3) ?? '').trim();
      if (raw.isEmpty) continue;
      final parts = raw
          .split(RegExp(r'[\s_/]+'))
          .where((p) => p.isNotEmpty)
          .toList(growable: false);
      if (parts.isNotEmpty && parts.every(_techOrReleaseSegRegex.hasMatch)) {
        continue;
      }
      segments.add(raw);
    }
    return segments;
  }

  /// 提取带完整限定前缀或子变体字母的特典展示标题，例如：
  /// `Character PV 01`、`Teaser PV 01`、`Main PV`、`Climax PV`、`BD CM 01`、`TV CM 01`、`NCED1a`、`NCED1b`。
  /// 若不属于上述需要保留限定词/子变体的命名，返回 `null` 交由通用短标签逻辑处理。
  static String? extractQualifiedExtraTitle(
    String fileName, {
    String? relativePath,
  }) {
    final stem = _stripExtension(fileName);
    if (stem.isEmpty) return null;

    final brackets = _extractBracketSegments(stem);

    // 1. 优先扫描独立括号标签内带限定词的预告宣传（如 `[Character PV 01]`、`[Main PV]`、`[BD CM 01]`）
    for (final seg in brackets) {
      final m = _qualifiedPromoInBracketRegex.firstMatch(seg);
      if (m != null) {
        final formatted = _formatQualifiedPromoMatch(
          m.group(1)!,
          m.group(2)!,
          m.group(3),
        );
        if (formatted != null) return formatted;
      }
    }

    // 2. 扫描括号标签内或全文中的带子变体字母 NCOP/NCED（如 `[NCED1a]`、`[NCED 01b]`、`Creditless ED 1b`）
    for (final seg in brackets) {
      final nc = _explicitNcSubVariantRegex.firstMatch(seg);
      if (nc != null) {
        final rawType = (nc.group(1) ?? nc.group(2))!.toLowerCase();
        final type = (rawType == 'op' || rawType == 'opening') ? 'OP' : 'ED';
        return 'NC$type${nc.group(3)!}${nc.group(4)!.toLowerCase()}';
      }
    }
    final stemWithoutBrackets = stem
        .replaceAll(RegExp(r'\[[^\]]*\]|【[^】]*】|\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final ncStem = _explicitNcSubVariantRegex.firstMatch(stemWithoutBrackets);
    if (ncStem != null) {
      final rawType = (ncStem.group(1) ?? ncStem.group(2))!.toLowerCase();
      final type = (rawType == 'op' || rawType == 'opening') ? 'OP' : 'ED';
      return 'NC$type${ncStem.group(3)!}${ncStem.group(4)!.toLowerCase()}';
    }

    // 若文件处于无字幕特典目录且命名仅写了 `ED1a` / `OP2b`
    final normPath = (relativePath ?? '').replaceAll('\\', '/');
    if (normPath.isNotEmpty) {
      final segs = normPath.split('/');
      final inNcDir = segs
          .take(segs.length > 1 ? segs.length - 1 : 0)
          .any(
            (s) =>
                _ncopDirSeg.hasMatch(s) ||
                _ncedDirSeg.hasMatch(s) ||
                _ncGenericDirSeg.hasMatch(s),
          );
      if (inNcDir) {
        for (final candidate in [...brackets, stemWithoutBrackets]) {
          final bareNc = _bareNcSubVariantRegex.firstMatch(candidate);
          if (bareNc != null) {
            final type = bareNc.group(1)!.toUpperCase();
            return 'NC$type${bareNc.group(2)!}${bareNc.group(3)!.toLowerCase()}';
          }
        }
      }
    }

    // 3. 回退扫描去掉括号后的词干中含语义限定词的 PV/CM（如 `Frieren Character PV 01.mkv`）
    final m = _qualifiedPromoBoundaryRegex.firstMatch(stemWithoutBrackets);
    if (m != null) {
      final formatted = _formatQualifiedPromoMatch(
        m.group(1)!,
        m.group(2)!,
        m.group(3),
      );
      if (formatted != null) return formatted;
    }

    return null;
  }

  static String? _canonicalVolDiscTag(String fileName, String relativePath) {
    final volPattern = RegExp(
      r'(?:^|[\s._\-\[\(【])(vol(?:ume)?|disc|bd|dvd|part)[\s._-]*0*(\d{1,2})(?=$|[\s._\-\]\)】])',
      caseSensitive: false,
    );
    for (final input in [fileName, relativePath]) {
      final m = volPattern.firstMatch(input);
      if (m != null) {
        final rawKind = m.group(1)!.toLowerCase();
        final kind = rawKind.startsWith('vol') ? 'vol' : rawKind;
        return '$kind${int.parse(m.group(2)!)}';
      }
    }
    return null;
  }

  /// 生成用于判断多版本归并的规范化完整核心标识键。
  ///
  /// 规则：
  /// - 仅当归一化后的完整核心语义标识一致时才归入同一多版本集：
  ///   - `[PV01]` (1080p) 与 `[PV 01]` (4K) -> `pv::pv:1:`（合并为 2 版本）
  ///   - `[Character PV 01]` -> `pv::character_pv:1:`（绝不与 `pv::pv:1:`、`pv::character_pv:2:` 或 `pv::teaser_pv:1:` 合并）
  ///   - `[BD CM 01]` (`pv::bd_cm:1:`) 与 `[TV CM 01]` (`pv::tv_cm:1:`) 各自独立
  ///   - `[NCED1a]` (`nced::nced:1:a`) 与 `[NCED1b]` (`nced::nced:1:b`) 各自独立
  /// - 对于无编号纯文本/CD随附特典，将纯净词干与专辑上下文纳入键中，避免误合并。
  static String buildExtraCanonicalMergeKey({
    required String fileName,
    String? relativePath,
    ExtraKind? extraType,
    String? titleHint,
    String? workTitle,
  }) {
    final path = (relativePath ?? fileName).replaceAll('\\', '/');
    final kind =
        extraType ??
        classifyExtraVideo(fileName: fileName, relativePath: relativePath);

    final stem = _stripExtension(fileName);
    final cleanedHint = (titleHint ?? '').trim();

    if (_isCdBundledExtraPath(path)) {
      final albumGroup = extractCdAlbumGroup(relativePath: path);
      final normAlbum = albumGroup.albumKey.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9\u3040-\u9fff]+'),
        '_',
      );
      final normStem = _cleanStemForMergeKey(
        stem,
      ).toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), '_');
      return '${kind.name}::cd::$normAlbum::$normStem';
    }

    // 1. 先检查提取出的带限定词/子变体完整标题（保留 `Character PV 01`、`Main PV`、`BD CM 01`、`NCED1a` 等）
    final qualified = extractQualifiedExtraTitle(
      fileName,
      relativePath: relativePath,
    );
    final candidateText = (qualified != null && qualified.isNotEmpty)
        ? qualified
        : (cleanedHint.isNotEmpty ? cleanedHint : _cleanStemForMergeKey(stem));

    // 优先在 candidateText 上提取结构化核心标识，若无则回退文件名括号内容
    RegExpMatch? tokenMatch = _canonicalTokenRegex.firstMatch(candidateText);
    if (tokenMatch == null) {
      for (final seg in _extractBracketSegments(stem)) {
        final m = _canonicalTokenRegex.firstMatch(seg);
        if (m != null) {
          tokenMatch = m;
          break;
        }
      }
    }
    tokenMatch ??= _canonicalTokenRegex.firstMatch(stem);

    final volTag = _canonicalVolDiscTag(fileName, path) ?? '';

    if (tokenMatch != null) {
      var coreRaw = tokenMatch.group(1)!.toLowerCase();
      coreRaw = coreRaw
          .replaceAll(
            RegExp(
              r'^(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean)[\s._-]*opening$',
            ),
            'ncop',
          )
          .replaceAll(
            RegExp(
              r'^(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean)[\s._-]*ending$',
            ),
            'nced',
          )
          .replaceAll(
            RegExp(
              r'^(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean)[\s._-]*op$',
            ),
            'ncop',
          )
          .replaceAll(
            RegExp(
              r'^(?:creditless|textless|non[\s._-]*(?:telop|credit)|clean)[\s._-]*ed$',
            ),
            'nced',
          )
          .replaceAll('information', 'info')
          .replaceAll('trailers', 'trailer')
          .replaceAll('teasers', 'teaser')
          .replaceAll('previews', 'preview')
          .replaceAll('spots', 'spot')
          .replaceAll('menus', 'menu')
          .replaceAll(RegExp(r'music[\s._-]*(?:video|clip)'), 'mv');
      final coreNorm = coreRaw
          .replaceAll(RegExp(r'[\s._-]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '')
          .replaceFirst('character_', 'char_')
          .replaceFirst('blu_ray_', 'bluray_');
      // 保留限定词边界，避免 `character_pv` 与 `pv` 混淆；同时统一 `nc_op` -> `ncop`, `pv_cm` -> `pvcm`, `tv_cm` -> `tv_cm`
      final normalizedCore = coreNorm
          .replaceAll('nc_op_ed', 'ncoped')
          .replaceAll('nc_op', 'ncop')
          .replaceAll('nc_ed', 'nced')
          .replaceAll('menu_ex', 'menuex')
          .replaceAll('pv_cm', 'pvcm')
          .replaceFirst(RegExp(r'^char_'), 'character_');
      final rawNum = tokenMatch.group(2);
      final numPart = rawNum != null ? int.parse(rawNum).toString() : '';
      final subVar = (tokenMatch.group(3) ?? '').toLowerCase();

      // 无编号且无语义前缀（例如泛化 `Menu`、`Making`、`PV`）或带显式卷碟信息时附加卷碟/纯净词干消歧
      final hasQualifier = normalizedCore.contains('_');
      if (numPart.isNotEmpty || hasQualifier) {
        final volSuffix = volTag.isNotEmpty && numPart.isEmpty
            ? ':$volTag'
            : '';
        return '${kind.name}::$normalizedCore:$numPart:$subVar$volSuffix';
      }

      if (volTag.isNotEmpty) {
        return '${kind.name}::$normalizedCore:$volTag';
      }
    }

    // 2. 非标准命名 / 纯描述词干回退键：剥去压制组、技术参数、作品名，确保同片不同版本可归并，异片不冲突
    var stripped = _cleanStemForMergeKey(stem).toLowerCase();
    if (workTitle != null && workTitle.trim().isNotEmpty) {
      final normWork = workTitle.trim().toLowerCase();
      stripped = stripped.replaceFirst(
        RegExp('^${RegExp.escape(normWork)}[\\s._\\-–—_:：]*'),
        '',
      );
    }
    final stemNorm = stripped
        .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final hintNorm = cleanedHint
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u3040-\u9fff]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final effective = stemNorm.isNotEmpty
        ? stemNorm
        : (hintNorm.isNotEmpty ? hintNorm : path.toLowerCase());
    return '${kind.name}::stem::$effective${volTag.isEmpty ? '' : '::$volTag'}';
  }

  /// 判断数据库中现有标题是否属于旧版截断生成的自动默认短名（可安全无感自愈刷新为 [resolvedTitle]）。
  static bool isLikelyTruncatedAutoExtraTitle(
    String? existingTitle,
    String resolvedTitle,
  ) {
    final existing = existingTitle?.trim() ?? '';
    final resolved = resolvedTitle.trim();
    if (resolved.isEmpty) return false;
    if (existing.isEmpty) return true;
    if (existing == resolved) return false;

    final compactExisting = existing.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    final compactResolved = resolved.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );
    if (compactExisting == compactResolved) return false;

    if (_legacyTruncatedExtraTitleRegex.hasMatch(existing)) {
      return true;
    }
    // 例如旧标题被截断为 `PV01` / `CM 01` / `NCED1`，而新解析保留完整前缀/子变体 (`Character PV 01` / `BD CM 01` / `NCED1a`)
    if (compactResolved.length > compactExisting.length &&
        (compactResolved.endsWith(compactExisting) ||
            compactResolved.startsWith(compactExisting))) {
      return RegExp(
        r'^(?:pv|cm|teaser|trailer|preview|spot|ncop|nced|menu|sp)\d*$',
      ).hasMatch(compactExisting);
    }
    return false;
  }
}
