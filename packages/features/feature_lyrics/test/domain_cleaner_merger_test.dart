import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('检索词扩展与多维相似度', () {
    test('清洗音轨序号、扩展名与下划线并扩展书名号及副标题别名', () {
      expect(LyricSearchQuery.cleanTitle('01. 恋のうた.flac'), '恋のうた');
      expect(LyricSearchQuery.cleanTitle('02_君の知らない物語.mp3'), '君の知らない物語');

      final query = LyricSearchQuery(
        title: '03. TVアニメ「ぼっち・ざ・ろっく！」OP「青春コンプレックス」 ～TV Edit～ (中文翻译)',
        artist: '桜咲千依 (CV. 洲崎綾)',
        extraTitleAliases: const ['青春情结'],
      );

      final aliases = query.titleAliases;
      expect(aliases, contains('青春コンプレックス'));
      expect(aliases, contains('青春情结'));
      expect(
        aliases.any((item) => item.contains('TVアニメ') && !item.contains('(中文翻译)')),
        isTrue,
      );

      final artists = query.searchArtists;
      expect(artists, contains('桜咲千依 (CV. 洲崎綾)'));
      expect(artists, contains('桜咲千依'));
      expect(artists, contains('洲崎綾'));
      expect(
        LyricTextSimilarity.artistSimilarity('結束バンド / 桜咲千依', '結束バンド'),
        greaterThanOrEqualTo(0.85),
      );
    });

    test('版本标签对立时触发显著版本罚分并过滤不匹配时长', () {
      final fullQuery = LyricSearchQuery(
        title: '残酷な天使のテーゼ',
        artist: '高橋洋子',
        durationSeconds: 245.0,
      );
      const fullCandidate = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'ncm-1',
        title: '残酷な天使のテーゼ',
        artist: '高橋洋子',
        durationSeconds: 245.0,
        lrcContent: '[00:10.00]line1\n[00:20.00]line2\n[00:30.00]line3\n[00:40.00]line4',
      );
      const tvCandidate = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'ncm-2',
        title: '残酷な天使のテーゼ (TV Size)',
        artist: '高橋洋子',
        durationSeconds: 89.0,
        lrcContent: '[00:10.00]line1\n[00:20.00]line2\n[00:30.00]line3\n[00:40.00]line4',
      );
      const versionMismatchSameLength = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'ncm-3',
        title: '残酷な天使のテーゼ (Remix)',
        artist: '高橋洋子',
        durationSeconds: 243.0,
        lrcContent: '[00:10.00]line1\n[00:20.00]line2\n[00:30.00]line3\n[00:40.00]line4',
      );

      final fullScore = LyricCandidateScorer.score(fullQuery, fullCandidate);
      final tvScore = LyricCandidateScorer.score(fullQuery, tvCandidate);
      final remixScore = LyricCandidateScorer.score(
        fullQuery,
        versionMismatchSameLength,
      );

      expect(fullScore, isNotNull);
      expect(fullScore!, greaterThanOrEqualTo(LyricMatchThresholds.autoAccept));
      expect(tvScore, isNull);
      expect(remixScore, isNotNull);
      expect(remixScore!, lessThan(fullScore));
    });
  });

  group('歌词清洗与时间轴校验', () {
    test('解码实体、提取制作人员署名、去除贡献者垃圾行并折叠相邻重复行', () {
      const raw = '''
[offset:+500]
[00:01.00]恋のうた - 鬼頭明里
[00:02.00]作词：Yunomi
[00:03.00]歌词贡献者：某热心网友
[00:04.00]腾讯音乐享有本翻译作品的著作权
[00:05.00]---
[00:10.50]恋&apos;の&#39;始まり&#x266A;
[00:10.50]恋&apos;の&#39;始まり&#x266A;
[00:15.50]風が吹く街角
[00:20.50]手を繋いで歩く
[00:25.50]いつまでも二人で
''';

      final result = LyricCleaner.clean(raw);
      expect(result.isPlaceholder, isFalse);
      expect(result.credits, contains('恋のうた - 鬼頭明里'));
      expect(result.credits, contains('作词：Yunomi'));
      expect(result.lines.length, 4);
      expect(result.lines.first.timeSeconds, closeTo(10.0, 0.01));
      expect(result.lines.first.text, "恋'の'始まり♪");
      expect(result.cleanedLrc, isNot(contains('歌词贡献者')));
      expect(result.cleanedLrc, isNot(contains('著作权')));
    });

    test('识别纯音乐占位与过少有效行并标记异常时间轴罚分', () {
      final instrumental = LyricCleaner.clean('[00:01.00]纯音乐，请欣赏');
      expect(instrumental.isPlaceholder, isTrue);
      expect(instrumental.cleanedLrc, isEmpty);

      final tooFew = LyricCleaner.clean('[00:05.00]只有一行\n[00:10.00]仅有两行');
      expect(tooFew.isPlaceholder, isTrue);

      const reversedLrc = '''
[00:10.00]第一句歌词时间正常
[00:30.00]第二句跳到三十秒
[00:15.00]第三句时间明显倒退
[00:25.00]第四句仍然乱序
[00:18.00]第五句继续倒退
''';
      final cleaned = LyricCleaner.clean(reversedLrc);
      expect(cleaned.isPlaceholder, isFalse);
      expect(
        cleaned.outOfOrderRatio,
        greaterThan(LyricMatchThresholds.maxOutOfOrderRatio),
      );

      final query = LyricSearchQuery(
        title: '逆序曲目',
        artist: '测试歌手',
        durationSeconds: 180.0,
      );
      const cleanCandidate = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'ok',
        title: '逆序曲目',
        artist: '测试歌手',
        durationSeconds: 180.0,
        lrcContent: '''
[00:10.00]第一句歌词时间正常
[00:20.00]第二句时间顺序递增
[00:30.00]第三句时间顺序递增
[00:40.00]第四句时间顺序递增
''',
      );
      const badTimingCandidate = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'bad',
        title: '逆序曲目',
        artist: '测试歌手',
        durationSeconds: 180.0,
        lrcContent: reversedLrc,
      );

      final goodScore = LyricCandidateScorer.score(query, cleanCandidate)!;
      final badScore = LyricCandidateScorer.score(query, badTimingCandidate)!;
      expect(
        goodScore - badScore,
        closeTo(LyricMatchThresholds.timingAnomalyPenalty, 0.001),
      );
    });

    test('非纯音乐曲目拒绝仅标注纯音乐的候选且校验纯文本有效性', () {
      final query = LyricSearchQuery(
        title: '正常人声曲',
        artist: '主唱',
        durationSeconds: 200.0,
      );
      const instrumentalCand = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'inst-1',
        title: '正常人声曲',
        artist: '主唱',
        durationSeconds: 200.0,
        isInstrumental: true,
        lrcContent: '[00:10.00]行1\n[00:20.00]行2\n[00:30.00]行3\n[00:40.00]行4',
      );
      final instScore = LyricCandidateScorer.score(query, instrumentalCand);
      expect(instScore, isNotNull);
      expect(instScore!, lessThan(1.0));

      expect(LyricCleaner.isValidPlainLyrics('line1\nline2\nline3\nline4'), isTrue);
      expect(LyricCleaner.isValidPlainLyrics('纯音乐，请欣赏'), isFalse);
      expect(LyricCleaner.isValidPlainLyrics('只有一行\n两行'), isFalse);
    });
  });

  group('同源动态规划合并、双语倒挂修复与跨源对称借轨', () {
    test('同源译文与罗马音动态规划对齐、兜底补漏且禁止超窗错配', () {
      const mainLrc = '''
[00:10.00]<00:10.00-00:11.00>光<00:11.00-00:12.00>の中へ
[00:10.00]bg:ラララ
[00:15.00]風が走るよ
[00:20.00]空を越えてく
[00:25.00]未来へ届く
''';
      const primaryTrans = '''
[00:10.10]走向光芒之中
[00:19.90]跨越天空前行
''';
      const fallbackTrans = '''
[00:10.05]兜底译文一
[00:15.10]微风奔跑着
[00:20.00]兜底译文三
[00:28.50]超出容限的孤立行不应强行错配
''';
      const romaji = '''
[00:10.02]hikari no naka e
[00:15.02]kaze ga hashiru yo
[00:20.02]sora wo koeteku
[00:25.02]mirai he todoku
''';

      final merged = LyricMerger.mergeSameSource(
        mainLrc: mainLrc,
        translationLrc: primaryTrans,
        fallbackTranslationLrc: fallbackTrans,
        romajiLrc: romaji,
      );

      expect(merged.hasTranslation, isTrue);
      expect(merged.hasRomaji, isTrue);
      expect(merged.lrcContent, contains('<00:10.00-00:11.00>光'));
      expect(merged.lrcContent, contains('bg:ラララ'));
      expect(merged.lrcContent, contains('[00:10.00]走向光芒之中'));
      expect(merged.lrcContent, contains('[00:15.00]微风奔跑着'));
      expect(merged.lrcContent, isNot(contains('超出容限的孤立行不应强行错配')));
      expect(merged.lrcContent, contains('[00:15.00]roma:kaze ga hashiru yo'));
      // 第 4 句 25.00 与 28.50 相差 3.5 秒超过 1.20 秒窗口，译文栏留空。
      final transRows = LyricMerger.extractTranslationRows(merged.lrcContent);
      expect(transRows.length, 3);
    });

    test('主行误放中文译文而副行含日文假名时自动纠偏交换双语位置', () {
      const invertedMain = '''
[00:10.00]向着繁星许下心愿
[00:15.00]黎明终将点亮夜空
[00:20.00]我们并肩迎风而行
''';
      const japaneseOriginal = '''
[00:10.05]星に願いを込めて
[00:15.05]夜明けが夜空を照らす
[00:20.05]肩を並べて風の中へ
''';

      final merged = LyricMerger.mergeSameSource(
        mainLrc: invertedMain,
        translationLrc: japaneseOriginal,
      );
      expect(merged.hasTranslation, isTrue);
      final primaryRows = LyricMerger.extractPrimaryRows(merged.lrcContent);
      final transRows = LyricMerger.extractTranslationRows(merged.lrcContent);

      expect(primaryRows.map((e) => e.text).toList(), [
        '星に願いを込めて',
        '夜明けが夜空を照らす',
        '肩を並べて風の中へ',
      ]);
      expect(transRows.map((e) => e.text).toList(), [
        '向着繁星许下心愿',
        '黎明终将点亮夜空',
        '我们并肩迎风而行',
      ]);
    });

    test('跨源交叉验证对称性与缓存复算一致且不破坏主候选逐字标签', () {
      const amllWordLrc = '''
[00:10.00]<00:10.000-00:10.600>青<00:10.600-00:11.200>空を
[00:10.00]bg:あぁ
[00:16.00]<00:16.000-00:16.800>駆<00:16.800-00:17.500>けてく
[00:22.00]<00:22.000-00:22.800>君<00:22.800-00:23.600>と今
[00:28.00]<00:28.000-00:28.900>光<00:28.900-00:29.800>る風
''';
      const neteaseBilingual = '''
[00:10.12]青空を
[00:10.12]奔向那片湛蓝天空
[00:10.12]roma:aozora wo
[00:16.10]駆けてく
[00:16.10]与微风一同飞驰
[00:16.10]roma:kaketeku
[00:22.15]君と今
[00:22.15]此刻与你同行
[00:22.15]roma:kimi to ima
[00:28.08]光る風
[00:28.08]闪耀的清风拂过
[00:28.08]roma:hikaru kaze
''';

      const primary = LyricCandidate(
        source: LyricSource.amll,
        sourceId: 'amll-1',
        title: '青空',
        artist: '歌手A',
        lrcContent: amllWordLrc,
        hasWordTiming: true,
      );
      const other = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'ncm-1',
        title: '青空',
        artist: '歌手A',
        lrcContent: neteaseBilingual,
        hasTranslation: true,
        hasRomaji: true,
      );

      final cache = LyricCrossSourceCache();
      final alignAB = cache.align(primary, other);
      final alignBA = cache.align(other, primary);
      expect(alignAB.matchRatio, closeTo(1.0, 0.001));
      expect(alignBA.matchRatio, closeTo(alignAB.matchRatio, 0.001));
      expect(alignAB.medianShiftSeconds, closeTo(-alignBA.medianShiftSeconds, 0.001));

      final enriched = LyricMerger.enrichWithCrossSource(
        primary,
        const [other],
        cache: cache,
      );
      expect(enriched.crossSourceAgreed, isTrue);
      expect(enriched.borrowedTranslation, isTrue);
      expect(enriched.borrowedRomaji, isTrue);
      expect(enriched.candidate.hasWordTiming, isTrue);
      expect(enriched.candidate.hasTranslation, isTrue);
      expect(enriched.candidate.hasRomaji, isTrue);
      expect(enriched.candidate.lrcContent, contains('<00:10.000-00:10.600>青'));
      expect(enriched.candidate.lrcContent, contains('bg:あぁ'));
      expect(enriched.candidate.lrcContent, contains('奔向那片湛蓝天空'));
      expect(enriched.candidate.lrcContent, contains('roma:aozora wo'));
    });
  });
}
