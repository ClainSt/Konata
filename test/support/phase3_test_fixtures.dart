import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 第三阶段原型探针与回归测试专用确定性微型夹具工厂。
///
/// 全程纯内存代码生成，不向仓库提交任何大体积音视频、字库或字幕二进制资产。
class Phase3TestFixtures {
  Phase3TestFixtures._();

  /// 生成携带唯一采样帧序号签名的 16-bit PCM WAV 音频字节流。
  ///
  /// 左声道编码低 15 位帧号签名，右声道编码异或校验值，供 CUE 扇区切点与无缝拼接零丢样核验。
  static Uint8List generateUniqueSampleWav({
    int sampleRate = 48000,
    int channels = 2,
    int durationMs = 250,
    int frameStartIndex = 0,
  }) {
    final totalFrames = ((sampleRate * durationMs) / 1000).round();
    const bitsPerSample = 16;
    final bytesPerSample = bitsPerSample ~/ 8;
    final blockAlign = channels * bytesPerSample;
    final byteRate = sampleRate * blockAlign;
    final dataSize = totalFrames * blockAlign;
    final riffSize = 36 + dataSize;

    final out = Uint8List(44 + dataSize);
    final bd = ByteData.sublistView(out);

    // 写入 RIFF 头部与 WAVE 格式标记
    out.setRange(0, 4, ascii.encode('RIFF'));
    bd.setUint32(4, riffSize, Endian.little);
    out.setRange(8, 12, ascii.encode('WAVE'));

    // 写入 fmt 子块（PCM = 1）
    out.setRange(12, 16, ascii.encode('fmt '));
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little);
    bd.setUint16(22, channels, Endian.little);
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);

    // 写入 data 子块头部与唯一采样帧签名
    out.setRange(36, 40, ascii.encode('data'));
    bd.setUint32(40, dataSize, Endian.little);

    var offset = 44;
    for (var i = 0; i < totalFrames; i++) {
      final seq = frameStartIndex + i;
      final leftSample = ((seq % 16000) - 8000);
      final rightSample = (((seq * 3) % 16000) - 8000);
      bd.setInt16(offset, leftSample, Endian.little);
      offset += 2;
      if (channels >= 2) {
        bd.setInt16(offset, rightSample, Endian.little);
        offset += 2;
      }
      for (var c = 2; c < channels; c++) {
        bd.setInt16(offset, 0, Endian.little);
        offset += 2;
      }
    }
    return out;
  }

  /// 从微型 WAV 字节流中读取左声道样本列表，供精确边界抽检。
  static List<int> readWavLeftSamples(Uint8List wavBytes) {
    if (wavBytes.length < 44) return const [];
    final bd = ByteData.sublistView(wavBytes);
    final channels = bd.getUint16(22, Endian.little);
    final blockAlign = bd.getUint16(32, Endian.little);
    final dataSize = bd.getUint32(40, Endian.little);
    if (channels <= 0 || blockAlign <= 0) return const [];
    final frameCount = dataSize ~/ blockAlign;
    final samples = List<int>.filled(frameCount, 0);
    for (var i = 0; i < frameCount; i++) {
      samples[i] = bd.getInt16(44 + i * blockAlign, Endian.little);
    }
    return samples;
  }

  /// 生成满足 TrueType SFNT 规范的双字面微型字体二进制（支持 `.notdef`、`A` 与 `中`）。
  static Uint8List generateMinimalDualGlyphTtf({
    String familyName = 'KonataProbeFont',
  }) {
    final tables = <String, Uint8List>{};

    // 构造简单轮廓字形表（3 个字形：.notdef、A、中）
    final simpleGlyph = _buildSimpleBoxGlyph();
    final glyfBuilder = BytesBuilder(copy: false);
    final locaOffsets = <int>[];
    for (var i = 0; i < 3; i++) {
      locaOffsets.add(glyfBuilder.length);
      glyfBuilder.add(simpleGlyph);
    }
    locaOffsets.add(glyfBuilder.length);
    final glyfBytes = glyfBuilder.takeBytes();

    final locaBytes = Uint8List(locaOffsets.length * 4);
    final locaBd = ByteData.sublistView(locaBytes);
    for (var i = 0; i < locaOffsets.length; i++) {
      locaBd.setUint32(i * 4, locaOffsets[i], Endian.big);
    }

    // 构造 head 表（checkSumAdjustment 留 0 待整表完成后回填）
    final headBytes = Uint8List(54);
    final headBd = ByteData.sublistView(headBytes);
    headBd.setUint32(0, 0x00010000, Endian.big);
    headBd.setUint32(4, 0x00010000, Endian.big);
    headBd.setUint32(8, 0, Endian.big);
    headBd.setUint32(12, 0x5F0F3CF5, Endian.big);
    headBd.setUint16(16, 0x000B, Endian.big);
    headBd.setUint16(18, 1000, Endian.big);
    headBd.setInt16(36, 0, Endian.big);
    headBd.setInt16(38, 0, Endian.big);
    headBd.setInt16(40, 600, Endian.big);
    headBd.setInt16(42, 800, Endian.big);
    headBd.setUint16(46, 8, Endian.big);
    headBd.setInt16(48, 2, Endian.big);
    headBd.setInt16(50, 1, Endian.big);
    headBd.setInt16(52, 0, Endian.big);

    // 构造 hhea 表
    final hheaBytes = Uint8List(36);
    final hheaBd = ByteData.sublistView(hheaBytes);
    hheaBd.setUint32(0, 0x00010000, Endian.big);
    hheaBd.setInt16(4, 800, Endian.big);
    hheaBd.setInt16(6, -200, Endian.big);
    hheaBd.setUint16(10, 600, Endian.big);
    hheaBd.setInt16(18, 1, Endian.big);
    hheaBd.setUint16(34, 3, Endian.big);

    // 构造 maxp 表（v1.0，3 个字形）
    final maxpBytes = Uint8List(32);
    final maxpBd = ByteData.sublistView(maxpBytes);
    maxpBd.setUint32(0, 0x00010000, Endian.big);
    maxpBd.setUint16(4, 3, Endian.big);
    maxpBd.setUint16(6, 4, Endian.big);
    maxpBd.setUint16(8, 1, Endian.big);

    // 构造 hmtx 表（3 个字形等宽 600）
    final hmtxBytes = Uint8List(3 * 4);
    final hmtxBd = ByteData.sublistView(hmtxBytes);
    for (var i = 0; i < 3; i++) {
      hmtxBd.setUint16(i * 4, 600, Endian.big);
      hmtxBd.setInt16(i * 4 + 2, 50, Endian.big);
    }

    // 构造 OS/2 表（v1，86 字节）
    final os2Bytes = Uint8List(86);
    final os2Bd = ByteData.sublistView(os2Bytes);
    os2Bd.setUint16(0, 1, Endian.big);
    os2Bd.setInt16(2, 600, Endian.big);
    os2Bd.setUint16(4, 400, Endian.big);
    os2Bd.setUint16(6, 5, Endian.big);
    os2Bd.setUint16(62, 0x0040, Endian.big);
    os2Bd.setUint16(64, 0x0041, Endian.big);
    os2Bd.setUint16(66, 0x4E2D, Endian.big);
    os2Bd.setInt16(68, 800, Endian.big);
    os2Bd.setInt16(70, -200, Endian.big);
    os2Bd.setUint16(74, 800, Endian.big);
    os2Bd.setUint16(76, 200, Endian.big);

    // 构造 post 表（v3.0，无字形名表）
    final postBytes = Uint8List(32);
    final postBd = ByteData.sublistView(postBytes);
    postBd.setUint32(0, 0x00030000, Endian.big);

    // 构造 cmap 表（Platform 3 Encoding 1 Format 4：映射 'A' -> 1，'中' -> 2）
    final cmapBytes = _buildCmapFormat4([
      (codePoint: 0x0041, glyphId: 1),
      (codePoint: 0x4E2D, glyphId: 2),
    ]);

    // 构造 name 表（登记字体族名与全名）
    final nameBytes = _buildNameTable(familyName);

    tables['OS/2'] = os2Bytes;
    tables['cmap'] = cmapBytes;
    tables['glyf'] = glyfBytes;
    tables['head'] = headBytes;
    tables['hhea'] = hheaBytes;
    tables['hmtx'] = hmtxBytes;
    tables['loca'] = locaBytes;
    tables['maxp'] = maxpBytes;
    tables['name'] = nameBytes;
    tables['post'] = postBytes;

    return _assembleSfnt(tables);
  }

  static Uint8List _buildSimpleBoxGlyph() {
    // 1 条矩形轮廓（4 个端点），确保 libass / FreeType 可合法光栅化
    final out = Uint8List(24);
    final bd = ByteData.sublistView(out);
    bd.setInt16(0, 1, Endian.big);
    bd.setInt16(2, 50, Endian.big);
    bd.setInt16(4, 0, Endian.big);
    bd.setInt16(6, 550, Endian.big);
    bd.setInt16(8, 700, Endian.big);
    bd.setUint16(10, 3, Endian.big);
    bd.setUint16(12, 0, Endian.big);
    // 标志位：全在轮廓上，采用 16 位坐标增量
    out[14] = 0x01;
    out[15] = 0x01;
    out[16] = 0x01;
    out[17] = 0x01;
    // 简写为 4 字节对齐的零长度安全单点占位（保证长度 4 字节对齐）
    final compact = Uint8List(28);
    final cbd = ByteData.sublistView(compact);
    cbd.setInt16(0, 1, Endian.big);
    cbd.setInt16(2, 50, Endian.big);
    cbd.setInt16(4, 0, Endian.big);
    cbd.setInt16(6, 550, Endian.big);
    cbd.setInt16(8, 700, Endian.big);
    cbd.setUint16(10, 3, Endian.big);
    cbd.setUint16(12, 0, Endian.big);
    // 顶点标志位：全在轮廓上并启用单字节增量编码（坐标正向位与短增量位）
    compact[14] = 0x01 | 0x02 | 0x10 | 0x20;
    compact[15] = 0x01 | 0x10 | 0x04 | 0x20;
    compact[16] = 0x01 | 0x02 | 0x10 | 0x20;
    compact[17] = 0x01 | 0x10 | 0x04;
    // x 坐标列表：点0=50，点2=200
    compact[18] = 50;
    compact[19] = 200;
    // y 坐标列表：点1=200，点3=200（负向）
    compact[20] = 200;
    compact[21] = 200;
    return compact;
  }

  static Uint8List _buildCmapFormat4(
    List<({int codePoint, int glyphId})> entries,
  ) {
    final sorted = List<({int codePoint, int glyphId})>.from(entries)
      ..sort((a, b) => a.codePoint.compareTo(b.codePoint));
    final segCount = sorted.length + 1;
    final segCountX2 = segCount * 2;
    var searchRange = 2;
    var entrySelector = 0;
    while (searchRange * 2 <= segCountX2) {
      searchRange *= 2;
      entrySelector++;
    }
    final rangeShift = segCountX2 - searchRange;
    final subtableLength = 16 + segCount * 8;
    final totalLength = 12 + subtableLength;
    final bytes = Uint8List(totalLength);
    final bd = ByteData.sublistView(bytes);

    // cmap 顶层头（1 条编码子表：Platform 3, Encoding 1）
    bd.setUint16(0, 0, Endian.big);
    bd.setUint16(2, 1, Endian.big);
    bd.setUint16(4, 3, Endian.big);
    bd.setUint16(6, 1, Endian.big);
    bd.setUint32(8, 12, Endian.big);

    // Format 4 子表头
    var o = 12;
    bd.setUint16(o, 4, Endian.big);
    bd.setUint16(o + 2, subtableLength, Endian.big);
    bd.setUint16(o + 4, 0, Endian.big);
    bd.setUint16(o + 6, segCountX2, Endian.big);
    bd.setUint16(o + 8, searchRange, Endian.big);
    bd.setUint16(o + 10, entrySelector, Endian.big);
    bd.setUint16(o + 12, rangeShift, Endian.big);
    o += 14;

    // endCode 数组
    for (final e in sorted) {
      bd.setUint16(o, e.codePoint, Endian.big);
      o += 2;
    }
    bd.setUint16(o, 0xFFFF, Endian.big);
    o += 2;

    // 保留填充槽位（规范要求置零）
    bd.setUint16(o, 0, Endian.big);
    o += 2;

    // startCode 数组
    for (final e in sorted) {
      bd.setUint16(o, e.codePoint, Endian.big);
      o += 2;
    }
    bd.setUint16(o, 0xFFFF, Endian.big);
    o += 2;

    // idDelta 数组
    for (final e in sorted) {
      final delta = (e.glyphId - e.codePoint) & 0xFFFF;
      bd.setUint16(o, delta, Endian.big);
      o += 2;
    }
    bd.setUint16(o, 1, Endian.big);
    o += 2;

    // idRangeOffset 数组（全为 0）
    for (var i = 0; i < segCount; i++) {
      bd.setUint16(o, 0, Endian.big);
      o += 2;
    }
    return bytes;
  }

  static Uint8List _buildNameTable(String familyName) {
    final records = <({int nameId, Uint8List utf16be})>[
      (nameId: 1, utf16be: _encodeUtf16Be(familyName)),
      (nameId: 2, utf16be: _encodeUtf16Be('Regular')),
      (nameId: 4, utf16be: _encodeUtf16Be(familyName)),
      (nameId: 6, utf16be: _encodeUtf16Be(familyName.replaceAll(' ', ''))),
    ];
    final storageOffset = 6 + records.length * 12;
    var stringTotal = 0;
    for (final r in records) {
      stringTotal += r.utf16be.length;
    }
    final bytes = Uint8List(storageOffset + stringTotal);
    final bd = ByteData.sublistView(bytes);
    bd.setUint16(0, 0, Endian.big);
    bd.setUint16(2, records.length, Endian.big);
    bd.setUint16(4, storageOffset, Endian.big);

    var strCursor = 0;
    for (var i = 0; i < records.length; i++) {
      final rec = records[i];
      final ro = 6 + i * 12;
      bd.setUint16(ro, 3, Endian.big);
      bd.setUint16(ro + 2, 1, Endian.big);
      bd.setUint16(ro + 4, 0x0409, Endian.big);
      bd.setUint16(ro + 6, rec.nameId, Endian.big);
      bd.setUint16(ro + 8, rec.utf16be.length, Endian.big);
      bd.setUint16(ro + 10, strCursor, Endian.big);
      bytes.setRange(
        storageOffset + strCursor,
        storageOffset + strCursor + rec.utf16be.length,
        rec.utf16be,
      );
      strCursor += rec.utf16be.length;
    }
    return bytes;
  }

  static Uint8List _encodeUtf16Be(String text) {
    final units = text.codeUnits;
    final out = Uint8List(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      out[i * 2] = (units[i] >> 8) & 0xFF;
      out[i * 2 + 1] = units[i] & 0xFF;
    }
    return out;
  }

  static Uint8List _assembleSfnt(Map<String, Uint8List> tables) {
    final tags = tables.keys.toList()..sort();
    final numTables = tags.length;
    var searchRange = 16;
    var entrySelector = 0;
    while (searchRange * 2 <= numTables * 16) {
      searchRange *= 2;
      entrySelector++;
    }
    final rangeShift = numTables * 16 - searchRange;

    final headerLen = 12 + numTables * 16;
    var offset = headerLen;
    final offsets = <String, int>{};
    for (final tag in tags) {
      offsets[tag] = offset;
      final len = tables[tag]!.length;
      offset += (len + 3) & ~3;
    }

    final out = Uint8List(offset);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, 0x00010000, Endian.big);
    bd.setUint16(4, numTables, Endian.big);
    bd.setUint16(6, searchRange, Endian.big);
    bd.setUint16(8, entrySelector, Endian.big);
    bd.setUint16(10, rangeShift, Endian.big);

    var headOffset = 0;
    for (var i = 0; i < numTables; i++) {
      final tag = tags[i];
      final data = tables[tag]!;
      final tableOffset = offsets[tag]!;
      if (tag == 'head') headOffset = tableOffset;
      out.setRange(tableOffset, tableOffset + data.length, data);
      final dirPos = 12 + i * 16;
      out.setRange(dirPos, dirPos + 4, ascii.encode(tag));
      bd.setUint32(dirPos + 4, _sfntChecksum(data), Endian.big);
      bd.setUint32(dirPos + 8, tableOffset, Endian.big);
      bd.setUint32(dirPos + 12, data.length, Endian.big);
    }

    final totalChecksum = _sfntChecksum(out);
    final adjustment = (0xB1B0AFBA - totalChecksum) & 0xFFFFFFFF;
    bd.setUint32(headOffset + 8, adjustment, Endian.big);
    return out;
  }

  static int _sfntChecksum(Uint8List data) {
    final paddedLen = (data.length + 3) & ~3;
    var sum = 0;
    for (var i = 0; i < paddedLen; i += 4) {
      final b0 = i < data.length ? data[i] : 0;
      final b1 = (i + 1) < data.length ? data[i + 1] : 0;
      final b2 = (i + 2) < data.length ? data[i + 2] : 0;
      final b3 = (i + 3) < data.length ? data[i + 3] : 0;
      final word = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3;
      sum = (sum + word) & 0xFFFFFFFF;
    }
    return sum;
  }

  /// 按 ASS `[Fonts]` 规范将原始字节编码为无行首长度字节的 UUEncode 文本（每行 80 字符）。
  static String encodeAssUuFont(Uint8List bytes) {
    final buf = StringBuffer();
    var lineChars = 0;
    void emitChar(int sixBit) {
      buf.writeCharCode((sixBit & 0x3F) + 33);
      lineChars++;
      if (lineChars == 80) {
        buf.write('\n');
        lineChars = 0;
      }
    }

    var i = 0;
    while (i + 3 <= bytes.length) {
      final v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      emitChar((v >> 18) & 0x3F);
      emitChar((v >> 12) & 0x3F);
      emitChar((v >> 6) & 0x3F);
      emitChar(v & 0x3F);
      i += 3;
    }
    final rem = bytes.length - i;
    if (rem == 1) {
      final v = bytes[i] << 16;
      emitChar((v >> 18) & 0x3F);
      emitChar((v >> 12) & 0x3F);
    } else if (rem == 2) {
      final v = (bytes[i] << 16) | (bytes[i + 1] << 8);
      emitChar((v >> 18) & 0x3F);
      emitChar((v >> 12) & 0x3F);
      emitChar((v >> 6) & 0x3F);
    }
    return buf.toString();
  }

  /// 生成覆盖双语、`\fade`、`\t(accel)`、卡拉 OK 厘秒标签与可选内嵌字体的合成 ASS 字幕文本。
  static String generateSyntheticAss({
    bool includeEmbeddedFont = false,
    String fontFamily = 'KonataProbeFont',
  }) {
    final buf = StringBuffer()
      ..writeln('[Script Info]')
      ..writeln('ScriptType: v4.00+')
      ..writeln('PlayResX: 1920')
      ..writeln('PlayResY: 1080')
      ..writeln()
      ..writeln('[V4+ Styles]')
      ..writeln(
        'Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, '
        'OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, '
        'ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, '
        'Alignment, MarginL, MarginR, MarginV, Encoding',
      )
      ..writeln(
        'Style: Default,$fontFamily,54,&H00FFFFFF,&H0000FFFF,&H00000000,'
        '&H64000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,30,1',
      )
      ..writeln()
      ..writeln('[Events]')
      ..writeln(
        'Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, '
        'Effect, Text',
      )
      ..writeln(
        r'Dialogue: 0,0:00:01.00,0:00:05.00,Default,,0,0,0,,'
        r'{\fade(255,0,255,0,400,2000,2400)\t(100,900,1.5,\fs60)}繁體雙語測試\N日本語のテスト',
      )
      ..writeln(
        r'Dialogue: 1,0:00:05.50,0:00:08.50,Default,,0,0,0,,'
        r'{\k50}こ{\kf100}な{\ko75}た',
      );
    if (includeEmbeddedFont) {
      final fontBytes = generateMinimalDualGlyphTtf(familyName: fontFamily);
      buf
        ..writeln()
        ..writeln('[Fonts]')
        ..writeln('fontname: ${fontFamily}_0.ttf')
        ..writeln(encodeAssUuFont(fontBytes));
    }
    return buf.toString();
  }

  /// 生成含行内时间戳的合成 WebVTT 字幕文本。
  static String generateSyntheticVtt() {
    return '''WEBVTT

00:00:01.000 --> 00:00:04.500
第一句<00:00:02.250>同步<00:00:03.500>测试

00:00:05.000 --> 00:00:08.000
第二句测试
''';
  }
}

/// 回环 Mock WebDAV 请求审计记录。
class RecordedMockRequest {
  /// 创建请求审计记录。
  const RecordedMockRequest({
    required this.method,
    required this.path,
    required this.rangeHeader,
    required this.ifRangeHeader,
    required this.authorizationHeader,
    required this.statusCode,
  });

  final String method;
  final String path;
  final String? rangeHeader;
  final String? ifRangeHeader;
  final String? authorizationHeader;
  final int statusCode;
}

/// 可控故障注入的本地回环 HTTP / WebDAV 模拟服务器（`127.0.0.1` 随机端口）。
///
/// 支持 Digest `401` 质询握手、`206 Partial Content`、`ETag`/`If-Range` 强校验、
/// 半途断流注入、`200` 错位整包注入、`403` 终态拒绝与 `307` 跨源重定向注入。
class MockWebDavLoopbackServer {
  MockWebDavLoopbackServer._(
    this._server, {
    required this.files,
    this.requireDigestAuth = false,
    this.username = 'konata',
    this.password = 'secret',
    String initialEtag = '"etag-v1"',
  }) : realm = 'KonataMockRealm',
       nonce = 'nonce-step0-fixed',
       currentEtag = initialEtag;

  final HttpServer _server;

  /// 可服务的虚拟文件映射（键为不带前导斜杠的相对路径）。
  final Map<String, Uint8List> files;

  /// 是否强制 Digest 认证。
  bool requireDigestAuth;
  final String username;
  final String password;
  final String realm;
  String nonce;

  /// 当前对外宣告的强 ETag（测试中可动态切换以模拟服务端文件变更）。
  String currentEtag;

  /// 故障注入开关：若非空，则单次流写入指定字节数后强制销毁底层套接字。
  int? abortAfterBytesOnce;

  /// 故障注入开关：下一次带 `Range` 的 GET 请求故意返回 `200 OK` 全量正文。
  bool force200OnNextRange = false;

  /// 故障注入开关：全部请求直接返回 `403 Forbidden`。
  bool force403 = false;

  /// 故障注入开关：若非空，则返回 `307 Temporary Redirect` 指向该目标地址。
  Uri? redirectTargetOnce;

  /// 已记录的全部入站请求。
  final List<RecordedMockRequest> requests = [];

  /// 监听基地址。
  Uri get baseUri => Uri.parse('http://127.0.0.1:${_server.port}/');

  /// 启动本地回环 Mock 服务器。
  static Future<MockWebDavLoopbackServer> start({
    required Map<String, Uint8List> files,
    bool requireDigestAuth = false,
    String username = 'konata',
    String password = 'secret',
    String initialEtag = '"etag-v1"',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = MockWebDavLoopbackServer._(
      server,
      files: Map<String, Uint8List>.from(files),
      requireDigestAuth: requireDigestAuth,
      username: username,
      password: password,
      initialEtag: initialEtag,
    );
    server.listen(instance._handle);
    return instance;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final relPath = Uri.decodeComponent(req.uri.path).replaceAll(RegExp(r'^/+'), '');
    final auth = req.headers.value(HttpHeaders.authorizationHeader);
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final ifRange = req.headers.value(HttpHeaders.ifRangeHeader);

    void record(int status) {
      requests.add(
        RecordedMockRequest(
          method: req.method,
          path: relPath,
          rangeHeader: range,
          ifRangeHeader: ifRange,
          authorizationHeader: auth,
          statusCode: status,
        ),
      );
    }

    if (redirectTargetOnce != null) {
      final target = redirectTargetOnce!;
      redirectTargetOnce = null;
      res.statusCode = HttpStatus.temporaryRedirect;
      res.headers.set(HttpHeaders.locationHeader, target.toString());
      record(HttpStatus.temporaryRedirect);
      await res.close();
      return;
    }

    if (force403) {
      res.statusCode = HttpStatus.forbidden;
      record(HttpStatus.forbidden);
      await res.close();
      return;
    }

    if (requireDigestAuth && !_verifyDigest(req, auth)) {
      res.statusCode = HttpStatus.unauthorized;
      res.headers.set(
        HttpHeaders.wwwAuthenticateHeader,
        'Digest realm="$realm", nonce="$nonce", qop="auth", algorithm=MD5',
      );
      record(HttpStatus.unauthorized);
      await res.close();
      return;
    }

    if (req.method == 'PROPFIND') {
      final xml = _buildPropfindXml(relPath);
      res.statusCode = 207;
      res.headers.set(HttpHeaders.contentTypeHeader, 'application/xml; charset=utf-8');
      res.write(xml);
      record(207);
      await res.close();
      return;
    }

    final data = files[relPath];
    if (data == null) {
      res.statusCode = HttpStatus.notFound;
      record(HttpStatus.notFound);
      await res.close();
      return;
    }

    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    res.headers.set(HttpHeaders.etagHeader, currentEtag);

    if (req.method == 'HEAD') {
      res.statusCode = HttpStatus.ok;
      res.headers.contentLength = data.length;
      record(HttpStatus.ok);
      await res.close();
      return;
    }

    final ifRangeOk = ifRange == null || ifRange.trim() == currentEtag;
    if (range != null && ifRangeOk && !force200OnNextRange) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range.trim());
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final rawEnd = match.group(2)!;
        final end = rawEnd.isEmpty
            ? data.length - 1
            : int.parse(rawEnd).clamp(start, data.length - 1);
        if (start >= data.length || end < start) {
          res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${data.length}');
          record(HttpStatus.requestedRangeNotSatisfiable);
          await res.close();
          return;
        }
        final slice = data.sublist(start, end + 1);
        res.statusCode = HttpStatus.partialContent;
        res.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${data.length}',
        );
        res.headers.contentLength = slice.length;
        record(HttpStatus.partialContent);
        await _writeMaybeAbort(res, slice);
        return;
      }
    }

    if (force200OnNextRange) {
      force200OnNextRange = false;
    }
    res.statusCode = HttpStatus.ok;
    res.headers.contentLength = data.length;
    record(HttpStatus.ok);
    await _writeMaybeAbort(res, data);
  }

  Future<void> _writeMaybeAbort(HttpResponse res, Uint8List payload) async {
    final cut = abortAfterBytesOnce;
    if (cut == null || cut >= payload.length) {
      res.add(payload);
      await res.close();
      return;
    }
    abortAfterBytesOnce = null;
    res.bufferOutput = false;
    final socket = await res.detachSocket(writeHeaders: true);
    if (cut > 0) {
      socket.add(payload.sublist(0, cut));
      await socket.flush();
    }
    socket.destroy();
  }

  bool _verifyDigest(HttpRequest req, String? header) {
    if (header == null || !header.toLowerCase().startsWith('digest ')) {
      return false;
    }
    final params = <String, String>{};
    final reg = RegExp(r'([a-zA-Z0-9_-]+)=(?:"([^"]*)"|([^,\s]*))');
    for (final m in reg.allMatches(header.substring(7))) {
      params[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
    }
    if (params['username'] != username || params['nonce'] != nonce) {
      return false;
    }
    final uri = params['uri'] ?? req.uri.path;
    final ha1 = md5.convert(utf8.encode('$username:$realm:$password')).toString();
    final ha2 = md5.convert(utf8.encode('${req.method}:$uri')).toString();
    final qop = params['qop'];
    final expected = (qop != null && qop.isNotEmpty)
        ? md5
            .convert(
              utf8.encode(
                '$ha1:$nonce:${params['nc']}:${params['cnonce']}:$qop:$ha2',
              ),
            )
            .toString()
        : md5.convert(utf8.encode('$ha1:$nonce:$ha2')).toString();
    return params['response']?.toLowerCase() == expected.toLowerCase();
  }

  String _buildPropfindXml(String dirRelPath) {
    final prefix = dirRelPath.isEmpty ? '' : '$dirRelPath/';
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="utf-8"?>')
      ..writeln('<D:multistatus xmlns:D="DAV:">');
    final seenDirs = <String>{};
    for (final entry in files.entries) {
      if (prefix.isNotEmpty && !entry.key.startsWith(prefix)) continue;
      final rest = entry.key.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      if (slash >= 0) {
        final subDir = rest.substring(0, slash);
        if (seenDirs.add(subDir)) {
          final href = '/$prefix$subDir/';
          buf
            ..writeln('<D:response><D:href>$href</D:href><D:propstat><D:prop>')
            ..writeln('<D:resourcetype><D:collection/></D:resourcetype>')
            ..writeln('</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
        }
      } else {
        final href = '/${entry.key}';
        buf
          ..writeln('<D:response><D:href>$href</D:href><D:propstat><D:prop>')
          ..writeln('<D:resourcetype/>')
          ..writeln('<D:getcontentlength>${entry.value.length}</D:getcontentlength>')
          ..writeln('</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>');
      }
    }
    buf.writeln('</D:multistatus>');
    return buf.toString();
  }

  /// 强制关闭回环 Mock 服务器。
  Future<void> close() async {
    await _server.close(force: true);
  }
}
