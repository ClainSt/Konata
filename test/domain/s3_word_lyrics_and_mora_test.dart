import 'package:flutter_test/flutter_test.dart';

import 'package:konata/domain/lyrics/qrc_lyric_parser.dart';
import 'package:konata/domain/lyrics/ttml_lyric_converter.dart';
import 'package:konata/domain/lyrics/yrc_lyric_parser.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/playback/karaoke_clock_extrapolator.dart';
import 'package:konata/domain/playback/lyric_version_matcher.dart';
import 'package:konata/domain/playback/mora_pace_estimator.dart';
import 'package:konata/infrastructure/lyrics/qrc_decryptor.dart';

void main() {
  group('S3 逐字解析与精确结束时间', () {
    test('YrcLyricParser 提取 JSON 署名、保留精确字结束时间并兼容文本内括号', () {
      const sampleYrc = '''
{"t":0,"c":[{"tx":"作词: "},{"tx":"Ayase"}]}
{"t":500,"c":[{"tx":"作曲: "},{"tx":"Ayase"}]}
[10000,2500](10000,400,0)無(10400,400,0)敵(10800,300,0)の(11200,500,0)笑顔
[13000,2000](13000,500,0)(Yeah!)(13600,600,0)世界
[16000,2000](16000,400,0)光(16500,500,0)る(17100,400,0)星
''';

      final parsed = YrcLyricParser.parse(sampleYrc);
      expect(parsed.hasWordTiming, isTrue);
      expect(parsed.validLineCount, equals(3));
      expect(parsed.credits, containsAll(<String>['作词: Ayase', '作曲: Ayase']));

      final doc = LrcParser.parseText(parsed.lrcContent);
      expect(doc.lines, hasLength(3));
      expect(doc.lines[0].primaryText, equals('無敵の笑顔'));
      expect(doc.lines[0].words, hasLength(4));
      expect(doc.lines[0].words[0].startSeconds, closeTo(10.0, 1e-3));
      expect(doc.lines[0].words[0].endSeconds, closeTo(10.4, 1e-3));
      // 验证字间停顿（11.1s ~ 11.2s）未被拉伸覆盖。
      expect(doc.lines[0].words[2].endSeconds, closeTo(11.1, 1e-3));
      expect(doc.lines[0].words[3].startSeconds, closeTo(11.2, 1e-3));
      expect(doc.lines[0].words[3].endSeconds, closeTo(11.7, 1e-3));
      expect(doc.lines[0].words[2].sweepProgressAt(11.15), equals(1.0));
      expect(doc.lines[0].words[3].sweepProgressAt(11.15), equals(0.0));
      // 文本内自带括号不得被误吞。
      expect(doc.lines[1].primaryText, equals('(Yeah!)世界'));
      expect(doc.lines[1].words.first.text, equals('(Yeah!)'));
    });

    test('YrcLyricParser 拒绝纯音乐占位或有效行不足', () {
      const placeholder = '[0,1000](0,1000,0)纯音乐，请欣赏';
      final parsed = YrcLyricParser.parse(placeholder);
      expect(parsed.lrcContent, isEmpty);
      expect(parsed.hasWordTiming, isFalse);
    });

    test('QrcDecryptor 3DES+zlib 加密解密闭环及 QrcLyricParser 偏移解析', () {
      const qrcXml = '''
<QrcInfos>
  <LyricInfo LyricCount="1">
    <Lyric_1 LyricType="1" LyricContent="[offset:500]
[0,1000]作词：Ayase(0,1000)
[10500,2000]無敵(10500,500)の(11100,400)笑顔(11600,600)
[13500,1800](Ah)(13500,500)光る(14100,700)
[16500,1500]未来へ(16500,900)"/>
  </LyricInfo>
</QrcInfos>
''';

      final cipherHex = QrcDecryptor.encryptToHex(qrcXml);
      expect(QrcDecryptor.isValidCipherHex(cipherHex), isTrue);
      final decrypted = QrcDecryptor.decryptHex(cipherHex);
      expect(decrypted, isNotNull);
      expect(decrypted, contains('<Lyric_1'));

      // 非法十六进制或截断密文必须安全返回 null。
      expect(QrcDecryptor.decryptHex('not-hex'), isNull);
      expect(QrcDecryptor.decryptHex('deadbeef'), isNull);

      final parsed = QrcLyricParser.parse(decrypted!);
      expect(parsed.hasWordTiming, isTrue);
      expect(parsed.validLineCount, equals(3));
      expect(parsed.credits, contains('作词：Ayase'));

      final doc = LrcParser.parseText(parsed.lrcContent);
      expect(doc.lines, hasLength(3));
      // `[offset:500]` 按通行约定使歌词提前 0.5 秒：10.5s -> 10.0s。
      expect(doc.lines[0].startSeconds, closeTo(10.0, 1e-3));
      expect(doc.lines[0].words[0].startSeconds, closeTo(10.0, 1e-3));
      expect(doc.lines[0].words[0].endSeconds, closeTo(10.5, 1e-3));
      expect(doc.lines[0].words[1].startSeconds, closeTo(10.6, 1e-3));
      expect(doc.lines[0].words[1].endSeconds, closeTo(11.0, 1e-3));
      expect(doc.lines[1].primaryText, equals('(Ah)光る'));
    });

    test('TtmlLyricConverter 保留 span.end 与 x-roman，并过滤和声容器内嵌套译文', () {
      const ttml =
          '<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"><body><div>'
          '<p begin="00:10.000" end="00:12.500">'
          '<span begin="00:10.000" end="00:10.450">光</span>'
          '<span begin="00:10.650" end="00:11.200">る</span>'
          '<span ttm:role="x-bg">'
          '<span begin="00:10.300" end="00:10.900">(la)</span>'
          '<span ttm:role="x-translation">背景译文应忽略</span>'
          '</span>'
          '<span ttm:role="x-translation">闪耀</span>'
          '<span ttm:role="x-roman">hikaru</span>'
          '</p></div></body></tt>';

      final converted = TtmlLyricConverter.convert(ttml);
      expect(converted.hasWordTiming, isTrue);
      expect(converted.hasTranslation, isTrue);
      expect(converted.hasRomaji, isTrue);
      expect(converted.lrc, isNot(contains('背景译文应忽略')));

      final doc = LrcParser.parseText(converted.lrc);
      expect(doc.lines, hasLength(1));
      final line = doc.lines.first;
      expect(line.primaryText, equals('光る'));
      expect(line.secondaryLines, equals(<String>['闪耀']));
      expect(line.romajiText, equals('hikaru'));
      expect(line.words, hasLength(2));
      expect(line.words[0].endSeconds, closeTo(10.45, 1e-3));
      expect(line.words[1].startSeconds, closeTo(10.65, 1e-3));
      expect(line.words[1].endSeconds, closeTo(11.20, 1e-3));
      expect(line.harmonyWords, hasLength(1));
      expect(line.harmonyWords.first.isHarmony, isTrue);
      expect(line.harmonyWords.first.endSeconds, closeTo(10.90, 1e-3));
    });

    test('parseActiveSpanLines 与 LrcParser 均一致应用 [offset:] 至行与逐字标签', () {
      const enhancedWithOffset = '''
[offset:500]
[00:10.00]<00:10.000-00:10.400>光る<00:10.600-00:11.000>なら
[00:10.00]bg:<00:10.200-00:10.800>Ah~
''';
      final spanLines = LyricVersionMatcher.parseActiveSpanLines(
        enhancedWithOffset,
      );
      expect(spanLines, hasLength(1));
      expect(spanLines.first.startSeconds, closeTo(9.5, 1e-3));
      expect(spanLines.first.spans[0].startSeconds, closeTo(9.5, 1e-3));
      expect(spanLines.first.spans[0].endSeconds, closeTo(9.9, 1e-3));
      expect(spanLines.first.spans[1].startSeconds, closeTo(10.1, 1e-3));
      expect(spanLines.first.spans[1].endSeconds, closeTo(10.5, 1e-3));
      expect(spanLines.first.spans[2].startSeconds, closeTo(9.7, 1e-3));
      expect(spanLines.first.spans[2].endSeconds, closeTo(10.3, 1e-3));

      final doc = LrcParser.parseText(enhancedWithOffset);
      expect(doc.lines.first.startSeconds, closeTo(9.5, 1e-3));
      expect(doc.lines.first.words[0].startSeconds, closeTo(9.5, 1e-3));
      expect(doc.lines.first.words[0].endSeconds, closeTo(9.9, 1e-3));
      expect(doc.lines.first.harmonyWords[0].startSeconds, closeTo(9.7, 1e-3));
    });
  });

  group('S3 音拍加权与时钟外推柔性纠偏', () {
    test('MoraPaceEstimator 区分日文汉字/中文汉字/拗音/促音/长音/逗号停顿与罗马音校准', () {
      // 「きゃ」= 1 拍（ゃ 权重 0 并入前导假名），「っ」= 1 拍，「ー」= 1 拍，总计 3 拍。
      final yoonProfile = MoraPaceEstimator.buildLineProfile('きゃっー');
      expect(yoonProfile.totalMora, closeTo(3.0, 1e-6));
      expect(yoonProfile.segments.first.startOffset, equals(0));
      expect(yoonProfile.segments.first.endOffset, equals(2));

      // 日文行含假名：汉字 1.7 拍；纯中文行：汉字 1.0 拍。
      final jaKanji = MoraPaceEstimator.estimateLineMora(
        '世界',
        isJapaneseSong: true,
      );
      final zhHanzi = MoraPaceEstimator.estimateLineMora(
        '世界',
        isJapaneseSong: false,
      );
      expect(jaKanji, closeTo(3.4, 1e-6));
      expect(zhHanzi, closeTo(2.0, 1e-6));

      // 行内逗号提供 0.3 拍停顿权重。
      final withComma = MoraPaceEstimator.estimateLineMora(
        'あ、い',
        isJapaneseSong: true,
      );
      expect(withComma, closeTo(2.3, 1e-6));

      // 拉丁英文按元音组估算。
      expect(MoraPaceEstimator.estimateLineMora('hello world'), closeTo(3.0, 1e-6));

      // 有罗马音时按罗马音音节校准整行音拍（hikaru = 3 拍，高于「光る」按 1.7+1.0=2.7 拍的启发式估值）。
      final calibrated = MoraPaceEstimator.estimateLineMora(
        '光る',
        romajiText: 'hi ka ru',
        isJapaneseSong: true,
      );
      expect(calibrated, closeTo(3.0, 1e-6));
    });

    test('LrcDocument 在解析期一次性预计算 secondsPerMora 与 isJapaneseSong', () {
      const sample = '''
[00:10.00]何が理由で何と思われど
[00:13.00]変わらないキミは特別です
[00:16.00]欲望そのままに世界を従えろ
[00:19.50]ゲームだと思えば張り切れるのです
[00:35.00]次のサビへ
''';
      final doc = LrcParser.parseText(sample);
      expect(doc.isJapaneseSong, isTrue);
      expect(doc.secondsPerMora, inInclusiveRange(0.10, 0.36));

      // 间奏前一行（gap = 15.5s）应按音拍曲速 × 1.15 封顶，不拖延至 35 秒。
      final interludeDur = MoraPaceEstimator.estimateVocalDurationSeconds(
        lineStartSeconds: doc.lines[3].startSeconds,
        nextLineStartSeconds: doc.lines[4].startSeconds,
        text: doc.lines[3].primaryText,
        secondsPerMora: doc.secondsPerMora,
        isJapaneseSong: doc.isJapaneseSong,
      );
      expect(interludeDur, lessThan(5.0));
      expect(interludeDur, greaterThan(2.5));
    });

    test('KaraokeClockExtrapolator 小于 60ms 柔性收敛、大于等于 60ms 立即硬对齐', () {
      final extrap = KaraokeClockExtrapolator();
      extrap.snapTo(10.0, clockSeconds: 0.0);
      expect(extrap.advanceTo(0.10), closeTo(10.10, 1e-6));

      // 底层汇报 10.145s（超前 +45ms < 60ms）：进入柔性纠偏而非瞬间跳变。
      final afterSoftSync = extrap.reconcileFromMediaClock(
        10.145,
        clockSeconds: 0.10,
        isPlaying: true,
      );
      expect(afterSoftSync, closeTo(10.10, 1e-6));
      expect(extrap.isSoftCorrecting, isTrue);

      // 推进 150ms 后平滑追上目标位置（10.145 + 0.150 = 10.295s）。
      final converged = extrap.advanceTo(0.25);
      expect(converged, closeTo(10.295, 1e-3));
      expect(extrap.isSoftCorrecting, isFalse);

      // 偏差达到 80ms（>= 60ms）：立即硬对齐至最新位置。
      final snapped = extrap.reconcileFromMediaClock(
        10.375,
        clockSeconds: 0.25,
        isPlaying: true,
      );
      expect(snapped, closeTo(10.375, 1e-6));
      expect(extrap.isSoftCorrecting, isFalse);
    });
  });
}
