import '../models/media_extensions.dart';

/// 扫描器与重整校准共用的保守文件名/目录分类器；
/// 外部刮削源 ID 为可选项，始终以本地媒体语义判定为先。
abstract final class CloudMediaFileClassifier {
  static final _supplementaryDirectory = RegExp(
    r'^(?:sp|sps|special|specials|extra|extras|bonus|nc|ncop|nced|pv|cm|'
    r'menu|menus|music|music[\s._-]*videos?|mvs?|samples?|(?:eizou[\s._-]+)?tokuten|creditless|textless|interviews?|events?|making|'
    r'trailers?|previews?|promos?|promotion|tv[\s._-]*spots?|tvcm|bdcm|'
    r'effects?|fan[\s._-]*disc|fandisc|.*pvd.*|reviews?|'
    r'logo|logos|voices?|ost|soundtrack|gallery|artwork|特典|映像特典|'
    r'特典映像|花絮|幕后|访谈|预告|預告|宣传|聲優|声优|'
    r'(?:op|ed)(?:[\s._&-]*(?:op|ed))*)$',
    caseSensitive: false,
  );

  static final _preview = RegExp(
    r'予告|預告|预告|(^|[^a-z])(trailer|teaser|preview)(?=[^a-z]|$)',
    caseSensitive: false,
  );

  static final _noCredit = RegExp(
    r'creditless|textless|no[ ._-]?credit|non[ ._-]?telop|'
    r'non[ ._-]?credit|ノンクレジット|ノクレジット|ノンクレ|ノンテロップ',
    caseSensitive: false,
  );

  static final delimitedEpisode = RegExp(
    r'[\s_]+[-–—][\s_]+(\d{1,3})(?:v\d+)?[\s_]+[-–—][\s_]+(?=\S)',
    caseSensitive: false,
  );

  static final _supplementaryTag = RegExp(
    r'[\[【]\s*(?:メニュ[ー一][ ._-]*\d*|drama[ ._-]*cd)\s*[\]】]',
    caseSensitive: false,
  );

  static final _releaseSample = RegExp(
    r'\b(?:\d{3,4}p|bdrip|bluray|webrip|web[._-]?dl)\b.*[._-]sample\.[^.]+$',
    caseSensitive: false,
  );

  static final _discAppendix = RegExp(
    r'(?<=\d)[ ._-]+appendix(?=\s*(?:[\[(（【]|\.[^.]+$))|'
    r'[ ._]+[-–—][ ._]+(?:hyakka|百科)[ ._-]*0?[1-9]\d?'
    r'(?=\s*(?:[\[(（【]|\.[^.]+$))',
    caseSensitive: false,
  );

  /// 相邻括号特典标识后紧跟类集号括号，例如 `[SP][01]`、`[OVA][01]`、`[OAD][01]`、`[NCOP][01]`。
  /// 用于识别双括号拆分的特典序号。
  static final adjacentBracketExtra = RegExp(
    r'[\[【]\s*(?:sp|special|ova|oad|pv|cm|ncop(?:ed)?|nced)\s*[\]】]\s*'
    r'[\[【]\s*\d{1,3}(?:v\d+)?\s*[\]】]',
    caseSensitive: false,
  );

  /// 捆绑光盘顺序的特典标记，例如 `[13(OAD)]`、`[11(OAD)]`、`[12(OVA01)]`。
  static final bundledExtraTag = RegExp(
    r'[\[【]\s*\d{1,3}\s*[\(（]\s*(?:oad|ova\d*|sp\d*|special)\s*[\)）]\s*[\]】]',
    caseSensitive: false,
  );

  /// 日版蓝光/DVD 常见特典关键词；当目录内同存正片剧集时，
  /// 命中此类关键词的文件应降级识别为附属映像特典。
  static final contextualJapanBdExtra = RegExp(
    r'初日舞台挨拶|舞台挨拶|キャストトークショー|トークショー|'
    r'(?:スペシャル|キャスト)?[\s._-]*トーク(?:ショー)?|talk[\s._-]+show|'
    r'オーディオ[\s._-]*コメンタリー|アイキャッチ(?:集)?|'
    r'(?:tv[\s._-]*)?シリーズ[\s._-]*ガイド|'
    r'prologue[\s._-]+to[\s._-]+the[\s._-]+movie|'
    r"supporters?(?:['’]s?)?[\s._-]+gathering(?:[\s._-]*(?:19|20)\d{2})?|"
    r'ドキュメント[\s._-]*[#＃][\s._-]*\d+|'
    r'名場面(?:集|コレクション)?|番宣(?:集|映像)?|'
    r'(?:ms|メカ|キャラ(?:クター)?)?[\s._-]*図鑑|'
    r'(?:完結)?記念ナイト|\d+のq[&＆]a|'
    r'(?:^|[\s._-])(?:ラジオ|radio)(?=$|[\s._-])|'
    r'(?:^|[\s._-])final[\s._-]+plus(?=$|[\s._-])|'
    r'(?:^|[\s._-])frag\.(?:前|後|上|中|下)[編篇]|'
    r'帰ってきた[^\r\n]*甲子園|beginning[\s._-]+of[\s._-]+',
    caseSensitive: false,
  );

  static final numberedSupplementLabel = RegExp(
    r'(?<=\d)\s+(?:after[ ._-]+phase|post[ ._-]+credits(?:[ ._-]+scene)?)'
    r'(?=\s*(?:\[|\(|\.[a-z0-9]+$))',
    caseSensitive: false,
  );

  static final String _videoExtensionSuffix =
      KonataMediaExtensions.videoExtensionSuffixPattern;

  static final RegExp _trailingSpacedVideoExtension = RegExp(
    r'\s+(' '${KonataMediaExtensions.videoExtensionSuffixPattern}' r')',
    caseSensitive: false,
  );

  static final RegExp _adjacentLocalizedEpisodeRegex = RegExp(
    r'[^\x00-\x7f]\s*(\d{1,4})'
    r'(?=\s*(?:[\[(（]|' '${KonataMediaExtensions.videoExtensionSuffixPattern}' r'|$))',
    caseSensitive: false,
  );

  static final RegExp _leadingEpisodeRegex = RegExp(
    r'^[ ._-]*(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
    r'(?=\s*(?:' '${KonataMediaExtensions.videoExtensionSuffixPattern}' r'|[-–—_]))',
    caseSensitive: false,
  );

  static final RegExp _looseTailEpisodeRegex = RegExp(
    r'^\s*[._-]*\s*(?:[\[(（【]|' '${KonataMediaExtensions.videoExtensionSuffixPattern}' r'|'
    r'(?:\d{3,4}p|bd|web|dvd|ld|tv|hdtv|hevc|avc|[xh][ ._-]?26[45]|flac|aac|'
    r'opus|ac3|eac3|dts|dtshd|truehd|alac|end|fin|final|premiere|'
    r'early[\s._-]*screening|screening)\b)',
    caseSensitive: false,
  );

  static final _crc32Bracket = RegExp(
    r'[\[(（【［]\s*[0-9a-fA-F]{8}\s*[\])）】］]',
  );

  static final _frameRateMarker = RegExp(
    r'(?<![a-z0-9.])\d+(?:\.\d+)?\s*fps(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _standaloneResolution = RegExp(
    r'(?<![a-z0-9])\d{3,4}x\d{3,4}[pi]?(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _bracketBlock = RegExp(
    r'[\[(（【［]([^\]\)）】］]*)[\])）】］]',
  );

  static final _coreTechToken = RegExp(
    r'^(?:'
    r'\d{3,4}x\d{3,4}[pi]?|\d{3,4}[pi]|[248]k|'
    r'\d+(?:\.\d+)?fps|vfr|cfr|'
    r'[xh]\.?26[45]|hevc|avc|av1|vp9|xvid|divx|mpeg[24]?|'
    r'yuv\d{3}p(?:\d{1,2})?|yuv444p10|rgb\d*|hdr(?:10(?:\+)?)?|dovi|'
    r'(?:main|ma|hi)\d{1,2}p?|main12|\d{1,2}-?bit'
    r')$',
    caseSensitive: false,
  );

  static final _auxTechToken = RegExp(
    r'^(?:'
    r'bd|bdmv|bdrip|bluray|blu|ray|dvd|dvdrip|ld|ldrip|hdtv|web|webrip|webdl|'
    r'tvrip|uhd|fhd|hd|sd|remux|raw|raws|hdr|sdr|dv|nvenc|rip|dl|'
    r'\d*x?(?:flac|aac|opus|ac3|eac3|ec3|ddp?|dd|dts|dtshd|hdma|ma|truehd|'
    r'lpcm|pcm|mp3|vorbis|alac|atmos|wv|wavpack)(?:x?\d+(?:\.\d+)?)?|'
    r'audio|dual|multi|lossless|\d+(?:\.\d+)?ch(?:x\d+)?|(?:2\.0|5\.1|7\.1)(?:x\d+)?|'
    r'chs|cht|chi|zh|cn|jp|jpn|jap|en|eng|sub|subs|softsub|hardsub|'
    r'gb|big5|(?:ass|ssa|srt|pgs|sup|idx)(?:x\d+)?|vobsub|mkv|mp4|v\d+|'
    r'[0-9a-f]{8}'
    r')$',
    caseSensitive: false,
  );

  /// 在执行特典归类与集号提取前，先行剥离 CRC32 校验括号、
  /// 编码技术规格括号（分辨率/编码/位深/音轨）及帧率标签。
  /// 避免编码参数干扰正片集号与特典识别。
  static String stripTechnicalNoise(String name) {
    var result = name
        .replaceAll(_crc32Bracket, ' ')
        .replaceAll(_frameRateMarker, ' ');
    result = result.replaceAllMapped(_bracketBlock, (match) {
      final inner = match.group(1)!.trim();
      if (inner.isEmpty || _isTechnicalBracketContent(inner)) {
        return ' ';
      }
      return match.group(0)!;
    });
    result = result.replaceAll(_standaloneResolution, ' ');
    return result
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(_trailingSpacedVideoExtension, (m) => m.group(1)!)
        .trim();
  }

  static bool _isTechnicalBracketContent(String content) {
    final normalized = _normalizeName(content).trim();
    if (normalized.isEmpty) return true;
    final rawTokens = normalized
        .split(RegExp(r'[\s_,|/\\+&]+'))
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
    if (rawTokens.isEmpty) return false;
    var hasCoreTech = false;
    for (final token in rawTokens) {
      final parts = token.contains('-')
          ? token.split('-').where((p) => p.isNotEmpty)
          : <String>[token];
      for (final part in parts) {
        if (_coreTechToken.hasMatch(part)) {
          hasCoreTech = true;
          continue;
        }
        if (_auxTechToken.hasMatch(part)) {
          continue;
        }
        return false;
      }
    }
    return hasCoreTech;
  }

  static final _supplementaryName = RegExp(
    r'(?<![a-z0-9])(?:'
    r'ncoped|ncop|nced|menus?(?:[ ._-]*ex)?\d*|pv|pvcm|cm|mv|ova(?:v\d+)?|oad|sp|'
    r'logo|rl|info|websp|extras?\d*|'
    r'interview|making|'
    r"supporters?(?:['’]s?)?[\s._-]+gathering(?:[\s._-]*(?:19|20)\d{2})?|"
    r'digest|trailer|teaser|preview|promo|promotion|commentary|recitation|'
    r'picture[\s._-]*collection|eyecatch|artwork|gallery|spot|tv[\s._-]*cm|'
    r'bd[\s._-]*cm|bd[\s._-]*menu\d*|'
    r'music[\s._-]*(?:video|clip)|mv[\s._-]*making|musical[\s._-]*clip|'
    r'mini[\s._-]*(?:anime|series|story|episode)s?|'
    r'short[\s._-]*(?:story|episode|anime|animation|film|special)s?|'
    r'character[\s._-]*(?:short|song|video|clip|movie)s?|'
    r'(?:opening|ending)(?:[\s._-]*(?:movie|video|clip|special|ver\.?|\d+))*|'
    r'specials?|featurettes?|prologue|epilogue|lite|'
    r'eng(?:lish)?[\s._-]*credits?|'
    r'anniversary|congrats(?:ulations)?[\s._-]*messages?|'
    r'true[\s._-]*end[\s._-]*episode|remix(?:[\s._-]*v?\d+)?|'
    r'arcadian[\s._-]*memory|events?|ng[\s._-]*cuts|'
    r'tokubetsu[\s._-]*hen|zenyasai|twi[\s._-]*yaba|'
    r'insert(?:song)?\d+|another[\s._-]*world|'
    r'one[\s._-]*more[\s._-]*time|true[\s._-]*birth[\s._-]*edition|'
    r'previously|shinka[\s._-]*scene|magical[\s._-]*festa|'
    r'karaoke|with[\s._-]*credits|record[\s._-]*(?:19|20)\d{2}|'
    r'pv(?:cm|tri)\d*|reviews?|'
    r'ex[\s._-]*season|pre[\s._-]*show|reminder|prototype|'
    r'side[\s._-]*(?:galo|lio)|gomband|'
    r'transformation|attack[\s._-]*scene|'
    r'panel|discussion|summary|recap|extra[\s._-]*episode|short[\s._-]*track|'
    r'oab|ex[ ._-]*\d+|ex(?=$|[\]）】#])|#[ ._-]*ex'
    r')(?=[^a-z]|$)|'
    r'(?:[\[(【]\s*(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])\s*[\]）】]|'
    r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))|'
    r'(?<![a-z0-9])(?:op|ed)v?\d{1,2}(?![a-z0-9])'
    r'(?=\s*(?:[\[(（【._-]|$)))|'
    r'予告|預告|预告|特報|映像特典|特典|インタビュー|メイキング|座談会|'
    r'舞台|イベント|番宣|コメンタリー|放送前|発売前|宣伝|スポット|'
    r'プロモーションビデオ|オープニング|エンディング|ピクチャー|アイキャッチ|'
    r'トーク|特番|ラジオ|キャスト|アフレコ|制作|現場|パイロット|'
    r'ダイジェスト|総集編|ステージ|ライブ|未公開|メイキング|指南|'
    r'感謝祭|上映会|試写会|ミュージッククリップ|イラスト|エンドカード|'
    r'ミニアニメ|ショートエピソード|ショートアニメ|短編|短片|'
    r'番外編|番外篇|番外|特別編|特别篇|特別版|特别版|'
    r'特別企画|特别企划|放送直前|新作アニメーション|引退記念|'
    r'ミュージカルパート|挿入歌|キャラクターソング|キャラソン|'
    r'イメージボード|ラッシュビデオ|ガイド|講座|讲座|ドキュメント[\s._-]*[#＃][\s._-]*\d+|'
    r'映像|本編制作',
    caseSensitive: false,
  );

  static final _opEdExtra = RegExp(
    r'[\[(【（]\s*(?<![a-z0-9])(?:nc(?:oped|op|ed)|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])\s*[\])】）]|'
    r'(?<![a-z0-9])nc(?:oped|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])|'
    r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))|'
    r'(?<![a-z0-9])(?:op|ed)v?\d{1,2}(?![a-z0-9])'
    r'(?=\s*(?:[\[(（【._-]|$))',
    caseSensitive: false,
  );

  static final _strongSupplementaryName = RegExp(
    r'(?<![a-z0-9])(?:'
    r'ncoped|ncop|nced|pv(?:cm|tri)?\d*|tv[\s._-]*cm|bd[\s._-]*cm|cm|'
    r'bd[\s._-]*menu\w*|menus?(?:[ ._-]*ex)?\d*|making|commentary|eyecatch|karaoke|'
    r'music[\s._-]*(?:video|clip)|mv[\s._-]*making|'
    r'trailers?|teasers?|previews?|promos?|promotion|samples?|'
    r'drama[\s._-]*cd|picture[\s._-]*collection|artwork|gallery|'
    r'creditless|textless'
    r')(?![a-z0-9])|'
    r'[\[(（【]\s*mv\s*[\])）】]|'
    r'予告|預告|预告|特報|メニュ[ー一]?|メイキング|映像特典|ノンクレ|'
    r'アイキャッチ(?:集)?|オーディオ[\s._-]*コメンタリー|ミュージック[\s._-]*(?:ビデオ|クリップ)',
    caseSensitive: false,
  );

  /// 判断 [name] 是否包含严格的独立 `OP/ED` 特典词元（校验字母数字边界）。
  static bool isOpEdExtra(String name) =>
      _opEdExtra.hasMatch(stripTechnicalNoise(name));

  /// 判断视频是否携带强特典标记（如无字幕主题曲、预告、宣传片、菜单、预览及特典目录），
  /// 以区分仅带弱备注标识（如特别篇、总集篇）的正片文件。
  static bool isStrongSupplementary(String directory, String name) {
    if (isSupplementaryDirectory(directory)) return true;
    if (_releaseSample.hasMatch(name)) return true;
    final cleanName = stripTechnicalNoise(name);
    return _preview.hasMatch(cleanName) ||
        _noCredit.hasMatch(cleanName) ||
        _supplementaryTag.hasMatch(cleanName) ||
        bundledExtraTag.hasMatch(cleanName) ||
        _discAppendix.hasMatch(cleanName) ||
        _strongSupplementaryName.hasMatch(cleanName) ||
        _opEdExtra.hasMatch(cleanName) ||
        _isFractionalEpisode(cleanName);
  }

  static bool isPreview(String name) =>
      _preview.hasMatch(stripTechnicalNoise(name));

  static bool isNoCredit(String name) =>
      _noCredit.hasMatch(stripTechnicalNoise(name));

  /// 判断单个视频无需参考目录内其余文件计数即可确认为附属内容，
  /// 扫描器据此从含预告/菜单/活动视频的目录中筛选出唯一无编号正片候选。
  /// 保障单剧场版或单卷 OVA 目录的主正片稳定识别。
  static bool isClearlySupplementary(String directory, String name) {
    if (isSupplementaryDirectory(directory)) return true;
    if (_releaseSample.hasMatch(name)) return true;
    final cleanName = stripTechnicalNoise(name);
    return _preview.hasMatch(cleanName) ||
        _noCredit.hasMatch(cleanName) ||
        _supplementaryTag.hasMatch(cleanName) ||
        adjacentBracketExtra.hasMatch(cleanName) ||
        bundledExtraTag.hasMatch(cleanName) ||
        _discAppendix.hasMatch(cleanName) ||
        _supplementaryName.hasMatch(cleanName) ||
        _opEdExtra.hasMatch(cleanName) ||
        _isFractionalEpisode(cleanName);
  }

  static bool isSupplementaryDirectory(String path) {
    final segments = path
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty);
    return segments.any(_supplementaryDirectory.hasMatch);
  }

  static String classifyAsset(
    String directory,
    String name,
    String kind, {
    int? videoCount,
    int? numberedVideoCount,
    int? unresolvedUnnumberedVideoCount,
  }) {
    if (kind != 'video') return 'metadata';
    if (isClearlySupplementary(directory, name)) return 'extra';

    final episodeNumber = episodeNumberFromNameInDirectory(directory, name);
    if (episodeNumber != null) return 'episode';
    if ((videoCount ?? 0) > 1 &&
        contextualJapanBdExtra.hasMatch(stripTechnicalNoise(name))) {
      return 'extra';
    }

    // 剧场版或单集作品通常无集号标识：当目录内仅此一份可播视频，
    // 或作品标题明确包含电影/剧场版词汇时，将未命中特典的唯一视频视作正片。
    // 避免独生无编号剧场版被误过滤。
    if (_isMovieContext(directory, name)) return 'episode';
    if (RegExp(r'\{tmdb-\d+\}', caseSensitive: false).hasMatch(name)) {
      return 'episode';
    }
    if (_isYearVariantFeature(
      directory,
      name,
      videoCount,
      numberedVideoCount,
    )) {
      return 'episode';
    }
    if ((videoCount ?? 0) == 1 || unresolvedUnnumberedVideoCount == 1) {
      return 'episode';
    }
    return 'review';
  }

  static bool _looksLikeTitleNumber(
    String directory,
    String name,
    int episodeNumber,
  ) {
    final meaningfulDirectory = directory
        .replaceAll('\\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .where(
          (segment) => !RegExp(
            r'^(?:s\d{1,2}|season[ ._-]*\d{1,2}|'
            r'第[0-9一二三四五六七八九十百]+[季期]|'
            r'episodes?|tv[ ._-]*ver|sp|sps|extras?|bonus|nc)$',
            caseSensitive: false,
          ).hasMatch(segment.trim()),
        )
        .join('/');
    final directoryNumbers = RegExp(r'(?<!\d)(\d{1,4})(?!\d)')
        .allMatches(meaningfulDirectory)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toSet();
    if (!directoryNumbers.contains(episodeNumber)) return false;
    final nameNumbers =
        RegExp(r'(?<![a-z0-9])(\d{1,4})(?!\d)', caseSensitive: false)
            .allMatches(name)
            .map((match) => int.tryParse(match.group(1)!))
            .whereType<int>()
            .where((value) => value != 1080 && value != 720 && value != 480)
            .toSet();
    return nameNumbers.length <= 1;
  }

  /// 结合目录级“标题数字抑制”策略解析文件名集号；
  /// 构建目录索引的调用方应优先使用此入口，避免作品名自带数字（如 `86`、`365`）
  /// 虚增目录内的带编号正片数量统计。
  static int? episodeNumberFromNameInDirectory(String directory, String name) {
    final cleanName = stripTechnicalNoise(name);
    final episodeNumber = episodeNumberFromName(cleanName);
    if (episodeNumber == null ||
        _hasExplicitEpisodeMarker(cleanName) ||
        !_looksLikeTitleNumber(directory, cleanName, episodeNumber)) {
      return episodeNumber;
    }
    return null;
  }

  /// 即使作品标题本身含有相同数字，显式集号标识依然具有最高权威性；
  /// 标题数字抑制策略仅作用于宽松兜底数字提取路径。
  static bool _hasExplicitEpisodeMarker(String name) {
    final searchable = _withoutSeasonAndPartMarkers(
      _normalizeName(stripTechnicalNoise(name)),
    );
    if (RegExp(
      r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*\d{1,4}',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*\d{1,4}',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])e(?![a-z])[ ._-]*\d{1,3}(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'第[ ._-]*(?:[0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
      r'[ ._-]*(?:话|話|集|回)',
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])stage[ ._-]*\d{1,4}(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*\d{1,4}(?=\s+\S)',
    ).hasMatch(searchable)) {
      return true;
    }
    if (RegExp(
      r'[#＃][ ._-]*\d{1,4}(?:[ ._-]*(?:end|fin|final|完))?',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    if (_episodeFromBrackets(searchable) != null) return true;
    if (delimitedEpisode.hasMatch(searchable)) return true;
    if (RegExp(
      r'(?:^|[\s\]】)])\s*\d{1,4}'
      r'(?:[-–—]\d{1,4}|\s*[&~]\s*\d{1,4})'
      '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
      caseSensitive: false,
    ).hasMatch(searchable)) {
      return true;
    }
    return _extractPostMarkerEpisode(searchable, explicitCheck: true) != null;
  }

  /// 提取文件名所代表的首个集号；多集连播文件名（如 `01-04`、`003&004`）
  /// 默认映射至起始集号，完整原始文件名仍由目录索引保留用于播放与展示。
  /// 确保连续合集文件具备唯一稳定的排序主键。
  static int? episodeNumberFromName(String name) {
    final normalized = _normalizeName(stripTechnicalNoise(name));
    final normalizedStem = normalized.replaceFirst(
      KonataMediaExtensions.trailingVideoExtensionRegex,
      '',
    );
    if (RegExp(r'^\s*\d+\s*[/／]\s*\d+\s*$').hasMatch(normalizedStem)) {
      return null;
    }
    final searchable = _withoutSeasonAndPartMarkers(normalized).replaceAll(
      RegExp(r'(?<![a-z0-9])\d{1,2}\.\d{1,2}\s*ch\b', caseSensitive: false),
      ' ',
    );

    var match = RegExp(
      r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*(\d{1,4})',
      caseSensitive: false,
    ).firstMatch(searchable);
    final seasonEpisode = _number(match?.group(1));
    if (seasonEpisode != null) return seasonEpisode;

    match = RegExp(
      r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*(\d{1,4})',
      caseSensitive: false,
    ).firstMatch(searchable);
    final explicitEpisode = _number(match?.group(1));
    if (explicitEpisode != null) return explicitEpisode;

    match = RegExp(
      r'(?<![a-z0-9])e(?![a-z])[ ._-]*(\d{1,3})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(searchable);
    final shortEpisode = _number(match?.group(1));
    if (shortEpisode != null) return shortEpisode;

    match = RegExp(
      r'(?<![a-z0-9])stage[ ._-]*(\d{1,4})(?![a-z0-9])',
      caseSensitive: false,
    ).firstMatch(searchable);
    final stage = _number(match?.group(1));
    if (stage != null) return stage;

    match = RegExp(
      r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*(\d{1,4})'
      r'(?=\s+\S)',
    ).firstMatch(searchable);
    final datedEpisode = _number(match?.group(1));
    if (datedEpisode != null) return datedEpisode;

    match = RegExp(
      r'第[ ._-]*([0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
      r'[ ._-]*(?:话|話|集|回)',
    ).firstMatch(searchable);
    final localized = _number(match?.group(1));
    if (localized != null) return localized;

    match = RegExp(
      r'[#＃][ ._-]*(\d{1,4})(?:[ ._-]*(?:end|fin|final|完))?',
      caseSensitive: false,
    ).firstMatch(searchable);
    final hash = _number(match?.group(1));
    if (hash != null) return hash;

    final bracketed = _episodeFromBrackets(searchable);
    if (bracketed != null) return bracketed;

    final delimited = _number(
      delimitedEpisode.firstMatch(searchable)?.group(1),
    );
    if (delimited != null) return delimited;

    match = RegExp(
      r'(?:^|[\s\]】)])\s*(\d{1,4})'
      r'(?:[-–—]\d{1,4}|\s*[&~]\s*\d{1,4})'
      '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final rangeStart = _number(match?.group(1));
    if (rangeStart != null) return rangeStart;

    final postMarker = _extractPostMarkerEpisode(searchable);
    if (postMarker != null) return postMarker;

    match = RegExp(r'\((\d{1,4})\)').firstMatch(searchable);
    final parenthesized = _number(match?.group(1));
    if (parenthesized != null) return parenthesized;

    match = _adjacentLocalizedEpisodeRegex.firstMatch(searchable);
    final adjacentLocalized = _number(match?.group(1));
    if (adjacentLocalized != null) return adjacentLocalized;

    match = _leadingEpisodeRegex.firstMatch(searchable);
    final leading = _number(match?.group(1));
    if (leading != null) return leading;
    return _looseEpisodeNumber(searchable);
  }

  static int? _extractPostMarkerEpisode(
    String searchable, {
    bool explicitCheck = false,
  }) {
    // 位于副标题或方括号标签前方的显式分隔符集号具备最高优先级，
    // 优先于作品续作数字（例如 `Eizou Hakusho II - 01 Yusuke`）。
    final spacedDash = RegExp(
      r'(?:^|\s|[\]】)])[-–—]\s+(\d{1,4})(?:v\d+)?(?![a-z0-9.])'
      r'(?=\s+(?!(?:days?|hours?|minutes?|mins?|seconds?|secs?|years?|'
      r'months?|weeks?|meters?|km|miles?|st|nd|rd|th)\b)\S|'
      '\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
      caseSensitive: false,
    );
    for (final m in spacedDash.allMatches(searchable)) {
      final value = _number(m.group(1));
      if (value != null && !_technicalNumber(value)) return value;
    }

    final separatedMatch = RegExp(
      r'(?:^|[\s\]】)])(?:\d*\s*[-–—_]|(?<!\d)\.)\s*(?!\d{3,4}[pi](?![a-z0-9]))'
      r'(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
      '(?=\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
      caseSensitive: false,
    ).firstMatch(searchable);
    final separated = _number(
      separatedMatch?.group(1),
      rejectYears: false,
    );
    if (separated != null) return separated;

    final trailingPattern = RegExp(
      r'(?:^|[\s\]】)])\s*(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
      '(?=\\s*(?:[-–—_]|\\.(?!\\d)|[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|'
      r'(?:tv|theatre|theater|encore|uncensored|nc)[ ._-]*ver|完|$))',
      caseSensitive: false,
    );
    for (final m in trailingPattern.allMatches(searchable)) {
      final rawDigits = m.group(1)!;
      final tail = searchable.substring(m.end).trimLeft();
      if (tail.isNotEmpty && '-–—'.contains(tail[0])) {
        final prefixWords = searchable
            .substring(0, m.start)
            .replaceAll(RegExp(r'[\[【][^\]】]*[\]】]|\([^)]*\)'), ' ')
            .trim();
        if (prefixWords.isNotEmpty) {
          if (rawDigits.length == 1 && !rawDigits.startsWith('0')) continue;
          if (explicitCheck && !rawDigits.startsWith('0')) continue;
        } else if (explicitCheck && !rawDigits.startsWith('0')) {
          continue;
        }
      }
      final value = _number(rawDigits);
      if (value != null && (!explicitCheck || !_technicalNumber(value))) {
        return value;
      }
    }
    return null;
  }

  static bool _isFractionalEpisode(String name) =>
      RegExp(r'(?:^|[\[(_【\s])\d{1,3}\.\d(?=[\])）._\s]|$)').hasMatch(name);

  static bool _isMovieContext(String directory, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    return RegExp(
      r'电影|剧场版|劇場版|映画|movie|film|gekijouban|'
      r'the[\s._-]*final|活動写真|活动写真|終局特異点|终局特异点|'
      r'[\[(（]\s*m\d{1,2}\s*[\]）)]|'
      r'main[\s._-]*(?:movie|feature)?',
      caseSensitive: false,
    ).hasMatch('$directory/$stem');
  }

  static bool _isYearVariantFeature(
    String directory,
    String name,
    int? videoCount,
    int? numberedVideoCount,
  ) {
    if ((videoCount ?? 0) < 2) return false;
    final stem = name.replaceFirst(
      KonataMediaExtensions.trailingVideoExtensionRegex,
      '',
    );
    final nameYears = RegExp(
      r'(?<![\dx])(?:19|20)\d{2}(?![\dx])',
    ).allMatches(stem).map((match) => match.group(0)!).toSet();
    final directoryYears = RegExp(
      r'(?<![\dx])(?:19|20)\d{2}(?![\dx])',
    ).allMatches(directory).map((match) => match.group(0)!).toSet();
    return nameYears.isNotEmpty && directoryYears.isNotEmpty;
  }

  static int? _episodeFromBrackets(String name, {bool completeOnly = true}) {
    for (final bracket in RegExp(r'[\[【]([^\]】]+)[\]】]').allMatches(name)) {
      final content = bracket.group(1)!.trim();
      if (content.isEmpty ||
          RegExp(
            r'^(?:\d{3,4}p|[248]k|[xh][ ._-]?26[45]|hevc|avc|av1|ma10p|main12|'
            r'yuv444p10|flac|alac|aac|opus|ac3|eac3|dts|dtshd|truehd|10bit|'
            r'hi10p|web|bd|dvd|ldrip|hdtv)',
            caseSensitive: false,
          ).hasMatch(content)) {
        continue;
      }
      final suffix = completeOnly
          ? r'(?=\s*(?:$|[-–—&~]\s*\d|\([^)]*\)\s*$)|\s+(?:Ma\d+p|\d{3,4}p|BDRip|WEB|HEVC|AVC|[xh][ ._-]?26[45])(?=$|[^a-z0-9]))'
          : r'(?![a-z0-9])';
      final match = RegExp(
        r'^(?:(?:movie|tv|episode|ep|part|act|final[ ._-]*act|chapter|'
        r'record|vol(?:ume)?|disc)[ ._-]*)?(\d{1,4})(?:v\d+)?'
        '(?:[ ._-]*(?:end|fin|final))?$suffix',
        caseSensitive: false,
      ).firstMatch(content);
      var group = 1;
      var entryMatch = match;
      if (!completeOnly &&
          entryMatch == null &&
          RegExp(r'[\u3400-\u9fff]').hasMatch(content) &&
          content.length <= 40) {
        entryMatch = RegExp(r'(\d{1,4})\s*$').firstMatch(content);
        group = 1;
      }
      final number = _number(entryMatch?.group(group));
      if (number != null && !_technicalNumber(number)) return number;
    }
    // 优先采纳任意位置出现的完整规范集号证据，其次才回退历史注解格式。
    return completeOnly
        ? _episodeFromBrackets(name, completeOnly: false)
        : null;
  }

  static int? _looseEpisodeNumber(String name) {
    final stem = name.replaceFirst(
      KonataMediaExtensions.trailingVideoExtensionRegex,
      '',
    );
    if (RegExp(r'^\s*\d+\s*[/／]\d+\s*$').hasMatch(stem)) return null;
    final candidates = <int>[];
    for (final match in RegExp(
      r'(?<![a-z0-9])(\d{1,4})(?:v\d+)?(?![a-z0-9])',
      caseSensitive: false,
    ).allMatches(name)) {
      final value = _number(match.group(1));
      if (value == null || _technicalNumber(value)) continue;
      if (match.start > 0 && '/／'.contains(name[match.start - 1])) {
        continue;
      }
      if (match.start >= 2 &&
          name[match.start - 1] == '.' &&
          name.codeUnitAt(match.start - 2) >= 48 &&
          name.codeUnitAt(match.start - 2) <= 57) {
        continue;
      }
      if (match.end + 1 < name.length &&
          name[match.end] == '.' &&
          name.codeUnitAt(match.end + 1) >= 48 &&
          name.codeUnitAt(match.end + 1) <= 57) {
        continue;
      }
      final tail = name.substring(match.end);
      if (_looseTailEpisodeRegex.hasMatch(tail)) {
        candidates.add(value);
      }
    }
    return candidates.isEmpty ? null : candidates.last;
  }

  static bool _technicalNumber(int value) =>
      value >= 1800 && value <= 2200 ||
      const {
        240,
        360,
        480,
        540,
        576,
        720,
        848,
        960,
        1080,
        1280,
        1440,
        1920,
        2160,
        3840,
        4096,
      }.contains(value);

  static int? _number(String? raw, {bool rejectYears = true}) {
    if (raw == null || raw.isEmpty) return null;
    final arabic = int.tryParse(raw);
    final value = arabic ?? _localizedNumber(raw);
    if (value == null || value < 0) return null;
    if (rejectYears && value >= 1800 && value <= 2200) return null;
    return value;
  }

  static int? _localizedNumber(String raw) {
    const digits = <String, int>{
      '〇': 0,
      '零': 0,
      '一': 1,
      '壱': 1,
      '二': 2,
      '弐': 2,
      '三': 3,
      '参': 3,
      '四': 4,
      '五': 5,
      '伍': 5,
      '六': 6,
      '七': 7,
      '八': 8,
      '九': 9,
      '十': 10,
      '拾': 10,
      '百': 100,
    };
    if (raw.isEmpty) return null;
    var total = 0;
    var current = 0;
    for (final character in raw.split('')) {
      final value = digits[character];
      if (value == null) return null;
      if (value == 10 || value == 100) {
        total += (current == 0 ? 1 : current) * value;
        current = 0;
      } else {
        current = value;
      }
    }
    return total + current;
  }

  static String _normalizeName(String name) => name
      .replaceAllMapped(
        RegExp('[０-９]'),
        (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
      )
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('［', '[')
      .replaceAll('］', ']')
      .replaceAll('：', ':');

  static String _withoutSeasonAndPartMarkers(String name) => name.replaceAll(
    RegExp(
      r'(?<![a-z0-9])s\d{1,2}(?![a-z0-9])|'
      r'(?<![a-z0-9])season[ ._]*\d{1,2}(?![a-z0-9])|'
      r'\d{1,2}(?:st|nd|rd|th)[ ._-]*season|'
      r'第[ ._-]*[0-9一二三四五六七八九十百]+[ ._-]*[季期]|'
      r'(?<![a-z0-9])part[ ._-]*\d{1,2}(?![a-z0-9])|'
      r'(?<![a-z0-9])\d{1,3}[ ._-]*sai(?![a-z0-9])|'
      r'(?<!\d)\d{1,3}\s*(?:歳|岁|周年)(?!\d)|'
      r'(?<![a-z0-9])\d{1,3}[ ._-]*bit(?![a-z0-9])|'
      r'(?<![a-z0-9])[xh][ ._-]?26[45](?![a-z0-9])',
      caseSensitive: false,
    ),
    ' ',
  );
}
