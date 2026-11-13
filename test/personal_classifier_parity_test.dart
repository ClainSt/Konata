// Adapted from NipaPlay Personal cloud_media_scanner_test.dart (pure rules).
import 'package:flutter_test/flutter_test.dart';
import 'package:ccplayer/core/cloud_media_file_classifier.dart';
import 'package:ccplayer/core/personal_filename_parser.dart';
import 'package:ccplayer/core/auto_classifier.dart';

void main() {
  test('search keywords omit combined season labels and release separators', () {
    expect(PersonalFilenameParser.extractAnimeSearchKeyword('Series Name S1+S2.mkv'),
        'Series Name');
    expect(PersonalFilenameParser.extractAnimeSearchKeyword(
        '[Group] Series Name／Ep.01 「Episode title」 (BDRip).mkv'), 'Series Name');
  });
  test('repeated numbering under different release titles splits the inventory', () {
    const folder = 'Mixed releases';
    const paths = [
      '$folder/[Group] Saga Name - 01 (BDRip 1080p).mkv',
      '$folder/[Group] Saga Name - 02 (BDRip 1080p).mkv',
      '$folder/[Group] Saga Name Side Stories II - 01 Character (BDRip 720p).mkv',
      '$folder/[Group] Saga Name Side Stories II - 02 Other (BDRip 720p).mkv',
    ];
    final assigned = AutoClassifier.releaseFolders(folder, paths);
    expect(assigned[paths[0]], folder);
    expect(assigned[paths[1]], folder);
    expect(assigned[paths[2]], '$folder/Saga Name Side Stories II');
    expect(assigned[paths[3]], assigned[paths[2]]);
    expect(AutoClassifier.releaseFolders(folder, paths.take(3).toList()), isEmpty);
  });

  test('r7 separators preserve the release title and episode before the subtitle', () {
    const file =
        '[a-s]_slayers_evolution-r_-_01_-_newcomer!_a_brand_new_journey__rs2_[1080p_bd-rip][500DAD4E].mkv';
    expect(CloudMediaFileClassifier.episodeNumberFromName(file), 1);
    expect(PersonalFilenameParser.extractAnimeSearchKeyword(file), 'slayers evolution-r');
    const movie = 'New Initial D the Movie Legend 01 - Awakening.mkv';
    expect(PersonalFilenameParser.extractAnimeSearchKeyword(movie), contains('Awakening'));
  });

  test('r7 explicit samples, disc menus and drama CDs are supplemental', () {
    const cases = [
      ('Collection/Movie/Sample', 'A feature title.mkv'),
      ('Collection/Film', 'Saint.Seiya.Legend.2014.1080p.BluRay.Sample.mkv'),
      ('Collection/Film/Tokuten', '[QTS] Information.mkv'),
      ('Collection/Film/Eizou Tokuten', '[QTS] EP27 Parallel Version.mkv'),
      ('Collection/Series', '[CXRAW][Series][メニュ一01][BDrip].mkv'),
      ('Collection/Series', '[Raws][Series][DramaCD][Blind Target].mkv'),
    ];
    for (final (folder, name) in cases) {
      expect(CloudMediaFileClassifier.classifyAsset(folder, name, 'video'), 'extra');
    }
    expect(CloudMediaFileClassifier.classifyAsset('A Sample of Life',
        'A Sample of Life (BDRip 1080p).mkv', 'video', videoCount: 1), 'episode');
  });

  test('Moozzi2 3D Kanojo continuous episode 13 is a main episode', () {
    const name =
        '[Moozzi2] 3D Kanojo Real Girl - 13 (BD 1920x1080 x.264 Flac).mkv';
    expect(CloudMediaFileClassifier.episodeNumberFromName(name), 13);
    expect(
      CloudMediaFileClassifier.classifyAsset(
        '3D Kanojo Real Girl',
        name,
        'video',
      ),
      'episode',
    );
  });

  test('parses episode forms observed in the full cloud inventory', () {
    const samples = <String, int>{
      '[VCB-Studio] BUDDY COMPLEX [14(Final Act 01)][Ma10p_1080p].mkv': 14,
      '[WBDP] 01 - Once Upon a Time [BD][1080p].mkv': 1,
      '[Nekomoe] Nazotoki wa Dina no Ato de - 03（1080P）.mp4': 3,
      '[Dymy] うたわれるもの 01 「招かれざるもの」.mkv': 1,
      '[Exiled-Destiny]_Saiyuki_Reload_Ep02_(C20C8DDF).mkv': 2,
      '[ReinForce] Gensou Mangekyou 02-04 (BDRip 1080p).mkv': 2,
      '[Kagura] Urusei Yatsura - 001&002 [BDRip].mkv': 1,
      '[FLsnow][Violet_Evergarden][01-03][Theater_Ver.].mkv': 1,
      '[Group] Show [Movie 01][1080p].mkv': 1,
      '[AI-Raws] 新世紀エヴァンゲリオン 第弐拾参話「涙」.mkv': 23,
      '[Group] Show 第１２話.mkv': 12,
      '[Moozzi2] Youjo Shachou - 12-A (BD 1080p).mkv': 12,
      '[Erai-raws] Exception - 06 [1080p][139ED514].mkv': 6,
      '[AI-Raws] Show #02 [E6570BDB].mkv': 2,
      '[Sakurato] Show [01v2][HEVC-10bit].mkv': 1,
      '[Moozzi2] Magic Kaito 1412 - 01 (BD 1080p).mkv': 1,
      '[Henshin]_Tenchi_Muyo!_GXP_01_(DVD_x264_720x544_FLAC).mkv': 1,
      'Kenpuu.Denki.Berserk.TV.Series.-.01.[Salender-Raws].mkv': 1,
      '[AI-Raws] Show Agenda.03 (BD HEVC 1920x1080).mkv': 3,
      '[IrizaRaws] Show - 03 TV Ver (BDRip 1080p).mkv': 3,
      '[UHA-WINGS][Show][放課後Vタイム 01][BDRIP].mkv': 1,
      '天使の3P！01.mkv': 1,
      '[Nekomoe kissaten][Show][12END][720p][CHS].mp4': 12,
      '[Moozzi2] Monogatari Series Off & Monster Season - 01 '
              '[ Orokamonogatari ] (BD 1920x1080).mkv':
          1,
      '乐园字幕组 Show 第4季 03 1080p GB.mp4': 3,
      '[Beatrice-Raws] Show 05 Premiere Early Screening II Ver '
              '[BDRip 1920x1080].mkv':
          5,
      '[Kagura] New Cutey Honey - Stage1 [BDRip 1440x1080].mkv': 1,
      'Rurouni Kenshin - Shin Kyoto Hen 2011 - 01 前編 '
              '[BD 1920x1080].mkv':
          1,
    };
    for (final entry in samples.entries) {
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(entry.key),
        entry.value,
        reason: entry.key,
      );
    }
    for (final name in [
      'Show 2nd Season.mkv',
      'Show [1080p][Ma10p].mkv',
      'Movie.2026.1080p.BluRay.mkv',
      '[Erai-raws] Show - 06 [1080p][139ED514].mkv'.replaceAll(' - 06', ''),
    ]) {
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(name),
        isNull,
        reason: name,
      );
    }
    const taktOp =
        '[Nekomoe kissaten&VCB-Studio] takt op.Destiny [01][x265].mkv';
    expect(CloudMediaFileClassifier.episodeNumberFromName(taktOp), 1);
    expect(
      CloudMediaFileClassifier.classifyAsset('Show', taktOp, 'video'),
      'episode',
    );
  });

  test('recognizes supplementary videos and standalone movies', () {
    for (final name in [
      'Show Creditless ED (BD 1080p).mkv',
      'Show Info01 (BD 1080p).mkv',
      'Show [TVCM1][BDRip].mkv',
      'Show ノンテロップOP (BD 1080p).mkv',
      'Show [11.5][Ma10p_1080p].mkv',
      '[Henshin]_Show_no-credit_opening_(x264).mkv',
      '[AI-Raws] Show キャスト特番 (BD 1080p).mkv',
      '[AI-Raws] Movie Supporter\'s Gathering 2010 (BD 720p FLAC).mkv',
      'Movie Supporters’ Gathering2010 (BD 720p).mkv',
      '[Release]_Show_-_03 Appendix.avi',
      '[Release] Show - Hyakka 01 (BD 1080p).mkv',
      '[Candy Boy] EX01 (DVD 720p).mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.classifyAsset('Show', name, 'video'),
        'extra',
        reason: name,
      );
    }
    expect(
      CloudMediaFileClassifier.isClearlySupplementary('', 'The Appendix (BD 1080p).mkv'),
      isFalse,
    );
    expect(
      CloudMediaFileClassifier.classifyAsset('Show/Bonus', 'Logo.mkv', 'video'),
      'extra',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Show/OP & ED',
        'Show - OP.mkv',
        'video',
      ),
      'extra',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Show/Fan Disc',
        'Show [Map01].mkv',
        'video',
      ),
      'extra',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        '东方PVD 2010',
        '[Group] Touhou PVD - Fire Flower [DVDrip].mkv',
        'video',
      ),
      'extra',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'EX-ARM (2021) {tmdb-92401}',
        '[IrizaRaws] Ex-Arm - 01 (BDRip 1920x1080 x264 10bit FLAC).mkv',
        'video',
      ),
      'episode',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Standalone Movie',
        'Standalone Movie.mkv',
        'video',
        videoCount: 1,
        numberedVideoCount: 0,
      ),
      'episode',
    );
    expect(
      CloudMediaFileClassifier.episodeNumberFromName(
        '[VCB-Studio] Movie [1080p][HEVC].mkv',
      ),
      isNull,
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Show',
        'Unknown side story.mkv',
        'video',
        videoCount: 2,
        numberedVideoCount: 1,
      ),
      'review',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Interstella 5555 (2003)',
        '[Group] Interstella 5555 [DVDRip 960x720].mkv',
        'video',
        videoCount: 1,
        numberedVideoCount: 0,
      ),
      'episode',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Fairy Tail 第二季',
        '[ReinForce] Fairy Tail - 301 (BDRip 1080p).mkv',
        'video',
      ),
      'episode',
    );
  });

  test('recognizes movie naming without explicit episode markers', () {
    for (final sample in <Map<String, String>>[
      {
        'directory': '妖精的尾巴 第二季 & 最终季 (2014) {tmdb-46261}',
        'name':
            '[ReinForce] Gekijouban Fairy Tail ~Dragon Cry~ '
            '(BDRip 1920x1080 x264 FLAC).mkv',
      },
      {
        'directory': '银魂 THE FINAL (2021) {tmdb-732203}',
        'name':
            '[ReinForce] Gintama ~The Final~ '
            '(BDRip 1920x1080 x264 FLAC).mkv',
      },
      {
        'directory': '樱花大战 (2000) {tmdb-27885}',
        'name':
            '[アニメ DVD] サクラ大戦 活動写真 '
            '(1280x720 H.264／AVC AAC).mp4',
      },
      {
        'directory':
            'Fate Grand Order -终局特异点 冠位时间神殿所罗门- '
            '(2021) {tmdb-829920}',
        'name':
            "[Moozzi2] Fate Grand Order Shuukyoku Tokuiten Kan'i "
            'Jikan Shinden Solomon (BD 1920x1080).mkv',
      },
      {
        'directory': '遗迹守护者 (2022) {tmdb-94925}',
        'name':
            '[AI-Raws] スプリガン(1998) '
            '(BD HEVC 1920x1032 FLAC／AC3).mkv',
      },
      {
        'directory': '名侦探柯南 业火的向日葵 (2015) {tmdb-316873}',
        'name':
            '[SBSUB][CONAN][M19][BDRIP][1080P][AVC_FLAC]'
            '[CHS_CHT_JP].mkv',
      },
      {
        'directory': '你想活出怎样的人生 (2023) {tmdb-508883}',
        'name':
            '你想活出怎样的人生.The.Boy.and.the.Heron.2023.1080p.'
            'BDRip.x265.FLAC-CoolFansSub.mkv',
      },
    ]) {
      expect(
        CloudMediaFileClassifier.classifyAsset(
          sample['directory']!,
          sample['name']!,
          'video',
          videoCount: 12,
          numberedVideoCount: 11,
        ),
        'episode',
        reason: sample['name'],
      );
    }
  });

  test('directory-aware parsing ignores numeric work titles', () {
    const name = '[VCB-Studio] GO!GO!575 [Ma10p_1080p][x265_flac].mkv';
    const directory = 'GO!GO!575 (2014) {tmdb-73394}';
    expect(CloudMediaFileClassifier.episodeNumberFromName(name), 575);
    expect(
      CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
        directory,
        name,
      ),
      isNull,
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        directory,
        name,
        'video',
        videoCount: 1,
        numberedVideoCount: 0,
      ),
      'episode',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        '物语系列 外传季&怪物季 (2024) {tmdb-46195}',
        '[Moozzi2] Monogatari Series Off & Monster Season - 01 '
            '[ Orokamonogatari ] (BD 1920x1080).mkv',
        'video',
        videoCount: 15,
        numberedVideoCount: 14,
      ),
      'episode',
    );
  });

  test('release-year variants identify unnumbered feature films', () {
    expect(
      CloudMediaFileClassifier.classifyAsset(
        '你想活出怎样的人生 (2023) {tmdb-508883}',
        '你想活出怎样的人生.The.Boy.and.the.Heron.2023.1080p.'
            'BDRip.x265.FLAC-CoolFansSub.mkv',
        'video',
        videoCount: 2,
        numberedVideoCount: 0,
        unresolvedUnnumberedVideoCount: 2,
      ),
      'episode',
    );
  });

  test('embedded TMDB work markers identify standalone videos', () {
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'FLCL Alternative & FLCL Progressive (2018)',
        '[SweetSub&VCB-Studio] FLCL Alternative [Ma10p_1080p] '
            '[x265_flac] {tmdb-737931}.mkv',
        'video',
        videoCount: 2,
        numberedVideoCount: 0,
        unresolvedUnnumberedVideoCount: 2,
      ),
      'episode',
    );
  });

  test('only a lone unresolved unnumbered video becomes main content', () {
    const directory = '伊克西翁传说DT (2012) {tmdb-45822}';
    const name =
        '[AI-Raws] イクシオン サーガ DT マジでガチで '
        'イクシオンサーガやっちゃいました！① '
        '(BD HEVC 1920x1080 FLAC).mkv';
    expect(
      CloudMediaFileClassifier.classifyAsset(
        directory,
        name,
        'video',
        videoCount: 6,
        numberedVideoCount: 0,
        unresolvedUnnumberedVideoCount: 6,
      ),
      'review',
    );
    expect(
      CloudMediaFileClassifier.classifyAsset(
        directory,
        name,
        'video',
        videoCount: 6,
        numberedVideoCount: 5,
        unresolvedUnnumberedVideoCount: 1,
      ),
      'episode',
    );
  });

  test('explicit episode markers override numeric work titles', () {
    const samples = <Map<String, String>>[
      {
        'directory': '9-nine- 支配者的王冠 (2025) {tmdb-270931}',
        'name': '[DMG&SumiSora][9-nine-][09][1080P][GB].mp4',
      },
      {
        'directory': 'Fate kaleid liner 魔法少女☆伊莉雅 2wei Herz! (2015)',
        'name':
            '[VCB-Studio] Fate／Kaleid Liner Prisma Illya 2wei Herz! '
            '[02][Ma10p_1080p][x265_flac_aac].mkv',
      },
      {
        'directory': '『你们先走我断后』，于是10年后我成为了传说 (2026)',
        'name':
            '[Nix-Raws] Koko wa Ore ni Makasete Saki ni Ike to Ittekara '
            '10-nen ga Tattara Densetsu ni Natteita S01E10 '
            '[CR WEB-DL 1080p AVC AAC][SC_TC].mkv',
      },
      {
        'directory': '【第三代】Yes! 光之美少女5 (2007) {tmdb-34075}',
        'name':
            '[WBX-SUB] Yes! プリキュア5 EP05「プリキュアの資格」'
            '[BDrip][HEVC 1080P FLAC].mkv',
      },
      {
        'directory': '因为太怕痛就全点防御力了。2 (2023) {tmdb-96402}',
        'name': '[VCB-Studio] BOFURI 2 [02][Ma10p_1080p][x265_flac].mkv',
      },
      {
        'directory': 'PSYCHO-PASS 3 (2019)',
        'name': '[VCB-Studio] PSYCHO-PASS 3 [03][Ma10p_1080p][x265_flac].mkv',
      },
    ];
    for (final sample in samples) {
      expect(
        CloudMediaFileClassifier.classifyAsset(
          sample['directory']!,
          sample['name']!,
          'video',
        ),
        'episode',
        reason: sample['name'],
      );
    }
  });

  test('recognizes short episodes and unnumbered bonus naming families', () {
    for (final name in [
      '[FLsnow][Show][Mini-Ikamusume_Short_Story_1][1080p].mkv',
      '[AI-Raws] Show 先付けミニアニメ『花丸日記』①あぶらげ編.mkv',
      '[AI-Raws] Show ショートエピソード 01 ～絆～.mkv',
      '[Snow-Raws] Show 番外編 (BD 1920x1080).mkv',
      '[Snow-Raws] Show 特別編 (BD 1920x1080).mkv',
      'ぷち#特別編.mkv',
      'Show BDMenu1 [BDRip 1080p].mkv',
      '[VCB-Studio] Show [Special][Ma10p_1080p].mkv',
      '[AI-Raws] Show #EX (BD HEVC 1080p).mkv',
      '[IrizaRaws] Show - 12 Ending Special Ver (BDRip 1080p).mkv',
      '[VCB-Studio] Show [OVAv2][Ma10p_1080p].mkv',
      '[VCB-Studio] Show [Extra01][Ma10p_1080p].mkv',
      '[VCB-Studio] Show [WebSP][Hi10p_1080p].mkv',
      '[AI-Raws] Show PVCM集 (BD HEVC 1080p).mkv',
      '[AI-Raws] Show 放送直前特別番組 (BD HEVC 1080p).mkv',
      '[Group] Show English Credits (BD 1080p).mkv',
      '[VCB-Studio] Show [True End Episode][Ma10p_1080p].mkv',
      '[VCB-Studio] Show [Remix01][Ma10p_1080p].mkv',
      '[Sub][Show][Event][Blessing][BDRIP].mkv',
      '[AI-Raws] Show 特別企画Vol.1 (BD HEVC 1080p).mkv',
      '[Group] Show Season 1 Review Part1 (BDRip 1080p).mkv',
      '[Group] Show [Insert01][Ma10p_1080p].mkv',
      '[Group] Show ANOTHER WORLD [Record 2027][Ma10p_1080p].mkv',
      '[Group] Show One More Time, One More Chance [BDRip 1080p].mkv',
      '[Group] Show PVtri.5 [BDRip 1080p].mkv',
      '[Group] Show ~Karaoke ver.~ [BDRip 1080p].mkv',
      '[Group] Show [EX Season 01][Ma10p_1080p].mkv',
      '[Group] Show [Pre-show Reminder][BDRIP].mkv',
      '[Group] Promare SIDE Galo [Ma10p_1080p].mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.classifyAsset('Show', name, 'video'),
        'extra',
        reason: name,
      );
    }
  });

  test('Japanese WEB previews are extras before hash episode parsing', () {
    for (var number = 1; number <= 12; number++) {
      final name =
          '[AI-Raws] 29歳独身中堅冒険者の日常 WEB予告#${number.toString().padLeft(2, '0')} (BD HEVC 1920x1080 FLAC)[D10ABF0C].mkv';
      expect(
        CloudMediaFileClassifier.classifyAsset('Show', name, 'video'),
        'extra',
      );
    }
    for (final marker in ['WEB预告', 'WEB預告', 'Trailer', 'Preview', 'Teaser']) {
      expect(
        CloudMediaFileClassifier.classifyAsset(
          'Show',
          'Show $marker #01.mkv',
          'video',
        ),
        'extra',
      );
    }
    expect(
      CloudMediaFileClassifier.classifyAsset(
        'Show',
        'Show #01 WEB-DL.mkv',
        'video',
      ),
      'episode',
    );
  });

  test('Japanese non-credit openings and endings are extras', () {
    for (final name in [
      '[AI-Raws] Show ノンクレジットOP (BD HEVC 1920x1080 FLAC).mkv',
      '[AI-Raws] Show ノンクレジットED (BD HEVC 1920x1080 FLAC).mkv',
      '[AI-Raws] Show ノンクレジット OP2 (BD HEVC 1920x1080 FLAC).mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.classifyAsset('Show', name, 'video'),
        'extra',
        reason: name,
      );
    }
  });

  test('22/7 and numeric releases extract episode tokens, not title numbers', () {
    for (final name in [
      '[LoliHouse] 22／7 - 01 [BDRip 1080p HEVC-10bit FLAC AAC].mkv',
      '[AI-Raws] 29歳独身中堅冒険者の日常 #01 (BD HEVC 1920x1080 FLAC)[89A35093].mkv',
      '29歳独身中堅冒険者の日常 ＃01.mkv',
      '[ANK-Raws] 91 Days 01 (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv',
      'Lets.Play.S01E01.Life.is.S-Rank.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG.mkv',
      '[Group] 22／7 - 01 [1080p].mkv',
      '[Group] 22_7 - 01v2 [Ma10p_1080p].mkv',
      '01.mkv',
      '01 - title.mkv',
      '22／7 E01.mkv',
      '22／7 Episode 01.mkv',
      '22／7 (01).mkv',
      '[Group] 22／7 [01 Ma10p_1080p].mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(name),
        1,
        reason: name,
      );
      expect(
        CloudMediaFileClassifier.classifyAsset('22／7', name, 'video'),
        'episode',
      );
    }
    for (final name in [
      '22／7.mkv',
      '91 Days.mkv',
      '29歳独身中堅冒険者の日常.mkv',
      'Show [1080p].mkv',
      'Show [2020].mkv',
      'Show x265.mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.episodeNumberFromName(name),
        isNull,
        reason: name,
      );
    }
    for (final name in [
      '22／7 - 01 NCOP.mkv',
      '22／7 SP01.mkv',
      '22／7 OVA 01.mkv',
      '22／7 - 01 MV.mkv',
    ]) {
      expect(
        CloudMediaFileClassifier.classifyAsset('22／7', name, 'video'),
        'extra',
      );
    }
    expect(
      CloudMediaFileClassifier.classifyAsset(r'22／7\SPs', '01.mkv', 'video'),
      'extra',
    );
  });
}
