import '../models/series_group.dart';
import '../models/work.dart';
import '../parsing/season_number_parser.dart';
import 'media_display_formatter.dart';

/// 详情页无徽标风格化标题的长度视觉档位。
enum DetailTitleTier {
  /// 极短凝练标题（如 2–4 字中文或短英文）。
  short,

  /// 标准平衡标题。
  standard,

  /// 较长副题或带季别标题。
  long,

  /// 超长轻改标题。
  ultraLong,
}

/// 详情页标题语种与字形分布画像（用于调校拉丁与汉字光学字距）。
enum DetailTitleScriptProfile {
  /// 汉字与日文假名占主导。
  cjkDominant,

  /// 拉丁字母与数字占主导。
  latinDominant,

  /// 中日与拉丁混排。
  mixed,
}

/// 详情页标题所在的端形态与视口规格档位。
enum DetailTitleViewportProfile {
  /// Windows 桌面宽屏全屏原画左下区。
  desktop,

  /// Android 平板横屏全屏原画左下区。
  tabletLandscape,

  /// Android 平板竖屏详情流或头图过渡区。
  tabletPortrait,

  /// Android 手机竖屏封面下方暗底区。
  phonePortrait,

  /// Android 手机横屏紧凑沉浸头图左下区。
  phoneLandscape,
}

/// 详情页文字标题块所承担的视觉角色模式。
enum DetailTitlePresentationMode {
  /// 无透明徽标时的主视觉铭牌替代态（或仅开启文字标题模式）。
  heroEmblem,

  /// 已有透明徽标且同时开启文字标题时的轻量伴随态。
  companionText,
}

/// 详情页风格化标题排版计算结果（纯领域不可变值对象）。
class DetailTitleTypographySpec {
  /// 创建排版规格对象。
  const DetailTitleTypographySpec({
    required this.tier,
    required this.scriptProfile,
    required this.mode,
    required this.viewport,
    required this.visualUnits,
    required this.titleFontSize,
    required this.minTitleFontSize,
    required this.titleWeight,
    required this.titleLetterSpacing,
    required this.titleLineHeight,
    required this.titleMaxLines,
    required this.maxWidth,
    required this.heightBudget,
    required this.subtitleText,
    required this.subtitleFontSize,
    required this.subtitleLetterSpacing,
    required this.kickerText,
    required this.kickerFontSize,
    required this.kickerLetterSpacing,
    required this.kickerBarWidth,
    required this.showHairline,
    required this.hairlineWidth,
    required this.hairlineThickness,
  });

  /// 命中的长度视觉档位。
  final DetailTitleTier tier;

  /// 语种与字形画像。
  final DetailTitleScriptProfile scriptProfile;

  /// 当前呈现模式（主视觉铭牌或伴随文字）。
  final DetailTitlePresentationMode mode;

  /// 所属视口形态档位。
  final DetailTitleViewportProfile viewport;

  /// 折算后的字符视觉当量宽度。
  final double visualUnits;

  /// 主标题起始字号（在容器过窄时允许软退档，不低于 [minTitleFontSize]）。
  final double titleFontSize;

  /// 主标题软退档的最小清晰字号底线。
  final double minTitleFontSize;

  /// 主标题连续可变字重（对应 `FontVariation('wght', ...)`）。
  final double titleWeight;

  /// 主标题光学字距。
  final double titleLetterSpacing;

  /// 主标题行高倍率。
  final double titleLineHeight;

  /// 主标题允许的最大行数。
  final int titleMaxLines;

  /// 标题块最大宽度上限。
  final double maxWidth;

  /// 主标题文本高度软预算（超出时触发向下微缩退档防过早截断）。
  final double heightBudget;

  /// 可选原名副标题文本（遵循中文标题不重复展示日文原名契约，无需展示时为 `null`）。
  final String? subtitleText;

  /// 副标题字号。
  final double subtitleFontSize;

  /// 副标题字距。
  final double subtitleLetterSpacing;

  /// 可选语义眉标文案（如 `剧场版`、`OVA`、`特别篇`、`第 2 季`；无需展示时为 `null`）。
  final String? kickerText;

  /// 眉标字号。
  final double kickerFontSize;

  /// 眉标字距。
  final double kickerLetterSpacing;

  /// 眉标左侧极细短横宽度。
  final double kickerBarWidth;

  /// 是否渲染主标题下方的极细水平渐隐装饰线。
  final bool showHairline;

  /// 极细水平渐隐装饰线宽度。
  final double hairlineWidth;

  /// 极细水平渐隐装饰线厚度。
  final double hairlineThickness;
}

/// 详情页无透明徽标风格化文字标题的纯领域排版计算器。
abstract final class DetailTitleTypographyResolver {
  static final RegExp _cjkOrFullWidthPattern = RegExp(
    r'[\u3000-\u303F\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]',
  );
  static final RegExp _upperOrDigitPattern = RegExp(r'[A-Z0-9]');
  static final RegExp _latinCharPattern = RegExp(r'[A-Za-z0-9]');
  static final RegExp _movieWordPattern = RegExp(
    r'(剧场版|劇場版|电影版|電影版|\bmovie\b|\bfilm\b|\bthe\s+movie\b)',
    caseSensitive: false,
  );
  static final RegExp _ovaWordPattern = RegExp(
    r'\b(?:ova|oad)\b',
    caseSensitive: false,
  );
  static final RegExp _specialWordPattern = RegExp(
    r'(特别篇|特別篇|番外篇|总集篇|總集篇|\bspecial\b|\bsp\b)',
    caseSensitive: false,
  );

  /// 估算标题的视觉当量长度（汉字/假名/全角记 `1.0`，大写/数字记 `0.62`，小写/半角标点记 `0.48`）。
  static double measureVisualUnits(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isEmpty) return 0.0;
    var units = 0.0;
    for (final rune in trimmed.runes) {
      final ch = String.fromCharCode(rune);
      if (_cjkOrFullWidthPattern.hasMatch(ch)) {
        units += 1.0;
      } else if (_upperOrDigitPattern.hasMatch(ch)) {
        units += 0.62;
      } else {
        units += 0.48;
      }
    }
    return units;
  }

  /// 判定标题的语种字形主导画像。
  static DetailTitleScriptProfile detectScriptProfile(String rawTitle) {
    final trimmed = rawTitle.trim();
    if (trimmed.isEmpty) return DetailTitleScriptProfile.cjkDominant;
    var cjkCount = 0;
    var latinCount = 0;
    for (final rune in trimmed.runes) {
      final ch = String.fromCharCode(rune);
      if (_cjkOrFullWidthPattern.hasMatch(ch)) {
        cjkCount++;
      } else if (_latinCharPattern.hasMatch(ch)) {
        latinCount++;
      }
    }
    if (cjkCount == 0 && latinCount > 0) {
      return DetailTitleScriptProfile.latinDominant;
    }
    if (latinCount == 0 || cjkCount >= latinCount) {
      return DetailTitleScriptProfile.cjkDominant;
    }
    if (cjkCount == 0) {
      return DetailTitleScriptProfile.cjkDominant;
    }
    return DetailTitleScriptProfile.mixed;
  }

  /// 按视觉当量长度映射四档展示排版分级。
  static DetailTitleTier classifyTier(double visualUnits) {
    if (visualUnits <= 4.5) return DetailTitleTier.short;
    if (visualUnits <= 10.0) return DetailTitleTier.standard;
    if (visualUnits <= 17.0) return DetailTitleTier.long;
    return DetailTitleTier.ultraLong;
  }

  /// 按严格克制原则提取可选语义眉标；普通单季剧集或主标题已包含同类关键词时返回 `null`。
  static String? resolveKicker(Work work) {
    final title = work.title.trim();
    if (title.isEmpty) return null;

    final kind = SeriesSeasonFormatter.classifyMember(work);
    switch (kind) {
      case SeriesMemberKind.movie:
        return _movieWordPattern.hasMatch(title) ? null : '剧场版';
      case SeriesMemberKind.ova:
        if (_ovaWordPattern.hasMatch(title)) return null;
        final combined = '${work.title} ${work.originalTitle ?? ''}'
            .toUpperCase();
        return combined.contains('OAD') ? 'OAD' : 'OVA';
      case SeriesMemberKind.special:
        return _specialWordPattern.hasMatch(title) ? null : '特别篇';
      case SeriesMemberKind.tvSeason:
        final season = work.matchedSeason;
        if (season != null && season >= 2) {
          final parsedInTitle = SeasonNumberParser.splitSeasonSuffix(
            title,
          ).seasonNumber;
          if (parsedInTitle == season || _titleMentionsSeason(title, season)) {
            return null;
          }
          return SeriesLabelPresets.seasonLabel(season);
        }
        return null;
    }
  }

  /// 解析面向指定作品、视口形态与呈现角色的完整排版参数。
  static DetailTitleTypographySpec resolve({
    required Work work,
    required DetailTitleViewportProfile viewport,
    DetailTitlePresentationMode mode = DetailTitlePresentationMode.heroEmblem,
    double? availableWidth,
  }) {
    final title = work.title.trim();
    final units = measureVisualUnits(title);
    final script = detectScriptProfile(title);
    final tier = classifyTier(units);

    final showSubtitle = MediaDisplayFormatter.shouldShowOriginalSubtitle(
      title: work.title,
      originalTitle: work.originalTitle,
    );
    final subtitleText = showSubtitle ? work.originalTitle!.trim() : null;
    final subtitleScript = subtitleText == null
        ? DetailTitleScriptProfile.cjkDominant
        : detectScriptProfile(subtitleText);

    final vp = _viewportMetrics(viewport, availableWidth: availableWidth);

    if (mode == DetailTitlePresentationMode.companionText) {
      final companionSize = (vp.standardFontSize * 0.48).clamp(14.0, 18.0);
      return DetailTitleTypographySpec(
        tier: tier,
        scriptProfile: script,
        mode: mode,
        viewport: viewport,
        visualUnits: units,
        titleFontSize: companionSize,
        minTitleFontSize: 13.5,
        titleWeight: 560.0,
        titleLetterSpacing: script == DetailTitleScriptProfile.latinDominant
            ? 0.0
            : 0.2,
        titleLineHeight: 1.24,
        titleMaxLines: 2,
        maxWidth: vp.maxWidth,
        heightBudget: companionSize * 1.24 * 2.2,
        subtitleText: subtitleText,
        subtitleFontSize: (vp.subtitleFontSize - 1.0).clamp(11.0, 13.0),
        subtitleLetterSpacing:
            subtitleScript == DetailTitleScriptProfile.latinDominant
            ? 0.5
            : 0.3,
        kickerText: null,
        kickerFontSize: vp.kickerFontSize,
        kickerLetterSpacing: 1.6,
        kickerBarWidth: vp.kickerBarWidth,
        showHairline: false,
        hairlineWidth: 0,
        hairlineThickness: 0,
      );
    }

    final double tierFontSize = switch (tier) {
      DetailTitleTier.short => vp.shortFontSize,
      DetailTitleTier.standard => vp.standardFontSize,
      DetailTitleTier.long => vp.longFontSize,
      DetailTitleTier.ultraLong => vp.ultraLongFontSize,
    };

    final double titleWeight = switch (tier) {
      DetailTitleTier.short => 760.0,
      DetailTitleTier.standard => 720.0,
      DetailTitleTier.long => 690.0,
      DetailTitleTier.ultraLong => 660.0,
    };

    final double letterSpacing = switch ((tier, script)) {
      (DetailTitleTier.short, DetailTitleScriptProfile.latinDominant) => -0.4,
      (DetailTitleTier.short, DetailTitleScriptProfile.mixed) => 0.8,
      (DetailTitleTier.short, DetailTitleScriptProfile.cjkDominant) => 1.6,
      (DetailTitleTier.standard, DetailTitleScriptProfile.latinDominant) =>
        -0.5,
      (DetailTitleTier.standard, DetailTitleScriptProfile.mixed) => 0.2,
      (DetailTitleTier.standard, DetailTitleScriptProfile.cjkDominant) => 0.6,
      (DetailTitleTier.long, DetailTitleScriptProfile.latinDominant) => -0.4,
      (DetailTitleTier.long, _) => 0.2,
      (DetailTitleTier.ultraLong, DetailTitleScriptProfile.latinDominant) =>
        -0.2,
      (DetailTitleTier.ultraLong, _) => 0.0,
    };

    final double lineHeight = switch (tier) {
      DetailTitleTier.short => 1.08,
      DetailTitleTier.standard => 1.14,
      DetailTitleTier.long => 1.18,
      DetailTitleTier.ultraLong => 1.22,
    };

    final int maxLines = switch (tier) {
      DetailTitleTier.short =>
        viewport == DetailTitleViewportProfile.phonePortrait ? 2 : 1,
      DetailTitleTier.standard => 2,
      DetailTitleTier.long => 2,
      DetailTitleTier.ultraLong => vp.ultraLongMaxLines,
    };

    final kickerText = vp.allowKicker ? resolveKicker(work) : null;
    final kickerIsLatin =
        kickerText != null &&
        detectScriptProfile(kickerText) == DetailTitleScriptProfile.latinDominant;

    return DetailTitleTypographySpec(
      tier: tier,
      scriptProfile: script,
      mode: mode,
      viewport: viewport,
      visualUnits: units,
      titleFontSize: tierFontSize,
      minTitleFontSize: vp.minFontSize,
      titleWeight: titleWeight,
      titleLetterSpacing: letterSpacing,
      titleLineHeight: lineHeight,
      titleMaxLines: maxLines,
      maxWidth: vp.maxWidth,
      heightBudget: vp.heightBudget,
      subtitleText: subtitleText,
      subtitleFontSize: vp.subtitleFontSize,
      subtitleLetterSpacing:
          subtitleScript == DetailTitleScriptProfile.latinDominant ? 0.8 : 0.4,
      kickerText: kickerText,
      kickerFontSize: vp.kickerFontSize,
      kickerLetterSpacing: kickerIsLatin ? 2.2 : 1.6,
      kickerBarWidth: vp.kickerBarWidth,
      showHairline: true,
      hairlineWidth: vp.hairlineWidth,
      hairlineThickness: vp.hairlineThickness,
    );
  }

  static bool _titleMentionsSeason(String title, int season) {
    final normalized = title.toLowerCase();
    if (normalized.contains('season $season') ||
        normalized.contains('s$season') ||
        normalized.contains('第$season季') ||
        normalized.contains('第 $season 季')) {
      return true;
    }
    const cnDigits = <int, String>{
      2: '二',
      3: '三',
      4: '四',
      5: '五',
      6: '六',
      7: '七',
      8: '八',
      9: '九',
    };
    final cn = cnDigits[season];
    if (cn != null &&
        (title.contains('第$cn季') || title.contains('第$cn部'))) {
      return true;
    }
    return false;
  }

  static _ViewportTypographyPreset _viewportMetrics(
    DetailTitleViewportProfile viewport, {
    double? availableWidth,
  }) {
    final boundedW = availableWidth != null && availableWidth.isFinite
        ? availableWidth
        : null;
    switch (viewport) {
      case DetailTitleViewportProfile.desktop:
        return _ViewportTypographyPreset(
          shortFontSize: 44.0,
          standardFontSize: 38.0,
          longFontSize: 32.0,
          ultraLongFontSize: 27.0,
          minFontSize: 23.0,
          subtitleFontSize: 13.5,
          kickerFontSize: 11.0,
          kickerBarWidth: 14.0,
          hairlineWidth: 56.0,
          hairlineThickness: 1.5,
          maxWidth: boundedW != null && boundedW < 480.0 ? boundedW : 480.0,
          heightBudget: 112.0,
          ultraLongMaxLines: 3,
          allowKicker: true,
        );
      case DetailTitleViewportProfile.tabletLandscape:
        final limit = boundedW != null
            ? (boundedW * 0.56).clamp(300.0, 460.0)
            : 460.0;
        return _ViewportTypographyPreset(
          shortFontSize: 40.0,
          standardFontSize: 34.0,
          longFontSize: 29.0,
          ultraLongFontSize: 24.0,
          minFontSize: 21.0,
          subtitleFontSize: 13.0,
          kickerFontSize: 11.0,
          kickerBarWidth: 14.0,
          hairlineWidth: 52.0,
          hairlineThickness: 1.5,
          maxWidth: limit,
          heightBudget: 104.0,
          ultraLongMaxLines: 3,
          allowKicker: true,
        );
      case DetailTitleViewportProfile.tabletPortrait:
        final limit = boundedW != null && boundedW < 540.0 ? boundedW : 540.0;
        return _ViewportTypographyPreset(
          shortFontSize: 36.0,
          standardFontSize: 30.0,
          longFontSize: 26.0,
          ultraLongFontSize: 22.0,
          minFontSize: 20.0,
          subtitleFontSize: 12.5,
          kickerFontSize: 10.5,
          kickerBarWidth: 12.0,
          hairlineWidth: 48.0,
          hairlineThickness: 1.5,
          maxWidth: limit,
          heightBudget: 92.0,
          ultraLongMaxLines: 2,
          allowKicker: true,
        );
      case DetailTitleViewportProfile.phonePortrait:
        final limit = boundedW ?? 440.0;
        return _ViewportTypographyPreset(
          shortFontSize: 30.0,
          standardFontSize: 25.0,
          longFontSize: 22.0,
          ultraLongFontSize: 19.0,
          minFontSize: 18.0,
          subtitleFontSize: 12.0,
          kickerFontSize: 10.5,
          kickerBarWidth: 12.0,
          hairlineWidth: 40.0,
          hairlineThickness: 1.0,
          maxWidth: limit,
          heightBudget: 86.0,
          ultraLongMaxLines: 3,
          allowKicker: true,
        );
      case DetailTitleViewportProfile.phoneLandscape:
        final limit = boundedW != null
            ? (boundedW * 0.60).clamp(220.0, 360.0)
            : 360.0;
        return _ViewportTypographyPreset(
          shortFontSize: 26.0,
          standardFontSize: 23.0,
          longFontSize: 20.0,
          ultraLongFontSize: 18.0,
          minFontSize: 17.0,
          subtitleFontSize: 11.5,
          kickerFontSize: 10.0,
          kickerBarWidth: 10.0,
          hairlineWidth: 36.0,
          hairlineThickness: 1.0,
          maxWidth: limit,
          heightBudget: 54.0,
          ultraLongMaxLines: 2,
          allowKicker: false,
        );
    }
  }
}

class _ViewportTypographyPreset {
  const _ViewportTypographyPreset({
    required this.shortFontSize,
    required this.standardFontSize,
    required this.longFontSize,
    required this.ultraLongFontSize,
    required this.minFontSize,
    required this.subtitleFontSize,
    required this.kickerFontSize,
    required this.kickerBarWidth,
    required this.hairlineWidth,
    required this.hairlineThickness,
    required this.maxWidth,
    required this.heightBudget,
    required this.ultraLongMaxLines,
    required this.allowKicker,
  });

  final double shortFontSize;
  final double standardFontSize;
  final double longFontSize;
  final double ultraLongFontSize;
  final double minFontSize;
  final double subtitleFontSize;
  final double kickerFontSize;
  final double kickerBarWidth;
  final double hairlineWidth;
  final double hairlineThickness;
  final double maxWidth;
  final double heightBudget;
  final int ultraLongMaxLines;
  final bool allowKicker;
}
