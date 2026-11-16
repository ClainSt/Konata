import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ccplayer/domain/playback/chapter_skip_analyzer.dart';
import 'package:ccplayer/domain/playback/cue_and_lrc_parser.dart';
import 'package:ccplayer/domain/playback/playback_probe_stats.dart';

void main() {
  group('CueParser 分轨解析与多编码解码测试', () {
    test('精准解析整轨 CUE TRACK/INDEX 01 与 INDEX 00 前隙并推导结束时间', () {
      const cueContent = '''
PERFORMER "Evan Call"
TITLE "Frieren Original Soundtrack Disc 1"
FILE "Disc1.flac" WAVE
  TRACK 01 AUDIO
    TITLE "Journey of a Lifetime"
    PERFORMER "Evan Call"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "The End of One Journey"
    INDEX 00 03:10:00
    INDEX 01 03:12:37
  TRACK 03 AUDIO
    TITLE "Zoltraak"
    INDEX 01 06:00:00
''';
      final bytes = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(cueContent)]);
      final sheet = CueParser.parseBytes(bytes, totalDurationSeconds: 540.0);

      expect(sheet.title, equals('Frieren Original Soundtrack Disc 1'));
      expect(sheet.performer, equals('Evan Call'));
      expect(sheet.tracks, hasLength(3));

      expect(sheet.tracks[0].trackNumber, equals(1));
      expect(sheet.tracks[0].title, equals('Journey of a Lifetime'));
      expect(sheet.tracks[0].startSeconds, closeTo(0.0, 0.001));
      expect(sheet.tracks[0].endSeconds, closeTo(190.0, 0.001));

      expect(sheet.tracks[1].performer, equals('Evan Call'));
      expect(sheet.tracks[1].startSeconds, closeTo(192.493, 0.01));
      expect(sheet.tracks[1].endSeconds, closeTo(360.0, 0.001));

      expect(sheet.tracks[2].startSeconds, closeTo(360.0, 0.001));
      expect(sheet.tracks[2].endSeconds, closeTo(540.0, 0.001));
    });

    test('PlaybackTextDecoder 启发式区分 Shift-JIS 与 GBK 字节并支持回调桥接', () {
      // 含日文 Shift-JIS 平假名典型 0x82 段
      final sjisBytes = Uint8List.fromList([0x82, 0xA0, 0x82, 0xA2, 0x83, 0x41]);
      expect(
        PlaybackTextDecoder.detectLegacyEncoding(sjisBytes),
        equals(LegacyTextEncoding.shiftJis),
      );
      final decoded = PlaybackTextDecoder.decodeBytes(
        sjisBytes,
        legacyDecoder: (_, enc) =>
            enc == LegacyTextEncoding.shiftJis ? 'あいア' : null,
      );
      expect(decoded, equals('あいア'));
    });
  });

  group('LrcParser 同步双语歌词与二分高亮查找测试', () {
    test('合并同时间戳原文与翻译，支持 [offset:] 偏移与多时间戳复用', () {
      const lrc = '''
[ti:勇者]
[ar:YOASOBI]
[al:THE BOOK]
[offset:500]
[00:10.00]まるで御伽の話
[00:10.00]宛如童话般的故事
[00:20.00][01:05.50]終わらない旅
''';
      final doc = LrcParser.parseText(lrc);
      expect(doc.title, equals('勇者'));
      expect(doc.artist, equals('YOASOBI'));
      expect(doc.offsetMillis, equals(500));
      expect(doc.lines, hasLength(3));

      expect(doc.lines[0].startSeconds, closeTo(10.5, 0.001));
      expect(doc.lines[0].primaryText, equals('まるで御伽の話'));
      expect(doc.lines[0].secondaryLines, equals(['宛如童话般的故事']));

      expect(doc.lines[1].startSeconds, closeTo(20.5, 0.001));
      expect(doc.lines[2].startSeconds, closeTo(66.0, 0.001));

      expect(doc.activeIndexAt(5.0), equals(-1));
      expect(doc.activeIndexAt(15.0), equals(0));
      expect(doc.activeIndexAt(21.0), equals(1));
      expect(doc.activeIndexAt(70.0), equals(2));
    });
  });

  group('ChapterSkipAnalyzer OP/ED 二级智能识别测试', () {
    test('层级一显式命名精准匹配 OP 与带 C-Part / 无 C-Part 的 ED 动作', () {
      final planWithCPart = ChapterSkipAnalyzer.analyze(
        totalDurationSeconds: 1420.0,
        hasNextEpisode: true,
        rawChapters: const [
          PlaybackChapter(index: 0, title: 'Avant', startSeconds: 0, endSeconds: 70),
          PlaybackChapter(index: 1, title: 'OP', startSeconds: 70, endSeconds: 160),
          PlaybackChapter(index: 2, title: 'Part A', startSeconds: 160, endSeconds: 700),
          PlaybackChapter(index: 3, title: 'Ending', startSeconds: 1290, endSeconds: 1380),
          PlaybackChapter(index: 4, title: 'Next Preview', startSeconds: 1380, endSeconds: 1420),
        ],
      );

      expect(planWithCPart.opening?.kind, equals(SkipActionKind.skipOp));
      expect(planWithCPart.opening?.isTier1Named, isTrue);
      expect(planWithCPart.ending?.kind, equals(SkipActionKind.skipEdToCPart));
      expect(planWithCPart.activeWindowAt(95.0)?.label, equals('跳过 OP'));
      expect(planWithCPart.activeWindowAt(1320.0)?.kind, equals(SkipActionKind.skipEdToCPart));

      final planToNext = ChapterSkipAnalyzer.analyze(
        totalDurationSeconds: 1382.0,
        hasNextEpisode: true,
        rawChapters: const [
          PlaybackChapter(index: 0, title: 'Part B', startSeconds: 0, endSeconds: 1290),
          PlaybackChapter(index: 1, title: 'ED', startSeconds: 1290, endSeconds: 1380),
        ],
      );
      expect(planToNext.ending?.kind, equals(SkipActionKind.skipEdToNextEpisode));
    });

    test('层级二针对 >=18 分钟番剧未命名 85~96s 章节自动推导 OP/ED，短片不误触发', () {
      const genericChapters = [
        PlaybackChapter(index: 0, title: 'Chapter 01', startSeconds: 0, endSeconds: 60),
        PlaybackChapter(index: 1, title: 'Chapter 02', startSeconds: 60, endSeconds: 150),
        PlaybackChapter(index: 2, title: 'Chapter 03', startSeconds: 150, endSeconds: 1250),
        PlaybackChapter(index: 3, title: 'Chapter 04', startSeconds: 1250, endSeconds: 1340),
      ];

      final longEp = ChapterSkipAnalyzer.analyze(
        rawChapters: genericChapters,
        totalDurationSeconds: 1345.0,
        hasNextEpisode: true,
      );
      expect(longEp.opening?.isTier1Named, isFalse);
      expect(longEp.opening?.endSeconds, closeTo(150.0, 0.001));
      expect(longEp.ending?.isTier1Named, isFalse);
      expect(longEp.ending?.kind, equals(SkipActionKind.skipEdToNextEpisode));

      final shortClip = ChapterSkipAnalyzer.analyze(
        rawChapters: const [
          PlaybackChapter(index: 0, title: 'Chapter 01', startSeconds: 0, endSeconds: 90),
          PlaybackChapter(index: 1, title: 'Chapter 02', startSeconds: 90, endSeconds: 300),
        ],
        totalDurationSeconds: 300.0,
      );
      expect(shortClip.opening, isNull);
      expect(shortClip.ending, isNull);
    });
  });
}
