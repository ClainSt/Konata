import 'package:engine_scraping/engine_scraping.dart';
import 'package:test/test.dart';

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

    test('显式 ID 目录内捆绑的明确大型独立剧场版拆分为独立作品，TV 主簇保留原 ID', () {
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
      expect(groups, hasLength(2));
      final tvGroup = groups.firstWhere((g) => g.explicitTmdbId == 68768);
      final movieGroup = groups.firstWhere((g) => g.explicitTmdbId == null);
      expect(tvGroup.mainEpisodeNumbers, List.generate(12, (i) => i + 1));
      expect(movieGroup.isMovieHint, isTrue);
      expect(
        movieGroup.cleanTitle.toLowerCase(),
        contains('fortuna'),
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
      const movie =
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
      const ep =
          '$root/[VCB-Studio] Shomin Sample [01][Ma10p_1080p][x265_2flac].mkv';
      const ncop =
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

  group('实库体检防误拆与特典防泄漏回归', () {
    test('日式/罗马音/德语特典目录与尾括号特典子目录识别为特典，且支持 .mpg/.iso 扩展名', () {
      for (final dir in [
        'Tokuten DVD',
        'TVスポット',
        'プロモーション映像',
        'ミコージック・クリップ',
        '劇場アナウンス',
        'SP DISK',
        'CDs/2.0 OST/BVCH_47004/BDMV/STREAM',
        '[WBX-SUB][Precure_All-Stars_New_Stage][Extra]',
        '[S1.O.F.S&FLsnow][Aikatsu! x PriPara THE MOVIE][BDrip][SP Live]',
      ]) {
        expect(
          CloudMediaFileClassifier.isSupplementarySubdirectory(dir),
          isTrue,
          reason: dir,
        );
      }

      const clannadRoot = '动画-多作品/Key社 作品集/剧场版 CLANNAD (2007) {tmdb-16516}';
      const clannadMain =
          '$clannadRoot/劇場版 CLANNAD [DVD 720x480 23.976fps AVC-yuv420p10 FLAC] - fch1993.mkv';
      const clannadSpot =
          '$clannadRoot/TVスポット/劇場版 CLANNAD -クラナド- - 第1弾 (15秒) [DVD 712x362].mkv';
      const clannadMv =
          '$clannadRoot/ミコージック・クリップ/劇場版 CLANNAD -クラナド- - 「メグメル」0426Ver. [DVD].mkv';
      const clannadAnnounce =
          '$clannadRoot/劇場アナウンス/劇場版 CLANNAD -クラナド- - 渚・智代・杏 [DVD].mkv';
      final clannad = _group([
        _video(clannadMain, size: 1559 * _mb),
        _video(clannadSpot, size: 5 * _mb),
        _video(clannadMv, size: 18 * _mb),
        _video(clannadAnnounce, size: 7 * _mb),
      ]).single;
      expect(clannad.inventory?.shape, WorkShape.feature);
      expect(_slot(clannad, clannadMain).category, EpisodeCategory.main);
      expect(_slot(clannad, clannadSpot).category, EpisodeCategory.extra);
      expect(_slot(clannad, clannadMv).category, EpisodeCategory.extra);
      expect(_slot(clannad, clannadAnnounce).category, EpisodeCategory.extra);

      const sgRoot = '动画-多作品/命运石之门系列/命运石之门 (2011) {tmdb-42509}';
      const sgMain = '$sgRoot/[Group] Steins;Gate [01][1080p].mkv';
      const sgBonusMpg = '$sgRoot/Bonus/03_STEINS GATE_PSPOP.mpg';
      const sgCdIso = '$sgRoot/Soundtrack/CDs/DVD_VIDEO.ISO';
      final sg = _group([
        _video(sgMain, size: 900 * _mb),
        _video(sgBonusMpg, size: 120 * _mb),
        _video(sgCdIso, size: 300 * _mb),
      ]).single;
      expect(_slot(sg, sgMain).category, EpisodeCategory.main);
      expect(_slot(sg, sgBonusMpg).category, EpisodeCategory.extra);
      expect(_slot(sg, sgCdIso).category, EpisodeCategory.extra);
    });

    test('异国迷宫的十字路口：ピクチャードラマ与スペシャル映像不误拆为独立电影', () {
      const root = '动画-天雪论坛/异国迷宫的十字路口';
      final files = <ScannedFileInput>[
        for (var i = 1; i <= 12; i++)
          _video(
            '$root/[ANK-Raws] 異国迷路のクロワーゼ The Animation ${_ep(i)} (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv',
            size: 700 * _mb,
          ),
        _video('$root/「SD『湯音＆アリス』スペシャル映像（しゃっくり編）」.mkv', size: 98 * _mb),
        _video('$root/「SD『湯音＆アリス』スペシャル映像１（未公開）」.mkv', size: 53 * _mb),
        _video('$root/「ピクチャードラマ１ 『教えて 湯音ちゃん』」.mkv', size: 326 * _mb),
        _video('$root/「ピクチャードラマ２ 『赤ずきん 湯音』」.mkv', size: 363 * _mb),
      ];
      final groups = _group(files);
      expect(groups, hasLength(1));
      expect(groups.single.mainEpisodeNumbers.toSet().length, 12);
      expect(
        _slot(groups.single, '$root/「ピクチャードラマ１ 『教えて 湯音ちゃん』」.mkv').category,
        EpisodeCategory.extra,
      );
      expect(
        _slot(groups.single, '$root/「SD『湯音＆アリス』スペシャル映像（しゃっくり編）」.mkv').category,
        EpisodeCategory.extra,
      );
    });

    test('偶像活动Planet剧场版：十余条 BD_SP_Live 与 BD_Special_Talk 归入特典不拆出假作品且不被高频词误遮蔽', () {
      const root = '动画-系列作未收集/偶像活动系列/偶像活动Planet！剧场版';
      const movie =
          '$root/[FLsnow_feat.AO][Aikatsu_Planet!][BD_Movie][AVC_FLAC].mkv';
      const talk =
          '$root/[FLsnow_feat.AO][Aikatsu_Planet!][BD_Special_Talk][AVC_FLAC].mkv';
      final lives = [
        for (var i = 1; i <= 18; i++)
          '$root/[FLsnow_feat.AO][Aikatsu_Planet!][BD_SP_Live_${_ep(i)}][AVC_FLAC].mkv',
      ];
      final groups = _group([
        _video(movie, size: 2798 * _mb),
        for (final path in lives) _video(path, size: 320 * _mb),
        _video(talk, size: 280 * _mb),
      ]);
      expect(groups, hasLength(1));
      expect(groups.single.inventory?.shape, WorkShape.feature);
      expect(_slot(groups.single, movie).category, EpisodeCategory.main);
      for (final path in lives) {
        expect(_slot(groups.single, path).category, EpisodeCategory.extra);
      }
      expect(_slot(groups.single, talk).category, EpisodeCategory.extra);
    });

    test('东方活动写真馆：德语 Menue/Vorschau/OP/ED 与同人短片盘不被拆碎成多部假电影', () {
      const root = '动画-多作品/东方Project 作品集/东方活动写真馆 2009';
      final files = <ScannedFileInput>[
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_1_Erster_Akt_1_Touhou_Kinema_Kan_OP_[BD-1080p_Hi10P_AAC][Ger-Sub][11FEECB3].mkv',
          size: 73 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_1_Erster_Akt_2_Touhou-Spielplatz_[BD-1080p_Hi10P_AAC][Ger-Sub][B38A3A40].mkv',
          size: 44 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_1_Erster_Akt_3_Touhou_Kinema_Kan_ED_[BD-1080p_Hi10P_AAC][ADB48684].mkv',
          size: 26 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_1_Erster_Akt_Menue_[BD-1080p_Hi10P_AAC][Ger-Sub][E7A6CC5C].mkv',
          size: 68 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_2_Zweiter_Akt_2_Touhou_Unterstuetzergruppe_[BD-1080p_Hi10P_AAC][Ger-Sub][71C81331].mkv',
          size: 128 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_2_Zweiter_Akt_3_Touhou_Blumentanz_[BD-1080p_Hi10P_AAC][Ger-Sub][2E266699].mkv',
          size: 104 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_3_Chens_Gensoukyou_Ondo_1_Chens_Gensoukyou_Ondo_[BD-1080p_Hi10P_AAC][Ger-Sub][8C4FA94A].mkv',
          size: 37 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_4_Touhou_Kourindou_1_Touhou_Kourindou_[BD-1080p_Hi10P_AAC][Ger-Sub_V2][1B89B0B6].mkv',
          size: 42 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_4_Touhou_Kourindou_3_Vorschau_zu_Touhou_Tagtraum_[BD-1080p_Hi10P_AAC][Ger-Sub][24D9DDB5].mkv',
          size: 11 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_5_Touhou_Tagtraum_1_Touhou_Tagtraum_[BD-1080p_Hi10P_AAC][Ger-Sub][47DF23C4].mkv',
          size: 58 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_5_Touhou_Tagtraum_3_A_Flower_[BD-1080p_Hi10P_AAC][Ger-Sub][992A19C0].mkv',
          size: 305 * _mb,
        ),
        _video(
          '$root/[Akiba]_Touhou_Kinema_Kan_Hauptmenue_[BD-1080p_Hi10P_AAC][Ger-Sub][47659D2B].mkv',
          size: 47 * _mb,
        ),
      ];
      final groups = _group(files);
      expect(groups, hasLength(1));
      expect(
        _slot(
          groups.single,
          '$root/[Akiba]_Touhou_Kinema_Kan_Hauptmenue_[BD-1080p_Hi10P_AAC][Ger-Sub][47659D2B].mkv',
        ).category,
        EpisodeCategory.extra,
      );
      expect(
        _slot(
          groups.single,
          '$root/[Akiba]_Touhou_Kinema_Kan_4_Touhou_Kourindou_3_Vorschau_zu_Touhou_Tagtraum_[BD-1080p_Hi10P_AAC][Ger-Sub][24D9DDB5].mkv',
        ).category,
        EpisodeCategory.extra,
      );
    });
  });

  group('第二轮混合目录拆分、分类词净化与 OAD 集号回归', () {
    test('薄樱鬼双章剧场版拆分为两部独立电影并保留章节副标题', () {
      const root = '动画-多作品/薄樱鬼系列/薄樱鬼 剧场版 (2013) {tmdb-461067}';
      final groups = _group([
        _video(
          '$root/[AI-Raws] 劇場版 薄桜鬼 第一章 京都乱舞 (BD HEVC 1920x1080 FLAC)[8550EB3A].mkv',
          size: 4159 * _mb,
        ),
        _video(
          '$root/[AI-Raws] 劇場版 薄桜鬼 第二章 士魂蒼穹 (BD HEVC 1920x1080 FLAC)[8ADCD915].mkv',
          size: 3993 * _mb,
        ),
        _video(
          '$root/[AI-Raws] 劇場版 薄桜鬼 予告編・PV・CM集 (BD HEVC 1920x1080 FLAC)[DE9DC841].mkv',
          size: 255 * _mb,
        ),
      ]);
      expect(groups, hasLength(2));
      expect(groups.every((g) => g.isMovieHint), isTrue);
      expect(groups.every((g) => g.explicitTmdbId == null), isTrue);
      expect(groups.any((g) => g.cleanTitle.contains('京都乱舞')), isTrue);
      expect(groups.any((g) => g.cleanTitle.contains('士魂蒼穹')), isTrue);
    });

    test('特『刀剑乱舞-花丸-』雪月花三卷剧场版拆分为三部独立电影且迷你动画归特典', () {
      const root = '动画-多作品/刀剑乱舞系列/特『刀剑乱舞-花丸-』～雪月花～ (2022) {tmdb-978039}';
      final groups = _group([
        _video(
          '$root/[AI-Raws] 特・刀剣乱舞-花丸- #1～雪の巻～ (BD HEVC 1920x1080 FLAC).mkv',
          size: 4903 * _mb,
        ),
        _video(
          '$root/[AI-Raws] 特・刀剣乱舞-花丸- #2～月の巻～ (BD HEVC 1920x1080 FLAC).mkv',
          size: 5495 * _mb,
        ),
        _video(
          '$root/[AI-Raws] 特・刀剣乱舞-花丸- #3～華の巻～ (BD HEVC 1920x1080 FLAC).mkv',
          size: 4282 * _mb,
        ),
        _video(
          '$root/[AI-Raws] 特・刀剣乱舞-花丸- 先付けミニアニメ『花丸日記』①あぶらげ編 (BD HEVC 1920x1080 FLAC).mkv',
          size: 24 * _mb,
        ),
      ]);
      expect(groups, hasLength(3));
      expect(groups.every((g) => g.isMovieHint), isTrue);
      expect(groups.any((g) => g.cleanTitle.contains('雪の巻')), isTrue);
      expect(groups.any((g) => g.cleanTitle.contains('月の巻')), isTrue);
      expect(groups.any((g) => g.cleanTitle.contains('華の巻')), isTrue);
    });

    test('锚定父目录下自带独立 SPs/CDs/Scans 的多篇章子目录（物语系列第二季）各自成作', () {
      const root = '动画-多作品/西尾维新 作品集/物语系列 第二季 (2013) {tmdb-46195}';
      final files = <ScannedFileInput>[
        for (final arc in ['倾物语', '囮物语']) ...[
          for (var i = 1; i <= 4; i++)
            _video('$root/$arc/[VCB-S] $arc [${_ep(i)}][1080p].mkv'),
          _video('$root/$arc/SPs/[VCB-S] $arc [NCOP].mkv', size: 80 * _mb),
          ScannedFileInput(
            relativePath: '$root/$arc/CDs/ost.flac',
            fileName: 'ost.flac',
            fileSize: 100 * _mb,
            assetKind: AssetKind.cdAlbum,
          ),
        ],
      ];
      final groups = _group(files);
      expect(groups, hasLength(2));
      expect(groups.map((g) => g.cleanTitle).toSet(), {'倾物语', '囮物语'});
      expect(groups.every((g) => g.mainEpisodeNumbers.length == 4), isTrue);
    });

    test('防误拆底线：单章剧场版、PRIVILEGE DISC、7 集 OVA 与单集副标题含「映画」绝不误拆', () {
      const nanoha = '动画-多作品/魔法少女奈叶系列/魔法少女奈叶 The MOVIE 1st (2010) {tmdb-50716}';
      final nanohaGroups = _group([
        _video(
          '$nanoha/MAIN MOVIE/[FLsnow][NANOHA_The_Movie_1st][Main_Movie].mkv',
          size: 8000 * _mb,
        ),
        _video(
          '$nanoha/PRIVILEGE DISC/[FLsnow][NANOHA_The_Movie_1st][CV_Chat].mkv',
          size: 900 * _mb,
        ),
      ]);
      expect(nanohaGroups, hasLength(1));

      const uc = '未添加TMDB ID/机动战士高达 作品集/机动战士高达UC (2010) {tmdb-45500}';
      final ucGroups = _group([
        for (var i = 1; i <= 7; i++)
          _video(
            '$uc/[Group] Mobile Suit Gundam Unicorn Movie ${_ep(i)} - Ep $i.mkv',
            size: 3500 * _mb,
          ),
      ]);
      expect(ucGroups, hasLength(1));

      const precure = '动画-多作品/光之美少女 作品集/【第十四代】Star☆Twinkle 光之美少女 (2019) {tmdb-85322}';
      final precureGroups = _group([
        for (var i = 1; i <= 10; i++)
          _video('$precure/[Group] Star Twinkle Precure - ${_ep(i)}.mkv'),
        _video(
          '$precure/[Group] Star Twinkle Precure - 11 さよならララ！？映画監督は宇宙人☆.mkv',
          size: 900 * _mb,
        ),
      ]);
      expect(precureGroups, hasLength(1));
      expect(precureGroups.single.mainEpisodeNumbers, hasLength(11));
    });

    test('未添加TMDB ID 与系列分类目录不污染搜索词，独立 OAD01..10 提取第 0 季集号', () {
      const root = '未添加TMDB ID/新撰组异闻录 铁系列/新撰组异闻录 铁 ～想道～';
      final folder = _group([
        _video(
          '$root/[AI-Raws] 劇場版 PEACEMAKER鐵 #01 前篇 想道 (BD HEVC).mkv',
          size: 1477 * _mb,
        ),
      ]).single;
      final queries = ScrapeDomainAdapter.buildSearchQueries(folder);
      expect(
        queries.any((q) => q.contains('未添加TMDB')),
        isFalse,
        reason: '分类目录未添加TMDB ID不得进入检索词',
      );

      final oadInv = DirectoryAnalyzer.analyze(
        '出包王女Darkness OAD (2012) {tmdb-34742}',
        [
          for (var i = 1; i <= 10; i++)
            (
              path:
                  '[VCB-Studio] To LOVE-Ru Darkness OADs [OAD${_ep(i)}][Ma10p_1080p].mkv',
              size: 1200 * _mb,
            ),
        ],
        anchoredRoot: true,
      );
      expect(oadInv.shape, WorkShape.series);
      expect(oadInv.episodeCount, 10);
      expect(oadInv.main.every((item) => item.season == 0), isTrue);
    });
  });
}
