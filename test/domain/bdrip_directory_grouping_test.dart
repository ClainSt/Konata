import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:konata/application/providers/library_providers.dart';
import 'package:konata/application/scraping/scrape_work_persister.dart';
import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/parsing/title_normalizer.dart';
import 'package:konata/infrastructure/database/drift_library_repository.dart';
import 'package:konata/infrastructure/database/konata_database.dart';
import 'package:konata/presentation/library/poster_card.dart';
import 'package:konata/presentation/theme/konata_theme.dart';

Future<Uint8List> _dummyImageLoader(
  String? path, {
  int? targetWidth,
  TmdbImageSize? imageSize,
}) async {
  return Uint8List(0);
}

void main() {
  group('BDRip 目录抗碎裂与单集多版本计算测试', () {
    test('《86》复杂 BDRip 合集（含 Vol.01~08 / SPs / VVCL-1867 / 广播剧 / Scan）仅聚合为 1 部作品', () {
      const root = '[VCB-Studio] 86 -Eighty Six- [Ma10p_1080p]';

      final files = <ScannedFileInput>[
        // 正片 1~23 集放在根目录
        for (var ep = 1; ep <= 23; ep++)
          ScannedFileInput(
            relativePath:
                '$root/[VCB-Studio] 86 -Eighty Six- [${ep.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
            fileName:
                '[VCB-Studio] 86 -Eighty Six- [${ep.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
            fileSize: 1024,
            assetKind: AssetKind.video,
          ),
        // Vol.01 ~ Vol.08 特典视频
        for (var vol = 1; vol <= 8; vol++)
          ScannedFileInput(
            relativePath:
                '$root/Vol.0$vol/[VCB-Studio] 86 [NCOP0$vol][Ma10p_1080p].mkv',
            fileName: '[VCB-Studio] 86 [NCOP0$vol][Ma10p_1080p].mkv',
            fileSize: 1024,
            assetKind: AssetKind.video,
          ),
        // SPs 子目录
        const ScannedFileInput(
          relativePath: '$root/SPs/[VCB-Studio] 86 [SP01][Ma10p_1080p].mkv',
          fileName: '[VCB-Studio] 86 [SP01][Ma10p_1080p].mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath: '$root/SPs/Menu/[VCB-Studio] 86 [Menu01].mkv',
          fileName: '[VCB-Studio] 86 [Menu01].mkv',
          fileSize: 1024,
          assetKind: AssetKind.video,
        ),
        // VVCL-1867 CD 音轨与扫图
        const ScannedFileInput(
          relativePath: '$root/VVCL-1867/01. Avid.flac',
          fileName: '01. Avid.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        // 官方广播特典目录样例（AAC 音频格式）
        const ScannedFileInput(
          relativePath:
              '$root/[210322] Official Radio Program (aac)/Radio #01.aac',
          fileName: 'Radio #01.aac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        // 无损特典专辑目录样例（FLAC 与扫图）
        const ScannedFileInput(
          relativePath:
              '$root/[210602] 86 Original Soundtrack (flac+webp)/Disc 1/01.flac',
          fileName: '01.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        // 特别篇广播剧 CD 样例标签
        const ScannedFileInput(
          relativePath: '$root/SPECIAL DRAMA CD/Drama 01.flac',
          fileName: 'Drama 01.flac',
          fileSize: 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        // Scans / Booklet 图片
        const ScannedFileInput(
          relativePath: '$root/Scans/Booklet_01.jpg',
          fileName: 'Booklet_01.jpg',
          fileSize: 1024,
          assetKind: AssetKind.scanGallery,
        ),
      ];

      final groups = DirectoryGrouper.groupFiles(
        sourceId: 'src_bd',
        files: files,
      );

      expect(groups.length, 1);
      expect(groups.first.folderRelativePath, root);
      expect(groups.first.cleanTitle, contains('86'));
      expect(groups.first.variants.length, files.length);
    });

    test('无父级视频作品的顶层孤立广播剧/CD 目录将被忽略，不会生成幽灵卡片', () {
      final groups = DirectoryGrouper.groupFiles(
        sourceId: 'src_audio_only',
        files: const [
          ScannedFileInput(
            relativePath: '[210322] Official Radio Program (flac)/01.flac',
            fileName: '01.flac',
            fileSize: 1024,
            assetKind: AssetKind.cdAlbum,
          ),
          ScannedFileInput(
            relativePath: 'VVCL-1867/cover.jpg',
            fileName: 'cover.jpg',
            fileSize: 1024,
            assetKind: AssetKind.scanGallery,
          ),
        ],
      );
      expect(groups, isEmpty);
    });

    testWidgets('89 个资产但每集仅 1 个版本时，海报卡片绝不显示「89版本」角标', (tester) async {
      final item = WorkLibraryItem(
        work: const Work(
          id: 'w_86',
          title: '86 -不存在的战区-',
          scrapeStatus: ScrapeStatus.matched,
        ),
        variants: List.generate(
          89,
          (i) => MediaVariant(
            id: 'v_$i',
            workId: 'w_86',
            sourceId: 'src_1',
            relativePath: '86/ep_$i.mkv',
            fileName: 'ep_$i.mkv',
            fileSize: 1024,
          ),
        ),
        episodeCount: 23,
        maxEpisodeVariantCount: 1,
        releaseGroups: const ['VCB-Studio'],
      );

      expect(item.hasMultiVariants, isFalse);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 180,
                height: 280,
                child: PosterCard(
                  item: item,
                  imageLoader: _dummyImageLoader,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('版本'), findsNothing);
      expect(find.text('89版本'), findsNothing);

      final multiItem = WorkLibraryItem(
        work: item.work,
        variants: item.variants,
        episodeCount: 23,
        maxEpisodeVariantCount: 2,
        releaseGroups: item.releaseGroups,
      );

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: KonataTheme.darkTheme(),
            home: Scaffold(
              body: SizedBox(
                width: 180,
                height: 280,
                child: PosterCard(
                  item: multiItem,
                  imageLoader: _dummyImageLoader,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(find.text('2版本'), findsOneWidget);
    });

    test('《86》全量归集并持久化：SPs 下无标签视频强制归类为特典，且抑制标题数字 86 误判', () async {
      const root = '[VCB-Studio] 86 -Eighty Six- [Ma10p_1080p]';
      final files = <ScannedFileInput>[
        for (var ep = 1; ep <= 11; ep++)
          ScannedFileInput(
            relativePath:
                '$root/[VCB-Studio] 86 -Eighty Six- [${ep.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
            fileName:
                '[VCB-Studio] 86 -Eighty Six- [${ep.toString().padLeft(2, '0')}][Ma10p_1080p][x265_flac].mkv',
            fileSize: 900 * 1024 * 1024,
            assetKind: AssetKind.video,
          ),
        // SPs 目录内各种命名（包括不带 SP 标签的普通文件名 01.mkv、Menu、NCOP）
        const ScannedFileInput(
          relativePath: '$root/SPs/01.mkv',
          fileName: '01.mkv',
          fileSize: 80 * 1024 * 1024,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath: '$root/SPs/[VCB-Studio] 86 -Eighty Six- [NCOP1][Ma10p_1080p].mkv',
          fileName: '[VCB-Studio] 86 -Eighty Six- [NCOP1][Ma10p_1080p].mkv',
          fileSize: 90 * 1024 * 1024,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath: '$root/Vol.01/SPs/Menu_Disc1.mkv',
          fileName: 'Menu_Disc1.mkv',
          fileSize: 45 * 1024 * 1024,
          assetKind: AssetKind.video,
        ),
        const ScannedFileInput(
          relativePath: '$root/VVCL-1867/01.flac',
          fileName: '01.flac',
          fileSize: 20 * 1024 * 1024,
          assetKind: AssetKind.cdAlbum,
        ),
        const ScannedFileInput(
          relativePath: '$root/Scans/Booklet_01.webp',
          fileName: 'Booklet_01.webp',
          fileSize: 2 * 1024 * 1024,
          assetKind: AssetKind.scanGallery,
        ),
      ];

      final groups = DirectoryGrouper.groupFiles(
        sourceId: 'src_86',
        files: files,
      );
      expect(groups.length, 1);

      final db = KonataDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repo = DriftLibraryRepository(db);
      await repo.upsertMediaSource(
        const MediaSource(
          id: 'src_86',
          kind: MediaSourceKind.local,
          label: 'Local',
          location: 'D:/Anime',
        ),
      );

      const work = Work(
        id: 'w_86_persisted',
        title: '86 -不存在的战区-',
        scrapeStatus: ScrapeStatus.matched,
      );
      await repo.upsertWork(work);

      final persister = ScrapeWorkPersister(repo);
      await persister.syncEpisodesAndVariants(
        work: work,
        folder: groups.first,
        tmdbEpisodes: const [],
      );

      final episodes = await repo.getEpisodesByWork(work.id);
      final mainEps =
          episodes.where((e) => e.category == EpisodeCategory.main).toList();
      final extraEps =
          episodes.where((e) => e.category == EpisodeCategory.extra).toList();

      expect(mainEps.length, 11);
      expect(mainEps.any((e) => e.episodeNumber == 86), isFalse);
      expect(extraEps.length, 3);

      final variants = await repo.getVariantsByWork(work.id);
      expect(variants.length, files.length);
    });

    test('TitleNormalizer.expandQueryVariants 生成中英副标题与扩展检索词', () {
      final variants = TitleNormalizer.expandQueryVariants('86 -Eighty Six-');
      expect(variants, contains('86'));
      expect(variants, contains('Eighty Six'));
    });
  });
}
