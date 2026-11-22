import 'package:konata/domain/formatting/detail_title_typography.dart';
import 'package:konata/domain/models/work.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetailTitleTypographyResolver 视觉当量与四档分级', () {
    test('短标题、标准标题、较长标题与超长轻改标题准确落入四档并调校字重与字距', () {
      const shortWork = Work(id: 'w_86', title: '86', originalTitle: '86-エイティシックス-');
      final shortSpec = DetailTitleTypographyResolver.resolve(
        work: shortWork,
        viewport: DetailTitleViewportProfile.desktop,
      );
      expect(shortSpec.tier, DetailTitleTier.short);
      expect(shortSpec.scriptProfile, DetailTitleScriptProfile.latinDominant);
      expect(shortSpec.titleFontSize, 44.0);
      expect(shortSpec.titleWeight, 760.0);
      expect(shortSpec.titleLetterSpacing, -0.4);
      expect(shortSpec.showHairline, isTrue);
      // 非中文主标题允许展示原名副标题
      expect(shortSpec.subtitleText, '86-エイティシックス-');

      const shortCn = Work(id: 'w_kon', title: '轻音', originalTitle: 'けいおん!');
      final shortCnSpec = DetailTitleTypographyResolver.resolve(
        work: shortCn,
        viewport: DetailTitleViewportProfile.desktop,
      );
      expect(shortCnSpec.tier, DetailTitleTier.short);
      expect(shortCnSpec.scriptProfile, DetailTitleScriptProfile.cjkDominant);
      expect(shortCnSpec.titleLetterSpacing, 1.6);
      // 中文主标题不展示日文原名副标题
      expect(shortCnSpec.subtitleText, isNull);

      const standardWork = Work(
        id: 'w_frieren',
        title: '葬送的芙莉莲',
        originalTitle: '葬送のフリーレン',
      );
      final standardSpec = DetailTitleTypographyResolver.resolve(
        work: standardWork,
        viewport: DetailTitleViewportProfile.desktop,
      );
      expect(standardSpec.tier, DetailTitleTier.standard);
      expect(standardSpec.titleFontSize, 38.0);
      expect(standardSpec.titleWeight, 720.0);
      expect(standardSpec.subtitleText, isNull);

      const longWork = Work(id: 'w_aot', title: '进击的巨人 最终季 完结篇');
      final longSpec = DetailTitleTypographyResolver.resolve(
        work: longWork,
        viewport: DetailTitleViewportProfile.desktop,
      );
      expect(longSpec.tier, DetailTitleTier.long);
      expect(longSpec.titleFontSize, 32.0);
      expect(longSpec.titleWeight, 690.0);

      const ultraLongWork = Work(
        id: 'w_suka',
        title: '末日时在做什么？有没有空？可以来拯救吗？',
        originalTitle: '終末なにしてますか？ 忙しいですか？ 救ってもらっていいですか？',
      );
      final ultraSpec = DetailTitleTypographyResolver.resolve(
        work: ultraLongWork,
        viewport: DetailTitleViewportProfile.desktop,
      );
      expect(ultraSpec.tier, DetailTitleTier.ultraLong);
      expect(ultraSpec.titleFontSize, 27.0);
      expect(ultraSpec.titleWeight, 660.0);
      expect(ultraSpec.titleMaxLines, 3);
      expect(ultraSpec.subtitleText, isNull);
    });

    test('条件语义眉标仅在非重复的剧场版、OVA、特别篇与续季时生成', () {
      const movieNoPrefix = Work(
        id: 'm1',
        title: '千与千寻',
        tmdbMediaType: TmdbMediaType.movie,
      );
      expect(DetailTitleTypographyResolver.resolveKicker(movieNoPrefix), '剧场版');

      const movieWithPrefix = Work(
        id: 'm2',
        title: '剧场版 间谍过家家 代号：白',
        tmdbMediaType: TmdbMediaType.movie,
      );
      expect(DetailTitleTypographyResolver.resolveKicker(movieWithPrefix), isNull);

      const season1 = Work(
        id: 's1',
        title: '葬送的芙莉莲',
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      expect(DetailTitleTypographyResolver.resolveKicker(season1), isNull);

      const season2NoSuffix = Work(
        id: 's2',
        title: 'Wake Up, Girls! 新章',
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      expect(
        DetailTitleTypographyResolver.resolveKicker(season2NoSuffix),
        '第 2 季',
      );

      const season2WithSuffix = Work(
        id: 's2_dup',
        title: '关于我转生变成史莱姆这档事 第二季',
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      expect(
        DetailTitleTypographyResolver.resolveKicker(season2WithSuffix),
        isNull,
      );

      // 手机横屏紧凑模式与伴随文字模式不显示眉标
      final landscapeSpec = DetailTitleTypographyResolver.resolve(
        work: movieNoPrefix,
        viewport: DetailTitleViewportProfile.phoneLandscape,
      );
      expect(landscapeSpec.kickerText, isNull);
      expect(landscapeSpec.titleMaxLines, lessThanOrEqualTo(2));

      final companionSpec = DetailTitleTypographyResolver.resolve(
        work: movieNoPrefix,
        viewport: DetailTitleViewportProfile.desktop,
        mode: DetailTitlePresentationMode.companionText,
      );
      expect(companionSpec.kickerText, isNull);
      expect(companionSpec.showHairline, isFalse);
      expect(companionSpec.titleFontSize, lessThanOrEqualTo(18.0));
    });
  });
}
