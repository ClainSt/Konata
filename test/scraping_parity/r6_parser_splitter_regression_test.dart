import 'package:flutter_test/flutter_test.dart';
import 'package:konata/domain/scraping/cloud_media_asset_presentation.dart';
import 'package:konata/domain/scraping/cloud_media_file_classifier.dart';
import 'package:konata/domain/scraping/directory_analyzer.dart';
import 'package:konata/domain/scraping/multi_work_splitter.dart';
import 'package:konata/domain/scraping/personal_filename_parser.dart';
import 'package:konata/domain/scraping/title_normalizer.dart';

Map<String, Object?> _asset(
  String id,
  String relativePath, {
  int size = 500 * 1024 * 1024,
}) => {
  'id': id,
  'relative_path': relativePath,
  'name': relativePath.split('/').last,
  'size': size,
};

void main() {
  group('P1.2 TitleNormalizer & DirectoryAnalyzer.normalize', () {
    test('folds width, multiplication signs, Roman numerals, katakana, and traditional Chinese', () {
      expect(TitleNormalizer.fold('SPY×FAMILY'), TitleNormalizer.fold('Spy x Family'));
      expect(TitleNormalizer.fold('SPY✕FAMILY'), TitleNormalizer.fold('SPY✖FAMILY'));
      expect(
        DirectoryAnalyzer.normalize('ＳＰＹ×ＦＡＭＩＬＹ'),
        DirectoryAnalyzer.normalize('Spy x Family'),
      );

      expect(TitleNormalizer.fold('魔法少女奈葉Ⅴ'), TitleNormalizer.fold('魔法少女奈叶V'));
      expect(
        DirectoryAnalyzer.normalize('サクラ大戦Ⅳ'),
        DirectoryAnalyzer.normalize('さくら大戦IV'),
      );
      expect(
        DirectoryAnalyzer.normalize('ドラえもん 劇場版'),
        DirectoryAnalyzer.normalize('どらえもん 剧场版'),
      );
      expect(
        DirectoryAnalyzer.normalize('ヴァイオレット・エヴァーガーデン'),
        DirectoryAnalyzer.normalize('ゔぁいおれっと・えゔぁーがーでん'),
      );

      const pairs = [
        ('進擊の巨人', '进击の巨人'),
        ('機動戰士鋼彈', '机动战士钢弹'),
        ('偵探歌劇 少女福爾摩斯', '侦探歌剧 少女福尔摩斯'),
        ('學園絕望契約劇場物語', '学园绝望契约剧场物语'),
        ('魔導士閃光鐵籃劍龍風雲愛戀', '魔导士闪光铁篮剑龙风云爱恋'),
      ];
      for (final (trad, simp) in pairs) {
        expect(TitleNormalizer.toSimplified(trad), simp);
        expect(
          DirectoryAnalyzer.normalize(trad),
          DirectoryAnalyzer.normalize(simp),
        );
      }
    });

    test('preserves PersonalFilenameParser.normalizeIdentity strict semantics', () {
      expect(
        PersonalFilenameParser.normalizeIdentity('進擊の巨人'),
        isNot(equals(PersonalFilenameParser.normalizeIdentity('进击の巨人'))),
      );
      expect(
        PersonalFilenameParser.normalizeIdentity('Mob Psycho 100 (2016) {tmdb-67075}'),
        'mobpsycho100',
      );
    });
  });

  group('Problem 1 & 11: Adjacent bracket extras & bundled OAD/OVA markers', () {
    test('classifies [SP][01], [OVA][01], [OAD][01], [PV][01], [CM][01], [NCOP][01], [NCED][01] as extra', () {
      final samples = <(String, String)>[
        ('[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][01][BDrip][X264_FLAC][D62003DA].mkv', 'SP'),
        ('[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][02][BDrip][X264_FLAC][AABB1122].mkv', 'SP'),
        ('[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][03][BDrip][X264_FLAC][CCDD3344].mkv', 'SP'),
        ('[Sub][Work_Title][OVA][01][1080p].mkv', 'OVA'),
        ('[Sub][Work_Title][OAD][01][1080p].mkv', 'OAD'),
        ('[Sub][Work_Title][PV][01][1080p].mkv', 'PV'),
        ('[Sub][Work_Title][CM][01][1080p].mkv', 'CM'),
        ('[Sub][Work_Title][NCOP][01][1080p].mkv', 'NCOP'),
        ('[Sub][Work_Title][NCED][01][1080p].mkv', 'NCED'),
      ];
      for (final (name, expectedType) in samples) {
        expect(
          CloudMediaFileClassifier.classifyAsset('', name, 'video', videoCount: 20),
          'extra',
          reason: name,
        );
        expect(
          CloudMediaAssetPresentation.extraType({'name': name, 'relative_path': name}),
          expectedType,
          reason: name,
        );
      }

      // 目录已包含正片剧集时（即便缺失 1..3 话），绝不将 `[SP][01..03]` 提升为正片。
      final inv = DirectoryAnalyzer.analyze(
        'SD_Gundam_Sangokuden',
        [
          (path: '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][04][BDrip][X264_FLAC][11111111].mkv', size: 400 * 1024 * 1024),
          (path: '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][05][BDrip][X264_FLAC][22222222].mkv', size: 400 * 1024 * 1024),
          (path: '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][01][BDrip][X264_FLAC][D62003DA].mkv', size: 400 * 1024 * 1024),
          (path: '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][02][BDrip][X264_FLAC][AABB1122].mkv', size: 400 * 1024 * 1024),
          (path: '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][03][BDrip][X264_FLAC][CCDD3344].mkv', size: 400 * 1024 * 1024),
        ],
      );
      expect(inv.main.map((e) => e.episode).toList(), [4, 5]);
      expect(inv.extras, hasLength(3));

      // 混合 TV 与剧场版目录下将 `[SP][01..03]` 保持归入特典列表而非正片 1..3 集。
      final split = MultiWorkSplitter.split('SD高达三国传 TV+Movie', [
        _asset('m1', '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][01][BDrip].mkv'),
        _asset('m4', '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][04][BDrip].mkv'),
        _asset('sp1', '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][01][BDrip].mkv'),
        _asset('sp2', '[Koeisub][SD_Gundam_Sangokuden_Brave_Battle_Warriors][SP][02][BDrip].mkv'),
        _asset('mv', '[Koeisub][SD_Gundam_Sangokuden_Movie][BDrip].mkv'),
      ]);
      expect(split, hasLength(2));
      final tvCluster = split.singleWhere((c) => c.inventory.shape == WorkShape.series);
      expect(
        tvCluster.assignments.where((a) => a.category == 'main').map((a) => a.episode).toList(),
        [1, 4],
      );
      expect(
        tvCluster.assignments.where((a) => a.category == 'extra').map((a) => a.assetId).toSet(),
        {'sp1', 'sp2'},
      );
    });

    test('classifies bundled [13(OAD)], [11(OAD)], [13 (OVA)], [13(SP)], [13(Special)] as extra', () {
      const bundledSamples = <(String, String)>[
        ('[VCB-Studio] Shinmai Maou no Testament [13(OAD)][Ma10p_1080p][x265_flac].mkv', 'OAD'),
        ('[VCB-Studio] Shinmai Maou no Testament BURST [11(OAD)][Ma10p_1080p].mkv', 'OAD'),
        ('[VCB-Studio] Sample Series [13 (OVA)][Ma10p_1080p].mkv', 'OVA'),
        ('[VCB-Studio] Sample Series [13(SP)][Ma10p_1080p].mkv', 'SP'),
        ('[VCB-Studio] Sample Series [13(Special)][Ma10p_1080p].mkv', 'SP'),
      ];
      for (final (name, expectedType) in bundledSamples) {
        expect(
          CloudMediaFileClassifier.classifyAsset('', name, 'video', videoCount: 13),
          'extra',
          reason: name,
        );
        expect(
          CloudMediaFileClassifier.isStrongSupplementary('', name),
          isTrue,
          reason: name,
        );
        expect(
          CloudMediaAssetPresentation.extraType({'name': name, 'relative_path': name}),
          expectedType,
          reason: name,
        );
      }

      final invS1 = DirectoryAnalyzer.analyze(
        '新妹魔王的契约者',
        [
          for (var i = 1; i <= 12; i++)
            (
              path: '[VCB-Studio] Shinmai Maou no Testament [${i.toString().padLeft(2, '0')}][Ma10p_1080p].mkv',
              size: 400 * 1024 * 1024,
            ),
          (
            path: '[VCB-Studio] Shinmai Maou no Testament [13(OAD)][Ma10p_1080p].mkv',
            size: 450 * 1024 * 1024,
          ),
        ],
      );
      expect(invS1.main, hasLength(12));
      expect(invS1.extras, ['[VCB-Studio] Shinmai Maou no Testament [13(OAD)][Ma10p_1080p].mkv']);
    });
  });

  group('Problem 8 & 12: MV, MenuEX, and Japanese BD contextual extras', () {
    test('classifies MV tags, Music/ & MV/ dirs as MV and MenuEX as MENU', () {
      const mvPath =
          'Music/[220601] Ubugoe/BDRip/Ubugoe [MV][BDRip 1920x804 HEVC-10bit AAC].mkv';
      expect(
        CloudMediaFileClassifier.classifyAsset(
          'Music/[220601] Ubugoe/BDRip',
          'Ubugoe [MV][BDRip 1920x804 HEVC-10bit AAC].mkv',
          'video',
        ),
        'extra',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': 'Ubugoe [MV][BDRip 1920x804 HEVC-10bit AAC].mkv',
          'relative_path': mvPath,
        }),
        'MV',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': 'Opening [Music Video][1080p].mkv',
          'relative_path': 'Opening [Music Video][1080p].mkv',
        }),
        'MV',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': 'Song [MV Making][1080p].mkv',
          'relative_path': 'Song [MV Making][1080p].mkv',
        }),
        'MV',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': 'Theme.mkv',
          'relative_path': 'MV/Theme.mkv',
        }),
        'MV',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': '[VCB-Studio] Accel World [MenuEX1][1080p].mkv',
          'relative_path': 'SPs/[VCB-Studio] Accel World [MenuEX1][1080p].mkv',
        }),
        'MENU',
      );
      expect(
        CloudMediaAssetPresentation.extraType({
          'name': '[VCB-Studio] Accel World [MenuEX2][1080p].mkv',
          'relative_path': 'SPs/[VCB-Studio] Accel World [MenuEX2][1080p].mkv',
        }),
        'MENU',
      );

      // 不得将 `Music/` 目录内的音乐短片文件错误拆分为独立剧场版作品。
      final split = MultiWorkSplitter.split('机动战士高达 库库鲁斯·杜安之岛 (2022) {tmdb-883768}', [
        _asset('main', 'Mobile Suit Gundam Cucuruz Doan\'s Island (2022) [BDRip 1080p].mkv'),
        _asset('mv', mvPath),
      ]);
      expect(split, isEmpty);
    });

    test('keeps Japanese BD stage greetings, cast talk, guides, prologue, gathering, eyecatch, and documents as extras', () {
      const gundam00Extras = [
        '[AI-Raws] 劇場版 機動戦士ガンダム00 PROLOGUE TO THE MOVIE (BD HEVC 1920x1080 FLAC).mkv',
        "[AI-Raws] 劇場版 機動戦士ガンダム00 Supporter's Gathering 2010 (BD HEVC 1920x1080 FLAC).mkv",
        '[AI-Raws] 劇場版 機動戦士ガンダム00 TVシリーズガイド (BD HEVC 1920x1080 FLAC).mkv',
        '[AI-Raws] 劇場版 機動戦士ガンダム00 キャストトークショー (BD HEVC 1920x1080 FLAC).mkv',
        '[AI-Raws] 劇場版 機動戦士ガンダム00 初日舞台挨拶 (BD HEVC 1920x1080 FLAC).mkv',
        '[AI-Raws] 劇場版 機動戦士ガンダム00 オーディオコメンタリー (BD HEVC 1920x1080 FLAC).mkv',
      ];
      for (final file in gundam00Extras) {
        expect(
          CloudMediaFileClassifier.classifyAsset('', file, 'video', videoCount: 7),
          'extra',
          reason: file,
        );
      }

      final gundam00Split = MultiWorkSplitter.split(
        '机动战士高达00 先驱者的觉醒 (2010)',
        [
          _asset('movie', '[AI-Raws] 劇場版 機動戦士ガンダム00 -A wakening of the Trailblazer- (BD HEVC 1920x1080 FLAC).mkv'),
          for (var i = 0; i < gundam00Extras.length; i++)
            _asset('ex$i', gundam00Extras[i], size: 400 * 1024 * 1024),
        ],
      );
      expect(gundam00Split, isEmpty);

      // G-Reco: 舞台挨拶, アイキャッチ集, and Movies/ドキュメント#01 must not become ep 36..38 or separate films.
      final grecoInv = DirectoryAnalyzer.analyze(
        '高达 G之复国运动',
        [
          for (var i = 1; i <= 26; i++)
            (path: '[Group] G-Reco - ${i.toString().padLeft(2, '0')} [1080p].mkv', size: 400 * 1024 * 1024),
          (path: '[Group] 特別先行版 劇場舞台挨拶 Part1 [1080p].mkv', size: 300 * 1024 * 1024),
          (path: '[Group] アイキャッチ集 [1080p].mkv', size: 100 * 1024 * 1024),
          (path: 'Movies/[Group] ドキュメント#01 富野由悠季から君へ [1080p].mkv', size: 350 * 1024 * 1024),
        ],
      );
      expect(grecoInv.main, hasLength(26));
      expect(grecoInv.extras, hasLength(3));

      final grecoSplit = MultiWorkSplitter.split('高达 G之复国运动', [
        _asset('m1', 'Movies/[Group] G-Reco Movie I [1080p].mkv'),
        _asset('m2', 'Movies/[Group] G-Reco Movie II [1080p].mkv'),
        _asset('doc1', 'Movies/[Group] ドキュメント#01 富野由悠季から君へ [1080p].mkv'),
        _asset('stage', '[Group] 特別先行版 劇場舞台挨拶 Part1 [1080p].mkv'),
        _asset('eye', '[Group] アイキャッチ集 [1080p].mkv'),
      ]);
      expect(grecoSplit, hasLength(2));
      final extraIds = grecoSplit.expand((c) => c.assignments).where((a) => a.category == 'extra').map((a) => a.assetId).toSet();
      expect(extraIds, {'doc1', 'stage', 'eye'});
    });
  });

  group('Problem 9 & 10: Episode extraction priority & decimal/sequel protection', () {
    test('extracts explicit dash episode over Roman numerals and decimal audio specs', () {
      for (var ep = 1; ep <= 4; ep++) {
        final name =
            'Yu Yu Hakusho Eizou Hakusho II - 0$ep Yusuke (BDRip 720x480p x265 HEVC FLACx3 2.0x3).mkv';
        expect(CloudMediaFileClassifier.episodeNumberFromName(name), ep, reason: name);
        expect(
          CloudMediaFileClassifier.episodeNumberFromNameInDirectory('幽游白书', name),
          ep,
          reason: name,
        );
      }
    });

    test('returns null for sequel numbers before arc subtitle and fractional 2.5 menu extras', () {
      const kibou = '[LoliHouse] Danganronpa 3 - Kibou Hen [BDRip 1080p HEVC-10bit FLAC].mkv';
      const menu25 = '[LoliHouse] Danganronpa 2.5 - Menu [BDRip 1080p HEVC-10bit FLAC].mkv';
      const mirai01 = '[LoliHouse] Danganronpa 3 - Mirai Hen - 01 [BDRip 1080p HEVC-10bit FLAC].mkv';

      expect(CloudMediaFileClassifier.episodeNumberFromName(kibou), isNull);
      expect(CloudMediaFileClassifier.episodeNumberFromNameInDirectory('弹丸论破3', kibou), isNull);

      expect(CloudMediaFileClassifier.episodeNumberFromName(menu25), isNull);
      expect(CloudMediaFileClassifier.classifyAsset('', menu25, 'video'), 'extra');
      expect(
        CloudMediaAssetPresentation.extraType({'name': menu25, 'relative_path': menu25}),
        'MENU',
      );

      expect(CloudMediaFileClassifier.episodeNumberFromName(mirai01), 1);
    });

    test('preserves numeric titles (86, Mob Psycho 100, Blade Runner 2049)', () {
      expect(CloudMediaFileClassifier.episodeNumberFromName('86 - 01 [1080p].mkv'), 1);
      expect(
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory('86', '[Group] 86 - Special [1080p].mkv'),
        isNull,
      );
      expect(CloudMediaFileClassifier.episodeNumberFromName('Mob Psycho 100 II - 01 [1080p].mkv'), 1);
      expect(
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
          'Mob Psycho 100',
          'Mob Psycho 100 - Reigen [1080p].mkv',
        ),
        isNull,
      );
      expect(
        CloudMediaFileClassifier.episodeNumberFromName('Blade Runner 2049 (2017) [1080p].mkv'),
        isNull,
      );
    });
  });

  group('MultiWorkSplitter structural clustering upgrades', () {
    test('Problem 12 Beginning G: merges unbracketed scene 1080p/720p variants without splitting', () {
      final split = MultiWorkSplitter.split('模型战士高达 起始G', [
        _asset(
          'v1080',
          'Mokei Senshi Gunpla Builders Beginning G OVA 2010 1080p BluRay x264 10bit FLAC-Shiniori.mkv',
        ),
        _asset(
          'v720',
          'Mokei Senshi Gunpla Builders Beginning G OVA 2010 720p BluRay x264 10bit AAC-Shiniori.mp4',
        ),
      ]);
      expect(split, isEmpty);

      final splitDot = MultiWorkSplitter.split('Test Scene Series', [
        _asset('a', 'Sample.Show.2022.1080p.WEB-DL.x265.10bit.DDP5.1-SubsPlease.mkv'),
        _asset('b', 'Sample.Show.2022.720p.WEB-DL.x264.AAC-SubsPlease.mp4'),
      ]);
      expect(splitDot, isEmpty);
    });

    test('Problem 12 Slayers: groups episode-preceding quoted arcs and normalizes 04..06 -> 1..3', () {
      final assets = [
        _asset('s1', '[Moozzi2] Slayers OVA [1996] - 01 - 「 Special 」 (BDRip 1440x1080 x264 FLAC).mkv'),
        _asset('s2', '[Moozzi2] Slayers OVA [1996] - 02 - 「 Special 」 (BDRip 1440x1080 x264 FLAC).mkv'),
        _asset('s3', '[Moozzi2] Slayers OVA [1996] - 03 - 「 Special 」 (BDRip 1440x1080 x264 FLAC).mkv'),
        _asset('e1', '[Moozzi2] Slayers OVA [1998] - 04 - 「 Excellent 」 (BDRip 1440x1080 x264 FLAC).mkv'),
        _asset('e2', '[Moozzi2] Slayers OVA [1998] - 05 - 「 Excellent 」 (BDRip 1440x1080 x264 FLAC).mkv'),
        _asset('e3', '[Moozzi2] Slayers OVA [1998] - 06 - 「 Excellent 」 (BDRip 1440x1080 x264 FLAC).mkv'),
      ];
      final clusters = MultiWorkSplitter.split('秀逗魔导士 OVA', assets);
      expect(clusters, hasLength(2));

      final special = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 's1'),
      );
      expect(special.assignments.map((a) => a.episode).toList(), [1, 2, 3]);

      final excellent = clusters.singleWhere(
        (c) => c.assignments.any((a) => a.assetId == 'e1'),
      );
      expect(excellent.assignments.map((a) => a.episode).toList(), [1, 2, 3]);
    });

    test('Problem 9 Yu Yu Hakusho: keeps 112-ep main TV pure and detaches named OVA subseries', () {
      final assets = <Map<String, Object?>>[
        for (var i = 1; i <= 112; i++)
          _asset(
            'tv$i',
            'Yu Yu Hakusho - ${i.toString().padLeft(3, '0')} Title (BDRip 720x480p x265 HEVC FLAC).mkv',
          ),
        _asset('a1', 'Yu Yu Hakusho Eizou Hakusho Ankoku Bujutsukai No Shou - 01 (BDRip 720x480p).mkv'),
        _asset('a2', 'Yu Yu Hakusho Eizou Hakusho Ankoku Bujutsukai No Shou - 02 (BDRip 720x480p).mkv'),
        _asset('ii1', 'Yu Yu Hakusho Eizou Hakusho II - 01 Yusuke (BDRip 720x480p x265 HEVC FLACx3 2.0x3).mkv'),
        _asset('ii2', 'Yu Yu Hakusho Eizou Hakusho II - 02 Kuwabara (BDRip 720x480p x265 HEVC FLACx3 2.0x3).mkv'),
        _asset('ii3', 'Yu Yu Hakusho Eizou Hakusho II - 03 Kurama (BDRip 720x480p x265 HEVC FLACx3 2.0x3).mkv'),
        _asset('ii4', 'Yu Yu Hakusho Eizou Hakusho II - 04 Hiei (BDRip 720x480p x265 HEVC FLACx3 2.0x3).mkv'),
        _asset('iii1', 'Yu Yu Hakusho Eizou Hakusho III - 01 Yusuke (BDRip 720x480p).mkv'),
        _asset('iii2', 'Yu Yu Hakusho Eizou Hakusho III - 02 Kurama (BDRip 720x480p).mkv'),
        _asset('ts', 'Yu Yu Hakusho Two Shots and All or Nothing (2018) (BDRip 1920x1080p).mkv'),
      ];

      for (final folder in ['幽游白书', '幽游白书 {tmdb-30669}']) {
        final clusters = MultiWorkSplitter.split(folder, assets);
        expect(clusters, hasLength(5), reason: folder);

        final tvCluster = clusters.singleWhere((c) => c.assignments.length == 112);
        expect(tvCluster.assignments.map((a) => a.episode).toSet(), {for (var i = 1; i <= 112; i++) i});

        final iiCluster = clusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'ii1'));
        expect(iiCluster.assignments.map((a) => a.episode).toList(), [1, 2, 3, 4]);
        expect(iiCluster.inventory.tmdbId, isNull);

        final tsCluster = clusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'ts'));
        expect(tsCluster.assignments, hasLength(1));
        expect(tsCluster.inventory.tmdbId, isNull);
      }
    });

    test('Problem 7 Accel World: routes generic SPs/ extras to largest main TV while keeping MenuEX with 2-ep EX', () {
      final assets = [
        for (var i = 1; i <= 24; i++)
          _asset('tv$i', '[VCB-Studio] Accel World [${i.toString().padLeft(2, '0')}][Ma10p_1080p].mkv'),
        _asset('ex1', '[VCB-Studio] Accel World [EX1][Ma10p_1080p][x265_flac].mkv'),
        _asset('ex2', '[VCB-Studio] Accel World [EX2][Ma10p_1080p][x265_flac].mkv'),
        _asset('mv', '[VCB-Studio] Accel World Infinite Burst [Ma10p_1080p][x265_flac].mkv'),
        _asset('cm1', 'SPs/[VCB-Studio] Accel World [CM01][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
        _asset('menu1', 'SPs/[VCB-Studio] Accel World [Menu01][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
        _asset('ncop1', 'SPs/[VCB-Studio] Accel World [NCOP1][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
        _asset('sp1', 'SPs/[VCB-Studio] Accel World [SP01][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
        _asset('mex1', 'SPs/[VCB-Studio] Accel World [MenuEX1][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
        _asset('mex2', 'SPs/[VCB-Studio] Accel World [MenuEX2][Ma10p_1080p].mkv', size: 20 * 1024 * 1024),
      ];

      final clusters = MultiWorkSplitter.split('加速世界 TV+Movie', assets);
      expect(clusters, hasLength(3));

      final byAsset = <String, SubWorkCluster>{
        for (final c in clusters)
          for (final a in c.assignments) a.assetId: c,
      };
      expect(byAsset['ex1']!.slug, byAsset['ex2']!.slug);
      expect(
        byAsset['ex1']!.assignments.where((a) => a.category == 'main').map((a) => a.episode).toList(),
        [1, 2],
      );
      expect(byAsset['mex1']!.slug, byAsset['ex1']!.slug);
      expect(byAsset['mex2']!.slug, byAsset['ex1']!.slug);

      final tvSlug = byAsset['tv1']!.slug;
      expect(byAsset['cm1']!.slug, tvSlug);
      expect(byAsset['menu1']!.slug, tvSlug);
      expect(byAsset['ncop1']!.slug, tvSlug);
      expect(byAsset['sp1']!.slug, tvSlug);
    });

    test('Problem 10 Danganronpa 3: preserves sequel number 3 and arc names in virtualFolder & hints', () {
      final assets = [
        for (var i = 1; i <= 12; i++)
          _asset(
            'm$i',
            '[LoliHouse] Danganronpa 3 - Mirai Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
          ),
        for (var i = 1; i <= 11; i++)
          _asset(
            'z$i',
            '[LoliHouse] Danganronpa 3 - Zetsubou Hen - ${i.toString().padLeft(2, '0')} [BDRip 1080p HEVC-10bit FLAC].mkv',
          ),
        _asset('k', '[LoliHouse] Danganronpa 3 - Kibou Hen [BDRip 1080p HEVC-10bit FLAC].mkv'),
        _asset('m25', '[LoliHouse] Danganronpa 2.5 - Menu [BDRip 1080p HEVC-10bit FLAC].mkv', size: 20 * 1024 * 1024),
      ];

      final clusters = MultiWorkSplitter.split('弹丸论破3', assets);
      expect(clusters, hasLength(3));

      final mirai = clusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'm1'));
      expect(mirai.virtualFolder, contains('3'));
      expect(mirai.virtualFolder, contains('Mirai Hen'));
      expect(mirai.inventory.titleHints, contains('弹丸论破3 Mirai Hen'));

      final kibou = clusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'k'));
      expect(kibou.virtualFolder, contains('3'));
      expect(kibou.virtualFolder, contains('Kibou Hen'));
      expect(kibou.assignments.singleWhere((a) => a.assetId == 'k').episode, isNull);
      expect(kibou.inventory.titleHints, contains('弹丸论破3 Kibou Hen'));
    });

    test('Problem 3 Milky Holmes: avoids cross-mismatching & keeps Alternative - 01/- 02 split with Extra/ dir', () {
      final pairClusters = MultiWorkSplitter.split('派对之夜 & 亚森 华丽的欲望', [
        _asset('a', '[ReinForce] Tantei Opera Milky Holmes Arsene Karei Naru Yokubou (BDRip 1920x1080 x264 FLAC).mkv'),
        _asset('f', '[ReinForce] Tantei Opera Milky Holmes Fun Fun Pearly Night (BDRip 1920x1080 x264 FLAC).mkv'),
      ]);
      expect(pairClusters, hasLength(2));
      final arsene = pairClusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'a'));
      final funfun = pairClusters.singleWhere((c) => c.assignments.any((a) => a.assetId == 'f'));
      expect(arsene.virtualFolder, isNot(contains('派对之夜')));
      expect(arsene.virtualFolder, contains('Arsene'));
      expect(funfun.virtualFolder, isNot(contains('亚森')));
      expect(funfun.virtualFolder, contains('Fun Fun Pearly Night'));

      final altClusters = MultiWorkSplitter.split('侦探歌剧 少女福尔摩斯 Alternative', [
        _asset('alt1', '[ReinForce] Tantei Opera Milky Holmes Alternative - 01 (BDRip 1920x1080 x264 FLAC).mkv'),
        _asset('alt2', '[ReinForce] Tantei Opera Milky Holmes Alternative - 02 (BDRip 1920x1080 x264 FLAC).mkv'),
        _asset('cv', 'Extra/CV.mkv', size: 20 * 1024 * 1024),
        _asset('pv', 'Extra/PV.mkv', size: 20 * 1024 * 1024),
        _asset('ed', 'Extra/[ReinForce] Tantei Opera Milky Holmes Alternative - ED (BDRip 1920x1080 x264 FLAC).mkv', size: 30 * 1024 * 1024),
      ]);
      expect(altClusters, hasLength(2));
      expect(altClusters[0].inventory.titleHints.join(' '), contains('ONE'));
      expect(altClusters[1].inventory.titleHints.join(' '), contains('TWO'));
    });
  });
}
