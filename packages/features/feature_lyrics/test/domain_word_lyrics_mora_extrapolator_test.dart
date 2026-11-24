import 'package:engine_playback/engine_playback.dart';
import 'package:engine_scraping/engine_scraping.dart';
import 'package:feature_lyrics/feature_lyrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('逐字歌词格式转换与解密解析', () {
    test('YrcLyricParser 解析头部元数据、逐字结束时间戳与屏蔽占位', () {
      const rawYrc = '''
{"t":0,"c":[{"tx":"作词: "},{"tx":"Tester"}]}
[10000,3000](10000,500,0)光(10500,800,0)の(11300,1700,0)海
[14000,2000](14000,1000,0)風(15000,1000,0)が(16000,0,0)吹く
[18000,2500](18000,800,0)空(18800,1700,0)へ
''';
      final parsed = YrcLyricParser.parse(rawYrc);
      expect(parsed.hasWordTiming, isTrue);
      expect(parsed.credits, contains('作词: Tester'));
      expect(parsed.validLineCount, 3);
      expect(parsed.lrcContent, contains('<00:10.000-00:10.500>光'));
      expect(parsed.lrcContent, contains('<00:11.300-00:13.000>海'));
      expect(parsed.lrcContent, contains('<00:16.000-00:16.000>吹く'));

      final spanLines = LyricVersionMatcher.parseActiveSpanLines(parsed.lrcContent);
      expect(spanLines.length, 3);
      expect(spanLines.first.spans.first.text, '光');
      expect(spanLines.first.spans.first.endSeconds, closeTo(10.5, 0.001));

      final placeholder = YrcLyricParser.parse('[0,1000](0,1000,0)纯音乐，请欣赏');
      expect(placeholder.validLineCount, 0);
      expect(placeholder.lrcContent, isEmpty);
    });

    test('QrcDecryptor 往返加解密与 QrcLyricParser 解析 XML 外框和偏移', () {
      const rawQrcXml = '''
<?xml version="1.0" encoding="utf-8"?>
<QrcInfos>
<LyricInfo>
<Lyric_1 LyricType="1" LyricContent="[offset:-500]
[0,2000]作词：TestWriter
[10000,2500]青(10000,600)い(10600,900)空(11500,1000)&apos;s
[15000,2000]夢(15000,1000)の(16000,1000)中
[20000,2000]星(20000,1000)が(21000,1000)降る" />
</LyricInfo>
</QrcInfos>
''';

      final hexCipher = QrcDecryptor.encryptToHex(rawQrcXml);
      expect(QrcDecryptor.isValidCipherHex(hexCipher), isTrue);
      expect(QrcDecryptor.isValidCipherHex('not-hex!'), isFalse);

      final decrypted = QrcDecryptor.decryptHex(hexCipher);
      expect(decrypted, isNotNull);
      expect(decrypted, contains('LyricContent='));

      final qrc = QrcLyricParser.parse(decrypted!);
      expect(qrc.hasWordTiming, isTrue);
      expect(qrc.credits, contains('作词：TestWriter'));
      expect(qrc.validLineCount, 3);
      // offset:-500 => [t - (-0.5)] = +0.5 秒
      expect(qrc.lrcContent, contains('[00:10.50]<00:10.500-00:11.100>青'));
      expect(qrc.lrcContent, contains("'s"));
    });

    test('TtmlLyricConverter 转换逐字主唱、嵌套和声、译文与罗马音并拦截无效 XML', () {
      const ttml = '''
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
  <body>
    <div>
      <p begin="00:10.000" end="00:13.000">
        <span begin="00:10.000" end="00:11.000">青</span>
        <span begin="00:11.000" end="00:12.500">空</span>
        <span ttm:role="x-bg">
          <span begin="00:11.200" end="00:12.800">(あぁ)</span>
        </span>
        <span ttm:role="x-translation">蓝色的天空</span>
        <span ttm:role="x-roman">ao zora</span>
      </p>
      <p begin="00:15.000" end="00:18.000">風になる</p>
      <p begin="00:20.000" end="00:23.000">駆け出す</p>
    </div>
  </body>
</tt>
''';

      final conv = TtmlLyricConverter.convert(ttml);
      expect(conv.hasWordTiming, isTrue);
      expect(conv.hasTranslation, isTrue);
      expect(conv.hasRomaji, isTrue);
      expect(conv.lrc, contains('<00:10.000-00:11.000>青'));
      expect(conv.lrc, contains('[00:10.00]bg:<00:11.200-00:12.800>(あぁ)'));
      expect(conv.lrc, contains('[00:10.00]蓝色的天空'));
      expect(conv.lrc, contains('[00:10.00]roma:ao zora'));

      final activeLines = LyricVersionMatcher.parseActiveSpanLines(conv.lrc);
      expect(activeLines.length, 3);
      expect(
        activeLines.first.spans.where((s) => !s.isHarmony).map((s) => s.text).join(),
        '青空',
      );
      expect(activeLines.first.spans.where((s) => s.isHarmony).length, 1);

      final invalid = TtmlLyricConverter.convert('<tt>broken');
      expect(invalid.lrc, isEmpty);
      expect(invalid.hasWordTiming, isFalse);
    });
  });

  group('音拍估算、时钟外推、三级偏移与曲目补全', () {
    test('MoraPaceEstimator 小拗音并拍与 LrcDocument 曲速及 LRC 偏移解析', () {
      final profile = MoraPaceEstimator.buildLineProfile('きゃくしゃ');
      // きゃ / く / しゃ 共 3 个音拍单元（小写 ゃ 归并入前一个假名单元）。
      expect(profile.totalMora, closeTo(3.0, 0.01));
      expect(profile.segments.length, 3);

      const sampleLrc = '''
[offset:200]
[00:10.00]きみがわらう
[00:10.00]你展露笑颜
[00:10.00]roma:kimi ga warau
[00:13.00]かぜがふいた
[00:16.00]ほしがひかる
''';
      final doc = LrcParser.parseText(sampleLrc);
      expect(doc.lines.length, 3);
      expect(doc.lines.first.startSeconds, closeTo(9.8, 0.01));
      expect(doc.lines.first.secondaryLines.first, '你展露笑颜');
      expect(doc.lines.first.romajiText, 'kimi ga warau');
      expect(doc.secondsPerMora, greaterThan(0.05));
    });

    test('KaraokeClockExtrapolator 小于60ms柔性追赶且不倒退，超过60ms或暂停立即对齐', () {
      final extrapolator = KaraokeClockExtrapolator();
      final t0 = extrapolator.snapTo(10.0, clockSeconds: 1.0);
      expect(t0, closeTo(10.0, 0.0001));

      // 前进 0.50 秒，外推位置到达 10.50，报告为 10.54（+40ms 偏差）应进入柔性追赶而非硬跳。
      final afterSoft = extrapolator.reconcileFromMediaClock(
        10.54,
        clockSeconds: 1.5,
        isPlaying: true,
      );
      expect(afterSoft, closeTo(10.50, 0.0001));
      expect(extrapolator.isSoftCorrecting, isTrue);

      final midSoft = extrapolator.advanceTo(1.575);
      final endSoft = extrapolator.advanceTo(1.66);
      expect(midSoft, greaterThan(afterSoft));
      expect(endSoft, greaterThan(midSoft));
      expect(extrapolator.isSoftCorrecting, isFalse);
      expect(endSoft, closeTo(10.54 + 0.16, 0.01));

      // >= 60ms 偏差立即硬对齐。
      final snapped = extrapolator.reconcileFromMediaClock(
        25.0,
        clockSeconds: 1.70,
        isPlaying: true,
      );
      expect(snapped, closeTo(25.0, 0.0001));
      expect(extrapolator.isSoftCorrecting, isFalse);

      // 暂停态即使偏差很小也直接硬对齐，不外推漂移。
      final pausedSnap = extrapolator.reconcileFromMediaClock(
        25.02,
        clockSeconds: 2.0,
        isPlaying: false,
      );
      expect(pausedSnap, closeTo(25.02, 0.0001));

      // 1.5 倍速推进。
      extrapolator.snapTo(30.0, clockSeconds: 3.0, playbackRate: 1.5);
      expect(extrapolator.advanceTo(3.2), closeTo(30.3, 0.0001));
    });

    test('LyricOffsetResolver 蓝牙与有线路由归类及三级偏移叠加范围钳制', () {
      expect(
        LyricOffsetResolver.classifyAudioRoute(deviceName: 'AirPods Pro'),
        LyricAudioRouteKind.bluetooth,
      );
      expect(
        LyricOffsetResolver.classifyAudioRoute(
          deviceFingerprint: 'sony_wh-1000xm5_a2dp',
        ),
        LyricAudioRouteKind.bluetooth,
      );
      expect(
        LyricOffsetResolver.classifyAudioRoute(deviceName: 'USB DAC Audio'),
        LyricAudioRouteKind.wired,
      );
      expect(LyricOffsetResolver.classifyAudioRoute(), LyricAudioRouteKind.wired);

      const snapshot = LyricOffsetSnapshot(
        trackOffsetMillis: 200,
        albumOffsetMillis: -100,
        routeOffsetMillis: 350,
        activeRouteKind: LyricAudioRouteKind.bluetooth,
        userOffsetLocked: true,
      );
      expect(snapshot.totalOffsetMillis, 450);
      expect(snapshot.totalOffsetSeconds, closeTo(0.45, 0.001));
      expect(LyricOffsetSnapshot.clampTrackOrAlbum(99999), 15000);
      expect(LyricOffsetSnapshot.clampRoute(-9999), -5000);
      expect(LyricOffsetResolver.formatOffsetSeconds(300), '+0.3s');
      expect(LyricOffsetResolver.formatOffsetSeconds(0), '0.0s');
    });

    test('BangumiTrackEnricher 恢复 Track 01 真实日文原名并附加跨语种别名', () {
      const tracks = [
        BangumiMusicTrack(
          subjectId: 9001,
          subjectTitle: '結束バンド',
          subjectTitleCn: '团结乐队',
          relation: '片头曲',
          trackNumber: 1,
          title: '青春コンプレックス',
          titleCn: '青春情结',
        ),
        BangumiMusicTrack(
          subjectId: 9001,
          subjectTitle: '結束バンド',
          subjectTitleCn: '团结乐队',
          relation: '片尾曲',
          trackNumber: 2,
          title: 'Distortion!!',
        ),
      ];

      expect(BangumiTrackEnricher.isWeakTrackTitle('Track 01'), isTrue);
      expect(BangumiTrackEnricher.isWeakTrackTitle('CD1-02'), isTrue);
      expect(BangumiTrackEnricher.isWeakTrackTitle('青春コンプレックス'), isFalse);

      final weakRes = BangumiTrackEnricher.enrich(
        title: 'Track 01',
        album: '結束バンド',
        trackNumber: 1,
        musicTracks: tracks,
      );
      expect(weakRes.hasEnhancement, isTrue);
      expect(weakRes.recoveredTitle, '青春コンプレックス');
      expect(weakRes.extraTitleAliases, containsAll(['青春コンプレックス', '青春情结']));

      final cnRes = BangumiTrackEnricher.enrich(
        title: '青春情结',
        album: '团结乐队',
        musicTracks: tracks,
      );
      expect(cnRes.recoveredTitle, isNull);
      expect(cnRes.extraTitleAliases, contains('青春コンプレックス'));
    });
  });
}
