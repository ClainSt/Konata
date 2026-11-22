import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:konata/domain/lyrics/lyric_candidate.dart';
import 'package:konata/domain/lyrics/lyric_candidate_scorer.dart';
import 'package:konata/domain/lyrics/lyric_cleaner.dart';
import 'package:konata/domain/lyrics/lyric_merger.dart';
import 'package:konata/domain/lyrics/lyric_search_query.dart';
import 'package:konata/domain/models/media_source.dart';
import 'package:konata/domain/models/media_variant.dart';
import 'package:konata/domain/playback/cue_and_lrc_parser.dart';
import 'package:konata/domain/repositories/file_system_gateway.dart';
import 'package:konata/infrastructure/players/audio_art_extractor.dart';
import 'package:konata/infrastructure/sources/byte_stream_source_gateway.dart';
import 'package:konata/infrastructure/sources/source_gateway_factory.dart';

/// 构造包含单个 `VORBIS_COMMENT` 块的合法 FLAC 字节头。
Uint8List _buildFlacWithVorbisComments(List<String> comments) {
  final payload = BytesBuilder();
  void writeU32Le(int v) {
    payload.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  }

  final vendor = utf8.encode('KonataTestEncoder');
  writeU32Le(vendor.length);
  payload.add(vendor);
  writeU32Le(comments.length);
  for (final c in comments) {
    final bytes = utf8.encode(c);
    writeU32Le(bytes.length);
    payload.add(bytes);
  }
  final block = payload.toBytes();
  final out = BytesBuilder()
    ..add(utf8.encode('fLaC'))
    // 末块标志 0x80 | 块类型 4（VORBIS_COMMENT）。
    ..add([
      0x84,
      (block.length >> 16) & 0xFF,
      (block.length >> 8) & 0xFF,
      block.length & 0xFF,
    ])
    ..add(block);
  return out.toBytes();
}

/// 构造包含单帧 ID3v2.3 标签的合法字节头。
Uint8List _buildId3v23SingleFrame(String frameId, Uint8List payload) {
  final frameSize = payload.length;
  final totalTagSize = 10 + frameSize;
  int syncSafeByte(int v, int shift) => (v >> shift) & 0x7F;
  final out = BytesBuilder()
    ..add(utf8.encode('ID3'))
    ..add([3, 0, 0])
    ..add([
      syncSafeByte(totalTagSize, 21),
      syncSafeByte(totalTagSize, 14),
      syncSafeByte(totalTagSize, 7),
      syncSafeByte(totalTagSize, 0),
    ])
    ..add(ascii.encode(frameId))
    ..add([
      (frameSize >> 24) & 0xFF,
      (frameSize >> 16) & 0xFF,
      (frameSize >> 8) & 0xFF,
      frameSize & 0xFF,
    ])
    ..add([0, 0])
    ..add(payload);
  return out.toBytes();
}

class _MemoryByteGateway
    implements MediaSourceGateway, ByteRangeReadableGateway {
  _MemoryByteGateway(this.files);

  final Map<String, Uint8List> files;

  @override
  Future<List<RemoteEntry>> listDirectory(String relativePath) async {
    return [
      for (final path in files.keys)
        RemoteEntry(
          name: path.split('/').last,
          relativePath: path,
          isDirectory: false,
          size: files[path]!.length,
        ),
    ];
  }

  @override
  Future<Stream<List<int>>> openByteRange(
    String relativePath, {
    required int start,
    int? endInclusive,
  }) async {
    final data = files[relativePath]!;
    final end = endInclusive == null
        ? data.length
        : (endInclusive + 1).clamp(start, data.length);
    return Stream<List<int>>.value(data.sublist(start, end));
  }

  @override
  Future<int?> probeFileLength(String relativePath) async =>
      files[relativePath]?.length;

  @override
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  }) async => null;

  @override
  Future<String?> testConnection() async => null;

  @override
  Future<void> close() async {}
}

class _FixedGatewayFactory extends MediaSourceGatewayFactory {
  const _FixedGatewayFactory(this.gateway);

  final MediaSourceGateway gateway;

  @override
  Future<MediaSourceGateway> create(
    MediaSource source, {
    String? passwordOverride,
    bool clearPassword = false,
  }) async => gateway;
}

void main() {
  group('LyricCleaner 清洗、署名提取与纯音乐占位拦截', () {
    test('提取作词/作曲/编曲及首行标题署名，剔除贡献者行、HTML 实体与相邻重复行', () {
      const raw = '''
[00:00.00]unravel (《东京食尸鬼》OP) - TK from 凛として時雨
[00:00.20]作词 : TK from 凛として時雨
[00:00.40]作曲 : TK from 凛として時雨
[00:00.60]歌词贡献者：某热心网友
[00:01.00]教えて 教えてよ &apos;その仕組み&apos;を
[00:01.08]教えて 教えてよ &apos;その仕組み&apos;を
[00:07.40]僕の中に誰がいるの？
[00:15.10]壊れた 壊れたよ この世界で
[00:22.00]//
''';
      final result = LyricCleaner.clean(raw);
      expect(result.isPlaceholder, isFalse);
      expect(result.credits, hasLength(3));
      expect(result.credits.first, contains('unravel'));
      expect(result.lines, hasLength(3));
      expect(result.lines.first.text, equals("教えて 教えてよ 'その仕組み'を"));
      expect(result.cleanedLrc, isNot(contains('歌词贡献者')));
      expect(result.cleanedLrc, isNot(contains('//')));
    });

    test('网易云纯音乐占位与有效行 <= 2 一律判零分', () {
      final query = LyricSearchQuery(
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240,
      );
      const placeholder = LyricCandidate(
        source: LyricSource.netease,
        sourceId: '1',
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240,
        lrcContent: '[00:00.00]纯音乐，请欣赏',
      );
      const tooShort = LyricCandidate(
        source: LyricSource.netease,
        sourceId: '2',
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240,
        lrcContent: '[00:00.00]作词：TK\n[00:10.00]只有一行有效歌词\n[00:20.00]第二行',
      );
      expect(LyricCandidateScorer.score(query, placeholder), equals(0.0));
      expect(LyricCandidateScorer.score(query, tooShort), equals(0.0));

      // 来源显式声明纯音乐而本曲非伴奏时，最终得分必须低于 lowConfidence 阈值，杜绝误显示。
      const markedInst = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: '3',
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240,
        isInstrumental: true,
        lrcContent: '[00:01.00]第一行\n[00:05.00]第二行\n[00:09.00]第三行',
      );
      expect(
        LyricCandidateScorer.score(query, markedInst)!,
        lessThan(LyricMatchThresholds.lowConfidence),
      );
    });

    test('时间轴异常校验：逆序行超 10% 或末行越界时长 + 3s 触发扣分', () {
      final query = LyricSearchQuery(
        title: 'アイドル',
        artist: 'YOASOBI',
        durationSeconds: 60.0,
      );
      const normal = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'ok',
        title: 'アイドル',
        artist: 'YOASOBI',
        durationSeconds: 60.0,
        lrcContent:
            '[00:05.00]一行目\n[00:15.00]二行目\n[00:25.00]三行目\n[00:40.00]四行目',
      );
      const overflow = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'bad',
        title: 'アイドル',
        artist: 'YOASOBI',
        durationSeconds: 60.0,
        lrcContent:
            '[00:05.00]一行目\n[00:15.00]二行目\n[00:25.00]三行目\n[01:25.00]严重越界末行',
      );
      final sOk = LyricCandidateScorer.score(query, normal)!;
      final sBad = LyricCandidateScorer.score(query, overflow)!;
      expect(sOk - sBad, closeTo(LyricMatchThresholds.timingAnomalyPenalty, 1e-6));
    });
  });

  group('LyricMerger 同源 DP 对齐、跨源借译文与独立罗马音解析', () {
    test('同源 DP 合并支持毫秒漂移、跳过 // 与同文译文，并分离 roma: 独立注音', () {
      const mainLrc = '''
[00:00.00]作词 : Ayase
[00:01.00]無敵の笑顔で荒らすメディア
[00:05.00]知りたいその秘密ミステリアス
[00:09.00]抜けてるとこさえ彼女のエリア
''';
      const transLrc = '''
[00:00.00]//
[00:01.28]以无敌的笑容席卷媒体
[00:05.22]想知道那份神秘的秘密
[00:09.10]抜けてるとこさえ彼女のエリア
''';
      const romaLrc = '''
[00:01.05]mu te ki no e ga o de a ra su me di a
[00:05.08]shi ri ta i so no hi mi tsu mi su te ri a su
[00:09.02]nu ke te ru to ko sa e ka no jo no e ri a
''';
      final merged = LyricMerger.mergeSameSource(
        mainLrc: mainLrc,
        translationLrc: transLrc,
        romajiLrc: romaLrc,
      );
      expect(merged.hasTranslation, isTrue);
      expect(merged.hasRomaji, isTrue);

      final doc = LrcParser.parseText(merged.lrcContent);
      expect(doc.lines, hasLength(3));
      expect(doc.lines[0].primaryText, equals('無敵の笑顔で荒らすメディア'));
      expect(doc.lines[0].secondaryLines, equals(['以无敌的笑容席卷媒体']));
      expect(
        doc.lines[0].romajiText,
        equals('mu te ki no e ga o de a ra su me di a'),
      );
      // 第三行译文与原文完全一致应被丢弃，且罗马音绝不能混入译文列表。
      expect(doc.lines[2].secondaryLines, isEmpty);
      expect(
        doc.lines[2].romajiText,
        equals('nu ke te ru to ko sa e ka no jo no e ri a'),
      );
    });

    test('跨源借译文与时间平移（unravel 案例）：LRCLIB 准确主轴借入偏移 1.5s 的网易云译文与罗马音', () {
      const lrclibPrimary = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'lrc_1',
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 240.7,
        lrcContent:
            '[00:02.00]教えて 教えてよ その仕組みを\n'
            '[00:09.00]僕の中に誰がいるの？\n'
            '[00:16.50]壊れた 壊れたよ この世界で\n'
            '[00:24.00]君が笑う 何も見えずに',
      );
      const neteaseOther = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'ncm_1',
        title: 'unravel',
        artist: 'TK from 凛として時雨',
        durationSeconds: 239.0,
        lrcContent:
            '[00:00.50]教えて 教えてよ その仕組みを\n'
            '[00:00.50]告诉我 告诉我 其中的构造\n'
            '[00:00.50]roma:o shi e te o shi e te yo\n'
            '[00:07.50]僕の中に誰がいるの？\n'
            '[00:07.50]在我的身体里 究竟是谁存在\n'
            '[00:07.50]roma:bo ku no na ka ni da re ga i ru no\n'
            '[00:15.00]壊れた 壊れたよ この世界で\n'
            '[00:15.00]坏掉了 坏掉了 在这个世界里\n'
            '[00:15.00]roma:ko wa re ta ko wa re ta yo\n'
            '[00:22.50]君が笑う 何も見えずに\n'
            '[00:22.50]你却在笑着 什么也看不见\n'
            '[00:22.50]roma:ki mi ga wa ra u',
        hasTranslation: true,
        hasRomaji: true,
      );

      final enriched = LyricMerger.enrichWithCrossSource(
        lrclibPrimary,
        const [neteaseOther],
      );
      expect(enriched.borrowedTranslation, isTrue);
      expect(enriched.borrowedRomaji, isTrue);
      // 整体偏差为 1.5s，超过 0.3s 交叉验证严格阈值，因此只借译文不误判时间完全一致。
      expect(enriched.crossSourceAgreed, isFalse);

      final doc = LrcParser.parseText(enriched.candidate.lrcContent);
      expect(doc.lines, hasLength(4));
      // 保留 LRCLIB 原始准确时间戳，并精准挂上借来的四句中文译文与罗马音。
      expect(doc.lines[0].startSeconds, closeTo(2.0, 0.02));
      expect(doc.lines[0].secondaryLines, equals(['告诉我 告诉我 其中的构造']));
      expect(doc.lines[0].romajiText, equals('o shi e te o shi e te yo'));
      expect(doc.lines[3].startSeconds, closeTo(24.0, 0.02));
      expect(doc.lines[3].secondaryLines, equals(['你却在笑着 什么也看不见']));
    });

    test('两独立源原文对齐 >= 0.9 且中位时间差 <= 0.3s 时触发交叉验证加分', () {
      const a = LyricCandidate(
        source: LyricSource.lrclib,
        sourceId: 'a',
        title: '紅蓮華',
        artist: 'LiSA',
        durationSeconds: 236,
        lrcContent:
            '[00:01.00]強くなれる理由を知った\n'
            '[00:06.00]僕を連れて進め\n'
            '[00:11.00]泥だらけの走馬灯に酔う\n'
            '[00:16.00]こわばる心',
      );
      const b = LyricCandidate(
        source: LyricSource.netease,
        sourceId: 'b',
        title: '紅蓮華',
        artist: 'LiSA',
        durationSeconds: 236,
        lrcContent:
            '[00:01.10]強くなれる理由を知った\n'
            '[00:06.15]僕を連れて進め\n'
            '[00:11.05]泥だらけの走馬灯に酔う\n'
            '[00:16.12]こわばる心',
      );
      final enriched = LyricMerger.enrichWithCrossSource(a, const [b]);
      expect(enriched.crossSourceAgreed, isTrue);
    });
  });

  group('LyricSearchQuery 别名扩展与多步查询计划', () {
    test('提取引号内核心曲名、去波浪副标题、去括号译名并识别角色 (CV.声优)', () {
      final q1 = LyricSearchQuery(
        title: '01. TVアニメ「推しの子」OP「アイドル」.flac',
        artist: 'YOASOBI (ヨアソビ)',
      );
      expect(q1.titleAliases, contains('アイドル'));
      expect(
        LyricTextSimilarity.titleSimilarity(
          '残酷な天使のテーゼ',
          '残酷な天使のテーゼ (残酷天使的行动纲领)',
        ),
        equals(1.0),
      );
      expect(
        LyricTextSimilarity.artistSimilarity('LiSA', 'LiSA (织部里沙)'),
        equals(1.0),
      );

      final q2 = LyricSearchQuery(
        title: 'secret base ～君がくれたもの～',
        artist: '本間芽衣子(CV.茅野愛衣)',
      );
      expect(q2.titleAliases, contains('secret base'));
      expect(q2.searchArtists.first, equals('茅野愛衣'));
      final steps = q2.buildSearchKeywords();
      expect(steps.first, equals('secret base ～君がくれたもの～ 本間芽衣子(CV.茅野愛衣)'));
      expect(steps.any((k) => k.contains('茅野愛衣') && !k.contains('CV')), isTrue);
      expect(steps.any((k) => k == 'secret base'), isTrue);
    });
  });

  group('AudioAssetExtractor 内嵌歌词标签提取（FLAC / ID3v2 USLT）', () {
    test('解析 FLAC VORBIS_COMMENT 中的 LYRICS 同步歌词并优先于 UNSYNCEDLYRICS', () {
      final flac = _buildFlacWithVorbisComments([
        'TITLE=勇者',
        'UNSYNCEDLYRICS=纯文本无时间戳歌词',
        'LYRICS=[00:01.00]まるで御伽の話\n[00:05.00]終わらない旅\n[00:09.00]記憶の奥で',
      ]);
      final extracted = AudioAssetExtractor.extractEmbeddedLyricsFromHeaderBytes(
        flac,
      );
      expect(extracted, isNotNull);
      final doc = LrcParser.parseText(extracted!);
      expect(doc.lines, hasLength(3));
      expect(doc.lines.first.primaryText, equals('まるで御伽の話'));
    });

    test('解析 ID3v2.3 USLT UTF-8 与 UTF-16LE BOM 内嵌歌词', () {
      // 1. UTF-8 编码（编码标识 3）
      final utf8Payload = BytesBuilder()
        ..add([3])
        ..add(ascii.encode('jpn'))
        ..add([0])
        ..add(utf8.encode('[00:02.00]無敵の笑顔\n[00:06.00]秘密ミステリアス\n[00:10.00]彼女のエリア'));
      final mp3Utf8 = _buildId3v23SingleFrame('USLT', utf8Payload.toBytes());
      final textUtf8 = AudioAssetExtractor.extractEmbeddedLyricsFromHeaderBytes(
        mp3Utf8,
      );
      expect(textUtf8, contains('無敵の笑顔'));

      // 2. 带字节序标记的 UTF-16LE 编码（编码标识 1）
      const lyricText = '[00:01.00]紅蓮華\n[00:04.00]強くなれる\n[00:08.00]進め';
      final utf16Payload = BytesBuilder()
        ..add([1])
        ..add(ascii.encode('jpn'))
        ..add([0, 0])
        ..add([0xFF, 0xFE]);
      for (final unit in lyricText.codeUnits) {
        utf16Payload.add([unit & 0xFF, (unit >> 8) & 0xFF]);
      }
      final mp3Utf16 = _buildId3v23SingleFrame('USLT', utf16Payload.toBytes());
      final textUtf16 = AudioAssetExtractor.extractEmbeddedLyricsFromHeaderBytes(
        mp3Utf16,
      );
      expect(textUtf16, equals(lyricText));
    });

    test('loadTrackAuxiliaryAssets 外挂 .lrc 优先于内嵌歌词，无外挂时自动回退内嵌同步歌词', () async {
      final flac = _buildFlacWithVorbisComments([
        'LYRICS=[00:01.00]内嵌第一句\n[00:04.00]内嵌第二句\n[00:08.00]内嵌第三句',
      ]);
      const source = MediaSource(
        id: 'src_mem',
        label: 'Mem',
        kind: MediaSourceKind.local,
        location: '/mem',
      );
      const variant = MediaVariant(
        id: 'v1',
        workId: 'w1',
        sourceId: 'src_mem',
        relativePath: 'album/01.flac',
        fileName: '01.flac',
        fileSize: 1024,
        assetKind: AssetKind.cdAlbum,
      );

      // 1. 仅存在内嵌歌词时：直接解析上屏。
      final gwOnlyEmbedded = _MemoryByteGateway({'album/01.flac': flac});
      final res1 = await AudioAssetExtractor.loadTrackAuxiliaryAssets(
        source: source,
        variant: variant,
        gatewayFactory: _FixedGatewayFactory(gwOnlyEmbedded),
      );
      expect(res1.lrc?.lines.first.primaryText, equals('内嵌第一句'));

      // 2. 同时存在外挂 .lrc 时：外挂优先。
      final gwBoth = _MemoryByteGateway({
        'album/01.flac': flac,
        'album/01.lrc': Uint8List.fromList(
          utf8.encode('[00:01.00]外挂优先首句\n[00:04.00]外挂第二句\n[00:08.00]外挂第三句'),
        ),
      });
      final res2 = await AudioAssetExtractor.loadTrackAuxiliaryAssets(
        source: source,
        variant: variant,
        gatewayFactory: _FixedGatewayFactory(gwBoth),
      );
      expect(res2.lrc?.lines.first.primaryText, equals('外挂优先首句'));
    });
  });
}
