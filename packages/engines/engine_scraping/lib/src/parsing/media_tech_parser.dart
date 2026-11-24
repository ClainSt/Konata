import 'package:konata_contracts/konata_contracts.dart';

/// 从文件名与发布串中解析出的视音频技术规格。
class ParsedMediaTechSpecs {
  /// 构造技术规格模型。
  const ParsedMediaTechSpecs({
    this.resolution,
    this.videoCodec,
    this.bitDepth,
    this.audioCodec,
    this.dynamicRange,
    this.mediaSourceTag,
    required this.strippedText,
  });

  /// 分辨率标签（如 `2160p`、`1080p`、`720p`）。
  final String? resolution;

  /// 视频编码（如 `HEVC`、`AV1`、`AVC`）。
  final String? videoCodec;

  /// 色深标签（如 `10bit`、`12bit`、`8bit`）。
  final String? bitDepth;

  /// 音频编码（如 `FLAC`、`PCM`、`DTS-HD`、`OPUS`、`AAC`）。
  final String? audioCodec;

  /// 动态范围（如 `HDR`、`DV`、`HDR10+`）。
  final String? dynamicRange;

  /// 片源介质标签（如 `BDRip`、`WEB-DL`、`REMUX`、`HDTV`）。
  final String? mediaSourceTag;

  /// 剥离场景尾缀（如 `-SubsPlease`、`-Shiniori`）和技术标签后的干净标题碎片。
  final String strippedText;
}

/// 媒体技术规格解析器（支持方括号内外、点分隔及无括号 Scene 命名）。
class MediaTechParser {
  const MediaTechParser._();

  static final RegExp _resolutionRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+x×])(?:(4K|UHD|2160p|1440p|1080p|720p|576p|480p)|(3840|1920|1280|1440|960|852|720)\s*[x×]\s*(2160|1080|720|576|540|480))(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _videoCodecRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+])(AV1|HEVC|H\.?265|x\.?265(?:p10)?|AVC|H\.?264|x\.?264(?:p10)?|VP9|MPEG-?2)(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _bitDepthRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+])(12\s*-?\s*bit|10\s*-?\s*bit|8\s*-?\s*bit|\d+bpp|Ma10p|Ma12p|Hi10P?|x\.?26[45]p10|yuv\d{3}p10(?:le|be)?|yuv\d{3}p12(?:le|be)?)(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _audioCodecRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+])\d*(DTS-?HD(?:\s*MA|\s*HR)?|TrueHD(?:x\d)?|Atmos|LPCM|PCM|FLAC(?:x\d)?|OPUS(?:x\d)?|DDP?(?:5\.1|2\.0|\+)?|E-?AC-?3|AC-?3(?:x\d)?|AAC(?:x\d)?|ALAC|ALS)(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _dynamicRangeRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+])(Dolby[\s._-]?Vision|DoVi|DV|HDR10\+|HDR10|HDR|HLG)(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _sourceTagRegex = RegExp(
    r'(?:^|[\s._\-\[\(【（/／+])('
    '${KonataMediaExtensions.sourceTagAlternation}'
    r')(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _crcRegex = RegExp(
    r'\[[0-9A-Fa-f]{8}\]|\([0-9A-Fa-f]{8}\)',
  );

  /// 仅当位于场景串尾部且前置技术字段或点号分词时剥离 `-Group` 无括号尾缀（如 `-Shiniori`）。
  static final RegExp _trailingSceneGroupRegex = RegExp(
    r'-(?:SubsPlease|Erai-raws|Judas|EMBER|ASW|Tsundere-Raws|Kamigami|LoliHouse|VCB-Studio|Moozzi2|Snow-Raws|SweetSub|Shiniori|Kawaiika-Raws|Beatrice-Raws|ANK-Raws|[A-Za-z][A-Za-z0-9]{2,15})\s*$',
    caseSensitive: false,
  );

  static final RegExp _techTokenStripper = RegExp(
    r'(?<=^|[\s._\-\[\(【（/／+])(?:4K|UHD|2160p|1440p|1080p|720p|576p|480p|\d{3,4}x\d{3,4}p?|AV1|HEVC|H\.?265|x\.?265(?:p10)?|AVC|H\.?264|x\.?264(?:p10)?|VP9|MPEG-?2|12\s*-?\s*bit|10\s*-?\s*bit|8\s*-?\s*bit|\d+bpp|Ma10p|Ma12p|Hi10P?|yuv\d{3}p\d*(?:le|be)?|\d*(?:DTS-?HD(?:\s*MA|\s*HR)?|DTS|TrueHD(?:x\d)?|Atmos|LPCM|PCM|FLAC(?:x\d)?|OPUS(?:x\d)?|DDP?(?:5\.1|2\.0|\+)?|E-?AC-?3|AC-?3(?:x\d)?|AAC(?:x\d)?|ALAC|ALS)|\d+Audio|(?:7\.1|5\.1|2\.0)(?:x\d|ch)?|\d+(?:\.\d+)?fps|Dolby[\s._-]?Vision|DoVi|DV|HDR10\+|HDR10|HDR|HLG|'
    '${KonataMediaExtensions.sourceTagAlternation}|'
    r'REPACK|PROPER|Multi-?Sub|Dual[\s._-]?Audio|MSub|日本語字幕|简繁日内封|简繁内封|简体内封|繁体内封|简繁外挂|内封字幕|字幕|CATCHPLAY|CHS|CHT|CHI|JPN|ENG|SC|TC|JPSC|JPTC|GB|BIG5|ASS(?:x\d)?|SSA(?:x\d)?|SRT(?:x\d)?|SUP(?:x\d)?|PGS(?:x\d)?|'
    '${KonataMediaExtensions.videoExtensionAlternation}|'
    r'Chap|rev|v[2-9])(?=$|[\s._\-\]\)】）/／+])',
    caseSensitive: false,
  );

  static final RegExp _bitDepthCompact = RegExp(r'[\s-]');

  /// 从不含扩展名的文件名主干中解析全部技术参数并给出剥离标签后的残余文本。
  static ParsedMediaTechSpecs parse(String stem) {
    final resolution = _parseResolution(stem);
    final videoCodec = _parseVideoCodec(stem);
    final bitDepth = _parseBitDepth(stem);
    final audioCodec = _parseAudioCodec(stem);
    final dynamicRange = _parseDynamicRange(stem);
    final sourceTag = _parseSourceTag(stem);

    var stripped = stem.replaceAll(_crcRegex, ' ');
    final hadTechTail =
        resolution != null ||
        videoCodec != null ||
        audioCodec != null ||
        sourceTag != null ||
        bitDepth != null;
    if (hadTechTail && _trailingSceneGroupRegex.hasMatch(stripped)) {
      stripped = stripped.replaceFirst(_trailingSceneGroupRegex, '');
    }
    stripped = stripped.replaceAll(_techTokenStripper, ' ');

    return ParsedMediaTechSpecs(
      resolution: resolution,
      videoCodec: videoCodec,
      bitDepth: bitDepth,
      audioCodec: audioCodec,
      dynamicRange: dynamicRange,
      mediaSourceTag: sourceTag,
      strippedText: stripped,
    );
  }

  /// 仅解析技术规格字段而不执行整串剥离替换（供调用方不读取 `strippedText` 时跳过昂贵正则替换）。
  static ParsedMediaTechSpecs parseSpecsOnly(String stem) =>
      ParsedMediaTechSpecs(
        resolution: _parseResolution(stem),
        videoCodec: _parseVideoCodec(stem),
        bitDepth: _parseBitDepth(stem),
        audioCodec: _parseAudioCodec(stem),
        dynamicRange: _parseDynamicRange(stem),
        mediaSourceTag: _parseSourceTag(stem),
        strippedText: '',
      );

  /// 短路探测文本是否包含任一核心技术参数，同时返回剥离技术标签后的残余文本（供括号块纯技术判定与集号预处理复用）。
  static ({bool hasSpec, String strippedText}) stripTechTokens(String stem) {
    final hadTechTail =
        _resolutionRegex.hasMatch(stem) ||
        _videoCodecRegex.hasMatch(stem) ||
        _audioCodecRegex.hasMatch(stem) ||
        _sourceTagRegex.hasMatch(stem) ||
        _bitDepthRegex.hasMatch(stem);
    final hasSpec = hadTechTail || _dynamicRangeRegex.hasMatch(stem);
    var stripped = stem.replaceAll(_crcRegex, ' ');
    if (hadTechTail && _trailingSceneGroupRegex.hasMatch(stripped)) {
      stripped = stripped.replaceFirst(_trailingSceneGroupRegex, '');
    }
    stripped = stripped.replaceAll(_techTokenStripper, ' ');
    return (hasSpec: hasSpec, strippedText: stripped);
  }

  /// 若无括号 Scene 文件名末尾存在 `-Group`（前置技术标识），提取发布组名。
  static String? extractTrailingSceneGroup(String stem) {
    final hasTech =
        _resolutionRegex.hasMatch(stem) ||
        _videoCodecRegex.hasMatch(stem) ||
        _sourceTagRegex.hasMatch(stem);
    if (!hasTech) return null;
    final match = _trailingSceneGroupRegex.firstMatch(stem.trim());
    if (match == null) return null;
    final raw = match.group(0)!.substring(1).trim();
    return raw.isEmpty ? null : raw;
  }

  static String? _parseResolution(String text) {
    final m = _resolutionRegex.firstMatch(text);
    if (m == null) return null;
    final direct = m.group(1)?.toUpperCase();
    if (direct != null) {
      if (direct == '4K' || direct == 'UHD') return '2160p';
      return direct.toLowerCase();
    }
    final height = m.group(3);
    if (height != null) return '${height}p';
    return null;
  }

  static String? _parseVideoCodec(String text) {
    final m = _videoCodecRegex.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase().replaceAll('.', '');
    if (raw == 'X265' || raw == 'H265' || raw == 'HEVC') return 'HEVC';
    if (raw == 'X264' || raw == 'H264' || raw == 'AVC') return 'AVC';
    return raw;
  }

  static String? _parseBitDepth(String text) {
    final m = _bitDepthRegex.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.toLowerCase().replaceAll(_bitDepthCompact, '');
    if (raw == 'hi10p' ||
        raw == 'hi10' ||
        raw == 'ma10p' ||
        raw == '10bpp' ||
        raw.contains('p10')) {
      return '10bit';
    }
    if (raw == 'ma12p' || raw == '12bpp' || raw.contains('p12')) {
      return '12bit';
    }
    if (raw == '8bpp') return '8bit';
    return raw;
  }

  static String? _parseAudioCodec(String text) {
    final m = _audioCodecRegex.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    if (raw.startsWith('DTS')) return 'DTS-HD';
    if (raw == 'LPCM' || raw == 'PCM') return 'PCM';
    if (raw.startsWith('FLAC')) return 'FLAC';
    if (raw.startsWith('AAC')) return 'AAC';
    if (raw.startsWith('EAC3') ||
        raw.startsWith('E-AC-3') ||
        raw.startsWith('DDP')) {
      return 'DD+';
    }
    if (raw == 'AC-3' || raw == 'AC3') return 'AC3';
    return raw;
  }

  static String? _parseDynamicRange(String text) {
    final m = _dynamicRangeRegex.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    if (raw.contains('VISION') || raw == 'DOVI' || raw == 'DV') return 'DV';
    return raw;
  }

  static String? _parseSourceTag(String text) {
    final m = _sourceTagRegex.firstMatch(text);
    if (m == null) return null;
    final raw = m.group(1)!.toUpperCase();
    if (raw == 'BLU-RAY' || raw == 'BLURAY' || raw == 'BD' || raw == 'BDMV') {
      return 'BDRip';
    }
    if (raw == 'WEBDL') return 'WEB-DL';
    if (raw == 'LDRIP' || raw == 'LD') return 'LDRip';
    if (raw == 'BDREMUX' || raw == 'BD-REMUX') return 'REMUX';
    return raw;
  }
}
