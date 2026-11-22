import 'package:konata/domain/matching/directory_grouper.dart';
import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/fanart_models.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/models/tmdb_models.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/scraping/bangumi_models.dart';
import 'package:konata/domain/scraping/directory_analyzer.dart';
import 'package:konata/domain/scraping/work_matcher.dart' as legacy;
import 'package:konata/domain/scraping/work_wall_eligibility.dart';
import 'package:flutter_test/flutter_test.dart';

GroupedWorkFolder _makeFolder({
  String path = 'Anime/OVA Show',
  List<int> mainEpisodes = const [1],
  Map<String, EpisodeSlotAssignment> slots = const {},
  DirectoryInventory? inventory,
  String? localPosterPath,
}) {
  return GroupedWorkFolder(
    folderRelativePath: path,
    folderName: path.split('/').last,
    cleanTitle: 'OVA Show',
    mainEpisodeNumbers: mainEpisodes,
    slotAssignmentsByPath: slots,
    inventory: inventory,
    localPosterPath: localPosterPath,
    variants: const [
      MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 'src_local',
        relativePath: 'Anime/OVA Show/[Sub] OVA Show [01].mkv',
        fileName: '[Sub] OVA Show [01].mkv',
        fileSize: 1024,
      ),
    ],
  );
}

void main() {
  group('WorkWallEligibility 独立上墙资格、背景图质量与跨源身份规则', () {
    test('含正片的 Bangumi 独立条目（高置信与无硬冲突中置信）具备独立上墙资格', () {
      final folder = _makeFolder(mainEpisodes: const [1, 2]);
      const subject = BangumiSubjectCandidate(
        id: 50001,
        name: 'OVA Show',
        nameCn: '测试 OVA',
        posterUrl: 'https://lain.bgm.tv/pic/cover/l/ova.jpg',
      );
      const highBgm = ScoredBangumiCandidate(
        subject: subject,
        score: 72.0,
        reasons: ['exact title'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: highBgm,
          bangumiTier: legacy.MatchTier.high,
          hasValidCover: true,
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: highBgm,
          bangumiTier: legacy.MatchTier.high,
          hasValidCover: false,
        ),
        isFalse,
      );

      const medOk = ScoredBangumiCandidate(
        subject: subject,
        score: 42.0,
        reasons: ['title match'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: medOk,
          bangumiTier: legacy.MatchTier.medium,
          hasValidCover: true,
        ),
        isTrue,
      );

      const medConflict = ScoredBangumiCandidate(
        subject: subject,
        score: 45.0,
        reasons: ['year conflict'],
      );
      expect(
        WorkWallEligibility.shouldPromoteBangumiOnly(
          folder: folder,
          bestBangumi: medConflict,
          bangumiTier: legacy.MatchTier.medium,
          hasValidCover: true,
        ),
        isFalse,
      );
    });

    test('防误拆红线：0 正片纯特典/NCOP/PV/CM 目录及未拆合集绝不晋升独立海报卡片', () {
      final extraOnlyFolder = _makeFolder(
        path: 'Anime/Show/SPs',
        mainEpisodes: const [],
        localPosterPath: r'D:\Anime\Show\SPs\poster.jpg',
        slots: const {
          'Anime/Show/SPs/NCOP01.mkv': EpisodeSlotAssignment(
            category: EpisodeCategory.extra,
            seasonNumber: 0,
            extraType: ExtraKind.ncop,
          ),
        },
      );
      expect(WorkWallEligibility.hasMainPlayableContent(extraOnlyFolder), isFalse);
      expect(
        WorkWallEligibility.shouldPromoteCoverFallback(
          folder: extraOnlyFolder,
          coverPath: extraOnlyFolder.localPosterPath,
        ),
        isFalse,
      );

      final anthologyInv = DirectoryInventory.synthetic(
        folder: 'Anime/Collection',
        title: 'Collection',
        main: [LogicalItem('1', 'Show A', 1, 1)],
        shape: WorkShape.anthology,
        titleHints: const ['Show A', 'Show B'],
      );
      final anthologyFolder = _makeFolder(
        mainEpisodes: const [1, 2],
        inventory: anthologyInv,
        localPosterPath: r'D:\Anime\Collection\folder.jpg',
      );
      expect(WorkWallEligibility.hasMainPlayableContent(anthologyFolder), isFalse);
      expect(
        WorkWallEligibility.shouldPromoteCoverFallback(
          folder: anthologyFolder,
          coverPath: anthologyFolder.localPosterPath,
        ),
        isFalse,
      );
    });

    test('TMDB 背景图低清（720p）或带文字时触发 Fanart 1080p 升级，1080p 无字则保持 TMDB', () {
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: null,
          candidateBackdrops: const [],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_720p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_720p.jpg',
              isoLanguage: null,
              width: 1280,
              height: 720,
            ),
          ],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_texted.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_texted.jpg',
              isoLanguage: 'en',
              width: 1920,
              height: 1080,
            ),
          ],
        ),
        isTrue,
      );
      expect(
        WorkWallEligibility.isTmdbBackdropSuboptimal(
          selectedBackdropPath: '/bg_clean_1080p.jpg',
          candidateBackdrops: const [
            TmdbArtworkImage(
              filePath: '/bg_clean_1080p.jpg',
              isoLanguage: null,
              width: 1920,
              height: 1080,
            ),
          ],
        ),
        isFalse,
      );
    });

    test('跨来源身份键严格区分同系列不同季，并稳定聚合同作品不同来源卡片', () {
      const s1Local = Work(
        id: 'w_local_s1',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      const s1Webdav = Work(
        id: 'w_dav_s1',
        title: '葬送的芙莉莲',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 1,
      );
      const s2Local = Work(
        id: 'w_local_s2',
        title: '葬送的芙莉莲 第2季',
        tmdbId: 209867,
        tmdbMediaType: TmdbMediaType.tv,
        matchedSeason: 2,
      );
      expect(
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Local),
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Webdav),
      );
      expect(
        WorkWallEligibility.buildCrossSourceIdentityKey(s1Local),
        isNot(WorkWallEligibility.buildCrossSourceIdentityKey(s2Local)),
      );
    });
  });

  group('ClearLogoRanker 跨源排序与 FanartUrlHelper 预览地址转换', () {
    test('Fanart 高清日文徽标严格胜过 TMDB 英文徽标；简中高清最高优先', () {
      final ranked = ClearLogoRanker.sortMerged(const [
        RankedLogoCandidate(
          filePath: '/tmdb_en_hd.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'en',
          isoCountry: 'US',
          isHd: true,
          width: 1500,
          voteAverage: 9.2,
          voteCount: 40,
        ),
        RankedLogoCandidate(
          filePath: 'https://assets.fanart.tv/fanart/tv/424536/hdtvlogo/ja.png',
          source: LogoSourceKind.fanart,
          isoLanguage: 'ja',
          isHd: true,
          likes: 6,
        ),
        RankedLogoCandidate(
          filePath: 'https://assets.fanart.tv/fanart/tv/424536/clearlogo/ja_sd.png',
          source: LogoSourceKind.fanart,
          isoLanguage: 'ja',
          isHd: false,
          likes: 20,
        ),
      ]);
      expect(ranked.first.filePath, contains('/hdtvlogo/ja.png'));
      expect(ranked[1].filePath, contains('/clearlogo/ja_sd.png'));
      expect(ranked[2].filePath, '/tmdb_en_hd.png');

      final withZh = ClearLogoRanker.sortMerged([
        ...ranked,
        const RankedLogoCandidate(
          filePath: '/tmdb_zh_cn.png',
          source: LogoSourceKind.tmdb,
          isoLanguage: 'zh',
          isoCountry: 'CN',
          isHd: true,
          width: 900,
          voteAverage: 7.0,
        ),
      ]);
      expect(withZh.first.filePath, '/tmdb_zh_cn.png');
    });

    test('FanartUrlHelper 精确完成 /fanart/ 与 /preview/ 双向转换并升级 HTTPS', () {
      const rawHttp = 'http://assets.fanart.tv/fanart/tv/424536/tvposter/p1.jpg';
      final preview = FanartUrlHelper.toPreviewUrl(rawHttp);
      expect(
        preview,
        'https://assets.fanart.tv/preview/tv/424536/tvposter/p1.jpg',
      );
      expect(
        FanartUrlHelper.toOriginalUrl(preview),
        'https://assets.fanart.tv/fanart/tv/424536/tvposter/p1.jpg',
      );
    });
  });
}
