import 'package:engine_scraping/engine_scraping.dart';
import 'package:test/test.dart';

MediaVariant _variant(
  String id,
  String relativePath, {
  AssetKind kind = AssetKind.cdAlbum,
}) {
  final fileName = relativePath.split('/').last;
  return MediaVariant(
    id: id,
    workId: 'w_1',
    sourceId: 'src_1',
    relativePath: relativePath,
    fileName: fileName,
    assetKind: kind,
    fileSize: 2048,
  );
}

void main() {
  group('特典 / CD / Scan 二级分类与双决策规则测试', () {
    test('专辑下平铺的 Scans 保留专辑分类，不与作品根扫图混淆', () {
      final scans = [
        _variant(
          'a',
          'Work/CDs/[241218] Release Sigh (flac+webp)/Scans/01.webp',
          kind: AssetKind.scanGallery,
        ),
        _variant(
          'b',
          'Work/CDs/[241218] Release Sigh (flac+webp)/Scans/02.webp',
          kind: AssetKind.scanGallery,
        ),
        _variant(
          'c',
          'Work/CDs/[240828] Watch Me/Scans/01.webp',
          kind: AssetKind.scanGallery,
        ),
        _variant('d', 'Work/Scans/01.webp', kind: AssetKind.scanGallery),
      ];
      final summary = SupplementarySubclassifier.groupScanVariants(scans);
      expect(summary.chips, hasLength(2));
      expect(
        summary.byVariantId['a']?.volumeKey,
        summary.byVariantId['b']?.volumeKey,
      );
      expect(
        summary.byVariantId['a']?.volumeKey,
        isNot(summary.byVariantId['c']?.volumeKey),
      );
      expect(summary.byVariantId['a']?.chipLabel, contains('Release Sigh'));
      expect(summary.byVariantId['d']?.volumeKey, isNull);
      final singleGroup = SupplementarySubclassifier.groupScanVariants(
        scans.take(2).toList(),
      );
      expect(singleGroup.chips, hasLength(1));
      expect(singleGroup.hasMultipleSubdirs, isFalse);
      expect(singleGroup.byVariantId, hasLength(2));

      final mixedGroups = SupplementarySubclassifier.groupScanVariants([
        scans.first,
        scans.last,
      ]);
      expect(mixedGroups.chips, hasLength(1));
      expect(mixedGroups.hasMultipleSubdirs, isTrue);
      expect(mixedGroups.byVariantId, hasLength(2));

      final empty = SupplementarySubclassifier.groupScanVariants([]);
      expect(empty.chips, isEmpty);
      expect(empty.hasMultipleSubdirs, isFalse);
    });
    test('决策点 1：文件名显式类型语义优先于父目录；纯歌名回退父目录 MV', () {
      // MVs 目录下带メイキング显式语义 -> 归入 sp 特别篇与花絮
      final makingKind = SupplementarySubclassifier.classifyExtraVideo(
        fileName: '実写MVメイキング映像.mkv',
        relativePath: 'MVs/実写MVメイキング映像.mkv',
      );
      expect(makingKind, ExtraKind.sp);

      final cloudExtraType = CloudMediaClassifier.detectExtraKind(
        relativePath: 'Show/MVs/実写MVメイキング映像.mkv',
        fileName: '実写MVメイキング映像.mkv',
      );
      expect(cloudExtraType, ExtraKind.sp);

      // 纯歌名无显式类型关键词 -> 回退按父级子目录 MV 归入 mv
      final pureSongMv = SupplementarySubclassifier.classifyExtraVideo(
        fileName: 'Garden ~(K)NoW_NAME~.mkv',
        relativePath: 'Extra/MV/Garden ~(K)NoW_NAME~.mkv',
      );
      expect(pureSongMv, ExtraKind.mv);

      // 显式 NCOP / PV / CM / Menu 文件名优先级检验
      expect(
        SupplementarySubclassifier.classifyExtraVideo(
          fileName: '[NCOP01] 1080p.mkv',
          relativePath: 'SPs/[NCOP01] 1080p.mkv',
        ),
        ExtraKind.ncop,
      );
      expect(
        SupplementarySubclassifier.classifyExtraVideo(
          fileName: 'BD発売告知CM 15s.mkv',
          relativePath: 'Extras/SP/BD発売告知CM 15s.mkv',
        ),
        ExtraKind.pv,
      );
      expect(
        SupplementarySubclassifier.classifyExtraVideo(
          fileName: 'PV02_Ver.mkv',
          relativePath: 'Specials/PV02_Ver.mkv',
        ),
        ExtraKind.pv,
      );
      expect(
        SupplementarySubclassifier.classifyExtraVideo(
          fileName: 'Menu Disc1.mkv',
          relativePath: 'SPs/Menu Disc1.mkv',
        ),
        ExtraKind.menu,
      );
    });

    test('决策点 2：CD 附带视频按单曲/专辑短名自动拼接标题且跨碟不误合并', () {
      const singlePathA =
          'CDs/[EAC][190529] TVアニメ「鬼滅の刃」OPテーマ「紅蓮華」- LiSA [FLAC+DVD]/BDMV/STREAM/00000.m2ts';
      const singlePathB =
          'CDs/[EAC][191211] ED「from the edge」/DVD/VIDEO_TS/VTS_01_1.vob';
      const multiDiscVideo1 =
          'CDs/[EAC][201014] Single「炎」[FLAC+BD]/BD/BDMV/STREAM/00000.m2ts';
      const multiDiscVideo2 =
          'CDs/[EAC][201014] Single「炎」[FLAC+BD]/BD/BDMV/STREAM/00001.m2ts';
      const namedVideo = 'CDs/[190529] 紅蓮華 [FLAC]/DVD/Making_Video.mkv';

      final rawEntries = <({String fileName, String relativePath})>[
        (fileName: '00000.m2ts', relativePath: singlePathA),
        (fileName: 'VTS_01_1.vob', relativePath: singlePathB),
        (fileName: '00000.m2ts', relativePath: multiDiscVideo1),
        (fileName: '00001.m2ts', relativePath: multiDiscVideo2),
        (fileName: 'Making_Video.mkv', relativePath: namedVideo),
      ];

      // 单张碟仅 1 个无意义流文件 -> "<单曲短名> · 特典映像"
      expect(
        SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
          fileName: '00000.m2ts',
          relativePath: singlePathA,
          workVideoEntries: rawEntries,
        ),
        'TVアニメ「鬼滅の刃」OPテーマ「紅蓮華」- LiSA · 特典映像',
      );
      expect(
        SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
          fileName: 'VTS_01_1.vob',
          relativePath: singlePathB,
          workVideoEntries: rawEntries,
        ),
        'ED「from the edge」 · 特典映像',
      );

      // 同碟含多个流文件 -> "<单曲短名> / 00000"
      expect(
        SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
          fileName: '00000.m2ts',
          relativePath: multiDiscVideo1,
          workVideoEntries: rawEntries,
        ),
        'Single「炎」 / 00000',
      );
      expect(
        SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
          fileName: '00001.m2ts',
          relativePath: multiDiscVideo2,
          workVideoEntries: rawEntries,
        ),
        'Single「炎」 / 00001',
      );

      // 有明确含义文件名 -> "<单曲短名> / <原文件名去后缀>"
      expect(
        SupplementarySubclassifier.formatCdBundledExtraTitleFromRaw(
          fileName: 'Making_Video.mkv',
          relativePath: namedVideo,
          workVideoEntries: rawEntries,
        ),
        '紅蓮華 / Making_Video',
      );

      // 验证 resolveExtraSlotAssignment 对不同单曲同名 00000.m2ts 产出不同槽位防误合并
      final slotA = resolveExtraSlotAssignment(
        fileName: '00000.m2ts',
        relativePath: singlePathA,
        parsed: BdripParser.parseFileName(
          '00000.m2ts',
          relativePath: singlePathA,
        ),
        workVideoEntries: rawEntries,
      );
      final slotB = resolveExtraSlotAssignment(
        fileName: '00000.m2ts',
        relativePath: multiDiscVideo1,
        parsed: BdripParser.parseFileName(
          '00000.m2ts',
          relativePath: multiDiscVideo1,
        ),
        workVideoEntries: rawEntries,
      );
      expect(slotA.extraTitleHint, 'TVアニメ「鬼滅の刃」OPテーマ「紅蓮華」- LiSA · 特典映像');
      expect(slotB.extraTitleHint, 'Single「炎」 / 00000');
      expect(slotA.unnumberedStemKey, isNot(equals(slotB.unnumberedStemKey)));
    });

    test('CD EAC 专辑短名提炼、多碟子目录穿透与 Scan 平铺/分卷二级筛选判断', () {
      final cdVariants = <MediaVariant>[
        _variant(
          'c1',
          'CDs/[EAC][120829] Original Soundtrack [FLAC+CUE]/CD1/01.flac',
        ),
        _variant(
          'c2',
          'CDs/[EAC][120829] Original Soundtrack [FLAC+CUE]/CD2/01.flac',
        ),
        _variant('c3', 'CDs/[220105] OP Single「残響散歌」(24bit 96kHz)/01.flac'),
      ];
      final cdSummary = SupplementarySubclassifier.groupCdVariants(cdVariants);
      expect(cdSummary.chips.length, 2);
      expect(cdSummary.chips.first.label, 'Original Soundtrack');
      expect(cdSummary.chips.first.count, 2);
      expect(cdSummary.chips.last.label, 'OP Single「残響散歌」');
      expect(cdSummary.byVariantId['c1']?.directSubdirShort, 'CD1');
      expect(cdSummary.byVariantId['c2']?.directSubdirShort, 'CD2');

      // 单层平铺 Scans/ 返回空分组列表（UI 据此隐藏二级筛选栏）
      final flatScans = <MediaVariant>[
        _variant('s1', 'Scans/001.jpg', kind: AssetKind.scanGallery),
        _variant('s2', 'Scans/002.jpg', kind: AssetKind.scanGallery),
      ];
      final flatSummary = SupplementarySubclassifier.groupScanVariants(
        flatScans,
      );
      expect(flatSummary.chips, isEmpty);
      expect(flatSummary.hasMultipleSubdirs, isFalse);

      // 分卷 Vol.1 / Booklet 自动拆出二级筛选标签
      final volScans = <MediaVariant>[
        _variant('sv1', 'Scans/Vol.1/01.png', kind: AssetKind.scanGallery),
        _variant('sv2', 'Scans/Booklet/02.png', kind: AssetKind.scanGallery),
      ];
      final volSummary = SupplementarySubclassifier.groupScanVariants(volScans);
      expect(volSummary.chips.length, 2);
      expect(volSummary.hasMultipleSubdirs, isTrue);
    });
  });
}
