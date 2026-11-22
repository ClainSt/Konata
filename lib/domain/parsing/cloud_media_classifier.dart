import '../matching/supplementary_subclassifier.dart';
import '../models/episode.dart';

/// 云盘/BDRip 特典分类与媒体目录过滤工具。
class CloudMediaClassifier {
  const CloudMediaClassifier._();

  static final RegExp _suppDirSegment = RegExp(
    r'^(?:sp|sps|sp[\s._-]*disk|specials?|special\s*cd\d*|ovas?|oads?|extras?|bonus|credits|events?|live\s*part|menus?|pv|pvs|cm|cms|nc|ncop|nced|op|ed|openings?|endings?|op\s*&\s*ed|creditless[\s._-]*op[\s._-]*ed|trailer|trailers|mv|mvs|sc|scan|scans|cd|cds|ost|soundtrack|music|bk|booklet|digest|effects?|fan\s*disc|tokubetsu(?:\s*eizou)?|promotional?|tvスポット|プロモーション映像|ミ[コュ]ージック[・\s]*クリップ|特典|映像特典|音声特典|番外|预告|花絮)$',
    caseSensitive: false,
  );

  static final RegExp _opDir = RegExp(
    r'^(?:ncop|op|openings?)$',
    caseSensitive: false,
  );
  static final RegExp _edDir = RegExp(
    r'^(?:nced|ed|endings?)$',
    caseSensitive: false,
  );
  static final RegExp _pvDir = RegExp(
    r'^(?:pv|pvs|cm|cms|pv\s*&\s*cm|trailer|trailers|digest|promotional?|tvスポット|プロモーション映像|预告)$',
    caseSensitive: false,
  );
  static final RegExp _menuDir = RegExp(
    r'^(?:menu|menus)$',
    caseSensitive: false,
  );
  static final RegExp _ovaDir = RegExp(
    r'^(?:ova|ovas|oad|oads)$',
    caseSensitive: false,
  );
  static final RegExp _mvDir = RegExp(
    r'^(?:mv|mvs|music\s*video|ミ[コュ]ージック[・\s]*クリップ)$',
    caseSensitive: false,
  );

  static final RegExp _ncopTag = RegExp(
    r'(?:^|[\s._\-\[\(【#])(?:nc[\s._-]*op\d*(?:(?!v\d)[a-z])?(?:v\d+)?|clean[\s._-]*(?:op|opening)\d*(?:(?!v\d)[a-z])?|creditless[\s._-]*(?:a+vant|op|opening)\d*(?:(?!v\d)[a-z])?|non[\s._-]*(?:credit|telop)[^\]\)]*?(?:a+vant|op|opening)\d*(?:(?!v\d)[a-z])?|ノンクレ(?:ジット)?[\s._-]*(?:op|opening)?\d*(?:(?!v\d)[a-z])?(?:v\d+)?|ノンテロップ\s*(?:op|opening)?\d*(?:(?!v\d)[a-z])?|op\s*\d+(?:(?!v\d|ver\b)[a-z])?(?:ver|v\d+)?|op\s*-\s*\d+)(?=$|[\s._\-\]\)】「&])|[\[\(【]\s*(?:ep_?\d+\s+)?op\d*(?:(?!v\d)[a-z])?\s*[\]\)】]|(?:^|\s-\s*|\s版?\s*)オープニング\s*\d*\s*$|(?:^|\s-\s*)op\d*\s*$',
    caseSensitive: false,
  );
  static final RegExp _ncedTag = RegExp(
    r'(?:^|[\s._\-\[\(【#])(?:nc[\s._-]*ed\d*(?:(?!v\d)[a-z])?(?:v\d+)?|clean[\s._-]*(?:ed|ending)\d*(?:(?!v\d)[a-z])?|creditless[\s._-]*(?:ed|ending)\d*(?:(?!v\d)[a-z])?|chorei[\s._-]*ending\d*(?:(?!v\d)[a-z])?|non[\s._-]*(?:credit|telop)[^\]\)]*?(?:ed|ending)[^\]\)\d]*\d*(?:(?!v\d)[a-z])?|ノンクレ(?:ジット)?[\s._-]*(?:ed|ending)?\d*(?:(?!v\d)[a-z])?(?:v\d+)?|ノンテロップ\s*(?:ed|ending)?\d*(?:(?!v\d)[a-z])?|ed\s*\d+(?:(?!v\d|ver\b)[a-z])?(?:ver|v\d+)?|ed\s*-\s*\d+)(?=$|[\s._\-\]\)】「.&])|[\[\(【]\s*(?:ep_?\d+\s+)?ed\d*(?:(?!v\d)[a-z])?\s*[\]\)】]|(?:^|\s-\s*|\s版?\s*)エンディング\s*\d*\s*$|(?:^|\s-\s*)ed\d*\s*$',
    caseSensitive: false,
  );
  static final RegExp _menuTag = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:menu[\s._-]*(?:ex)?\d*|bd[\s._-]*menu\d*|dvd[\s._-]*menu\d*|top[\s._-]*menu|(?:haupt)?menue)(?=$|[\s._\-\[\(\]\)】（）])',
    caseSensitive: false,
  );
  static final RegExp _mvTag = RegExp(
    r'(?:^|[\s._\-\[\(【』」])(?:music[\s._-]*(?:video|clip)(?:[\s._-]*\d+)?|mv\d*)(?=$|[\s._\-\]\)】「])|ミュージック[\s・]?クリップ集?|(?:アニメ)?コラボmv',
    caseSensitive: false,
  );
  static final RegExp _pvTag = RegExp(
    r'(?:^|[\s._\-\[\(【#！!？?』」・])(?:特報(?:[・･·&＆+＋/](?:pv|cm))+集?|pv(?:[・･·&＆+＋/](?:tv)?cm)+\s*集?|(?:pv)?cm集?|pv集?|pv\d+|pvs|cm\d+|(?:bd|tv|番宣|先行)cm\d*|(?:\d+秒)?cm(?=$|[\s._\-\]\)】\(（])|(?:ティザー|プロローグ|メイン|主題歌|web|キャラクター)[\s._-]*pv\d*集?|web[\s._-]*preview(?:\s*\d+)?|true\s+end\s+pv|trailers?\d*|teaser\d*|preview\d*|(?:(?:trailers?|pvs?|cms?)[\s._\-]*[&+・/][\s._\-]*)?tv[\s._\-]*spots?(?:[\s._\-]*\d+s?(?:[&/]\d+s?)*)?集?|tri\.?\d*(?:pv|cm)\d*|pvtri\.?\d*|(?:#?\d+|web用?|本|次回|新番組|劇場)?予告(?:映像|編|篇|集)?(?:\d+秒)?(?:#?\d+)?|(?:劇場|超)?特報(?:映像)?\d*|発売告知cm|告知[編篇]?\d*|番宣集?\d*|spot\s*\d*|info\s*\d+|cm\+info|taf\d{4}映像|イベント用映像)(?=$|[\s._\-\]\)】\(（！!・])|[\[\(【]\s*info\s*[\]\)】]|(?<![A-Za-z])(?:pv\d*|cm集|pv集|tvcm|番宣集)(?=$|[\s._\-\]\)】「！!・])|プロモーション映像|オリジナル予告編?|劇場予告篇?|劇場特報\d*',
    caseSensitive: false,
  );

  /// 强特典标识符（不会因同目录正片序列保护而回滚为正片）。
  static final RegExp _ovaStrongTag = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:ova\s*\d*|oad\s*\d*|\d+\(\s*ova\s*\d*\s*\))(?=$|[\s._\-\]\)】「『（《！!])',
    caseSensitive: false,
  );

  static final RegExp _jpBdExtraTag = RegExp(
    r'(?:映像特典|音声特典|ピクチャードラマ|ミニアニメ|新作アニメ|インタビュー|公開記念|引退記念|舞台挨拶|オーディオコメンタリー?|ビジュアルコメンタリー?|メイキング|ノンクレジット|ノンテロップ|ノクレジット|bd特典|特典映像|特典ゲーム|特典[巻卷]|パッケージ特典|密着映像|先行上映(?:会|イベント)?|特別先行上映会|ス[ペベ]シャルイベント|スペシャルステージ|スペシャルバージョン|スペシャル映像|キャスト生特番|記念特番|特別番組|tvスペシャル\d*映像?|放送直前|アフレコ現場|ngシーン集|振付映像|体験動画|講座|おまけ|ラジオ|キャストトーク|トークショー|女子会トーク|影ナレーション|朗読音楽劇|特別映像|振り返り映像|次回予告|バージョン予告(?:映像|編|篇|集)?|本編制作過程映像|制作過程映像|制作工程(?:オリジナル)?映像|制作現場|劇場マナー映像|マナー映像|エンドカード集|放課後[vｖ]タイム|クッキング|お年賀映像|魔法レッスン|トレーニング|パイロットフ?イルム|ダイジェスト(?:映像)?|啓蒙映像|想い出い?ムービー|第\d+弾\s*\(\d+秒\))',
    caseSensitive: false,
  );

  static final RegExp _strongSpTag = RegExp(
    r'(?:^|[\s._\-\[\(【！!？?])(?:sp\s*\d+|ex\s*\d+|websp|ex\s*season(?:\s*\d+)?|extra[\s._-]*(?:audio|\d+)|iv\s*\d+|insert\s*\d+|bonus|interview[\s_-]*\d*|eyecatch(?:es)?\d*|cast\s*film\s*\d*|non[\s_-]?(?:credit|telop)[^\]\)]*ver\.?|(?:audio[\s._-]+|visual[\s._-]+)?commentary\b|making(?:\s+of)?|digest|short\s*track|pilot\s*film|memorial\s*movie|zenyasai|omake|remix\d+|m\d+(?:opening|sp\d+)|tokuten(?:\s*dvd)?|touhou[\s._-]+pvd|aj\d{4}[\s._-]*message|(?:opening|op)\s*&\s*(?:ending|ed)\s+ency\w*|(?:opening|ending)\s+(?:talk\s*\d*|long\s*speech)|dance[_\s]*lesson|congrats[_\s]*messages?|caution|web[\s_-]?live|logo|greeting[\s._-]+event|transformation[\s&_-]*(?:attack[\s._-]*)?scene\d*|cms?[\s._-]+&[\s._-]+tv[\s._-]+spots?|info\.[a-z\u3040-\u30ff]+|(?<!with\s)(?:(?:eng(?:lish)?|clean|textless)\s+)credits|(?<=\s-\s)credits|番外篇?\d*)(?=$|[\s._\-\]\)】『]|ed|op)|(?:特别篇|特別編)\s*(?:ed|op)|#ex\d*(?=$|[\s._\-\]\)】『])|[\[\(【]\s*(?:live|data\s*carddass(?:\s*\d+)?|credits)\s*[\]\)】]',
    caseSensitive: false,
  );

  /// 独立特别篇作品与 TV 番外特别篇共用的词根：需结合目录名判断是否就是该作自身片名。
  static final RegExp _standaloneOrSpTitleTag = RegExp(
    r'(?:^|[\s._\-\[\(【！!？?])(?:tokubetsu[\s._-]*hen|特别篇\d*|特別編\d*)(?=$|[\s._\-\]\)】『])',
    caseSensitive: false,
  );

  static final RegExp _folderStandaloneSpecialTag = RegExp(
    r'(?:(?:特別|特别)[編篇]|tokubetsu[\s._-]*hen)',
    caseSensitive: false,
  );

  /// 弱上下文特典词：仅在没有连续正片保护时判为特典（如标题内含 `総集編` / `Recap` / `Special`）。
  static final RegExp _weakContextExtraTag = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:recap|specials?|総集編|総集篇|总集篇)(?=$|[\s._\-\]\)】#])',
    caseSensitive: false,
  );

  /// 判定 `[12(OVA01)]` 类复合括注中的 OVA 编号。
  static final RegExp _bundledOvaPattern = RegExp(
    r'\[\s*\d+\s*\(\s*ova\s*0*(\d+)\s*\)\s*\]',
    caseSensitive: false,
  );

  /// 提取独立特典编号（如 `[OVA01]`、`SP02`、`MenuEX1`、`NCOP2` 等）中的序号。
  static final RegExp _explicitExtraNumberPattern = RegExp(
    r'(?:^|[\s._\-\[\(【])(?:ova|oad|sp|ex|extra|ncop|nced|pv|cm|menu(?:\s*ex)?)[\s._-]*0*(\d{1,3})(?:v\d+)?(?=$|[\s._\-\]\)】])',
    caseSensitive: false,
  );

  static final RegExp _sampleSuffix = RegExp(
    r'(?:-sample$|^sample$|[\[\(【]\s*sample\s*[\]\)】])',
    caseSensitive: false,
  );
  static final RegExp _fractionalTag = RegExp(
    r'(?:^|[\s._\-\[\(【E])\d{1,3}\.5(?:v\d+)?(?=$|[\s_\]\)】\(]|\.(?!\d)|-(?![a-zA-Z]))',
    caseSensitive: false,
  );
  static final RegExp _techNoise = RegExp(
    r'\[?(?:1920x1080|1280x720|3840x2160|2160p|1080p|720p|480p|x264|x265|h264|h265|hevc|av1|10bit|12bit|8bit|flac|aac|opus|lpcm|pcm|dts-?hd|hdr10\+?|dovi|bdrip|web-?dl|ma10p|[0-9a-f]{8})\]?',
    caseSensitive: false,
  );
  static final RegExp _explicitEpMarker = RegExp(
    r'(?:S\d{1,2}E\d{1,3}|第\s*[0-9一二三四五六七八九十百零〇]+\s*[話话集回]|\b(?:EP|Episode)[\s._-]?\d{1,3})',
    caseSensitive: false,
  );

  static final RegExp _multiSpace = RegExp(r'\s+');
  static final RegExp _slashRegex = RegExp(r'[/\\]');

  /// 剥离纯技术规格字符串，减少特典识别误判。
  static String stripTechnicalNoise(String input) =>
      input.replaceAll(_techNoise, ' ').replaceAll(_multiSpace, ' ').trim();

  /// 判断相对路径任一目录段是否属于特典/附加内容子目录。
  static bool isSupplementaryDirectory(String? relativePath) {
    if (relativePath == null || relativePath.trim().isEmpty) return false;
    final parts = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.length <= 1) return false;
    for (var i = 0; i < parts.length - 1; i++) {
      final seg = parts[i].trim();
      if (_suppDirSegment.hasMatch(seg)) return true;
    }
    return false;
  }

  /// 单趟同时返回特典细分类型、强特典判定与已去噪主干（避免热路径重复调用 [detectExtraKind] 与 [isStrongSupplementary]）。
  static ({ExtraKind? kind, bool isStrong, String cleanedBase})
  classifyExtraWithStrength({
    required String fileName,
    String? relativePath,
    bool hasFractionalEpisode = false,
  }) {
    final baseName = _stripExt(fileName);
    final cleaned = stripTechnicalNoise(baseName);

    // 1. 优先识别文件名中的显式类型关键词（严格遵循决策点 1：花絮/Making/访谈等优先于 MV 与父目录）。
    final explicitDecision =
        SupplementarySubclassifier.detectExplicitExtraKindFromFileName(
          fileName,
        );
    if (explicitDecision != null) {
      return (
        kind: explicitDecision,
        isStrong: _isStrongFromPrepared(
          baseName: baseName,
          cleaned: cleaned,
          relativePath: relativePath,
          hasFractionalEpisode: hasFractionalEpisode,
        ),
        cleanedBase: cleaned,
      );
    }

    if (_ncopTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.ncop, isStrong: true, cleanedBase: cleaned);
    }
    if (_ncedTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.nced, isStrong: true, cleanedBase: cleaned);
    }
    if (_menuTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.menu, isStrong: true, cleanedBase: cleaned);
    }
    if (_mvTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.mv, isStrong: true, cleanedBase: cleaned);
    }
    if (_sampleSuffix.hasMatch(cleaned) || _pvTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.pv, isStrong: true, cleanedBase: cleaned);
    }
    if (_bundledOvaPattern.hasMatch(baseName) ||
        _ovaStrongTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.ova, isStrong: true, cleanedBase: cleaned);
    }

    // 2. 其次识别所在目录是否为明确细分类型（op/ed/pv/menu/ova/mv）。
    final specificDirExtra = _detectSpecificExtraFromDirectory(relativePath);
    if (specificDirExtra != null) {
      return (kind: specificDirExtra, isStrong: true, cleanedBase: cleaned);
    }

    // 3. 识别小数半集、日版特典关键词与通用 SP/弱特典词。
    if (hasFractionalEpisode || _fractionalTag.hasMatch(baseName)) {
      return (kind: ExtraKind.sp, isStrong: true, cleanedBase: cleaned);
    }
    if (_jpBdExtraTag.hasMatch(cleaned)) {
      return (kind: ExtraKind.sp, isStrong: true, cleanedBase: cleaned);
    }
    final isStrongSp = _strongSpTag.hasMatch(cleaned);
    final isWeakContext = _weakContextExtraTag.hasMatch(cleaned);
    if (isStrongSp || isWeakContext) {
      final isStrong =
          isSupplementaryDirectory(relativePath) ||
          (!(isWeakContext && _explicitEpMarker.hasMatch(baseName)) &&
              (isStrongSp ||
                  (_standaloneOrSpTitleTag.hasMatch(cleaned) &&
                      !_hasFolderStandaloneSpecialTitle(relativePath))));
      return (kind: ExtraKind.sp, isStrong: isStrong, cleanedBase: cleaned);
    }
    if (_standaloneOrSpTitleTag.hasMatch(cleaned) &&
        !_hasFolderStandaloneSpecialTitle(relativePath)) {
      return (kind: ExtraKind.sp, isStrong: true, cleanedBase: cleaned);
    }

    // 4. 兜底匹配泛化特典容器目录（如 Extras/SPs/特典/番外）。
    if (isSupplementaryDirectory(relativePath)) {
      return (kind: ExtraKind.sp, isStrong: true, cleanedBase: cleaned);
    }
    return (kind: null, isStrong: false, cleanedBase: cleaned);
  }

  /// 检测文件是否为特典及其细分类型；返回 `null` 表示暂判定为正片。
  static ExtraKind? detectExtraKind({
    required String fileName,
    String? relativePath,
    bool hasFractionalEpisode = false,
  }) => classifyExtraWithStrength(
    fileName: fileName,
    relativePath: relativePath,
    hasFractionalEpisode: hasFractionalEpisode,
  ).kind;

  static bool _isStrongFromPrepared({
    required String baseName,
    required String cleaned,
    String? relativePath,
    bool hasFractionalEpisode = false,
  }) {
    if (_detectSpecificExtraFromDirectory(relativePath) != null ||
        isSupplementaryDirectory(relativePath)) {
      return true;
    }
    if (_ncopTag.hasMatch(cleaned) ||
        _ncedTag.hasMatch(cleaned) ||
        _menuTag.hasMatch(cleaned) ||
        _mvTag.hasMatch(cleaned) ||
        _sampleSuffix.hasMatch(cleaned) ||
        _pvTag.hasMatch(cleaned) ||
        _bundledOvaPattern.hasMatch(baseName) ||
        _ovaStrongTag.hasMatch(cleaned) ||
        hasFractionalEpisode ||
        _fractionalTag.hasMatch(baseName) ||
        _jpBdExtraTag.hasMatch(cleaned)) {
      return true;
    }
    // 对已含正片 `第08话` / `S01E08` 的仅带弱 `Recap`/`Special`/`総集編` 的集数视为弱特典，交由保护器判断。
    if (_weakContextExtraTag.hasMatch(cleaned) &&
        _explicitEpMarker.hasMatch(baseName)) {
      return false;
    }
    return _strongSpTag.hasMatch(cleaned) ||
        (_standaloneOrSpTitleTag.hasMatch(cleaned) &&
            !_hasFolderStandaloneSpecialTitle(relativePath));
  }

  /// 是否属于**强特典**（目录即特典或带 NCOP/NCED/Menu/MV/PV/OVA/小数半集/日版特典关键词）。
  ///
  /// 当返回 `false` 时（仅由 `Recap`/`Special`/`総集編` 弱词触发），允许同目录连续 `1..N` 正片保护将其挽回为正片。
  static bool isStrongSupplementary({
    required String fileName,
    String? relativePath,
    bool hasFractionalEpisode = false,
  }) {
    if (_detectSpecificExtraFromDirectory(relativePath) != null ||
        isSupplementaryDirectory(relativePath)) {
      return true;
    }
    final baseName = _stripExt(fileName);
    final cleaned = stripTechnicalNoise(baseName);
    return _isStrongFromPrepared(
      baseName: baseName,
      cleaned: cleaned,
      relativePath: relativePath,
      hasFractionalEpisode: hasFractionalEpisode,
    );
  }

  static bool _hasFolderStandaloneSpecialTitle(String? relativePath) {
    if (relativePath == null || relativePath.trim().isEmpty) return false;
    final segs = relativePath
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segs.length <= 1) return false;
    // 仅检测所在父级或紧邻两层作品目录，避免外层“系列/合集”总目录名污染下属普通集。
    final minIdx = segs.length >= 3 ? segs.length - 3 : 0;
    for (var i = segs.length - 2; i >= minIdx; i--) {
      if (_folderStandaloneSpecialTag.hasMatch(segs[i])) return true;
    }
    return false;
  }

  /// 从 `[12(OVA01)]` 格式中提取内嵌 OVA 序号（若存在）。
  static int? extractBundledOvaEpisode(String fileName) {
    final m = _bundledOvaPattern.firstMatch(fileName);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }

  /// 从已剥离技术噪音的主干文本中提取独立特典序号。
  static int? extractExplicitExtraNumberFromClean(String cleaned) {
    final m = _explicitExtraNumberPattern.firstMatch(cleaned);
    if (m == null) return null;
    return int.tryParse(m.group(1) ?? '');
  }

  /// 从 `[OVA01]` / `SP02` / `MenuEX1` 等独立特典标记中提取特典序号（若存在）。
  static int? extractExplicitExtraNumber(String baseName) =>
      extractExplicitExtraNumberFromClean(stripTechnicalNoise(baseName));

  static bool hasExplicitEpisodeMarker(String baseName) =>
      _explicitEpMarker.hasMatch(baseName);

  static ExtraKind? _detectSpecificExtraFromDirectory(String? relativePath) {
    if (relativePath == null || relativePath.trim().isEmpty) return null;
    final norm = relativePath.replaceAll('\\', '/');
    final segs = norm.split('/').where((s) => s.trim().isNotEmpty).toList();
    if (segs.length <= 1) return null;
    for (var i = segs.length - 2; i >= 0; i--) {
      final s = segs[i].trim();
      if (_opDir.hasMatch(s)) return ExtraKind.ncop;
      if (_edDir.hasMatch(s)) return ExtraKind.nced;
      if (_pvDir.hasMatch(s)) return ExtraKind.pv;
      if (_menuDir.hasMatch(s)) return ExtraKind.menu;
      if (_ovaDir.hasMatch(s)) return ExtraKind.ova;
      if (_mvDir.hasMatch(s)) return ExtraKind.mv;
    }
    return null;
  }

  static String _stripExt(String name) {
    final slash = name.lastIndexOf(_slashRegex);
    final fileOnly = slash >= 0 ? name.substring(slash + 1) : name;
    final dot = fileOnly.lastIndexOf('.');
    return dot > 0 ? fileOnly.substring(0, dot) : fileOnly;
  }
}
