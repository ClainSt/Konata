import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_detail/feature_detail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DetailTitleTypographyResolver 无徽标排版预算', () {
    test('超长外文或中文字标题在窄屏下自动阶梯缩字并启用紧凑字重', () {
      final shortPlan = DetailTitleTypographyResolver.resolve(
        title: '轻音少女',
        originalTitle: 'けいおん！',
        maxWidth: 640,
        isCompactViewport: false,
      );
      final longPlan = DetailTitleTypographyResolver.resolve(
        title: '末日时在做什么？有没有空？可以来拯救吗？第一季完整纪念版',
        originalTitle: '終末なにしてますか？忙しいですか？救ってもらっていいですか？',
        maxWidth: 280,
        isCompactViewport: true,
      );

      expect(shortPlan.primaryFontSize, greaterThan(longPlan.primaryFontSize));
      expect(shortPlan.secondaryText, 'けいおん！');
      expect(longPlan.useCondensedWeight, isTrue);
      expect(longPlan.primaryMaxLines, 2);
      expect(longPlan.primaryFontSize, greaterThanOrEqualTo(20.0));
    });

    test('空白标题兜底未命名且同名副标题自动去重省略', () {
      final blankPlan = DetailTitleTypographyResolver.resolve(
        title: '   ',
        originalTitle: null,
        maxWidth: 400,
        isCompactViewport: false,
      );
      final dupPlan = DetailTitleTypographyResolver.resolve(
        title: 'Frieren',
        originalTitle: 'frieren',
        maxWidth: 400,
        isCompactViewport: false,
      );

      expect(blankPlan.primaryText, '未命名作品');
      expect(dupPlan.secondaryText, isNull);
    });
  });

  group('ClearLogoLegibility 透明徽标自适应可读性评估', () {
    Uint8List buildSolidRgba(int width, int height, int r, int g, int b, int a) {
      final out = Uint8List(width * height * 4);
      for (var i = 0; i < width * height; i++) {
        final offset = i * 4;
        out[offset] = r;
        out[offset + 1] = g;
        out[offset + 2] = b;
        out[offset + 3] = a;
      }
      return out;
    }

    test('纯白透明徽标在亮灰背景上开启暗角强化衬底', () {
      final rgba = buildSolidRgba(8, 8, 250, 250, 250, 255);
      final stats = ClearLogoLegibility.analyzeRgbaBytes(rgba, 8, 8);
      final result = ClearLogoLegibility.evaluateForSurface(
        stats: stats,
        estimatedBackground: const Color(0xFFCCCCCC),
      );

      expect(stats.opaquePixelCount, 64);
      expect(stats.brightPixelRatio, closeTo(1.0, 0.01));
      expect(result.needsDarkScrim, isTrue);
      expect(result.needsLightScrim, isFalse);
      expect(result.recommendedScrimStrength, greaterThan(0.5));
    });

    test('深墨黑透明徽标在暗黑背景上开启柔光托底并返回预览浅色光晕', () {
      final rgba = buildSolidRgba(8, 8, 12, 12, 16, 255);
      final stats = ClearLogoLegibility.analyzeRgbaBytes(rgba, 8, 8);
      final result = ClearLogoLegibility.evaluateForSurface(
        stats: stats,
        estimatedBackground: const Color(0xFF0B0C10),
      );
      final glow = ClearLogoLegibility.resolvePreviewGlowTint(
        stats: stats,
        isDarkSurface: true,
      );

      expect(stats.darkPixelRatio, closeTo(1.0, 0.01));
      expect(result.needsLightScrim, isTrue);
      expect(result.needsDarkScrim, isFalse);
      expect(glow, isNotNull);
    });
  });

  group('ArtworkCropMath 固定比例裁切几何引擎', () {
    test('初始居中选框严格锁定 2:3 与 16:9 宽高比且移动绝不越界', () {
      final posterCrop = ArtworkCropMath.initialMaxCenteredRect(
        imageWidth: 1920,
        imageHeight: 1080,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      final pxPoster = ArtworkCropMath.toSourcePixelRect(
        posterCrop,
        imageWidth: 1920,
        imageHeight: 1080,
      );
      expect(
        pxPoster.width / pxPoster.height,
        closeTo(ArtworkCropMath.posterAspectRatio, 0.01),
      );

      final moved = ArtworkCropMath.moveRect(
        posterCrop,
        deltaNormX: 2.0,
        deltaNormY: -1.0,
      );
      expect(moved.left, closeTo(1.0 - moved.width, 1e-6));
      expect(moved.top, 0.0);

      final resized = ArtworkCropMath.resizeFromCorner(
        posterCrop,
        corner: ArtworkCropCorner.bottomRight,
        pointerNormX: posterCrop.left + posterCrop.width * 0.6,
        pointerNormY: posterCrop.top + posterCrop.height * 0.6,
        imageWidth: 1920,
        imageHeight: 1080,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      final pxResized = ArtworkCropMath.toSourcePixelRect(
        resized,
        imageWidth: 1920,
        imageHeight: 1080,
      );
      expect(
        pxResized.width / pxResized.height,
        closeTo(ArtworkCropMath.posterAspectRatio, 0.02),
      );

      final zoomed = ArtworkCropMath.zoomAroundCenter(
        resized,
        zoomScale: 0.75,
        imageWidth: 1920,
        imageHeight: 1080,
        aspectRatio: ArtworkCropMath.posterAspectRatio,
      );
      expect(zoomed.left, greaterThanOrEqualTo(0.0));
      expect(zoomed.bottom, lessThanOrEqualTo(1.0 + 1e-6));
    });
  });

  group('MediaDisplayFormatter 技术标签与文件体积规整', () {
    test('正确格式化字节大小、版本技术徽章与媒体源短名', () {
      expect(MediaDisplayFormatter.formatBytes(1536 * 1024 * 1024), '1.5 GB');
      expect(MediaDisplayFormatter.fileExtensionUpper('ep01.flac'), 'FLAC');
      expect(
        MediaDisplayFormatter.formatSourceKindShort(MediaSourceKind.webdav),
        'WebDAV',
      );
      const variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 's1',
        relativePath: 'Season 1/01.mkv',
        fileName: '[VCB-Studio] Ep01 [v2].mkv',
        fileSize: 850 * 1024 * 1024,
        releaseGroup: 'VCB-Studio [v2]',
        resolution: '1080p',
        videoCodec: 'HEVC',
        bitDepth: '10bit',
        audioCodec: 'FLAC',
      );
      expect(
        MediaDisplayFormatter.buildVariantTechTags(variant),
        <String>['VCB-Studio', '1080p', 'HEVC', '10bit', 'FLAC'],
      );
    });
  });

  group('SeriesMemberLabelResolver 系列摘要与多形态筛选', () {
    final gundamWorks = <Work>[
      const Work(
        id: 'g_01',
        tmdbId: 1001,
        tmdbMediaType: TmdbMediaType.tv,
        title: '机动战士高达',
        originalTitle: '機動戦士ガンダム',
        year: 1979,
        seriesOrder: 1,
        seriesLabel: '第 1 季',
        scrapeStatus: ScrapeStatus.matched,
      ),
      const Work(
        id: 'g_02',
        tmdbId: 1002,
        tmdbMediaType: TmdbMediaType.movie,
        title: '机动战士高达 逆袭的夏亚',
        originalTitle: '機動戦士ガンダム 逆襲のシャア',
        year: 1988,
        seriesOrder: 2,
        seriesLabel: '第 1 季',
        scrapeStatus: ScrapeStatus.matched,
      ),
      const Work(
        id: 'g_03',
        tmdbId: 1003,
        tmdbMediaType: TmdbMediaType.tv,
        title: '机动战士高达 0080 口袋里的战争 OVA',
        originalTitle: '機動戦士ガンダム0080 ポケットの中の戦争',
        year: 1989,
        seriesOrder: 3,
        seriesLabel: '第 1 季',
        scrapeStatus: ScrapeStatus.matched,
      ),
      for (var i = 4; i <= 26; i++)
        Work(
          id: 'g_${i.toString().padLeft(2, '0')}',
          tmdbId: 1000 + i,
          tmdbMediaType: TmdbMediaType.tv,
          title: '机动战士高达 衍生TV第 $i 部超长标题示例',
          year: 1990 + i,
          seriesOrder: i,
          scrapeStatus: ScrapeStatus.matched,
        ),
    ];

    test('入口胶囊展示简洁系列摘要，不强加第1季前缀也不重复截断超长标题', () {
      final group = SeriesGroup(
        id: 'ser_gundam',
        title: '高达系列',
        createdAt: DateTime.utc(2025, 1, 1),
        updatedAt: DateTime.utc(2025, 1, 1),
      );
      final ovaWork = gundamWorks[2];
      final movieWork = gundamWorks[1];

      expect(
        SeriesMemberLabelResolver.resolveCapsuleSummary(
          members: gundamWorks,
          activeWork: ovaWork,
          seriesGroup: group,
          compact: false,
        ),
        '高达系列 · 26 部',
      );
      expect(
        SeriesMemberLabelResolver.resolveCapsuleSummary(
          members: gundamWorks,
          activeWork: ovaWork,
          seriesGroup: SeriesGroup(
            id: 'ser_long',
            title: '超长系列名称超过十四个字时绝不重复显示或者截断',
            createdAt: DateTime.utc(2025, 1, 1),
            updatedAt: DateTime.utc(2025, 1, 1),
          ),
          compact: true,
        ),
        '系列 26部',
      );

      expect(
        SeriesMemberLabelResolver.resolveMemberLabel(
          ovaWork,
          members: gundamWorks,
          seriesGroup: group,
        ),
        'OVA',
      );
      expect(
        SeriesMemberLabelResolver.resolveMemberLabel(
          movieWork,
          members: gundamWorks,
          seriesGroup: group,
        ),
        '剧场版',
      );
      expect(
        SeriesMemberLabelResolver.resolveMemberLabel(
          gundamWorks[0],
          members: gundamWorks,
          seriesGroup: group,
        ),
        isNot(contains('第 1 季')),
      );
    });

    test('同质多季 TV 保留规范季号标签，并正确执行全部/TV/剧场版/OVA 筛选与搜索', () {
      const season1 = Work(
        id: 'tv_s1',
        tmdbId: 2001,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
        seriesOrder: 1,
        title: '某番剧 第一季',
        scrapeStatus: ScrapeStatus.matched,
      );
      const season2 = Work(
        id: 'tv_s2',
        tmdbId: 2001,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
        seriesOrder: 2,
        title: '某番剧 第二季',
        scrapeStatus: ScrapeStatus.matched,
      );
      expect(
        SeriesMemberLabelResolver.isHeterogeneousSeries(const [season1, season2]),
        isFalse,
      );
      expect(
        SeriesMemberLabelResolver.resolveMemberLabel(
          season1,
          members: const [season1, season2],
        ),
        startsWith('第 1 季'),
      );

      final counts = SeriesMemberLabelResolver.countByFilter(gundamWorks);
      expect(counts[SeriesWorkMediaFilter.all], 26);
      expect(counts[SeriesWorkMediaFilter.movie], 1);
      expect(counts[SeriesWorkMediaFilter.ova], 1);
      expect(counts[SeriesWorkMediaFilter.tv], 24);

      expect(
        SeriesMemberLabelResolver.filterMembers(
          members: gundamWorks,
          mediaFilter: SeriesWorkMediaFilter.movie,
        ).single.id,
        'g_02',
      );
      expect(
        SeriesMemberLabelResolver.filterMembers(
          members: gundamWorks,
          mediaFilter: SeriesWorkMediaFilter.all,
          query: '口袋里的战争',
        ).single.id,
        'g_03',
      );
    });
  });
}
