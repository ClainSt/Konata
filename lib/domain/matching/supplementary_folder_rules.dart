import '../scraping/cloud_media_file_classifier.dart';

/// BDRip 目录拓扑中应向上归并至父级作品的附属子目录判定规则（纯逻辑，零 IO）。
class SupplementaryFolderRules {
  const SupplementaryFolderRules._();

  /// 特典/附加视频子目录（全称或去除尾部标签后的主名匹配）。
  static final RegExp _extraVideoDir = RegExp(
    r'^(?:'
    r'sps?|specials?|ova|oad|oav|extras?|bonus(?:[ ._-]*disc)?|privilege[ ._-]*dis[ck]|pvs?|cms?|'
    r'menus?(?:[ ._-]*ex)?\d*|nc|ncop(?:ed)?|nced|trailers?|teasers?|previews?|'
    r'promos?|promotion|making|interviews?|events?|commentary|creditless|textless|'
    r'tv[ ._-]*spots?|tvcm|bdcm|fan[ ._-]*disc|fandisc|'
    r'(?:eizou[ ._-]+)?tokuten|'
    r'特典|映像特典|特典映像|特典视频|花絮|幕后|访谈|预告|預告|预览|宣传'
    r')(?:[ ._-]*\d+)?$',
    caseSensitive: false,
  );

  /// 仅匹配明确分季子目录（不含 `Vol`/`Disc`/`BDMV`/`Part`），用于区分独立季目录与同季蓝光分卷。
  static final RegExp _explicitSeasonOnlyDir = RegExp(
    r'^(?:'
    r'(?:\d{1,2}(?:st|nd|rd|th)[ ._-]+)?seasons?(?:[ ._-]*\d{1,2})?|'
    r's\d{1,2}|'
    r'第[0-9一二三四五六七八九十百]+[季期]'
    r')$',
    caseSensitive: false,
  );

  /// 蓝光分卷与季度子目录（含 `Season 2`、`2nd Season`、`S02`、`第二季`、`第2期`）。
  static final RegExp _volumeOrSeasonDir = RegExp(
    r'^(?:'
    r'(?:\d{1,2}(?:st|nd|rd|th)[ ._-]+)?seasons?(?:[ ._-]*\d{1,2})?|'
    r's\d{1,2}|'
    r'vol(?:ume)?[ ._-]*\d{1,3}|v\d{1,2}|'
    r'bd[ ._-]*\d{1,2}|bd(?:rip|[ ._-]*box)?|bdrip[ ._-]*\d{1,2}|'
    r'dis[ck][ ._-]*\d{1,2}|'
    r'part[ ._-]*\d{1,2}|'
    r'第[0-9一二三四五六七八九十百]+[季期卷巻篇]|'
    r'正片|main(?:[ ._-]*feature)?'
    r')$',
    caseSensitive: false,
  );

  /// 音乐/广播剧/扫图附属子目录关键词（精确名或标准短语）。
  static final RegExp _audioOrScanDir = RegExp(
    r'^(?:'
    r'cds?|cd[ ._-]*\d{1,2}|ost|soundtracks?|original[ ._-]*soundtracks?|music|'
    r'(?:special[ ._-]*)?drama[ ._-]*cds?|audio[ ._-]*drama|'
    r'(?:official[ ._-]*)?radio|character[ ._-]*songs?|chara[ ._-]*songs?|'
    r'vocals?|op|ed|op[ ._-]*&[ ._-]*ed|themes?|'
    r'scans?|booklets?|bk|artworks?|gallery|illustrations?|endcards?|'
    r'角色歌|广播剧|原声[集带帶]?|扫图|畫冊|画册|设定集'
    r')(?:[ ._-]*\d{1,2})?$',
    caseSensitive: false,
  );

  /// 含特定短语的音乐/广播剧/特典容器目录（允许前后附带修饰文本）。
  static final RegExp _supplementaryPhrase = RegExp(
    r'\b(?:special[ ._-]+drama[ ._-]+cd|drama[ ._-]+cd|character[ ._-]+song|'
    r'original[ ._-]+soundtrack|soundtrack|official[ ._-]+radio|bonus[ ._-]+cd|'
    r'bonus[ ._-]+disc|bonus[ ._-]+track|picture[ ._-]+drama|audio[ ._-]+commentary|'
    r'映像特典|特典映像|特典cd|原声集|角色歌|广播剧)\b',
    caseSensitive: false,
  );

  /// 日期前缀封包目录，例如 `[210322] Official Radio... (aac)` 或 `(210602) ...`。
  static final RegExp _datedReleaseDir = RegExp(
    r'^\s*[\[【(]\s*(?:19|20)?\d{2}[01]\d[0-3]\d\s*[\]】)]',
  );

  /// 日版 CD/BD 盘号目录（全称或前缀），例如 `VVCL-1867`, `SVWC-70528`, `LACA-15871`。
  static final RegExp _jpCatalogNumberDir = RegExp(
    r'^\s*[A-Z]{3,5}-\d{3,5}(?:\b|~|-|$)',
  );

  /// 结尾附带纯音频/扫图格式封装标签的目录，例如 `... (flac+webp)`、`... (aac)`、`[flac]`。
  static final RegExp _mediaFormatPackageSuffix = RegExp(
    r'[\[(（【]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|ogg|alac|m4a|webp|jpg|jpeg|png)'
    r'(?:\s*[+&/／,，_-]\s*(?:flac|aac|mp3|wav|ape|tta|tak|opus|ogg|alac|m4a|webp|jpg|jpeg|png|cue|bk|scans?|booklet|rr\d*))*\s*[\])）】]\s*$',
    caseSensitive: false,
  );

  static final RegExp _leadingGroupBracket = RegExp(r'^\s*[\[【]');

  /// 常见附加技术括号后缀（用于清理目录名后再次判定如 `SPs [Ma10p_1080p]`）。
  static final RegExp _trailingBracketTag = RegExp(
    r'\s*(?:\[[^\]]*\]|【[^】]*】|\([^)]*\)|（[^）]*）)\s*$',
  );

  static final RegExp _lastBracketBlock = RegExp(
    r'[\[(（【]([^\[\]()（）【】]*)[\])）】]\s*$',
  );

  /// 全方括号发布目录末尾的分卷块（如 `[组名][片名][BDrip_1]`、`[...][Disc_2]`）。
  static bool _endsWithVolumeBlock(String segment) {
    final m = _lastBracketBlock.firstMatch(segment.trim());
    if (m == null) return false;
    final inner = m.group(1)!.trim();
    return inner.isNotEmpty &&
        !_explicitSeasonOnlyDir.hasMatch(inner) &&
        _volumeOrSeasonDir.hasMatch(inner) &&
        RegExp(r'\d').hasMatch(inner);
  }

  /// 判断单个目录段名是否属于「分卷或季度」子目录（非特典/CD/Scan）。
  static bool isSeasonOrVolumeSegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return false;
    if (_volumeOrSeasonDir.hasMatch(trimmed) || _endsWithVolumeBlock(trimmed)) {
      return true;
    }
    var stripped = trimmed;
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
      if (_volumeOrSeasonDir.hasMatch(stripped)) return true;
    }
    return false;
  }

  /// 判断单个目录段名是否属于明确「季度」子目录（如 `Season 1`、`S02`、`第3季`）。
  static bool isExplicitSeasonSubdir(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return false;
    if (_explicitSeasonOnlyDir.hasMatch(trimmed)) return true;
    var stripped = trimmed;
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
      if (_explicitSeasonOnlyDir.hasMatch(stripped)) return true;
    }
    return false;
  }

  /// 判断单个目录段名是否属于「附属/分卷/音乐/扫图」子目录（应向上归并到父级番剧目录）。
  static bool isSupplementarySegment(String segment) {
    final trimmed = segment.trim();
    if (trimmed.isEmpty) return false;

    if (_datedReleaseDir.hasMatch(trimmed) ||
        _jpCatalogNumberDir.hasMatch(trimmed) ||
        _mediaFormatPackageSuffix.hasMatch(trimmed) ||
        _supplementaryPhrase.hasMatch(trimmed)) {
      return true;
    }

    if (_extraVideoDir.hasMatch(trimmed) ||
        _volumeOrSeasonDir.hasMatch(trimmed) ||
        _audioOrScanDir.hasMatch(trimmed) ||
        _endsWithVolumeBlock(trimmed)) {
      return true;
    }

    // 不带压制组前缀的特典词元目录（如 `NC Ver`、`BD Menu`、`Non Credit`）；带组名前缀的通常是独立发布目录，不在此折叠。
    if (!_leadingGroupBracket.hasMatch(trimmed) &&
        CloudMediaFileClassifier.isExtraVideoDirectoryName(trimmed)) {
      return true;
    }

    // 去掉尾部括号标签后再次判定（例如 `SPs (BD)`, `Vol.01 [1080p]`, `CDs (FLAC)`）
    var stripped = trimmed;
    while (_trailingBracketTag.hasMatch(stripped)) {
      final next = stripped.replaceFirst(_trailingBracketTag, '').trim();
      if (next == stripped || next.isEmpty) break;
      stripped = next;
      if (_extraVideoDir.hasMatch(stripped) ||
          _volumeOrSeasonDir.hasMatch(stripped) ||
          _audioOrScanDir.hasMatch(stripped)) {
        return true;
      }
    }
    return false;
  }

  /// 判断目录路径的任意段是否明显属于音频 CD / 广播剧 / 扫图资产容器目录。
  static bool isAudioOrScanPath(String folderPath) {
    final segments = folderPath
        .replaceAll('\\', '/')
        .split('/')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty);
    for (final seg in segments) {
      if (_audioOrScanDir.hasMatch(seg) ||
          _datedReleaseDir.hasMatch(seg) ||
          _jpCatalogNumberDir.hasMatch(seg) ||
          _mediaFormatPackageSuffix.hasMatch(seg) ||
          _supplementaryPhrase.hasMatch(seg)) {
        return true;
      }
    }
    return false;
  }
}
