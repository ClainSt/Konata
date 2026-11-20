import '../models/media_extensions.dart';
import 'track_preferences.dart';

/// 面向播放器界面与切换菜单的标准化字幕候选项（内嵌与外挂去重统一 + 智能语义提炼）。
class SubtitleChoice {
  /// 创建字幕候选项。
  const SubtitleChoice({
    this.mpvTrackId,
    required this.title,
    this.language = '',
    this.codec = '',
    this.externalPath,
    this.isExternal = false,
    this.isDefault = false,
    this.isForced = false,
    this.selected = false,
  });

  /// 已挂载至 libmpv 时的轨道 ID；未挂载的外部文件暂为 null（切换时按需挂载）。
  final int? mpvTrackId;

  /// 显示标题或原始文件名。
  final String title;

  /// 语言标签。
  final String language;

  /// 编码格式（如 `ass` / `subrip` / `pgs` / `vobsub`）。
  final String codec;

  /// 外部字幕路径或 URL。
  final String? externalPath;

  /// 是否属于外挂字幕。
  final bool isExternal;

  /// 是否默认轨。
  final bool isDefault;

  /// 是否强制字幕。
  final bool isForced;

  /// 当前是否激活。
  final bool selected;

  /// 语义化解析结果（语言 + 附加标记 + 字幕组 + 来源格式徽标 + 原始提示）。
  TrackSemanticInfo get semanticInfo => _TrackSemanticExtractor.describeSubtitle(
        title: title,
        language: language,
        codec: codec,
        externalPath: externalPath,
        isExternal: isExternal,
        isDefault: isDefault,
        isForced: isForced,
      );

  /// 界面主展示文本（例如 `简日双语 · UHA-WINGS&VCB-Studio`）。
  String get primaryTitle => semanticInfo.primaryTitle;

  /// 右侧简洁来源/格式角标（例如 `外挂 ASS` / `内封 SRT`）。
  String get sourceFormatBadge => semanticInfo.sourceFormatBadge;

  /// 悬停完整原始文件名或轨道详情提示文案。
  String get rawTooltip => semanticInfo.rawTooltip;

  /// 面向 UI 菜单与无障碍读屏的完整语义描述。
  String get displayLabel =>
      '$primaryTitle [$sourceFormatBadge]${isDefault ? ' · 默认' : ''}';
}

/// 面向播放器界面与切换菜单的标准化音轨候选项（内嵌与 `.mka/.flac` 外挂去重统一 + 智能语义提炼）。
class AudioTrackChoice {
  /// 创建音轨候选项。
  const AudioTrackChoice({
    this.mpvTrackId,
    required this.title,
    this.language = '',
    this.codec = '',
    this.channelCount,
    this.sampleRateHz,
    this.externalPath,
    this.isExternal = false,
    this.isDefault = false,
    this.selected = false,
  });

  /// 已挂载至 libmpv 时的轨道 ID。
  final int? mpvTrackId;

  /// 轨道标题或原始文件名。
  final String title;

  /// 语言代码。
  final String language;

  /// 编解码器。
  final String codec;

  /// 声道数。
  final int? channelCount;

  /// 采样率（Hz）。
  final int? sampleRateHz;

  /// 外挂音频文件路径。
  final String? externalPath;

  /// 是否为外挂音轨。
  final bool isExternal;

  /// 是否默认音轨。
  final bool isDefault;

  /// 当前是否激活。
  final bool selected;

  /// 是否为无损音频格式。
  bool get isLossless => TrackPreferences.isLosslessCodec(codec);

  /// 语义化解析结果（语言 + 评论/主音轨标记 + 声道 + 来源格式徽标）。
  TrackSemanticInfo get semanticInfo => _TrackSemanticExtractor.describeAudio(
        title: title,
        language: language,
        codec: codec,
        channelCount: channelCount,
        externalPath: externalPath,
        isExternal: isExternal,
      );

  /// 界面主展示文本（例如 `日语 · 2ch` / `日语 · 评论 · 2ch`）。
  String get primaryTitle => semanticInfo.primaryTitle;

  /// 右侧简洁来源/格式角标（例如 `内封 FLAC` / `外挂 MKA`）。
  String get sourceFormatBadge => semanticInfo.sourceFormatBadge;

  /// 悬停完整原始文件名或轨道详情提示文案。
  String get rawTooltip => semanticInfo.rawTooltip;

  /// 面向 UI 菜单与无障碍读屏的一行描述文案。
  String get displayLabel => '$primaryTitle [$sourceFormatBadge]';
}

/// 字幕与音轨统一语义解析视图模型。
class TrackSemanticInfo {
  const TrackSemanticInfo({
    required this.primaryTitle,
    required this.sourceFormatBadge,
    required this.rawTooltip,
    this.languageLabel = '',
    this.groupName = '',
  });

  /// 提炼后的主标题（`<语言> · <标记/组名>`）。
  final String primaryTitle;

  /// 来源与封装编码角标（如 `外挂 ASS` / `内封 FLAC`）。
  final String sourceFormatBadge;

  /// 完整原始文件名或原生轨道元数据（供 Tooltip 悬停查看）。
  final String rawTooltip;

  /// 识别出的规范中文语言名（如 `简日双语` / `简体中文` / `日语`）。
  final String languageLabel;

  /// 识别出的字幕组或制作组名。
  final String groupName;
}

class _TrackSemanticExtractor {
  _TrackSemanticExtractor._();

  static final RegExp _legacyStagePrefixRe = RegExp(r'^\d+_');
  static final RegExp _bracketGroupRe = RegExp(r'\[([^\[\]]+)\]');
  static final RegExp _crc32Re = RegExp(r'^[0-9a-fA-F]{8}$');
  static final RegExp _epNumRe = RegExp(
    r'^(?:ep?|v|sp|ova|oad|ncop|nced|pv|menu|mv)?\d{1,3}(?:v\d+)?$',
    caseSensitive: false,
  );
  static final RegExp _techNoiseTokenRe = RegExp(
    r'^(?:2160p|1080p|720p|480p|540p|4k|8k|1920x1080|3840x2160|1280x720|'
    r'x264|x265|h\.?264|h\.?265|hevc|avc|av1|vc1|vp9|'
    r'ma10p|hi10p|10bit|8bit|yuv420p10|yuv420p|'
    r'flac|aac|ac3|eac3|dts|dtshd|truehd|opus|vorbis|mp3|alac|wav|pcm|'
    r'bdrip|bd|webrip|webdl|web-dl|remux|hdr|hdr10|dv|dovi|sdr|2ch|5\.1|7\.1)$',
    caseSensitive: false,
  );

  static TrackSemanticInfo describeSubtitle({
    required String title,
    required String language,
    required String codec,
    required String? externalPath,
    required bool isExternal,
    required bool isDefault,
    required bool isForced,
  }) {
    final rawName = _extractFileName(externalPath);
    final rawCleanName = rawName.isNotEmpty
        ? rawName.replaceFirst(_legacyStagePrefixRe, '')
        : title.trim();
    final combinedForDetect = [
      title.trim(),
      rawCleanName,
    ].where((s) => s.isNotEmpty).join(' ');

    final langLabel = _detectLanguage(
      explicitLang: language,
      text: combinedForDetect,
    );
    final qualifier = _detectSubtitleQualifier(
      combinedForDetect,
      isForced: isForced,
    );
    final group = _extractMeaningfulGroup(
      rawCleanName.isNotEmpty ? rawCleanName : title,
    );
    final cleanDesc = group.isEmpty && !_looksLikeExternalReleaseFileName(title)
        ? _extractCleanEmbeddedTitle(title)
        : '';

    final parts = <String>[
      if (langLabel.isNotEmpty) langLabel,
      if (qualifier.isNotEmpty) qualifier,
      if (group.isNotEmpty)
        group
      else if (cleanDesc.isNotEmpty)
        cleanDesc,
    ];

    final fallback = rawCleanName.isNotEmpty
        ? SubtitleAndAudioChoices.stemOf(rawCleanName)
        : (isExternal ? '外挂字幕' : '内置字幕');
    final primary = parts.isNotEmpty ? parts.join(' · ') : fallback;
    final badge = _formatBadge(isExternal: isExternal, codec: codec, externalPath: externalPath);
    final tooltip = rawCleanName.isNotEmpty
        ? rawCleanName
        : (title.trim().isNotEmpty ? title.trim() : primary);

    return TrackSemanticInfo(
      primaryTitle: primary,
      sourceFormatBadge: badge,
      rawTooltip: tooltip,
      languageLabel: langLabel,
      groupName: group,
    );
  }

  static TrackSemanticInfo describeAudio({
    required String title,
    required String language,
    required String codec,
    required int? channelCount,
    required String? externalPath,
    required bool isExternal,
  }) {
    final rawName = _extractFileName(externalPath);
    final rawCleanName = rawName.isNotEmpty
        ? rawName.replaceFirst(_legacyStagePrefixRe, '')
        : title.trim();
    final combinedForDetect = [
      title.trim(),
      rawCleanName,
    ].where((s) => s.isNotEmpty).join(' ');

    final langLabel = _detectLanguage(
      explicitLang: language,
      text: combinedForDetect,
    );
    final isCommentary = _hasToken(combinedForDetect, const [
      'commentary',
      'comment',
      'comm',
      '评论',
      '副音轨',
    ]);
    final group = _extractMeaningfulGroup(rawCleanName);
    final cleanDesc = (!isCommentary && group.isEmpty)
        ? _extractCleanEmbeddedTitle(title)
        : '';

    final parts = <String>[
      if (langLabel.isNotEmpty) langLabel else (isExternal ? '外挂音轨' : '主音轨'),
      if (isCommentary) '评论',
      if (group.isNotEmpty)
        group
      else if (cleanDesc.isNotEmpty && cleanDesc != '主音轨')
        cleanDesc,
      if (channelCount != null && channelCount > 0) '${channelCount}ch',
    ];

    final badge = _formatBadge(
      isExternal: isExternal,
      codec: codec,
      externalPath: externalPath,
    );
    final tooltip = rawCleanName.isNotEmpty
        ? rawCleanName
        : (title.trim().isNotEmpty ? title.trim() : parts.join(' · '));

    return TrackSemanticInfo(
      primaryTitle: parts.join(' · '),
      sourceFormatBadge: badge,
      rawTooltip: tooltip,
      languageLabel: langLabel,
      groupName: group,
    );
  }

  static String _extractFileName(String? rawPath) {
    if (rawPath == null) return '';
    final trimmed = rawPath.trim();
    if (trimmed.isEmpty || trimmed.startsWith('memory://')) return '';
    final withoutQuery = trimmed.split('?').first;
    final lastSeg = withoutQuery.replaceAll('\\', '/').split('/').last;
    try {
      return Uri.decodeComponent(lastSeg);
    } catch (_) {
      return lastSeg;
    }
  }

  static String _formatBadge({
    required bool isExternal,
    required String codec,
    String? externalPath,
  }) {
    final prefix = isExternal ? '外挂' : '内封';
    var rawCodec = codec.trim().toLowerCase();
    if (rawCodec.isEmpty && externalPath != null) {
      final ext = SubtitleAndAudioChoices.extensionOf(externalPath);
      if (ext.isNotEmpty) rawCodec = ext.substring(1);
    }
    final normalizedCodec = switch (rawCodec) {
      'subrip' || 'srt' => 'SRT',
      'ass' => 'ASS',
      'ssa' => 'SSA',
      'webvtt' || 'vtt' => 'VTT',
      'hdmv_pgs_subtitle' || 'pgs' || 'sup' => 'PGS',
      'dvd_subtitle' || 'vobsub' || 'idx' => 'VOBSUB',
      'dvb_subtitle' => 'DVB',
      'flac' => 'FLAC',
      'aac' => 'AAC',
      'opus' => 'OPUS',
      'ac3' => 'AC3',
      'eac3' => 'EAC3',
      'dts' => 'DTS',
      'truehd' => 'TrueHD',
      'alac' => 'ALAC',
      'mp3' => 'MP3',
      'mka' => 'MKA',
      _ when rawCodec.startsWith('pcm') => 'PCM',
      _ => rawCodec.toUpperCase(),
    };
    return normalizedCodec.isNotEmpty ? '$prefix $normalizedCodec' : prefix;
  }

  static String _detectLanguage({
    required String explicitLang,
    required String text,
  }) {
    final lowerText = text.toLowerCase();
    final lowerExplicit = explicitLang.trim().toLowerCase();

    // 1. 优先判定简日/繁日双语复合标记
    if (_matchesAnyPattern(lowerText, _bilingualScPatterns) ||
        (_hasAnyLanguageCode(lowerText, const ['sc', 'chs', 'zh-hans', 'gb', 'simp']) &&
            _hasAnyLanguageCode(lowerText, const ['jp', 'jpn', 'ja', 'jap']))) {
      return '简日双语';
    }
    if (_matchesAnyPattern(lowerText, _bilingualTcPatterns) ||
        (_hasAnyLanguageCode(lowerText, const ['tc', 'cht', 'zh-hant', 'big5', 'trad']) &&
            _hasAnyLanguageCode(lowerText, const ['jp', 'jpn', 'ja', 'jap']))) {
      return '繁日双语';
    }

    // 2. 简体中文 / 繁体中文（先看文件名和标题语义，再回退显式 lang 代码）
    if (_hasAnyLanguageCode(lowerText, const [
      'sc',
      'chs',
      'zh-cn',
      'zh_cn',
      'zh-hans',
      'zh_hans',
      'zhs',
      'gb',
      'simp',
      '简体',
      '简中',
      '简体中文',
    ])) {
      return '简体中文';
    }
    if (_hasAnyLanguageCode(lowerText, const [
      'tc',
      'cht',
      'zh-tw',
      'zh_tw',
      'zh-hk',
      'zh_hk',
      'zh-hant',
      'zh_hant',
      'zht',
      'big5',
      'trad',
      '繁体',
      '繁體',
      '繁中',
      '繁体中文',
      '繁體中文',
    ])) {
      return '繁体中文';
    }

    // 3. 根据 track.lang 显式语言字段判别
    switch (lowerExplicit) {
      case 'chs':
      case 'sc':
      case 'zh-cn':
      case 'zh_cn':
      case 'zh-hans':
      case 'zhs':
        return '简体中文';
      case 'cht':
      case 'tc':
      case 'zh-tw':
      case 'zh-hk':
      case 'zh-hant':
      case 'zht':
        return '繁体中文';
      case 'chi':
      case 'zh':
      case 'zho':
        if (lowerText.contains('繁') || lowerText.contains('雙')) {
          return '繁体中文';
        }
        return '简体中文';
      case 'jp':
      case 'jpn':
      case 'ja':
      case 'jap':
        return '日语';
      case 'en':
      case 'eng':
        return '英语';
      case 'ko':
      case 'kor':
        return '韩语';
    }

    // 4. 从标题/文件名尾缀提取单语种标记
    if (_hasAnyLanguageCode(lowerText, const [
      'jp',
      'jpn',
      'ja',
      'jap',
      'japanese',
      '日语',
      '日語',
      '日文',
    ])) {
      return '日语';
    }
    if (_hasAnyLanguageCode(lowerText, const ['en', 'eng', 'english', '英语', '英文'])) {
      return '英语';
    }
    if (_hasAnyLanguageCode(lowerText, const ['ko', 'kor', 'korean', '韩语'])) {
      return '韩语';
    }
    return '';
  }

  static final List<RegExp> _bilingualScPatterns = List<RegExp>.unmodifiable([
    RegExp(
      r'(?:^|[._\-\s\[\]()/])(jpsc|scjp|chs[&+_\-]?jpn?|jpn?[&+_\-]?chs|sc[&+_\-]?jpn?|jpn?[&+_\-]?sc|zh-hans-jp)(?=$|[._\-\s\[\]()/])',
    ),
    RegExp(r'简日双语|簡日雙語|简日'),
  ]);

  static final List<RegExp> _bilingualTcPatterns = List<RegExp>.unmodifiable([
    RegExp(
      r'(?:^|[._\-\s\[\]()/])(jptc|tcjp|cht[&+_\-]?jpn?|jpn?[&+_\-]?cht|tc[&+_\-]?jpn?|jpn?[&+_\-]?tc|zh-hant-jp)(?=$|[._\-\s\[\]()/])',
    ),
    RegExp(r'繁日双语|繁日雙語|繁日'),
  ]);

  static bool _matchesAnyPattern(String text, List<RegExp> patterns) {
    for (final p in patterns) {
      if (p.hasMatch(text)) return true;
    }
    return false;
  }

  static bool _hasAnyLanguageCode(String lowerText, List<String> codes) {
    for (final code in codes) {
      final escaped = RegExp.escape(code);
      final re = RegExp(
        '(?:^|[._\\-\\s\\[\\]()/&,+])$escaped(?=\$|[._\\-\\s\\[\\]()/&,+.])',
      );
      if (re.hasMatch(lowerText)) return true;
      if (code.codeUnitAt(0) > 127 && lowerText.contains(code)) return true;
    }
    return false;
  }

  static bool _hasToken(String text, List<String> tokens) =>
      _hasAnyLanguageCode(text.toLowerCase(), tokens);

  static String _detectSubtitleQualifier(
    String text, {
    required bool isForced,
  }) {
    final lower = text.toLowerCase();
    if (_hasToken(lower, const ['comment', 'comm', 'commentary', '评论'])) {
      return '评论';
    }
    if (RegExp(r'signs?\s*[&+_/]\s*songs?').hasMatch(lower) ||
        lower.contains('屏幕字/歌词') ||
        (lower.contains('sign') && lower.contains('song'))) {
      return '屏幕字/歌词';
    }
    if (_hasToken(lower, const ['sign', 'signs', '屏幕字'])) {
      return '屏幕字';
    }
    if (_hasToken(lower, const ['song', 'songs', 'lyrics', '歌词'])) {
      return '歌词';
    }
    if (isForced || _hasToken(lower, const ['forced', '强制'])) {
      return '强制';
    }
    return '';
  }

  static String _extractMeaningfulGroup(String rawText) {
    if (rawText.trim().isEmpty) return '';
    for (final match in _bracketGroupRe.allMatches(rawText)) {
      final candidate = (match.group(1) ?? '').trim();
      if (candidate.isEmpty) continue;
      if (_isNoiseBracketContent(candidate)) continue;
      return candidate;
    }
    return '';
  }

  static bool _isNoiseBracketContent(String raw) {
    final trimmed = raw.trim();
    if (_crc32Re.hasMatch(trimmed) || _epNumRe.hasMatch(trimmed)) {
      return true;
    }
    final subTokens = trimmed
        .split(RegExp(r'[._\-\s&+/]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (subTokens.isEmpty) return true;

    for (final tok in subTokens) {
      final low = tok.toLowerCase();
      if (_epNumRe.hasMatch(low) ||
          _techNoiseTokenRe.hasMatch(low) ||
          _isPureLanguageOrQualifierToken(low)) {
        continue;
      }
      return false;
    }
    return true;
  }

  static bool _isPureLanguageOrQualifierToken(String low) {
    const tokens = {
      'jpsc',
      'scjp',
      'jptc',
      'tcjp',
      'sc',
      'chs',
      'tc',
      'cht',
      'jp',
      'jpn',
      'ja',
      'jap',
      'en',
      'eng',
      'gb',
      'big5',
      'simp',
      'trad',
      'zh',
      'chi',
      'zho',
      'sub',
      'subs',
      'ass',
      'srt',
      'sign',
      'signs',
      'song',
      'songs',
      'comm',
      'comment',
      'commentary',
      'forced',
    };
    return tokens.contains(low);
  }

  static final RegExp _releaseFileExtRe = RegExp(
    r'\.(?:ass|ssa|srt|vtt|sup|idx|sub|mkv|mp4)$',
    caseSensitive: false,
  );
  static final RegExp _releaseTechNoiseRe = RegExp(
    r'\b(?:2160p|1080p|720p|480p|x265|x264|hevc|avc|ma10p|hi10p|flac|bdrip|webrip|web-dl|remux)\b',
    caseSensitive: false,
  );

  static bool _looksLikeExternalReleaseFileName(String rawTitle) {
    final t = rawTitle.trim();
    if (t.isEmpty) return false;
    return _releaseFileExtRe.hasMatch(t) || _releaseTechNoiseRe.hasMatch(t);
  }

  static String _extractCleanEmbeddedTitle(String rawTitle) {
    var cleaned = rawTitle.trim();
    if (cleaned.isEmpty) return '';
    cleaned = cleaned
        .replaceAll(
          RegExp(
            r'\b(?:jpsc|scjp|jptc|tcjp|chs|cht|zh-cn|zh-tw|zh-hans|zh-hant|'
            r'zh-hans-jp|zh-hant-jp|jpn|jap|eng|sc|tc|jp|ja|en|gb|big5|simp|trad|'
            r'signs?\s*[&+_/]\s*songs?|signs?|songs?|commentary|comment|comm|forced)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(r'简体中文|繁体中文|繁體中文|简日双语|繁日双语|繁日雙語|简中|繁中|简体|繁体|繁體|日语|日語|英语|屏幕字|歌词|评论'),
          ' ',
        )
        .replaceAll(RegExp(r'[\[\]()·\-_&+/:]+'), ' ')
        .replaceAll(RegExp(r'\s{2,}'), ' ')
        .trim();
    return cleaned;
  }
}

/// 同源外挂字幕与外挂音轨文件发现与合并去重构建器（纯字符串规则，跨本地与 WebDAV/SMB）。
class SubtitleAndAudioChoices {
  SubtitleAndAudioChoices._();

  /// 支持的外挂字幕扩展名集合（统一引用领域权威常量表）。
  static const Set<String> subtitleExtensions = KonataMediaExtensions.subtitle;

  /// 支持挂载为外部音轨的扩展名集合（传递给 `audio-files-append`）。
  static const Set<String> externalAudioExtensions =
      KonataMediaExtensions.externalAudio;

  /// 提取小写文件扩展名（含点号，如 `.ass`）。
  static String extensionOf(String pathOrName) =>
      KonataMediaExtensions.extensionOf(pathOrName);

  /// 提取不含目录与最终扩展名的文件名。
  static String stemOf(String pathOrName) {
    final normalized = pathOrName.replaceAll('\\', '/');
    final fileName = normalized.split('/').last;
    final dot = fileName.lastIndexOf('.');
    return dot <= 0 ? fileName : fileName.substring(0, dot);
  }

  /// 提取标准化父目录路径。
  static String parentDirOf(String pathOrName) {
    final normalized = pathOrName.replaceAll('\\', '/');
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return '';
    return normalized.substring(0, slash);
  }

  /// 检查 [candidatePath] 是否与 [videoPath] 构成同名或带语言/音轨后缀的外挂音轨匹配。
  static List<String> findMatchingExternalAudioPaths({
    required String videoRelativePath,
    required Iterable<String> candidatePaths,
  }) {
    final videoDir = parentDirOf(videoRelativePath).toLowerCase();
    final videoStem = stemOf(videoRelativePath).toLowerCase();
    if (videoStem.isEmpty) return const [];

    final matched = <String>[];
    final seenNormalized = <String>{};

    for (final raw in candidatePaths) {
      final candidate = raw.replaceAll('\\', '/');
      final ext = extensionOf(candidate);
      if (!externalAudioExtensions.contains(ext)) continue;

      final candDir = parentDirOf(candidate).toLowerCase();
      final inSameDir = candDir == videoDir;
      final inAudioSubdir =
          videoDir.isEmpty &&
              (candDir == 'audio' || candDir == 'sp audio') ||
          (videoDir.isNotEmpty &&
              (candDir == '$videoDir/audio' ||
                  candDir == '$videoDir/sp audio'));
      if (!inSameDir && !inAudioSubdir) continue;

      final candStem = stemOf(candidate).toLowerCase();
      final matchesStem =
          candStem == videoStem ||
          candStem.startsWith('$videoStem.') ||
          candStem.startsWith('${videoStem}_') ||
          candStem.startsWith('$videoStem ') ||
          candStem.startsWith('$videoStem[');
      if (!matchesStem) continue;

      final key = candidate.toLowerCase();
      if (seenNormalized.add(key)) {
        matched.add(raw);
      }
    }
    matched.sort();
    return matched;
  }

  /// 合并内嵌字幕与外挂字幕文件列表，对已作为 VobSub `.idx+.sub` 配对及已挂载的轨道（含 `memory://` 内存轨）精准去重。
  static List<SubtitleChoice> mergeSubtitles({
    required List<MpvTrackInfo> mpvTracks,
    required List<String> discoveredExternalPaths,
    Map<int, String> mountedSourcePathsByTrackId = const {},
  }) {
    final results = <SubtitleChoice>[];
    final mountedKeys = <String>{};

    for (final track in mpvTracks) {
      if (track.type != MpvTrackType.subtitle) continue;
      final mappedSource = mountedSourcePathsByTrackId[track.id];
      final rawExt = track.externalFilename;
      final isMemoryPseudoPath =
          rawExt != null && rawExt.trim().startsWith('memory://');
      final effectiveExtPath =
          (mappedSource != null && mappedSource.trim().isNotEmpty)
          ? mappedSource.trim()
          : (isMemoryPseudoPath ? null : rawExt);

      if (effectiveExtPath != null && effectiveExtPath.isNotEmpty) {
        mountedKeys.add(_normalizeDedupKey(effectiveExtPath));
      }
      final trimmedTitle = track.title.trim();
      if ((track.isExternal || isMemoryPseudoPath || mappedSource != null) &&
          trimmedTitle.isNotEmpty) {
        mountedKeys.add(_normalizeDedupKey(trimmedTitle));
      }

      final fallbackTitle = trimmedTitle.isNotEmpty
          ? trimmedTitle
          : (effectiveExtPath != null && effectiveExtPath.isNotEmpty
                ? effectiveExtPath.replaceAll('\\', '/').split('/').last
                : '');
      results.add(
        SubtitleChoice(
          mpvTrackId: track.id,
          title: fallbackTitle,
          language: track.lang,
          codec: track.codec,
          externalPath: effectiveExtPath,
          isExternal:
              track.isExternal || isMemoryPseudoPath || mappedSource != null,
          isDefault: track.isDefault,
          isForced: track.isForced,
          selected: track.selected,
        ),
      );
    }

    // 处理 .idx/.sub VobSub 成对文件：存在同名 .idx 时跳过独立 .sub
    final idxStems = <String>{};
    for (final p in discoveredExternalPaths) {
      if (extensionOf(p) == '.idx') {
        idxStems.add(_stemDirKey(p));
      }
    }

    for (final path in discoveredExternalPaths) {
      final ext = extensionOf(path);
      if (!subtitleExtensions.contains(ext)) continue;
      if (ext == '.sub' && idxStems.contains(_stemDirKey(path))) {
        continue;
      }
      final key = _normalizeDedupKey(path);
      if (mountedKeys.contains(key)) continue;
      mountedKeys.add(key);

      final fileName = path.replaceAll('\\', '/').split('/').last;
      final extCodec = ext.isNotEmpty ? ext.substring(1) : '';
      results.add(
        SubtitleChoice(
          title: fileName,
          codec: extCodec == 'idx' ? 'vobsub' : extCodec,
          externalPath: path,
          isExternal: true,
        ),
      );
    }

    return results;
  }

  /// 合并内嵌音轨与外挂 `.mka/.flac` 音轨列表并去重。
  static List<AudioTrackChoice> mergeAudioTracks({
    required List<MpvTrackInfo> mpvTracks,
    required List<String> discoveredExternalAudioPaths,
  }) {
    final results = <AudioTrackChoice>[];
    final mountedKeys = <String>{};

    for (final track in mpvTracks) {
      if (track.type != MpvTrackType.audio) continue;
      final extPath = track.externalFilename;
      if (extPath != null && extPath.isNotEmpty) {
        mountedKeys.add(_normalizeDedupKey(extPath));
      }
      final fallbackTitle =
          track.title.trim().isNotEmpty
              ? track.title.trim()
              : (extPath != null && extPath.isNotEmpty
                    ? extPath.replaceAll('\\', '/').split('/').last
                    : '');
      results.add(
        AudioTrackChoice(
          mpvTrackId: track.id,
          title: fallbackTitle,
          language: track.lang,
          codec: track.codec,
          channelCount: track.channelCount,
          sampleRateHz: track.sampleRateHz,
          externalPath: extPath,
          isExternal: track.isExternal,
          isDefault: track.isDefault,
          selected: track.selected,
        ),
      );
    }

    for (final path in discoveredExternalAudioPaths) {
      final ext = extensionOf(path);
      if (!externalAudioExtensions.contains(ext)) continue;
      final key = _normalizeDedupKey(path);
      if (mountedKeys.contains(key)) continue;
      mountedKeys.add(key);

      final fileName = path.replaceAll('\\', '/').split('/').last;
      results.add(
        AudioTrackChoice(
          title: fileName,
          codec: ext.isNotEmpty ? ext.substring(1) : '',
          externalPath: path,
          isExternal: true,
        ),
      );
    }

    return results;
  }

  static String _normalizeDedupKey(String raw) {
    final normalized = raw.replaceAll('\\', '/').trim();
    // 针对本地 HTTP 网桥代理 URL（可能含 query token），取解码后的文件名做辅助去重键。
    final withoutQuery = normalized.split('?').first;
    final tail = withoutQuery.split('/').last;
    try {
      return Uri.decodeComponent(tail).toLowerCase();
    } catch (_) {
      return tail.toLowerCase();
    }
  }

  static String _stemDirKey(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    final dot = normalized.lastIndexOf('.');
    return dot > 0 ? normalized.substring(0, dot) : normalized;
  }

  static const Set<String> _subtitleSubdirExactNames = {
    'sub',
    'subs',
    'subtitle',
    'subtitles',
    '字幕',
  };

  static const Set<String> _audioSidecarSubdirExactNames = {
    'audio',
    'sp audio',
    'mka',
  };

  static final RegExp _subtitleSubdirTokenRegex = RegExp(
    r'^(?:subs?|subtitles?)(?:[\s._\-]?\d+|[\s._\-](?:chs|cht|sc|tc|jp|jpn|eng|zh|bilingual|all|extra))?$',
    caseSensitive: false,
  );

  /// 全仓唯一外挂字幕子目录判定（如 `Subs`、`Subtitles`、`Subs5_CHS`、`简体字幕`）。
  static bool isSubtitleSubdirName(String rawName) {
    final lower = rawName.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (_subtitleSubdirExactNames.contains(lower)) return true;
    if (lower.contains('字幕')) return true;
    return _subtitleSubdirTokenRegex.hasMatch(lower);
  }

  /// 全仓唯一外挂音轨子目录判定（如 `Audio`、`SP Audio`）。
  static bool isAudioSidecarSubdirName(String rawName) {
    final lower = rawName.trim().toLowerCase();
    return _audioSidecarSubdirExactNames.contains(lower);
  }

  /// 全仓唯一媒体附属子目录判定（涵盖外挂字幕子目录与外挂音轨子目录）。
  static bool isSidecarSubdirName(String rawName) {
    return isSubtitleSubdirName(rawName) || isAudioSidecarSubdirName(rawName);
  }

  /// 若目录尾段为字幕子目录（如 `Anime/S1/Subs`），返回其逻辑父目录（`Anime/S1`）；否则原样返回。
  static String logicalParentDirOfSubtitleDir(String posixDir) {
    final normalized = posixDir
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'^/+|/+$'), '');
    if (normalized.isEmpty) return '';
    final slash = normalized.lastIndexOf('/');
    final tail = slash < 0 ? normalized : normalized.substring(slash + 1);
    if (!isSubtitleSubdirName(tail)) return normalized;
    return slash < 0 ? '' : normalized.substring(0, slash);
  }
}
