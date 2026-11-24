import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' as cs;
import 'package:engine_playback/engine_playback.dart';
import 'package:test/test.dart';

import '../support/playback_test_fixtures.dart';

void main() {
  group('全仓唯一多编码解码模块与码表覆盖验证', () {
    test('精准识别 UTF-8(无/含BOM)、UTF-16LE/BE、Shift-JIS、GBK 与 Big5', () {
      final utf8NoBom = Uint8List.fromList(utf8.encode('简体中文与日本語テスト'));
      final resUtf8 = MultibyteTextDecoder.decodeWithInfo(utf8NoBom);
      expect(resUtf8.charset, equals(DetectedTextCharset.utf8));
      expect(resUtf8.text, equals('简体中文与日本語テスト'));

      final utf8Bom = Uint8List.fromList([
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('带BOM字幕'),
      ]);
      final resUtf8Bom = MultibyteTextDecoder.decodeWithInfo(utf8Bom);
      expect(resUtf8Bom.charset, equals(DetectedTextCharset.utf8Bom));
      expect(resUtf8Bom.hadBom, isTrue);

      final utf16LeBytes = Uint8List.fromList([
        0x5B,
        0x00,
        0x53,
        0x00,
        0x63,
        0x00,
        0x72,
        0x00,
        0x69,
        0x00,
        0x70,
        0x00,
        0x74,
        0x00,
      ]);
      expect(
        MultibyteTextDecoder.decodeWithInfo(utf16LeBytes).text,
        equals('[Script'),
      );

      final utf16BeBom = Uint8List.fromList([
        0xFE,
        0xFF,
        0x00,
        0x41,
        0x4E,
        0x2D,
      ]);
      final res16Be = MultibyteTextDecoder.decodeWithInfo(utf16BeBom);
      expect(res16Be.charset, equals(DetectedTextCharset.utf16Be));
      expect(res16Be.text, equals('A中'));

      final sjisBytes = Uint8List.fromList(cs.shiftJis.encode('葬送のフリーレン 第一話'));
      final resSjis = MultibyteTextDecoder.decodeWithInfo(sjisBytes);
      expect(resSjis.charset, equals(DetectedTextCharset.cp932ShiftJis));
      expect(resSjis.text, equals('葬送のフリーレン 第一話'));

      final gbkBytes = Uint8List.fromList(cs.gbk.encode('葬送的芙莉莲 第一话 简体字幕'));
      final resGbk = MultibyteTextDecoder.decodeWithInfo(gbkBytes);
      expect(resGbk.charset, equals(DetectedTextCharset.gb18030Gbk));
      expect(resGbk.text, equals('葬送的芙莉莲 第一话 简体字幕'));

      final big5Bytes = Uint8List.fromList([
        0xC1,
        0x63,
        0xC5,
        0xE9,
        0xA6,
        0x72,
        0xB9,
        0xF5,
        0xB4,
        0xFA,
        0xB8,
        0xD5,
      ]);
      final resBig5 = MultibyteTextDecoder.decodeWithInfo(big5Bytes);
      expect(resBig5.charset, equals(DetectedTextCharset.big5));
      expect(resBig5.text, equals('繁體字幕測試'));
      expect(PlaybackTextDecoder.decodeBytes(gbkBytes), equals('葬送的芙莉莲 第一话 简体字幕'));
    });

    test('Big5/GBK/Shift-JIS 内置紧凑码表全量映射数校验', () {
      expect(
        Big5Cp950Table.ensureTableForVerification().where((v) => v != 0).length,
        equals(Big5Cp950Table.totalMappedCount),
      );
      expect(
        OpenCcDictionaries.convert('後面的動畫聲音', toSimplified: true),
        equals('后面的动画声音'),
      );
      expect(
        OpenCcDictionaries.convert('头发发现后门', toSimplified: false),
        equals('頭髮發現後門'),
      );
    });
  });

  group('三态子集保护、双语 ASS OpenCC 与分段线性时间轴重映射', () {
    test('区分未子集/可还原映射子集/不透明混淆子集，保留日文假名与绘图块', () {
      const normalAss = '''
[Script Info]
ScriptType: v4.00+
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,這個字幕組的時間軸很準確
''';
      final normalRes = SubtitleContentProcessor.process(
        content: normalAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(normalRes.subsetState, equals(SubtitleSubsetState.unsubsetted));
      expect(normalRes.converted, isTrue);
      expect(normalRes.content, contains('这个字幕组的时间轴很准确'));

      const opaquePuaAss = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,\uE001\uE002\uE003\uE004
[Fonts]
fontname: X9K2M1+ObfFont.ttf
''';
      final opaqueRes = SubtitleContentProcessor.process(
        content: opaquePuaAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(
        opaqueRes.subsetState,
        equals(SubtitleSubsetState.opaqueObfuscatedSubset),
      );
      expect(opaqueRes.converted, isFalse);

      const bilingualAss = r'''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:02.00,0:00:05.00,Default,,0,0,0,,{\b1}後{\b0}面的{\i1}動畫{\i0}聲音\Nこれは日本語の測試です{\p1}m 0 0 l 100 0 100 100{\p0}
''';
      final res = SubtitleContentProcessor.process(
        content: bilingualAss,
        mode: SubtitleOpenCcMode.toSimplified,
      );
      expect(res.content, contains(r'{\b1}后{\b0}面的{\i1}动画{\i0}声音'));
      expect(
        res.content,
        contains(r'\Nこれは日本語の測試です{\p1}m 0 0 l 100 0 100 100{\p0}'),
      );
    });

    test('暂停对齐归零反应补偿，精确变换 ASS \\fade/\\t/50 音节卡拉 OK（<= 5ms）与 SRT/VTT', () {
      const pausedTransform = SubtitleTimelineTransform(
        rateScale: 1.0,
        offsetSeconds: 1.5,
        isPausedAlignment: true,
        reactionCompensationSeconds: -0.25,
      );
      expect(pausedTransform.effectiveReactionCompensation, equals(0.0));

      const scale = 25.0 / 23.976;
      const transform = SubtitleTimelineTransform(
        rateScale: scale,
        offsetSeconds: 2.0,
      );
      final karaokeSyllables = List<String>.generate(
        50,
        (i) => i.isEven ? r'{\kf17}音' : r'{\ko17}节',
      ).join();
      final ass = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:10.00,0:00:18.50,Default,,0,0,0,,{\\fade(255,0,255,100,400,2000,2500)\\t(100,500,0.5,\\fs48)}$karaokeSyllables
Dialogue: 0,0:00:00.50,0:00:01.00,Default,,0,0,0,,钳位下界测试
''';

      final remapped = SubtitleTimelineRemapper.remap(
        content: ass,
        transform: transform,
        format: SubtitleTextFormat.ass,
      );
      final kMatches = RegExp(r'\\(?:kf|ko)(\d+)').allMatches(remapped).toList();
      expect(kMatches, hasLength(50));
      final sumCs = kMatches.fold<int>(
        0,
        (acc, m) => acc + int.parse(m.group(1)!),
      );
      expect((sumCs * 10.0 - 850 * 10.0 * scale).abs(), lessThanOrEqualTo(5.0));

      final clampedAss = SubtitleTimelineRemapper.remap(
        content: ass,
        transform: const SubtitleTimelineTransform(offsetSeconds: -5.0),
      );
      expect(clampedAss, contains('Dialogue: 0,0:00:00.00,0:00:00.00,Default'));

      const vtt = '''
WEBVTT

00:01.000 --> 00:04.000
Hello <00:02.500>world <00:00:03.500>!
''';
      final remappedVtt = SubtitleTimelineRemapper.remap(
        content: vtt,
        transform: const SubtitleTimelineTransform(offsetSeconds: 1.5),
      );
      expect(remappedVtt, contains('00:02.500 --> 00:05.500'));
      expect(remappedVtt, contains('Hello <00:04.000>world <00:00:05.000>!'));
    });

    test('ASS UUEncode 精确余数截断往返与逐事件语义同构校验', () {
      for (final sample in [
        Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0xAA, 0xBB]),
        Uint8List.fromList([0x00, 0x01, 0x00, 0x00, 0x11, 0x22, 0x33]),
        Uint8List.fromList([0x4F, 0x54, 0x54, 0x4F, 0xFE, 0xDC, 0xBA, 0x98]),
      ]) {
        final decoded = AssUueFontDecoder.decode(
          AssUueFontDecoder.encode(sample),
        );
        expect(decoded, equals(sample));
      }

      final ttfBytes = PlaybackTestFixtures.generateMinimalDualGlyphTtf(
        familyName: 'KonataUueProbe',
      );
      final uueBlock = AssUueFontDecoder.encode(ttfBytes);
      final assWithFonts = '''
[Script Info]
ScriptType: v4.00+
[Events]
Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,测试中文字形
[Fonts]
fontname: KonataUueProbe.ttf
$uueBlock
''';
      final extracted = AssUueFontDecoder.extractEmbeddedFonts(assWithFonts);
      expect(extracted, hasLength(1));
      expect(extracted.first.bytes, equals(ttfBytes));

      final verifyOk = AssSemanticVerifier.verify(
        originalAss: assWithFonts,
        subsettedAss: assWithFonts,
      );
      expect(verifyOk.isValid, isTrue);
    });
  });
}
