/// libmpv 轨道大类。
enum MpvTrackType {
  /// 视频轨。
  video,

  /// 音频轨。
  audio,

  /// 字幕轨。
  subtitle,
}

/// 轨道元数据领域实体（由 libmpv `track-list` 节点映射而来）。
class MpvTrackInfo {
  /// 创建轨道信息实体。
  const MpvTrackInfo({
    required this.id,
    required this.type,
    this.title = '',
    this.lang = '',
    this.codec = '',
    this.channelCount,
    this.sampleRateHz,
    this.isDefault = false,
    this.isForced = false,
    this.isExternal = false,
    this.externalFilename,
    this.selected = false,
  });

  /// libmpv 内部轨道 ID（从 1 开始）。
  final int id;

  /// 轨道分类。
  final MpvTrackType type;

  /// 轨道标题（如字幕组/配音说明）。
  final String title;

  /// ISO-639 语言代码（如 `jpn` / `chi` / `chs`）。
  final String lang;

  /// 编解码器（如 `flac` / `ass` / `subrip` / `hdmv_pgs_subtitle`）。
  final String codec;

  /// 声道数（仅音轨）。
  final int? channelCount;

  /// 采样率（仅音轨，Hz）。
  final int? sampleRateHz;

  /// 是否声明为默认轨。
  final bool isDefault;

  /// 是否为强制字幕轨。
  final bool isForced;

  /// 是否为外挂轨。
  final bool isExternal;

  /// 若为外挂轨，对应外部文件路径。
  final String? externalFilename;

  /// 当前是否处于选中状态。
  final bool selected;
}

/// 字幕样式覆盖模式（映射至 libmpv `sub-ass-override`）。
enum SubtitleAssOverrideMode {
  /// 完整保留 ASS/SSA 原生特效与字体布局（默认高保真）。
  preserveAss('no'),

  /// 允许缩放字号但保留位置特效（`scale`）。
  scaleOnly('scale'),

  /// 统一以用户自定义样式覆盖原生字体/大小/位置（`force`）。
  forceStyle('force');

  const SubtitleAssOverrideMode(this.mpvValue);

  /// 传递给 libmpv `sub-ass-override` 的参数值。
  final String mpvValue;
}

/// BDRip 默认轨道选择偏好策略（纯领域规则）。
class TrackPreferences {
  /// 创建默认轨道偏好配置。
  const TrackPreferences({
    this.preferredAudioLangs = const [
      'jpn',
      'ja',
      'japanese',
      'chi',
      'zho',
      'zh',
    ],
    this.preferredSubtitleLangs = const [
      'chs',
      'zh-hans',
      'zh-cn',
      'sc',
      'chi',
      'zho',
      'zh',
      'cht',
      'zh-hant',
      'zh-tw',
      'zh-hk',
      'tc',
    ],
    this.preferLosslessAudio = true,
    this.preferAssOverSrt = true,
  });

  /// 优先音轨语言顺序（默认日语原声优先，其次中文）。
  final List<String> preferredAudioLangs;

  /// 优先字幕语言顺序（默认简中优先，其次繁中）。
  final List<String> preferredSubtitleLangs;

  /// 是否优先选择无损音频（FLAC / TrueHD / PCM / DTS-HD）。
  final bool preferLosslessAudio;

  /// 是否优先选择 ASS/SSA 字幕胜过纯文本 SRT/VTT。
  final bool preferAssOverSrt;

  static final RegExp _zhHintRegex = RegExp(
    r'(?:简|繁|中|双语|chs|cht|sc|tc|gb|big5|hans|hant|zh)',
    caseSensitive: false,
  );
  static final RegExp _simplifiedHintRegex = RegExp(
    r'(?:简体|简日|简中|chs|sc|gb|hans|zh-cn|zh_cn|zh-hans)',
    caseSensitive: false,
  );
  static final RegExp _jpAudioHintRegex = RegExp(
    r'(?:jpn|ja|jap|日|原声|native)',
    caseSensitive: false,
  );
  static final RegExp _commentaryHintRegex = RegExp(
    r'(?:commentary|评论|副音轨|cast|staff)',
    caseSensitive: false,
  );

  /// 判断音轨是否为无损或高规格主音轨。
  static bool isLosslessCodec(String codec) {
    final c = codec.trim().toLowerCase();
    return c.contains('flac') ||
        c.contains('truehd') ||
        c.contains('pcm') ||
        c.contains('alac') ||
        c.contains('mlp') ||
        c.contains('dts');
  }

  /// 为单条音轨打分，分值越高越优先作为默认音轨。
  int scoreAudioTrack(MpvTrackInfo track) {
    if (track.type != MpvTrackType.audio) return -10000;
    var score = 0;
    final lang = track.lang.trim().toLowerCase();
    final combined = '${track.title} ${track.lang}'.trim();

    for (var i = 0; i < preferredAudioLangs.length; i++) {
      final target = preferredAudioLangs[i].toLowerCase();
      if (lang == target || lang.startsWith('$target-')) {
        score += 400 - i * 40;
        break;
      }
    }

    if (lang.isEmpty && _jpAudioHintRegex.hasMatch(combined)) {
      score += 280;
    }

    if (_commentaryHintRegex.hasMatch(combined)) {
      score -= 350;
    }

    if (preferLosslessAudio && isLosslessCodec(track.codec)) {
      score += 120;
    }

    if (track.isDefault) {
      score += 60;
    }

    if (track.isExternal) {
      score += 40;
    }

    return score;
  }

  /// 为单条字幕轨打分，分值越高越优先作为默认字幕。
  int scoreSubtitleTrack(MpvTrackInfo track) {
    if (track.type != MpvTrackType.subtitle) return -10000;
    var score = 0;
    final lang = track.lang.trim().toLowerCase();
    final title = track.title.trim();
    final filename = track.externalFilename ?? '';
    final combined = '$title $lang $filename';

    for (var i = 0; i < preferredSubtitleLangs.length; i++) {
      final target = preferredSubtitleLangs[i].toLowerCase();
      if (lang == target || lang.startsWith('$target-')) {
        score += 500 - i * 25;
        break;
      }
    }

    if (_simplifiedHintRegex.hasMatch(combined)) {
      score += 180;
    } else if (_zhHintRegex.hasMatch(combined)) {
      score += 120;
    }

    final codec = track.codec.trim().toLowerCase();
    if (preferAssOverSrt) {
      if (codec == 'ass' || codec == 'ssa') {
        score += 90;
      } else if (codec == 'subrip' || codec == 'srt' || codec == 'webvtt') {
        score += 35;
      } else if (codec.contains('pgs') || codec.contains('dvd')) {
        score += 20;
      }
    }

    if (track.isForced) {
      score -= 120;
    }

    if (track.isExternal) {
      score += 80;
    }

    if (track.isDefault) {
      score += 50;
    }

    return score;
  }

  /// 从轨道列表挑选最佳默认音轨。
  MpvTrackInfo? pickBestAudioTrack(List<MpvTrackInfo> tracks) {
    final audioTracks = tracks
        .where((t) => t.type == MpvTrackType.audio)
        .toList();
    if (audioTracks.isEmpty) return null;
    audioTracks.sort((a, b) => scoreAudioTrack(b).compareTo(scoreAudioTrack(a)));
    return audioTracks.first;
  }

  /// 从轨道列表挑选最佳默认字幕轨。
  MpvTrackInfo? pickBestSubtitleTrack(List<MpvTrackInfo> tracks) {
    final subTracks = tracks
        .where((t) => t.type == MpvTrackType.subtitle)
        .toList();
    if (subTracks.isEmpty) return null;
    subTracks.sort(
      (a, b) => scoreSubtitleTrack(b).compareTo(scoreSubtitleTrack(a)),
    );
    return subTracks.first;
  }
}

/// 跨话轨道记忆（同一作品连播下一话时，尽量沿用用户上一话手动选定的音轨与字幕特征）。
class CrossEpisodeTrackMemory {
  /// 创建空的跨话轨道记忆。
  const CrossEpisodeTrackMemory({
    this.audioLang,
    this.audioTitle,
    this.audioCodec,
    this.audioExternal = false,
    this.subtitleDisabled = false,
    this.subLang,
    this.subTitle,
    this.subCodec,
    this.subExternal = false,
  });

  /// 用户手动选中的音轨语言。
  final String? audioLang;

  /// 用户手动选中的音轨标题关键词。
  final String? audioTitle;

  /// 用户手动选中的音轨编码。
  final String? audioCodec;

  /// 是否来自外挂音轨。
  final bool audioExternal;

  /// 用户是否明确关闭了字幕。
  final bool subtitleDisabled;

  /// 用户手动选中的字幕语言。
  final String? subLang;

  /// 用户手动选中的字幕标题/字幕组特征。
  final String? subTitle;

  /// 用户手动选中的字幕编码。
  final String? subCodec;

  /// 是否来自外挂字幕。
  final bool subExternal;

  /// 根据上一话选择的音轨生成新记忆状态。
  CrossEpisodeTrackMemory rememberAudio(MpvTrackInfo track) {
    return CrossEpisodeTrackMemory(
      audioLang: track.lang.trim().toLowerCase(),
      audioTitle: track.title.trim(),
      audioCodec: track.codec.trim().toLowerCase(),
      audioExternal: track.isExternal,
      subtitleDisabled: subtitleDisabled,
      subLang: subLang,
      subTitle: subTitle,
      subCodec: subCodec,
      subExternal: subExternal,
    );
  }

  /// 根据上一话选择的字幕（或 `null` 表示手动关闭字幕）生成新记忆状态。
  CrossEpisodeTrackMemory rememberSubtitle(MpvTrackInfo? track) {
    if (track == null) {
      return CrossEpisodeTrackMemory(
        audioLang: audioLang,
        audioTitle: audioTitle,
        audioCodec: audioCodec,
        audioExternal: audioExternal,
        subtitleDisabled: true,
      );
    }
    return CrossEpisodeTrackMemory(
      audioLang: audioLang,
      audioTitle: audioTitle,
      audioCodec: audioCodec,
      audioExternal: audioExternal,
      subtitleDisabled: false,
      subLang: track.lang.trim().toLowerCase(),
      subTitle: track.title.trim(),
      subCodec: track.codec.trim().toLowerCase(),
      subExternal: track.isExternal,
    );
  }

  /// 是否有可参考的音轨偏好。
  bool get hasAudioPreference =>
      (audioLang ?? '').isNotEmpty ||
      (audioTitle ?? '').isNotEmpty ||
      (audioCodec ?? '').isNotEmpty;

  /// 是否有可参考的字幕偏好。
  bool get hasSubtitlePreference =>
      subtitleDisabled ||
      (subLang ?? '').isNotEmpty ||
      (subTitle ?? '').isNotEmpty ||
      (subCodec ?? '').isNotEmpty;

  /// 在新一话音轨列表中匹配最符合跨话记忆的音轨；若无显式偏好则回退至 [fallback]。
  MpvTrackInfo? resolveAudioTrack(
    List<MpvTrackInfo> tracks, {
    TrackPreferences fallback = const TrackPreferences(),
  }) {
    final candidates = tracks
        .where((t) => t.type == MpvTrackType.audio)
        .toList();
    if (candidates.isEmpty) return null;
    if (!hasAudioPreference) {
      return fallback.pickBestAudioTrack(candidates);
    }

    MpvTrackInfo? best;
    var bestScore = -1;
    for (final t in candidates) {
      var s = 0;
      if ((audioTitle ?? '').isNotEmpty &&
          t.title.trim().toLowerCase() == audioTitle!.toLowerCase()) {
        s += 120;
      }
      if ((audioLang ?? '').isNotEmpty &&
          t.lang.trim().toLowerCase() == audioLang) {
        s += 90;
      }
      if ((audioCodec ?? '').isNotEmpty &&
          t.codec.trim().toLowerCase() == audioCodec) {
        s += 60;
      }
      if (t.isExternal == audioExternal) {
        s += 25;
      }
      if (s > bestScore) {
        bestScore = s;
        best = t;
      }
    }
    return bestScore >= 60 ? best : fallback.pickBestAudioTrack(candidates);
  }

  /// 在新一话字幕列表中匹配最符合跨话记忆的字幕；若用户上一话关了字幕则返回 null。
  MpvTrackInfo? resolveSubtitleTrack(
    List<MpvTrackInfo> tracks, {
    TrackPreferences fallback = const TrackPreferences(),
  }) {
    if (subtitleDisabled) return null;
    final candidates = tracks
        .where((t) => t.type == MpvTrackType.subtitle)
        .toList();
    if (candidates.isEmpty) return null;
    if (!hasSubtitlePreference) {
      return fallback.pickBestSubtitleTrack(candidates);
    }

    MpvTrackInfo? best;
    var bestScore = -1;
    for (final t in candidates) {
      var s = 0;
      if ((subTitle ?? '').isNotEmpty &&
          t.title.trim().toLowerCase() == subTitle!.toLowerCase()) {
        s += 140;
      }
      if ((subLang ?? '').isNotEmpty &&
          t.lang.trim().toLowerCase() == subLang) {
        s += 95;
      }
      if ((subCodec ?? '').isNotEmpty &&
          t.codec.trim().toLowerCase() == subCodec) {
        s += 50;
      }
      if (t.isExternal == subExternal) {
        s += 25;
      }
      if (s > bestScore) {
        bestScore = s;
        best = t;
      }
    }
    return bestScore >= 50 ? best : fallback.pickBestSubtitleTrack(candidates);
  }
}
