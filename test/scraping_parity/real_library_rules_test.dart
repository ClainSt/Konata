import 'package:ccplayer/domain/matching/directory_grouper.dart';
import 'package:ccplayer/domain/matching/supplementary_folder_rules.dart';
import 'package:ccplayer/domain/models/episode.dart';
import 'package:ccplayer/domain/models/media_variant.dart';
import 'package:ccplayer/domain/models/tmdb_models.dart';
import 'package:ccplayer/domain/models/work.dart';
import 'package:ccplayer/domain/scraping/cloud_media_file_classifier.dart';
import 'package:ccplayer/domain/scraping/directory_analyzer.dart';
import 'package:ccplayer/domain/scraping/personal_filename_parser.dart';
import 'package:ccplayer/domain/scraping/scrape_domain_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

const _mb = 1024 * 1024;

ScannedFileInput _video(String path, {int size = 900 * _mb}) =>
    ScannedFileInput(
      relativePath: path,
      fileName: path.split('/').last,
      fileSize: size,
      assetKind: AssetKind.video,
    );

List<GroupedWorkFolder> _group(List<ScannedFileInput> files) =>
    ScrapeDomainAdapter.groupAndSplitFiles(sourceId: 's', files: files);

EpisodeSlotAssignment _slot(GroupedWorkFolder g, String path) =>
    g.slotAssignmentsByPath[path]!;

String _ep(int n) => n.toString().padLeft(2, '0');

/// 基于真实媒体库命名样例固化的刮削规则回归：作品根目录锚定、系列主干拆分、方括号片名提取、
/// 片名特典词遮蔽、显式 ID 类型择优与搜索词净化。
void main() {
  group('作品根目录锚定', () {
    test('显式 ID 目录下的压制组目录、字幕语言目录与特典目录全部归入同一作品', () {
      const root = '动画-多作品/盖塔机器人系列/盖塔机器人G (1975) {tmdb-39369}';
      final groups = _group([
        for (var i = 1; i <= 3; i++) ...[
          _video('$root/CHS/[Group] Getter Robo G - ${_ep(i)}.mkv'),
          _video('$root/CHT/[Group] Getter Robo G - ${_ep(i)}.mkv'),
        ],
        _video(
          '$root/Creditless OPEDs/[Group] Getter Robo G NCOP.mkv',
          size: 80 * _mb,
        ),
        _video(
          '$root/NC Ver/[Group] Getter Robo G - 01 NC.mkv',
          size: 80 * _mb,
        ),
        _video(
          '$root/BD Menu/[Group] Getter Robo G Menu 01.mkv',
          size: 20 * _mb,
        ),
      ]);
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.explicitTmdbId, 39369);
      expect(g.cleanTitle, '盖塔机器人G');
      expect(g.year, 1975);
      expect(
        _slot(g, '$root/CHS/[Group] Getter Robo G - 02.mkv').episodeNumber,
        2,
      );
      for (final extra in [
        '$root/Creditless OPEDs/[Group] Getter Robo G NCOP.mkv',
        '$root/NC Ver/[Group] Getter Robo G - 01 NC.mkv',
        '$root/BD Menu/[Group] Getter Robo G Menu 01.mkv',
      ]) {
        expect(_slot(g, extra).category, EpisodeCategory.extra, reason: extra);
      }
    });

    test('「标题 (年份)」目录同样锚定，分卷发布目录不再碎片化成独立作品', () {
      const root = '动画-单作品/公主的管弦乐团 (2025)';
      final groups = _group([
        for (var v = 1; v <= 2; v++)
          for (var i = 1; i <= 3; i++)
            _video(
              '$root/[FLsnow & WBX][Princession_Orchestra][BDrip][vol.$v]/'
              '[FLsnow & WBX][Princession_Orchestra][${_ep((v - 1) * 3 + i)}][BDrip].mp4',
            ),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.cleanTitle, '公主的管弦乐团');
      expect(groups.single.mainEpisodeNumbers, [1, 2, 3, 4, 5, 6]);
    });

    test('显式 ID 目录内的剧场版与 OVA 不再拆成独立作品，而是作为该作品特典', () {
      const root = '动画-单作品/与魔共舞 (2015) {tmdb-68768}';
      final groups = _group([
        for (var i = 1; i <= 12; i++)
          _video(
            '$root/[Shiniori-Raws] Dance with Devils - ${_ep(i)} (BD 1920x1080 x265 10bit FLAC).mkv',
          ),
        _video(
          '$root/[Shiniori-Raws] Dance with Devils Fortuna The Movie (BD 1920x1080 x265 10bit FLAC).mkv',
          size: 4000 * _mb,
        ),
      ]);
      expect(groups, hasLength(1));
      final g = groups.single;
      expect(g.explicitTmdbId, 68768);
      expect(
        _slot(
          g,
          '$root/[Shiniori-Raws] Dance with Devils Fortuna The Movie (BD 1920x1080 x265 10bit FLAC).mkv',
        ).category,
        EpisodeCategory.extra,
      );
    });

    test('「标题 (年份)」目录名写明 `A & B` 时仍允许拆分为多部作品', () {
      const root = '动画-多作品/FLCL作品集/FLCL Alternative & FLCL Progressive (2018)';
      final groups = _group([
        _video(
          '$root/[Group] FLCL Alternative [BDRip 1080p].mkv',
          size: 4000 * _mb,
        ),
        _video(
          '$root/[Group] FLCL Progressive [BDRip 1080p].mkv',
          size: 4000 * _mb,
        ),
      ]);
      expect(groups.map((g) => g.cleanTitle).toSet(), {
        'FLCL Alternative',
        'FLCL Progressive',
      });
    });
  });

  group('同目录多系列主干拆分', () {
    test('同组同规模的 `Title` 与 `Title II` 按续季拆分，而非合并为同集多版本', () {
      const root = '动画-多作品/花牌情缘 (2011) {tmdb-45247}';
      String s1(int i) =>
          '$root/[Liuyun&VCB-S&ANK-Raws] Chihayafuru [${_ep(i)}][Hi10p_1080p][x264_flac].mkv';
      String s2(int i) =>
          '$root/[Liuyun&VCB-S&ANK-Raws] Chihayafuru II [${_ep(i)}][Hi10p_1080p][x264_flac].mkv';
      final g = _group([
        for (var i = 1; i <= 12; i++) ...[_video(s1(i)), _video(s2(i))],
      ]).single;
      expect(_slot(g, s1(3)).seasonNumber, 1);
      expect(_slot(g, s2(3)).seasonNumber, 2);
      expect(_slot(g, s2(3)).episodeNumber, 3);
    });

    test('全方括号命名的 `R2` 与感叹号数量区分续季', () {
      const geass = 'Code Geass 反叛的鲁路修 (2006) {tmdb-31724}';
      String r1(int i) =>
          '$geass/[ANK&VCB-Studio][Code Geass Lelouch of the Rebellion][${_ep(i)}][Hi10P FLAC][1920X1080].mkv';
      String r2(int i) =>
          '$geass/[ANK&VCB-Studio][Code Geass Lelouch of the Rebellion R2][${_ep(i)}][Hi10P FLAC][1920X1080].mkv';
      final g1 = _group([
        for (var i = 1; i <= 10; i++) ...[_video(r1(i)), _video(r2(i))],
      ]).single;
      expect(_slot(g1, r1(5)).seasonNumber, 1);
      expect(_slot(g1, r2(5)).seasonNumber, 2);

      const maou = '打工吧！！魔王大人 S1+S2 (2022) {tmdb-45997}';
      String m1(int i) =>
          '$maou/[ReinForce] Hataraku Maou-sama! - ${_ep(i)} (BDRip 1920x1080 x264 FLAC).mkv';
      String m2(int i) =>
          '$maou/[ReinForce] Hataraku Maou-sama!! - ${_ep(i)} (BDRip 1920x1080 x264 FLAC).mkv';
      final g2 = _group([
        for (var i = 1; i <= 10; i++) ...[_video(m1(i)), _video(m2(i))],
      ]).single;
      expect(_slot(g2, m1(4)).seasonNumber, 1);
      expect(_slot(g2, m2(4)).seasonNumber, 2);
    });

    test('体积显著偏小的同组衍生短篇降级为特典，不同压制组的同集仍是多版本', () {
      const root = '动画-单作品/猎龙飞船 (2020) {tmdb-94000}';
      String main(int i) =>
          '$root/[AI-Raws] 空挺ドラゴンズ #${_ep(i)} (BD HEVC 1920x1080 FLAC)[DC123664].mkv';
      String mini(int i) =>
          '$root/[AI-Raws] 空挺ドラゴンズ MIKA’S キッチン #${_ep(i)} (BD HEVC 1920x1080 FLAC)[D120525B].mkv';
      String other(int i) =>
          '$root/[OtherSub] Kuutei Dragons - ${_ep(i)} [1080p].mkv';
      final g = _group([
        for (var i = 1; i <= 12; i++) ...[
          _video(main(i), size: 1000 * _mb),
          _video(mini(i), size: 80 * _mb),
          _video(other(i), size: 400 * _mb),
        ],
      ]).single;
      expect(_slot(g, mini(2)).category, EpisodeCategory.extra);
      expect(_slot(g, main(2)).category, EpisodeCategory.main);
      expect(_slot(g, other(2)).category, EpisodeCategory.main);
      expect(_slot(g, other(2)).episodeNumber, 2);
      expect(_slot(g, other(2)).seasonNumber, _slot(g, main(2)).seasonNumber);
    });

    test('连续剧目录里无集号的剧场版、OVA 降级为特典', () {
      const root = '动画-多作品/机动战士高达 作品集/∀高达 (1999) {tmdb-37546}';
      final movie =
          '$root/[VCB-Studio] Turn A Gundam I Earth Light [Ma10p_1080p][x265_flac].mkv';
      final g = _group([
        for (var i = 1; i <= 12; i++)
          _video(
            '$root/[VCB-Studio] Turn A Gundam [${_ep(i)}][Ma10p_1080p][x265_flac].mkv',
          ),
        _video(movie, size: 6000 * _mb),
      ]).single;
      expect(_slot(g, movie).category, EpisodeCategory.extra);
      expect(g.mainEpisodeNumbers, List.generate(12, (i) => i + 1));
    });
  });

  group('文件名解析', () {
    test('全方括号命名取片名块而不是首块压制组名', () {
      expect(
        PersonalFilenameParser.extractAnimeSearchKeyword(
          '[ANK&VCB-Studio][Code Geass Lelouch of the Rebellion R2][01][Hi10P FLAC][1920X1080].mkv',
        ),
        'Code Geass Lelouch of the Rebellion R2',
      );
      expect(
        PersonalFilenameParser.extractAnimeSearchKeyword(
          '[FLsnow_feat.AO][Aikatsu_on_Parade!][BD_01][AVC_FLAC].mkv',
        ),
        'Aikatsu on Parade!',
      );
      expect(
        PersonalFilenameParser.extractAnimeSearchKeyword(
          '[philosophy-raws][Soukyuu no Fafner][01][on air format][BDRIP][Hi10P FLAC][1424X1068].mkv',
        ),
        'Soukyuu no Fafner',
      );
      expect(
        PersonalFilenameParser.bracketSeriesQualifier(
          '[FLsnow][Violet_Evergarden][Understanding_Violet_Evergarden_in_5_Minutes][01][BDRIP][HEVC_FLAC].mkv',
        ),
        'Understanding Violet Evergarden in 5 Minutes',
      );
    });

    test('联合发布与带组名后缀的标签识别为压制组，含 & 的普通片名不受影响', () {
      for (final tag in [
        'ANK&VCB-Studio',
        'FLsnow_feat.AO',
        'IrizaRaws',
        'Sakurato.sub',
        '北宇治字幕组',
        '粉羽社&超古代',
        'Nekomoe kissaten&LoliHouse',
      ]) {
        expect(
          PersonalFilenameParser.isReleaseGroupTag(tag),
          isTrue,
          reason: tag,
        );
      }
      for (final title in ['TIGER & BUNNY', 'Carole & Tuesday', 'Quick Draw']) {
        expect(
          PersonalFilenameParser.isReleaseGroupTag(title),
          isFalse,
          reason: title,
        );
      }
    });

    test('`[BD_01]` 补零编号是正片集号，`#12.5` 为半集特典，`おまけ` 为特典', () {
      expect(
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
          '',
          '[FLsnow_feat.AO][Aikatsu_on_Parade!][BD_14][AVC_FLAC].mkv',
        ),
        14,
      );
      expect(
        CloudMediaFileClassifier.isStrongSupplementary(
          '',
          '[AI-Raws] ファンタシースターオンライン2 エピソード・オラクル #12.5 (BD HEVC 1920x1080 FLAC)[828B8DC3].mkv',
        ),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isClearlySupplementary(
          '',
          '[AI-Raws] 天地無用！魎皇鬼 #13おまけ (BD HEVC 1448x1056 FLAC)[8A21B9C4].mkv',
        ),
        isTrue,
      );
    });

    test('日文罗马音单词 `Ii` 不再被当作第 2 季', () {
      expect(
        DirectoryAnalyzer.splitSeasonSuffix(
          'Raise wa Tanin ga Ii',
          isSeries: true,
        ).season,
        isNull,
      );
      expect(
        DirectoryAnalyzer.splitSeasonSuffix(
          'Mob Psycho 100 II',
          isSeries: true,
        ).season,
        2,
      );
    });

    test('片名自带特典词（`Shomin Sample`）时正片不被误降级为样片', () {
      const root = '动画-单作品/我被绑架到贵族女校当“庶民样本” (2015) {tmdb-64552}';
      final ep =
          '$root/[VCB-Studio] Shomin Sample [01][Ma10p_1080p][x265_2flac].mkv';
      final ncop =
          '$root/[VCB-Studio] Shomin Sample [NCOP][Ma10p_1080p][x265_flac].mkv';
      final g = _group([
        for (var i = 1; i <= 12; i++)
          _video(
            '$root/[VCB-Studio] Shomin Sample [${_ep(i)}][Ma10p_1080p][x265_2flac].mkv',
          ),
        _video(ncop, size: 80 * _mb),
      ]).single;
      expect(_slot(g, ep).category, EpisodeCategory.main);
      expect(_slot(g, ncop).category, EpisodeCategory.extra);
    });
  });

  group('目录与搜索词', () {
    test('特典词元目录与全方括号分卷目录识别', () {
      for (final dir in [
        'NC Ver',
        'BD Menu',
        'PV&CM',
        'Non Credit',
        'Bonus DVD',
        'Special CD1',
      ]) {
        expect(
          CloudMediaFileClassifier.isSupplementarySubdirectory(dir),
          isTrue,
          reason: dir,
        );
      }
      expect(
        CloudMediaFileClassifier.isSupplementarySubdirectory(
          '[Snow-Raws] ToHeart 映像特典',
        ),
        isTrue,
      );
      expect(
        CloudMediaFileClassifier.isSupplementarySubdirectory('CHS'),
        isFalse,
      );
      expect(
        CloudMediaFileClassifier.isSupplementarySubdirectory('Mofu Mofu!'),
        isFalse,
      );
      expect(
        SupplementaryFolderRules.isSupplementarySegment(
          '[FLsnow_feat.AO][Aikatsu_on_Parade!][BDrip_1]',
        ),
        isTrue,
      );
    });

    test('搜索词剔除压制组名、技术参数与画质标记', () {
      const root = '动画-多作品/摇曳露营△系列/电影 摇曳露营△ 1080P (2022)';
      final g = _group([
        _video(
          '$root/[Nekomoe kissaten][Yuru Camp Movie][BDRip 1080p HEVC-10bit FLAC].mkv',
          size: 8000 * _mb,
        ),
      ]).single;
      final queries = ScrapeDomainAdapter.buildSearchQueries(g);
      expect(g.cleanTitle, '电影 摇曳露营△');
      expect(queries, isNot(contains('Nekomoe kissaten')));
      expect(queries.where((q) => q.contains('1080')), isEmpty);
      expect(queries.where((q) => q == '电影'), isEmpty);
    });
  });

  group('显式 ID 类型择优', () {
    const tvRoot = '动画-单作品/16bit的感动 ANOTHER LAYER (2023) {tmdb-217512}';
    final series = _group([
      for (var i = 1; i <= 12; i++)
        _video(
          '$tvRoot/[SweetSub&VCB-Studio] 16bit Sensation Another Layer [${_ep(i)}][Ma10p_1080p][x265_flac].mkv',
        ),
    ]).single;
    const tv = TmdbWorkDetail(
      tmdbId: 217512,
      mediaType: TmdbMediaType.tv,
      title: '16bit的感动 ANOTHER LAYER',
      originalTitle: '16bit Sensation Another Layer',
      year: 2023,
    );
    const movie = TmdbWorkDetail(
      tmdbId: 217512,
      mediaType: TmdbMediaType.movie,
      title: 'Unrelated Documentary',
      year: 1998,
    );

    test('剧集目录在两侧同号条目都存在时选中标题一致的剧集', () {
      expect(series.isMovieHint, isFalse);
      expect(
        ScrapeDomainAdapter.chooseExplicitTypeCandidate(
          series,
          tv: tv,
          movie: movie,
        ).mediaType,
        TmdbMediaType.tv,
      );
    });

    test('电影提示错误时仍按标题与年份选回正确一侧', () {
      final misleading = GroupedWorkFolder(
        folderRelativePath: series.folderRelativePath,
        folderName: series.folderName,
        cleanTitle: series.cleanTitle,
        explicitTmdbId: series.explicitTmdbId,
        year: series.year,
        isMovieHint: true,
        variants: series.variants,
        inventory: series.inventory,
        titleHints: series.titleHints,
        fileHints: series.fileHints,
      );
      expect(
        ScrapeDomainAdapter.chooseExplicitTypeCandidate(
          misleading,
          tv: tv,
          movie: movie,
        ).mediaType,
        TmdbMediaType.tv,
      );
    });
  });
}
