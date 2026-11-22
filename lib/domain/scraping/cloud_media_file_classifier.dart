import '../models/media_extensions.dart';

/// 扫描器与重整校准共用的保守文件名/目录分类器；
/// 外部刮削源 ID 为可选项，始终以本地媒体语义判定为先。
abstract final class CloudMediaFileClassifier {
  static final _supplementaryDirectory = RegExp(
    r'^(?:sp|sps|special|specials|extra|extras|bonus|nc|ncop|nced|pv|cm|'
    r'menu|menus|music|music[\s._-]*videos?|mvs?|samples?|(?:eizou[\s._-]+)?tokuten|creditless|textless|interviews?|events?|making|'
    r'trailers?|previews?|promos?|promotion|tv[\s._-]*spots?|tvcm|bdcm|'
    r'effects?|fan[\s._-]*disc|fandisc|privilege[\s._-]*dis[ck]|.*pvd.*|reviews?|'
    r'logo|logos|voices?|cds|ost|soundtrack|gallery|artwork|特典|映像特典|'
    r'特典映像|花絮|幕后|访谈|预告|預告|宣传|聲優|声优|'
    r'tv[\s._-]*スポット|プロモーション映像|(?:ミュージック|ミコージック)[・·\s._-]*クリップ|'
    r'劇場アナウンス|アナウンス|ピクチャードラマ|スペシャル映像|'
    r'(?:op|ed)(?:[\s._&-]*(?:op|ed))*)$',
    caseSensitive: false,
  );

  static final _preview = RegExp(
    r'予告|預告|预告|(^|[^a-z])(trailer|teaser|preview|forecast)(?=[^a-z]|$)',
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
    r'帰ってきた[^\r\n]*甲子園|beginning[\s._-]+of[\s._-]+|'
    r'ピクチャードラマ|picture[\s._-]*drama|スペシャル[\s._-]*映像|未公開(?:映像)?|'
    r'bd[\s._-]*sp[\s._-]*live\w*|sp[\s._-]*live\w*|'
    r'bd[\s._-]*special[\s._-]*talk|special[\s._-]*talk|'
    r'greeting[\s._-]*event|stage[\s._-]*events?|premiere[\s._-]*event|'
    r'cv[\s._-]*chat|japan[\s._-]*expo|memorial[\s._-]*movie|'
    r'weekly[\s._-]*movies?|weekly[\s._-]*hero[\s._-]*countdown|shinka[\s._-]*scene|'
    r'撮りおろし[^\r\n]*インタビュー|先付けミニアニメ|ミニアニメ|'
    r'tokuten(?:[\s._-]*dvd)?|(?<![a-z0-9])(?:menue\d*|hauptmenue|vorschau)(?![a-z0-9])',
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
    r'\s+('
    '${KonataMediaExtensions.videoExtensionSuffixPattern}'
    r')',
    caseSensitive: false,
  );

  static final RegExp _adjacentLocalizedEpisodeRegex = RegExp(
    r'[^\x00-\x7f]\s*(\d{1,4})'
    r'(?=\s*(?:[\[(（]|'
    '${KonataMediaExtensions.videoExtensionSuffixPattern}'
    r'|$))',
    caseSensitive: false,
  );

  static final RegExp _leadingEpisodeRegex = RegExp(
    r'^[ ._-]*(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
    r'(?=\s*(?:'
    '${KonataMediaExtensions.videoExtensionSuffixPattern}'
    r'|[-–—_]))',
    caseSensitive: false,
  );

  static final RegExp _looseTailEpisodeRegex = RegExp(
    r'^\s*[._-]*\s*(?:[\[(（【]|'
    '${KonataMediaExtensions.videoExtensionSuffixPattern}'
    r'|'
    r'(?:\d{3,4}p|bd|web|dvd|ld|tv|hdtv|hevc|avc|[xh][ ._-]?26[45]|flac|aac|'
    r'opus|ac3|eac3|dts|dtshd|truehd|alac|end|fin|final|premiere|'
    r'early[\s._-]*screening|screening)\b)',
    caseSensitive: false,
  );

  static final _crc32Bracket = RegExp(r'[\[(（【［]\s*[0-9a-fA-F]{8}\s*[\])）】］]');

  static final _frameRateMarker = RegExp(
    r'(?<![a-z0-9.])\d+(?:\.\d+)?\s*fps(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _standaloneResolution = RegExp(
    r'(?<![a-z0-9])\d{3,4}x\d{3,4}[pi]?(?![a-z0-9])',
    caseSensitive: false,
  );

  static final _bracketBlock = RegExp(r'[\[(（【［]([^\]\)）】］]*)[\])）】］]');

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
    '${KonataMediaExtensions.sourceTagAlternation}|'
    r'blu|ray|fhd|hd|sd|raw|raws|hdr|sdr|dv|nvenc|rip|dl|'
    r'\d*x?(?:flac|aac|opus|ac3|eac3|ec3|ddp?|dd|dts|dtshd|hdma|ma|truehd|'
    r'lpcm|pcm|mp3|vorbis|alac|atmos|wv|wavpack)(?:x?\d+(?:\.\d+)?)?|'
    r'audio|dual|multi|lossless|\d+(?:\.\d+)?ch(?:x\d+)?|(?:2\.0|5\.1|7\.1)(?:x\d+)?|'
    r'chs|cht|chi|zh|cn|jp|jpn|jap|en|eng|sub|subs|softsub|hardsub|'
    r'gb|big5|(?:ass|ssa|srt|pgs|sup|idx)(?:x\d+)?|vobsub|'
    '${KonataMediaExtensions.videoExtensionAlternation}|'
    r'v\d+|[0-9a-f]{8}'
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
        .replaceAll(_reHot1, ' ')
        .replaceAllMapped(_trailingSpacedVideoExtension, (m) => m.group(1)!)
        .trim();
  }

  static bool _isTechnicalBracketContent(String content) {
    final normalized = _normalizeName(content).trim();
    if (normalized.isEmpty) return true;
    final rawTokens = normalized
        .split(_reHot2)
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
    r'映像|本編制作|おまけ|オマケ|[\[(（【]\s*live\s*[\])）】]',
    caseSensitive: false,
  );

  static final _opEdExtra = RegExp(
    r'[\[(【（]\s*(?<![a-z0-9])(?:nc(?:oped|op|ed)|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])\s*[\])】）]|'
    r'(?<![a-z0-9])nc(?:oped|op|ed)(?:[ ._-]*v?\d{1,2})?(?![a-z0-9])|'
    r'(?<![a-z0-9])(?:op|ed)(?:v?\d{1,2})?(?![a-z0-9])'
    '(?=[_\\s]*(?:[\\[(（【]|$_videoExtensionSuffix|\$))|'
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

  /// 判断已剥离技术噪音的 [cleanName] 是否包含严格的独立 `OP/ED` 特典词元。
  static bool isOpEdExtraClean(String cleanName) =>
      _opEdExtra.hasMatch(cleanName);

  /// 判断 [name] 是否包含严格的独立 `OP/ED` 特典词元（校验字母数字边界）。
  static bool isOpEdExtra(String name) =>
      _opEdExtra.hasMatch(stripTechnicalNoise(name));

  /// 判断视频是否携带强特典标记（如无字幕主题曲、预告、宣传片、菜单、预览及特典目录），
  /// 以区分仅带弱备注标识（如特别篇、总集篇）的正片文件。
  static bool isStrongSupplementary(String directory, String name) {
    if (isSupplementarySubdirectory(directory)) return true;
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

  /// 对已剥离技术噪音的 [cleanName] 执行预告词判定，避免重复剥离。
  static bool isPreviewClean(String cleanName) => _preview.hasMatch(cleanName);

  static bool isPreview(String name) =>
      _preview.hasMatch(stripTechnicalNoise(name));

  /// 对已剥离技术噪音的 [cleanName] 执行无字幕主题曲判定，避免重复剥离。
  static bool isNoCreditClean(String cleanName) =>
      _noCredit.hasMatch(cleanName);

  static bool isNoCredit(String name) =>
      _noCredit.hasMatch(stripTechnicalNoise(name));

  /// 在调用方已验证目录非特典目录且 `isPreviewClean`/`isNoCreditClean`/`isOpEdExtraClean` 均为假时，
  /// 检查剩余附属内容特征（与 [isClearlySupplementary] 在该分支下语义完全等价）。
  static bool isOtherSupplementaryClean(String cleanName) =>
      _releaseSample.hasMatch(cleanName) ||
      _supplementaryTag.hasMatch(cleanName) ||
      adjacentBracketExtra.hasMatch(cleanName) ||
      bundledExtraTag.hasMatch(cleanName) ||
      _discAppendix.hasMatch(cleanName) ||
      _supplementaryName.hasMatch(cleanName) ||
      _isFractionalEpisode(cleanName);

  /// 判断单个视频无需参考目录内其余文件计数即可确认为附属内容，
  /// 扫描器据此从含预告/菜单/活动视频的目录中筛选出唯一无编号正片候选。
  /// 保障单剧场版或单卷 OVA 目录的主正片稳定识别。
  static bool isClearlySupplementary(String directory, String name) {
    if (isSupplementarySubdirectory(directory)) return true;
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

  /// 判断作品根目录之下的相对子目录路径是否属于特典目录；
  /// 在 [isSupplementaryDirectory] 基础上按词元识别 `NC Ver`、`BD Menu`、`PV&CM`、`Bonus DVD`，
  /// 以及 `<作品名> 映像特典`、`[组名] XX Extras` 这类以强特典词收尾的目录。
  static bool isSupplementarySubdirectory(String relativeDirectory) {
    return relativeDirectory
        .replaceAll('\\', '/')
        .split('/')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .any((s) {
          if (_supplementaryDirectory.hasMatch(s) ||
              isExtraVideoDirectoryName(s)) {
            return true;
          }
          // 兼容全方括号发布子目录以 `[Extra]`、`[SP Live]`、`[Bonus]` 等特典标签收尾的命名。
          final trailingBracket = _trailingExtraBracket.firstMatch(s);
          if (trailingBracket != null) {
            final inner = trailingBracket.group(1)!.trim();
            if (inner.isNotEmpty && isExtraVideoDirectoryName(inner)) {
              return true;
            }
          }
          final tokens = _extraDirTokens(s);
          return tokens.isNotEmpty && _extraDirTailToken.hasMatch(tokens.last);
        });
  }

  static final _trailingExtraBracket = RegExp(
    r'[\[(（【]([^\[\]()（）【】]+)[\])）】]\s*$',
  );

  /// 特典视频目录核心词：目录名去除组名/卷号括号后，全部词元均为核心词或修饰词且至少含一个核心词时判定为特典目录。
  static final _extraDirCoreToken = RegExp(
    r'^(?:sps?|specials?|extras?|exrtras|bonus(?:es)?|omake|tokuten|'
    r'nc(?:op|ed|oped)?s?|opeds?|creditless|textless|noncredit|'
    r'pvs?|cms?|pvcms?|cmpvs?|menus?|mvs?|trailers?|teasers?|previews?|'
    r'promos?|promotion|spots?|tvcms?|bdcms?|effects?|fandisc|reviews?|'
    r'interviews?|events?|making|digest|recaps?|commentary|radio|comics?|'
    r'storyboards?|endcards?|eyecatch(?:es)?|lives?|credits?|samples?|cds|'
    r'スポット|プロモーション映像|プロモーション|ミュージック|ミコージック|'
    r'クリップ|アナウンス|劇場アナウンス|ピクチャードラマ|スペシャル映像|'
    r'特典|映像特典|特典映像|特典卷|花絮|幕后|访谈|预告|預告|宣传|番外|映像)$',
  );

  /// 特典视频目录修饰词：只能与核心词同现，单独出现不构成特典目录。
  static final _extraDirModifierToken = RegExp(
    r'^(?:bd|dvd|web|tv|ver|version|non|visual|music|video|next|episode|'
    r'videos|clip|clips|fan|dis[ck]|voice|and|the|of|op|ed|vol|volume|'
    r'collection|all|cds?\d{0,2}|\d{1,3}|v\d{1,2}|s\d{1,2}|ep?\d{1,3}|\d{3,4}p)$',
  );

  /// 允许以「作品名 + 特典词」形式收尾的强特典词（仅用于作品根目录之下的子目录）。
  static final _extraDirTailToken = RegExp(
    r'^(?:特典|映像特典|特典映像|extras|specials|sps|bonus)$',
  );

  static final _extraDirEdgeBracket = RegExp(
    r'^\s*[\[【][^\]】]*[\]】]\s*|\s*[\[(（【][^\])）】]*[\])）】]\s*$',
  );

  static List<String> _extraDirTokens(String segment) {
    var s = segment.trim();
    while (true) {
      final next = s.replaceFirst(_extraDirEdgeBracket, '').trim();
      if (next == s || next.isEmpty) break;
      s = next;
    }
    return s
        .toLowerCase()
        .split(_reHot3)
        .where((t) => t.isNotEmpty)
        .toList(growable: false);
  }

  /// 依据词元判断单个目录段是否为特典视频目录（如 `NC Ver`、`BD Menu`、`PV&CM`、`Creditless OPEDs`、`Bonus DVD`）。
  static bool isExtraVideoDirectoryName(String segment) {
    final tokens = _extraDirTokens(segment);
    if (tokens.isEmpty) return false;
    var hasCore = false;
    for (final token in tokens) {
      if (_extraDirCoreToken.hasMatch(token)) {
        hasCore = true;
      } else if (!_extraDirModifierToken.hasMatch(token)) {
        return false;
      }
    }
    return hasCore;
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
    if (_reHot4.hasMatch(name)) {
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
        .where((segment) => !_reHot5.hasMatch(segment.trim()))
        .join('/');
    final directoryNumbers = _reHot6
        .allMatches(meaningfulDirectory)
        .map((match) => int.tryParse(match.group(1)!))
        .whereType<int>()
        .toSet();
    if (!directoryNumbers.contains(episodeNumber)) return false;
    final nameNumbers = _reHot7
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
    final episodeNumber = _parseEpisode(cleanName, alreadyClean: true)?.start;
    if (episodeNumber == null ||
        _hasExplicitEpisodeMarker(cleanName, alreadyClean: true) ||
        !_looksLikeTitleNumber(directory, cleanName, episodeNumber)) {
      return episodeNumber;
    }
    return null;
  }

  /// 单次解析同时得到 [episodeNumberFromNameInDirectory] 的起始集号与同源的区间结束集号。
  ///
  /// 仅当产生起始集号的那个记号后紧跟 `-`、`~`、`～`、`&`、`＆` 加结束集
  /// （结束集可带 `E`/`EP` 前缀）时才给出结束集，且要求结束集大于起始集、跨度不超过
  /// [maxEpisodeRangeSpan] 集；带特典标识的文件名不给出结束集。该结束集只对正片槽位有意义。
  static ({int? start, int? end}) episodeSpanFromNameInDirectory(
    String directory,
    String name,
  ) =>
      episodeSpanFromCleanNameInDirectory(directory, stripTechnicalNoise(name));

  /// 对已剥离技术噪音的文件名执行目录级集号区间解析，避免热路径重复调用 [stripTechnicalNoise]。
  static ({int? start, int? end}) episodeSpanFromCleanNameInDirectory(
    String directory,
    String cleanName,
  ) {
    final parsed = _parseEpisode(cleanName, alreadyClean: true);
    if (parsed == null) return (start: null, end: null);
    if (!_hasExplicitEpisodeMarker(cleanName, alreadyClean: true) &&
        _looksLikeTitleNumber(directory, cleanName, parsed.start)) {
      return (start: null, end: null);
    }
    final end = parsed.end == null || _rangeExtraHint.hasMatch(cleanName)
        ? null
        : parsed.end;
    return (start: parsed.start, end: end);
  }

  /// 单次解析同时得到 [episodeNumberFromName] 的起始集号与同源区间结束集号（不含目录级标题数字抑制）。
  static ({int? start, int? end}) episodeSpanFromName(String name) {
    final parsed = _parseEpisode(name);
    if (parsed == null) return (start: null, end: null);
    final end = parsed.end == null || _rangeExtraHint.hasMatch(name)
        ? null
        : parsed.end;
    return (start: parsed.start, end: end);
  }

  /// 带有特典/附属映像标识的文件名：其区间（`NCOP EP01-08`、`Picture Drama 10-13` 等）不是正片合并。
  static final RegExp _rangeExtraHint = RegExp(
    r'(?<![a-z0-9])(?:ncop|nced|pv|cm|sp|ova|oad|menu|digest|special|extras?|'
    r'bonus|trailer|teaser|preview|creditless|textless|making|interview|'
    r'picture[ ._-]*drama|drama[ ._-]*cd)(?![a-z])',
    caseSensitive: false,
  );

  /// 单个文件允许的最大连续集数（结束集 - 起始集 + 1）。
  static const int maxEpisodeRangeSpan = 30;

  /// 紧随起始集号之后的区间尾部：分隔符 + 可带 `E`/`EP` 前缀的结束集。
  /// 不允许分隔符两侧出现空白，避免把 `Title 2 - 12` 之类片名数字当成区间。
  static final RegExp _rangeTailRegex = RegExp(
    r'^(?:v\d+)?[-–—~～&＆+＋](?:e(?:p(?:isode)?)?[ ._-]*)?(\d{1,4})(?:v\d+)?'
    r'(?![a-z0-9])(?!\.\d{1,2}(?!\d|[pi]\b))(?![-–—~～&＆+＋]\d)',
    caseSensitive: false,
  );

  /// `S01E01E02` 这类无分隔符的连写区间尾部。
  static final RegExp _rangeTailBareERegex = RegExp(
    r'^(?:v\d+)?e(?:p)?[ ._-]*(\d{1,4})(?:v\d+)?'
    r'(?![a-z0-9])(?!\.\d{1,2}(?!\d|[pi]\b))',
    caseSensitive: false,
  );

  /// `第01-02话`、`第1话-第2话` 这类本地化区间。
  static final RegExp _localizedRangeRegex = RegExp(
    r'第[ ._-]*([0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)[ ._-]*'
    r'(?:话|話|集|回)?[ ._-]*[-~～&＆+＋][ ._-]*第?[ ._-]*'
    r'([0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)[ ._-]*(?:话|話|集|回)',
  );

  static int? _validRangeEnd(int start, int? end) {
    if (end == null || end <= start) return null;
    if (end - start + 1 > maxEpisodeRangeSpan) return null;
    if (_technicalNumber(end)) return null;
    return end;
  }

  /// 从 [text] 的 [position] 起读取紧邻的区间结束集号。
  static int? _rangeEndAfter(
    String text,
    int position,
    int start, {
    bool allowBareE = false,
  }) {
    final tail = text.substring(position);
    var match = _rangeTailRegex.firstMatch(tail);
    if (match == null && allowBareE) {
      match = _rangeTailBareERegex.firstMatch(tail);
    }
    return _validRangeEnd(start, _number(match?.group(1)));
  }

  static final RegExp _explicitRangeMarkerRegex = RegExp(
    r'(?:^|[\s\]】)])\s*\d{1,4}'
    r'(?:[-–—]\d{1,4}|\s*[&~]\s*\d{1,4})'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
    caseSensitive: false,
  );

  static final RegExp _rangeSpanMarkerRegex = RegExp(
    r'(?:^|[\s\]】)])\s*(\d{1,4})'
    r'(?:[-–—~～+＋](\d{1,4})|\s*[&＆~～]\s*(\d{1,4}))'
    '(?=\\s*(?:[\\[(（【]|$_videoExtensionSuffix|\$))',
    caseSensitive: false,
  );

  static final RegExp _postMarkerSpacedDashRegex = RegExp(
    r'(?:^|\s|[\]】)])[-–—]\s+(\d{1,4})(?:v\d+)?(?![a-z0-9.])'
    r'(?=\s+(?!(?:days?|hours?|minutes?|mins?|seconds?|secs?|years?|'
    r'months?|weeks?|meters?|km|miles?|st|nd|rd|th)\b)\S|'
    '\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
    caseSensitive: false,
  );

  static final RegExp _postMarkerSeparatedRegex = RegExp(
    r'(?:^|[\s\]】)])(?:\d*\s*[-–—_]|(?<!\d)\.)\s*(?!\d{3,4}[pi](?![a-z0-9]))'
    r'(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
    '(?=\\s*(?:[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|完|\$))',
    caseSensitive: false,
  );

  static final RegExp _postMarkerTrailingRegex = RegExp(
    r'(?:^|[\s\]】)])\s*(\d{1,4})(?!\.\d)(?:[ ._-]*[a-z])?'
    '(?=\\s*(?:[-–—_]|\\.(?!\\d)|[\\[(（【「]|$_videoExtensionSuffix|v\\d+\\b|end\\b|fin\\b|final\\b|'
    r'(?:tv|theatre|theater|encore|uncensored|nc)[ ._-]*ver|完|$))',
    caseSensitive: false,
  );

  static final RegExp _bracketEpCompleteRegex = RegExp(
    r'^(?:(?:movie|tv|episode|ep|part|act|final[ ._-]*act|chapter|'
    r'record|vol(?:ume)?|disc)[ ._-]*)?(\d{1,4})(?:v\d+)?'
    r'(?:[ ._-]*(?:end|fin|final))?'
    r'(?=\s*(?:$|[-–—&~+＋]\s*\d|\([^)]*\)\s*$)|\s+(?:Ma\d+p|\d{3,4}p|BDRip|WEB|HEVC|AVC|[xh][ ._-]?26[45])(?=$|[^a-z0-9]))',
    caseSensitive: false,
  );

  static final RegExp _bracketEpLooseRegex = RegExp(
    r'^(?:(?:movie|tv|episode|ep|part|act|final[ ._-]*act|chapter|'
    r'record|vol(?:ume)?|disc)[ ._-]*)?(\d{1,4})(?:v\d+)?'
    r'(?:[ ._-]*(?:end|fin|final))?(?![a-z0-9])',
    caseSensitive: false,
  );

  /// 即使作品标题本身含有相同数字，显式集号标识依然具有最高权威性；
  /// 标题数字抑制策略仅作用于宽松兜底数字提取路径。
  static bool _hasExplicitEpisodeMarker(
    String name, {
    bool alreadyClean = false,
  }) {
    final searchable = _withoutSeasonAndPartMarkers(
      _normalizeName(alreadyClean ? name : stripTechnicalNoise(name)),
    );
    if (_reHot8.hasMatch(searchable)) {
      return true;
    }
    if (_reHot9.hasMatch(searchable)) {
      return true;
    }
    if (_reHot10.hasMatch(searchable)) {
      return true;
    }
    if (_reHot11.hasMatch(searchable)) {
      return true;
    }
    if (_reHot12.hasMatch(searchable)) {
      return true;
    }
    if (_localizedRangeRegex.hasMatch(searchable)) return true;
    if (_reHot13.hasMatch(searchable)) {
      return true;
    }
    if (_reHot14.hasMatch(searchable)) {
      return true;
    }
    if (_episodeFromBrackets(searchable) != null) return true;
    if (delimitedEpisode.hasMatch(searchable)) return true;
    if (_explicitRangeMarkerRegex.hasMatch(searchable)) {
      return true;
    }
    return _extractPostMarkerEpisode(searchable, explicitCheck: true) != null;
  }

  /// 提取文件名所代表的首个集号；多集连播文件名（如 `01-04`、`003&004`）
  /// 默认映射至起始集号，完整原始文件名仍由目录索引保留用于播放与展示。
  /// 确保连续合集文件具备唯一稳定的排序主键。
  static int? episodeNumberFromName(String name) => _parseEpisode(name)?.start;

  /// 解析起始集号及紧邻其后的区间结束集号；起始集号的判定顺序与历史行为完全一致。
  static ({int start, int? end})? _parseEpisode(
    String name, {
    bool alreadyClean = false,
  }) {
    final normalized = _normalizeName(
      alreadyClean ? name : stripTechnicalNoise(name),
    );
    final normalizedStem = normalized.replaceFirst(
      KonataMediaExtensions.trailingVideoExtensionRegex,
      '',
    );
    if (_reHot15.hasMatch(normalizedStem)) {
      return null;
    }
    final searchable = _withoutSeasonAndPartMarkers(
      normalized,
    ).replaceAll(_reHot16, ' ');

    var match = _reHot17.firstMatch(searchable);
    final seasonEpisode = _number(match?.group(1));
    if (seasonEpisode != null) {
      return (
        start: seasonEpisode,
        end: _rangeEndAfter(
          searchable,
          match!.end,
          seasonEpisode,
          allowBareE: true,
        ),
      );
    }

    match = _reHot18.firstMatch(searchable);
    final explicitEpisode = _number(match?.group(1));
    if (explicitEpisode != null) {
      return (
        start: explicitEpisode,
        end: _rangeEndAfter(searchable, match!.end, explicitEpisode),
      );
    }

    match = _reHot19.firstMatch(searchable);
    final shortEpisode = _number(match?.group(1));
    if (shortEpisode != null) {
      return (
        start: shortEpisode,
        end: _rangeEndAfter(searchable, match!.end, shortEpisode),
      );
    }

    match = _reHot20.firstMatch(searchable);
    final stage = _number(match?.group(1));
    if (stage != null) return (start: stage, end: null);

    match = _reHot21.firstMatch(searchable);
    final datedEpisode = _number(match?.group(1));
    if (datedEpisode != null) return (start: datedEpisode, end: null);

    match = _localizedRangeRegex.firstMatch(searchable);
    final localizedStart = _number(match?.group(1));
    if (localizedStart != null) {
      return (
        start: localizedStart,
        end: _validRangeEnd(localizedStart, _number(match!.group(2))),
      );
    }

    match = _reHot22.firstMatch(searchable);
    final localized = _number(match?.group(1));
    if (localized != null) return (start: localized, end: null);

    match = _reHot23.firstMatch(searchable);
    final hash = _number(match?.group(1));
    if (hash != null) {
      return (start: hash, end: _rangeEndAfter(searchable, match!.end, hash));
    }

    final bracketed = _episodeFromBracketsWithEnd(searchable);
    if (bracketed != null) return bracketed;

    final delimited = _number(
      delimitedEpisode.firstMatch(searchable)?.group(1),
    );
    if (delimited != null) return (start: delimited, end: null);

    match = _rangeSpanMarkerRegex.firstMatch(searchable);
    final rangeStart = _number(match?.group(1));
    if (rangeStart != null) {
      return (
        start: rangeStart,
        end: _validRangeEnd(
          rangeStart,
          _number(match!.group(2) ?? match.group(3)),
        ),
      );
    }

    final postMarker = _extractPostMarkerEpisode(searchable);
    if (postMarker != null) return (start: postMarker, end: null);

    match = _reHot24.firstMatch(searchable);
    final parenthesized = _number(match?.group(1));
    if (parenthesized != null) return (start: parenthesized, end: null);

    match = _adjacentLocalizedEpisodeRegex.firstMatch(searchable);
    final adjacentLocalized = _number(match?.group(1));
    if (adjacentLocalized != null) {
      return (start: adjacentLocalized, end: null);
    }

    match = _leadingEpisodeRegex.firstMatch(searchable);
    final leading = _number(match?.group(1));
    if (leading != null) return (start: leading, end: null);
    final loose = _looseEpisodeNumber(searchable);
    return loose == null ? null : (start: loose, end: null);
  }

  static int? _extractPostMarkerEpisode(
    String searchable, {
    bool explicitCheck = false,
  }) {
    // 位于副标题或方括号标签前方的显式分隔符集号具备最高优先级，
    // 优先于作品续作数字（例如 `Eizou Hakusho II - 01 Yusuke`）。
    for (final m in _postMarkerSpacedDashRegex.allMatches(searchable)) {
      final value = _number(m.group(1));
      if (value != null && !_technicalNumber(value)) return value;
    }

    final separatedMatch = _postMarkerSeparatedRegex.firstMatch(searchable);
    final separated = _number(separatedMatch?.group(1), rejectYears: false);
    if (separated != null) return separated;

    for (final m in _postMarkerTrailingRegex.allMatches(searchable)) {
      final rawDigits = m.group(1)!;
      final tail = searchable.substring(m.end).trimLeft();
      if (tail.isNotEmpty && '-–—'.contains(tail[0])) {
        final prefixWords = searchable
            .substring(0, m.start)
            .replaceAll(_reHot25, ' ')
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

  static bool _isFractionalEpisode(String name) => _reHot26.hasMatch(name);

  static bool _isMovieContext(String directory, String name) {
    final dot = name.lastIndexOf('.');
    final stem = dot < 0 ? name : name.substring(0, dot);
    return _reHot27.hasMatch('$directory/$stem');
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
    final nameYears = _reHot28
        .allMatches(stem)
        .map((match) => match.group(0)!)
        .toSet();
    final directoryYears = _reHot28
        .allMatches(directory)
        .map((match) => match.group(0)!)
        .toSet();
    return nameYears.isNotEmpty && directoryYears.isNotEmpty;
  }

  static int? _episodeFromBrackets(String name, {bool completeOnly = true}) =>
      _episodeFromBracketsWithEnd(name, completeOnly: completeOnly)?.start;

  static ({int start, int? end})? _episodeFromBracketsWithEnd(
    String name, {
    bool completeOnly = true,
  }) {
    for (final bracket in _reHot29.allMatches(name)) {
      final content = bracket.group(1)!.trim();
      // `[BD_01]`/`[BD 12]` 这类两位以上补零编号是蓝光正片集号，不能被 `bd` 技术词前缀跳过（单个数字的 `BD1` 仍视作碟号）。
      final bdEpisode = _reHot30.firstMatch(content);
      if (bdEpisode != null) {
        final number = _number(bdEpisode.group(1));
        if (number != null && !_technicalNumber(number)) {
          return (start: number, end: null);
        }
      }
      if (content.isEmpty || _reHot31.hasMatch(content)) {
        continue;
      }
      final match =
          (completeOnly ? _bracketEpCompleteRegex : _bracketEpLooseRegex)
              .firstMatch(content);
      var group = 1;
      var entryMatch = match;
      if (!completeOnly &&
          entryMatch == null &&
          _reHot32.hasMatch(content) &&
          content.length <= 40) {
        entryMatch = _reHot33.firstMatch(content);
        group = 1;
      }
      final number = _number(entryMatch?.group(group));
      if (number != null && !_technicalNumber(number)) {
        int? end;
        // 仅允许无前缀或 ep/episode 前缀的括号内区间，如 `[01-02]`、`[EP01-12]`；
        // `[Disc 1-2]`、`[Vol.1-3]` 等不视为集数区间。
        final prefix = _reHot34.firstMatch(content)!.group(1)!.toLowerCase();
        if (match != null &&
            identical(entryMatch, match) &&
            (prefix.isEmpty || prefix == 'ep' || prefix == 'episode')) {
          final tail = content.substring(match.end).trimRight();
          final tailMatch = _reHot35.firstMatch(tail);
          end = _validRangeEnd(number, _number(tailMatch?.group(1)));
        }
        return (start: number, end: end);
      }
    }
    // 优先采纳任意位置出现的完整规范集号证据，其次才回退历史注解格式。
    return completeOnly
        ? _episodeFromBracketsWithEnd(name, completeOnly: false)
        : null;
  }

  static int? _looseEpisodeNumber(String name) {
    final stem = name.replaceFirst(
      KonataMediaExtensions.trailingVideoExtensionRegex,
      '',
    );
    if (_reHot36.hasMatch(stem)) return null;
    final candidates = <int>[];
    for (final match in _reHot37.allMatches(name)) {
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
        _reHot38,
        (match) => String.fromCharCode(match.group(0)!.codeUnitAt(0) - 0xfee0),
      )
      .replaceAll('（', '(')
      .replaceAll('）', ')')
      .replaceAll('［', '[')
      .replaceAll('］', ']')
      .replaceAll('：', ':');

  static String _withoutSeasonAndPartMarkers(String name) =>
      name.replaceAll(_reHot39, ' ');

  /// 预编译热点正则表达式（避免在逐文件遍历与归组打分热路径中重复编译）。
  static final RegExp _reHot1 = RegExp(r'\s+');
  static final RegExp _reHot2 = RegExp(r'[\s_,|/\\+&]+');
  static final RegExp _reHot3 = RegExp(r'[\s&＆+＋_.,，、・·/\-–—!！]+');
  static final RegExp _reHot4 = RegExp(r'\{tmdb-\d+\}', caseSensitive: false);
  static final RegExp _reHot5 = RegExp(
    r'^(?:s\d{1,2}|season[ ._-]*\d{1,2}|'
    r'第[0-9一二三四五六七八九十百]+[季期]|'
    r'episodes?|tv[ ._-]*ver|sp|sps|extras?|bonus|nc)$',
    caseSensitive: false,
  );
  static final RegExp _reHot6 = RegExp(r'(?<!\d)(\d{1,4})(?!\d)');
  static final RegExp _reHot7 = RegExp(
    r'(?<![a-z0-9])(\d{1,4})(?!\d)',
    caseSensitive: false,
  );
  static final RegExp _reHot8 = RegExp(
    r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*\d{1,4}',
    caseSensitive: false,
  );
  static final RegExp _reHot9 = RegExp(
    r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*\d{1,4}',
    caseSensitive: false,
  );
  static final RegExp _reHot10 = RegExp(
    r'(?<![a-z0-9])e(?![a-z])[ ._-]*\d{1,3}(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot11 = RegExp(
    r'第[ ._-]*(?:[0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
    r'[ ._-]*(?:话|話|集|回)',
  );
  static final RegExp _reHot12 = RegExp(
    r'(?<![a-z0-9])stage[ ._-]*\d{1,4}(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot13 = RegExp(
    r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*\d{1,4}(?=\s+\S)',
  );
  static final RegExp _reHot14 = RegExp(
    r'[#＃][ ._-]*\d{1,4}(?:[ ._-]*(?:end|fin|final|完))?',
    caseSensitive: false,
  );
  static final RegExp _reHot15 = RegExp(r'^\s*\d+\s*[/／]\s*\d+\s*$');
  static final RegExp _reHot16 = RegExp(
    r'(?<![a-z0-9])\d{1,2}\.\d{1,2}\s*ch\b',
    caseSensitive: false,
  );
  static final RegExp _reHot17 = RegExp(
    r'(?<![a-z0-9])s\d{1,2}[ ._+-]*e(?:p)?[ ._-]*(\d{1,4})',
    caseSensitive: false,
  );
  static final RegExp _reHot18 = RegExp(
    r'(?<![a-z0-9])(?:episode|ep)(?![a-z])[ ._-]*(\d{1,4})',
    caseSensitive: false,
  );
  static final RegExp _reHot19 = RegExp(
    r'(?<![a-z0-9])e(?![a-z])[ ._-]*(\d{1,3})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot20 = RegExp(
    r'(?<![a-z0-9])stage[ ._-]*(\d{1,4})(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot21 = RegExp(
    r'(?<![a-z0-9])(?:19|20)\d{2}[ ._-]+-[ ._-]*(\d{1,4})'
    r'(?=\s+\S)',
  );
  static final RegExp _reHot22 = RegExp(
    r'第[ ._-]*([0-9]+|[一二三四五六七八九十百〇零壱弐参伍拾]+)'
    r'[ ._-]*(?:话|話|集|回)',
  );
  static final RegExp _reHot23 = RegExp(
    r'[#＃][ ._-]*(\d{1,4})(?:[ ._-]*(?:end|fin|final|完))?',
    caseSensitive: false,
  );
  static final RegExp _reHot24 = RegExp(r'\((\d{1,4})\)');
  static final RegExp _reHot25 = RegExp(r'[\[【][^\]】]*[\]】]|\([^)]*\)');
  static final RegExp _reHot26 = RegExp(
    r'(?:^|[\[(_【\s#＃])\d{1,3}\.\d(?=[\])）._\s]|$)',
  );
  static final RegExp _reHot27 = RegExp(
    r'电影|剧场版|劇場版|映画|movie|film|gekijouban|'
    r'the[\s._-]*final|活動写真|活动写真|終局特異点|终局特异点|'
    r'[\[(（]\s*m\d{1,2}\s*[\]）)]|'
    r'main[\s._-]*(?:movie|feature)?',
    caseSensitive: false,
  );
  static final RegExp _reHot28 = RegExp(r'(?<![\dx])(?:19|20)\d{2}(?![\dx])');
  static final RegExp _reHot29 = RegExp(r'[\[【]([^\]】]+)[\]】]');
  static final RegExp _reHot30 = RegExp(
    r'^bd[ _]+(\d{2,3})(?:v\d+)?$',
    caseSensitive: false,
  );
  static final RegExp _reHot31 = RegExp(
    r'^(?:\d{3,4}p|[248]k|[xh][ ._-]?26[45]|hevc|avc|av1|ma10p|main12|'
    r'yuv444p10|flac|alac|aac|opus|ac3|eac3|dts|dtshd|truehd|10bit|'
    r'hi10p|web|bd|dvd|ldrip|hdtv)',
    caseSensitive: false,
  );
  static final RegExp _reHot32 = RegExp(r'[\u3400-\u9fff]');
  static final RegExp _reHot33 = RegExp(r'(\d{1,4})\s*$');
  static final RegExp _reHot34 = RegExp(r'^([a-z]*)', caseSensitive: false);
  static final RegExp _reHot35 = RegExp(
    r'^(?:v\d+)?[-–—~～&＆+＋](?:e(?:p(?:isode)?)?[ ._-]*)?(\d{1,4})(?:v\d+)?$',
    caseSensitive: false,
  );
  static final RegExp _reHot36 = RegExp(r'^\s*\d+\s*[/／]\d+\s*$');
  static final RegExp _reHot37 = RegExp(
    r'(?<![a-z0-9])(\d{1,4})(?:v\d+)?(?![a-z0-9])',
    caseSensitive: false,
  );
  static final RegExp _reHot38 = RegExp('[０-９]');
  static final RegExp _reHot39 = RegExp(
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
  );
}
