import 'package:konata/domain/models/episode.dart';
import 'package:konata/domain/models/work.dart';
import 'package:konata/domain/parsing/bdrip_parser.dart';
import 'package:konata/domain/parsing/title_normalizer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BdripParser.parseFolderName', () {
    test('提取 [tmdbid=xxx] 与年份并剥离标签', () {
      final hint = BdripParser.parseFolderName(
        '葬送的芙莉莲 (2023) [tmdbid=209867]',
      );
      expect(hint.tmdbId, 209867);
      expect(hint.tmdbMediaType, isNull);
      expect(hint.year, 2023);
      expect(hint.cleanTitle, '葬送的芙莉莲');
    });

    test('提取 {tmdb-xxx} / {tmdbtv-xxx} / {tmdbmovie-xxx} 并识别类型', () {
      final tv = BdripParser.parseFolderName('Steins;Gate {tmdbtv-42509}');
      expect(tv.tmdbId, 42509);
      expect(tv.tmdbMediaType, TmdbMediaType.tv);
      expect(tv.cleanTitle, 'Steins;Gate');

      final movie = BdripParser.parseFolderName(
        'Blade Runner 2049 (2017) {tmdbmovie-335984}',
      );
      expect(movie.tmdbId, 335984);
      expect(movie.tmdbMediaType, TmdbMediaType.movie);
      expect(movie.year, 2017);
      expect(movie.cleanTitle, 'Blade Runner 2049');
    });
  });

  group('BdripParser.parseFileName', () {
    test('保留数字番名并准确提取 VCB-Studio 压制组与编码规格', () {
      final parsed = BdripParser.parseFileName(
        '[VCB-Studio] 86 -Eighty Six- [01][Ma10p_1080p][x265_flac].mkv',
      );
      expect(parsed.cleanTitle, '86 -Eighty Six');
      expect(parsed.season, 1);
      expect(parsed.episode, 1);
      expect(parsed.category, EpisodeCategory.main);
      expect(parsed.releaseGroup, 'VCB-Studio');
      expect(parsed.videoCodec, 'HEVC');
      expect(parsed.bitDepth, '10bit');
      expect(parsed.resolution, '1080p');
      expect(parsed.audioCodec, 'FLAC');
    });

    test('同时提取压制组与字幕组', () {
      final parsed = BdripParser.parseFileName(
        '[VCB-Studio][SweetSub] Bocchi the Rock! [05][1080p][HEVC][10bit][AAC].mkv',
      );
      expect(parsed.cleanTitle, 'Bocchi the Rock!');
      expect(parsed.episode, 5);
      expect(parsed.releaseGroup, 'VCB-Studio');
      expect(parsed.subtitleGroup, 'SweetSub');
      expect(parsed.videoCodec, 'HEVC');
      expect(parsed.bitDepth, '10bit');
      expect(parsed.audioCodec, 'AAC');
    });

    test('识别联合组与 S02E03 季集格式', () {
      final parsed = BdripParser.parseFileName(
        '[Moozzi2&Kamigami-Sub] Mob Psycho 100 S02E03 (2160p AV1 OPUS).mkv',
      );
      expect(parsed.cleanTitle, 'Mob Psycho 100');
      expect(parsed.season, 2);
      expect(parsed.episode, 3);
      expect(parsed.releaseGroup, 'Moozzi2');
      expect(parsed.subtitleGroup, 'Kamigami-Sub');
      expect(parsed.resolution, '2160p');
      expect(parsed.videoCodec, 'AV1');
      expect(parsed.audioCodec, 'OPUS');
    });

    test('正确识别 NCOP/NCED/PV/Menu/OVA 特典分类', () {
      final ncop = BdripParser.parseFileName(
        '[VCB-Studio] K-ON! [NCOP1][Ma10p_1080p][x265_flac].mkv',
      );
      expect(ncop.category, EpisodeCategory.extra);
      expect(ncop.extraType, ExtraKind.ncop);
      expect(ncop.season, 0);

      final menu = BdripParser.parseFileName(
        '[ANK-Raws] Fate stay night [Menu02][1080p][x264_aac].mkv',
      );
      expect(menu.category, EpisodeCategory.extra);
      expect(menu.extraType, ExtraKind.menu);
      expect(menu.releaseGroup, 'ANK-Raws');
      expect(menu.videoCodec, 'AVC');
    });

    test('真实云盘回归：2.5次元的诱惑不被误判为小数半集特典，且保留正确集号与10bit色深', () {
      final ep = BdripParser.parseFileName(
        '[VCB-Studio] 2.5-jigen no Ririsa [13][Ma10p_1080p][x265_flac].mkv',
        relativePath:
            r'2.5次元的诱惑 (2024) {tmdb-216074}\[VCB-Studio] 2.5-jigen no Ririsa [13][Ma10p_1080p][x265_flac].mkv',
      );
      expect(ep.category, EpisodeCategory.main);
      expect(ep.episode, 13);
      expect(ep.fractionalEpisode, isNull);
      expect(ep.bitDepth, '10bit');
      expect(ep.cleanTitle, '2.5-jigen no Ririsa');
    });

    test('真实云盘回归：Maesetsu! Opening Act 正片不被误判为 NCOP 特典', () {
      final ep = BdripParser.parseFileName(
        '[Shiniori-Raws] Maesetsu! Opening Act - 01 (WEBRip 1280x720 x265 10bit AAC).mp4',
      );
      expect(ep.category, EpisodeCategory.main);
      expect(ep.episode, 1);
      expect(ep.cleanTitle, 'Maesetsu! Opening Act');
    });

    test('真实云盘回归：识别 YUV420P10 色深、[14(Final Act 01)] 集号、与 [180-kimimimi] 标题保护', () {
      final yuv10 = BdripParser.parseFileName(
        '[ANK-Raws] あっちこっち 01 (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv',
      );
      expect(yuv10.bitDepth, '10bit');
      expect(yuv10.videoCodec, 'HEVC');
      expect(yuv10.episode, 1);

      final finalAct = BdripParser.parseFileName(
        '[VCB-Studio] BUDDY COMPLEX [14(Final Act 01)][Ma10p_1080p][x265_flac].mkv',
      );
      expect(finalAct.episode, 14);
      expect(finalAct.cleanTitle, 'BUDDY COMPLEX');

      final kimimimi = BdripParser.parseFileName(
        '[Nekomoe kissaten][180-kimimimi][01][1080p][JPSC].mp4',
        folderTitle: '180秒能让你的耳朵幸福吗？ (2021) {tmdb-124576}',
      );
      expect(kimimimi.releaseGroup, 'Nekomoe kissaten');
      expect(kimimimi.cleanTitle, '180-kimimimi');
      expect(kimimimi.episode, 1);

      final halfEp = BdripParser.parseFileName(
        '[UHA-WINGS&VCB-Studio] EIGHTY SIX [11.5][Ma10p_1080p][x265_flac].mkv',
      );
      expect(halfEp.fractionalEpisode, '11.5');
      expect(halfEp.cleanTitle, 'EIGHTY SIX');
    });

    test('真实云盘回归：准确识别 Creditless Opening/Ending、WEB予告、Info01、IV01 与 ミュージッククリップ', () {
      expect(
        BdripParser.parseFileName(
          'Real Drive - Creditless Ending [DVDRip 1280x720 x264 AC3].mkv',
        ).extraType,
        ExtraKind.nced,
      );
      expect(
        BdripParser.parseFileName(
          '[AI-Raws] 29歳独身中堅冒険者の日常 WEB予告#01 (BD HEVC 1920x1080 FLAC)[D10ABF0C].mkv',
        ).extraType,
        ExtraKind.pv,
      );
      expect(
        BdripParser.parseFileName(
          '[AI-Raws] 光が死んだ夏 予告映像#01 (BD HEVC 1920x1080 FLAC)[BCBE94C4].mkv',
        ).extraType,
        ExtraKind.pv,
      );
      expect(
        BdripParser.parseFileName(
          '[ANK-Raws] 91 Days Info01 (BDrip 1920x1080 HEVC-YUV420P10 FLAC).mkv',
        ).extraType,
        ExtraKind.pv,
      );
      expect(
        BdripParser.parseFileName(
          '[SweetSub&VCB-Studio] 16bit Sensation Another Layer [IV01][Ma10p_1080p][x265_aac].mkv',
        ).extraType,
        ExtraKind.sp,
      );
      expect(
        BdripParser.parseFileName(
          '[AI-Raws&ANK-Raws] 劇場版 プロジェクトセカイ 壊れたセカイと歌えないミク ミュージッククリップ「FUN!!」 (BD HEVC 1920x1080 FLAC)[B80E24AE].mkv',
        ).extraType,
        ExtraKind.mv,
      );
    });
  });

  group('TitleNormalizer', () {
    test('繁简汉字、全角半角与乘号折叠等价', () {
      expect(
        TitleNormalizer.fold('進擊的巨人'),
        TitleNormalizer.fold('进击的巨人'),
      );
      expect(
        TitleNormalizer.fold('ＳＰＹ×ＦＡＭＩＬＹ'),
        TitleNormalizer.fold('Spy x Family'),
      );
    });
  });

  group('云盘真实文件名正片与特典边界回归', () {
    test('含空格字幕组、语言标记、_CN/_JP与Renew技术标签剥离干净', () {
      final groupSpaced = BdripParser.parseFileName(
        '[Billion Meta Lab] Ore no Nounai Sentakushi ga, Gakuen Love Come o Zenryoku de Jama Shiteiru [01][1080p][HEVC 10bit].mkv',
      );
      expect(groupSpaced.releaseGroup, 'Billion Meta Lab');
      expect(groupSpaced.episode, 1);
      expect(
        groupSpaced.cleanTitle,
        'Ore no Nounai Sentakushi ga, Gakuen Love Come o Zenryoku de Jama Shiteiru',
      );

      final langTag = BdripParser.parseFileName(
        '[VCB-Studio] Tokyo_24th_Ward [01][GB_CN][Renew][Ma10p_1080p][x265_flac].mkv',
      );
      expect(langTag.episode, 1);
      expect(langTag.cleanTitle, 'Tokyo_24th_Ward');

      final jpLang = BdripParser.parseFileName(
        '[KitaujiSub] Kimi ga Shinu made [01][CHS_JP&CHT_JP][1080P][HEVC_AAC].mkv',
      );
      expect(jpLang.episode, 1);
      expect(jpLang.cleanTitle, 'Kimi ga Shinu made');
    });

    test('复杂集号格式：EP、巻ノ一、破折号单双数字、53-99高位裸数字、多集范围与分辨率边界', () {
      final epTight = BdripParser.parseFileName(
        '[WBX-SUB] キラキラ☆プリキュアアラモードEP37「サクラ咲く！」[BDrip][HEVC 1080P FLAC].mkv',
      );
      expect(epTight.episode, 37);
      expect(epTight.category, EpisodeCategory.main);

      final kanjiRoll = BdripParser.parseFileName(
        'うたわれるもの 巻ノ一.mkv',
      );
      expect(kanjiRoll.episode, 1);

      final karaNoKyoukai = BdripParser.parseFileName(
        '[VCB-Studio] Kara no Kyoukai - 1 - Overlooking View [Ma10p_1080p][x265_flac].mkv',
      );
      expect(karaNoKyoukai.episode, 1);
      expect(karaNoKyoukai.category, EpisodeCategory.main);

      final fairyTail240 = BdripParser.parseFileName(
        'Fairy Tail - 240 [1080p].mkv',
      );
      expect(fairyTail240.episode, 240);

      final rinne75 = BdripParser.parseFileName(
        'Kyoukai no Rinne 75 [1080p].mkv',
      );
      expect(rinne75.episode, 75);

      final multiRange = BdripParser.parseFileName(
        "[BeanSub] Chi's Sweet Home - 33-44 [BDRip][1080p][AVC_AAC].mkv",
      );
      expect(multiRange.episode, 33);
      expect(multiRange.episodeEnd, 44);
    });

    test('正片标题含疑似特典词不误判：takt op.、初舞台、With_Ending、VS Opening Theme', () {
      final taktOp = BdripParser.parseFileName(
        '[Nekomoe kissaten&VCB-Studio] takt op.Destiny [01][Ma10p_1080p][x265_flac_aac].mkv',
      );
      expect(taktOp.category, EpisodeCategory.main);
      expect(taktOp.episode, 1);

      final precureStage = BdripParser.parseFileName(
        '[WBX-SUB] ふたりはプリキュア EP37「いざ初舞台！！負けるなロミオとジュリエット」[BDrip][HEVC 1080P FLAC].mkv',
      );
      expect(precureStage.category, EpisodeCategory.main);
      expect(precureStage.episode, 37);

      final withEnding = BdripParser.parseFileName(
        '[TxxZ&A.I.R.nesSub][Soukyuu_no_Fafner_Exodus][22][With_Ending][BDRIP][1920x1080][HEVC_FLAC].mkv',
      );
      expect(withEnding.category, EpisodeCategory.main);
      expect(withEnding.episode, 22);
    });

    test('真特典识别：Trailers&TV-Spots、NCOP1v2、ノンクレOP、Menu(Vol.01)、特別編ED全画面版', () {
      expect(
        BdripParser.parseFileName('Trailers&TV-Spots.mkv').extraType,
        ExtraKind.pv,
      );
      expect(
        BdripParser.parseFileName('NCOP1v2.mkv').extraType,
        ExtraKind.ncop,
      );
      expect(
        BdripParser.parseFileName('ノンクレOP.mkv').extraType,
        ExtraKind.ncop,
      );
      expect(
        BdripParser.parseFileName('Menu(Vol.01).mkv').extraType,
        ExtraKind.menu,
      );
      expect(
        BdripParser.parseFileName(
          '[AI-Raws] 高校星歌劇-スタミュ- 第3期 特別編ED全画面版 (BD HEVC 1920x1080)[8F85A38F].mkv',
        ).extraType,
        ExtraKind.sp,
      );
    });

    test('独立特别篇作品（目录自身含特别篇）判为正片，TV 目录内特别篇判为 SP', () {
      final standaloneMovie = BdripParser.parseFileName(
        '[Airota&VCB-Studio] Tokubetsu Hen Hibike! Euphonium ~Ensemble Contest~ [Ma10p_1080p][x265_flac].mkv',
        relativePath:
            '动画-多作品/吹响吧！上低音号系列/特别篇 吹响吧！上低音号～合奏比赛～ (2023) {tmdb-1108306}/[Airota&VCB-Studio] Tokubetsu Hen Hibike! Euphonium ~Ensemble Contest~ [Ma10p_1080p][x265_flac].mkv',
      );
      expect(standaloneMovie.category, EpisodeCategory.main);
      expect(standaloneMovie.extraType, isNull);

      final standaloneMushishi = BdripParser.parseFileName(
        'Mushishi Tokubetsu Hen - Hihamu Kage [BDRip 1920x1080 x264 FLAC].mkv',
        relativePath:
            '动画-多作品/虫师系列/虫师 特別篇 蚀日之翳/Mushishi Tokubetsu Hen - Hihamu Kage [BDRip 1920x1080 x264 FLAC].mkv',
      );
      expect(standaloneMushishi.category, EpisodeCategory.main);

      final tvSp = BdripParser.parseFileName(
        '[Snow-Raws] 青春x機関銃 特別編 (BD 1920x1080 HEVC-YUV420P10 FLAC).mkv',
        relativePath:
            '动画-单作品/青春×机关枪 (2015) {tmdb-63088}/[Snow-Raws] 青春x機関銃 特別編 (BD 1920x1080 HEVC-YUV420P10 FLAC).mkv',
      );
      expect(tvSp.category, EpisodeCategory.extra);
      expect(tvSp.extraType, ExtraKind.sp);
    });
  });
}
