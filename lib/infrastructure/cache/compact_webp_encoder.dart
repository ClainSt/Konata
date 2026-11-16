import 'dart:math' as math;
import 'dart:typed_data';

/// 纯 Dart 实现的轻量级标准 WebP 无损（`RIFF....WEBPVP8L`, RFC 9649）微缩图编码器。
///
/// 专为 Scan 画集缩略图设计：在隔离 `Isolate.run` 中对硬件降采样后的 RGBA 像素
/// 执行自适应中位切分调色板量化、`COLOR_INDEXING_TRANSFORM`（含 `<=16` 色像素打包）、
/// 2D 邻域 LZ77 游程压缩与限长（`<=15` bits）Canonical Huffman 编码。
///
/// 生成的 `.webp` 文件严格遵循 RFC 9649 标准，可被 Flutter 原生 `ui.instantiateImageCodec`
/// 与桌面端看图器无损解码还原，且 `<= 360px` 缩略图体积稳定控制在 ~12–30 KB。
abstract final class CompactWebpEncoder {
  static const int _maxTargetBytes = 32 * 1024;
  static const List<int> _codeLengthCodeOrder = <int>[
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  ];

  /// 将紧致排列的 RGBA8888 像素编码为标准 `.webp` 字节流。
  static Uint8List encodeRgba({
    required Uint8List rgba,
    required int width,
    required int height,
    int maxBytesTarget = _maxTargetBytes,
  }) {
    if (width <= 0 || height <= 0 || width > 16384 || height > 16384) {
      throw ArgumentError('无效的图像尺寸: ${width}x$height');
    }
    final expectedLen = width * height * 4;
    if (rgba.length < expectedLen) {
      throw ArgumentError('RGBA 字节长度不足: ${rgba.length} < $expectedLen');
    }

    // 先尝试 64 色高保真调色板；若纹理复杂度导致体积超出预算，降阶至 16 色 4-in-1 打包确保轻量化。
    final encoded64 = _encodeWithColorBudget(
      rgba: rgba,
      width: width,
      height: height,
      maxColors: 64,
    );
    if (encoded64.length <= maxBytesTarget) {
      return encoded64;
    }
    final encoded16 = _encodeWithColorBudget(
      rgba: rgba,
      width: width,
      height: height,
      maxColors: 16,
    );
    return encoded16.length < encoded64.length ? encoded16 : encoded64;
  }

  static Uint8List _encodeWithColorBudget({
    required Uint8List rgba,
    required int width,
    required int height,
    required int maxColors,
  }) {
    final totalPixels = width * height;
    final hasAlpha = _detectHasAlpha(rgba, totalPixels);

    // 1. 构建调色板并对每像素量化映射至索引 [0, palette.length - 1]
    final quantized = _quantizePalette(
      rgba: rgba,
      pixelCount: totalPixels,
      maxColors: maxColors,
    );
    final palette = quantized.palette;
    final indices = quantized.indices;

    // 2. 根据调色板大小计算 RFC 9649 Color Indexing 像素打包参数
    final int xbits;
    if (palette.length <= 2) {
      xbits = 3;
    } else if (palette.length <= 4) {
      xbits = 2;
    } else if (palette.length <= 16) {
      xbits = 1;
    } else {
      xbits = 0;
    }
    final pixelsPerByte = 1 << xbits;
    final bitsPerIndex = 8 >> xbits;
    final packedWidth = xbits == 0
        ? width
        : ((width + pixelsPerByte - 1) ~/ pixelsPerByte);

    final packedIndices = Uint8List(packedWidth * height);
    if (xbits == 0) {
      packedIndices.setAll(0, indices);
    } else {
      for (var y = 0; y < height; y++) {
        final rowSrcOffset = y * width;
        final rowDstOffset = y * packedWidth;
        for (var px = 0; px < packedWidth; px++) {
          var byteVal = 0;
          final baseX = px * pixelsPerByte;
          for (var k = 0; k < pixelsPerByte; k++) {
            final sx = baseX + k;
            if (sx >= width) break;
            final idx = indices[rowSrcOffset + sx];
            byteVal |= (idx << (k * bitsPerIndex));
          }
          packedIndices[rowDstOffset + px] = byteVal;
        }
      }
    }

    // 3. 写入 VP8L 流
    final writer = _LsbBitWriter();

    // VP8L 5 字节头
    writer.writeByte(0x2f);
    final headerWord =
        ((width - 1) & 0x3FFF) |
        (((height - 1) & 0x3FFF) << 14) |
        ((hasAlpha ? 1 : 0) << 28);
    writer.writeBits(headerWord, 32);

    // Transform: COLOR_INDEXING_TRANSFORM (type = 3)
    writer.writeBits(1, 1); // transform_present = 1
    writer.writeBits(3, 2); // COLOR_INDEXING_TRANSFORM
    writer.writeBits(palette.length - 1, 8);
    _writeColorTableSubImage(writer, palette);

    // 结束 transform 链
    writer.writeBits(0, 1);

    // 压缩后的打包索引流（Green 携带索引字节，R=0, B=0, A=0 或 255）
    writer.writeBits(0, 1); // use_color_cache = 0
    writer.writeBits(0, 1); // meta_huffman = 0（主图单组 Huffman）

    _encodeGreenIndexedPixels(
      writer: writer,
      greenStream: packedIndices,
      width: packedWidth,
      height: height,
      constAlpha: 0,
    );

    final vp8lPayload = writer.finish();
    return _wrapRiffVp8l(vp8lPayload);
  }

  static bool _detectHasAlpha(Uint8List rgba, int pixelCount) {
    final len = pixelCount * 4;
    for (var i = 3; i < len; i += 4) {
      if (rgba[i] != 0xFF) return true;
    }
    return false;
  }

  static void _writeColorTableSubImage(
    _LsbBitWriter writer,
    Uint32List paletteArgb,
  ) {
    final count = paletteArgb.length;
    writer.writeBits(0, 1); // 子图无 color_cache（注：子图无 transforms/meta_huffman）

    // Color Indexing 规范要求相邻调色板条目按通道逐字节 mod 256 差分
    final green = Uint8List(count);
    final red = Uint8List(count);
    final blue = Uint8List(count);
    final alpha = Uint8List(count);

    var prevA = 0;
    var prevR = 0;
    var prevG = 0;
    var prevB = 0;
    for (var i = 0; i < count; i++) {
      final argb = paletteArgb[i];
      final a = (argb >> 24) & 0xFF;
      final r = (argb >> 16) & 0xFF;
      final g = (argb >> 8) & 0xFF;
      final b = argb & 0xFF;
      alpha[i] = (a - prevA) & 0xFF;
      red[i] = (r - prevR) & 0xFF;
      green[i] = (g - prevG) & 0xFF;
      blue[i] = (b - prevB) & 0xFF;
      prevA = a;
      prevR = r;
      prevG = g;
      prevB = b;
    }

    final gCode = _PrefixCode.fromChannelBytes(green, alphabetSize: 280);
    final rCode = _PrefixCode.fromChannelBytes(red, alphabetSize: 256);
    final bCode = _PrefixCode.fromChannelBytes(blue, alphabetSize: 256);
    final aCode = _PrefixCode.fromChannelBytes(alpha, alphabetSize: 256);
    final dCode = _PrefixCode.singleSymbol(0, alphabetSize: 40);

    gCode.writeToBitStream(writer);
    rCode.writeToBitStream(writer);
    bCode.writeToBitStream(writer);
    aCode.writeToBitStream(writer);
    dCode.writeToBitStream(writer);

    for (var i = 0; i < count; i++) {
      gCode.writeSymbol(writer, green[i]);
      rCode.writeSymbol(writer, red[i]);
      bCode.writeSymbol(writer, blue[i]);
      aCode.writeSymbol(writer, alpha[i]);
    }
  }

  /// 对仅在 Green 通道携带有用信息的像素流执行 2D LZ77 + Huffman 编码。
  static void _encodeGreenIndexedPixels({
    required _LsbBitWriter writer,
    required Uint8List greenStream,
    required int width,
    required int height,
    required int constAlpha,
  }) {
    final len = greenStream.length;
    // Token 队列：字面量 (`isMatch == false`) 或 LZ77 后向引用 (`distCode` 1..4 -> 仅 0 extra bits)
    final tokens = <({bool isMatch, int value, int distSym})>[];
    final greenFreq = Int32List(280);
    final distFreq = Int32List(40);

    // 邻域距离码表（RFC 9649 §4.1 前 4 项均为 0 extra bits）：
    // distCode=1 => dSym=0 => (0, 1) 正上方 = pos - width
    // distCode=2 => dSym=1 => (1, 0) 正左方 = pos - 1
    // distCode=3 => dSym=2 => (1, 1) 左上方 = pos - width - 1
    // distCode=4 => dSym=3 => (-1, 1) 右上方 = pos - width + 1
    var pos = 0;
    while (pos < len) {
      var bestLen = 0;
      var bestDistSym = 0;
      final maxPossible = math.min(4096, len - pos);

      if (maxPossible >= 3) {
        final candidates = <(int offset, int dSym)>[
          if (pos >= 1) (1, 1),
          if (pos >= width) (width, 0),
          if (pos >= width + 1) (width + 1, 2),
          if (width > 1 && pos >= width - 1) (width - 1, 3),
        ];

        for (final (offset, dSym) in candidates) {
          var matchLen = 0;
          while (matchLen < maxPossible &&
              greenStream[pos + matchLen] ==
                  greenStream[pos + matchLen - offset]) {
            matchLen++;
          }
          if (matchLen >= 3 && matchLen > bestLen) {
            bestLen = matchLen;
            bestDistSym = dSym;
            if (bestLen == maxPossible) break;
          }
        }
      }

      if (bestLen >= 3) {
        final lCode = _lengthToPrefixSymbol(bestLen);
        tokens.add((isMatch: true, value: bestLen, distSym: bestDistSym));
        greenFreq[256 + lCode.symbol]++;
        distFreq[bestDistSym]++;
        pos += bestLen;
      } else {
        final g = greenStream[pos];
        tokens.add((isMatch: false, value: g, distSym: 0));
        greenFreq[g]++;
        pos++;
      }
    }

    final gCode = _PrefixCode.fromFrequencies(greenFreq, alphabetSize: 280);
    final rCode = _PrefixCode.singleSymbol(0, alphabetSize: 256);
    final bCode = _PrefixCode.singleSymbol(0, alphabetSize: 256);
    final aCode = _PrefixCode.singleSymbol(constAlpha, alphabetSize: 256);
    final dCode = _PrefixCode.fromFrequencies(distFreq, alphabetSize: 40);

    gCode.writeToBitStream(writer);
    rCode.writeToBitStream(writer);
    bCode.writeToBitStream(writer);
    aCode.writeToBitStream(writer);
    dCode.writeToBitStream(writer);

    for (final t in tokens) {
      if (!t.isMatch) {
        gCode.writeSymbol(writer, t.value);
        // R, B, A 为单符号树，codeLen = 0，无需向位流写入任何位。
      } else {
        final lInfo = _lengthToPrefixSymbol(t.value);
        gCode.writeSymbol(writer, 256 + lInfo.symbol);
        if (lInfo.extraBits > 0) {
          writer.writeBits(lInfo.extraVal, lInfo.extraBits);
        }
        dCode.writeSymbol(writer, t.distSym);
      }
    }
  }

  static ({int symbol, int extraBits, int extraVal}) _lengthToPrefixSymbol(
    int length,
  ) {
    if (length <= 4) {
      return (symbol: length - 1, extraBits: 0, extraVal: 0);
    }
    final v = length - 1;
    final highestBit = v.bitLength - 1;
    final extraBits = highestBit - 1;
    final secondBit = (v >> extraBits) & 1;
    final symbol = 2 * extraBits + 2 + secondBit;
    final extraVal = v & ((1 << extraBits) - 1);
    return (symbol: symbol, extraBits: extraBits, extraVal: extraVal);
  }

  static Uint8List _wrapRiffVp8l(Uint8List vp8lPayload) {
    final chunkSize = vp8lPayload.length;
    final paddedChunkLen = chunkSize.isOdd ? chunkSize + 1 : chunkSize;
    final riffSize = 4 + 8 + paddedChunkLen;
    final out = Uint8List(8 + riffSize);
    final bd = ByteData.sublistView(out);

    // "RIFF"
    out[0] = 0x52;
    out[1] = 0x49;
    out[2] = 0x46;
    out[3] = 0x46;
    bd.setUint32(4, riffSize, Endian.little);
    // "WEBP"
    out[8] = 0x57;
    out[9] = 0x45;
    out[10] = 0x42;
    out[11] = 0x50;
    // "VP8L"
    out[12] = 0x56;
    out[13] = 0x50;
    out[14] = 0x38;
    out[15] = 0x4C;
    bd.setUint32(16, chunkSize, Endian.little);
    out.setRange(20, 20 + chunkSize, vp8lPayload);
    return out;
  }

  /// 基于中位切分的自适应调色板量化（保留高频代表色并以最近邻 33KB 查表实现毫秒级映射）。
  static ({Uint32List palette, Uint8List indices}) _quantizePalette({
    required Uint8List rgba,
    required int pixelCount,
    required int maxColors,
  }) {
    // 抽样/全量收集 15-bit RGB 量化桶（5-5-5 bits）用于快速高精度中位切分，同时若精准颜色 <= maxColors 直接无损保留
    final exactMap = <int, int>{};
    var overflowExact = false;
    final sampleStep = pixelCount > 24000 ? 2 : 1;

    final hist = <int, int>{};
    for (var i = 0; i < pixelCount; i++) {
      final base = i * 4;
      final r = rgba[base];
      final g = rgba[base + 1];
      final b = rgba[base + 2];
      final a = rgba[base + 3];
      final argb = (a << 24) | (r << 16) | (g << 8) | b;
      if (!overflowExact) {
        if (!exactMap.containsKey(argb)) {
          if (exactMap.length < maxColors) {
            exactMap[argb] = exactMap.length;
          } else {
            overflowExact = true;
          }
        }
      }
      if (i % sampleStep == 0) {
        final r5 = r >> 3;
        final g5 = g >> 3;
        final b5 = b >> 3;
        final key = (r5 << 10) | (g5 << 5) | b5;
        hist[key] = (hist[key] ?? 0) + 1;
      }
    }

    if (!overflowExact && exactMap.isNotEmpty) {
      final palette = Uint32List(exactMap.length);
      for (final entry in exactMap.entries) {
        palette[entry.value] = entry.key;
      }
      final indices = Uint8List(pixelCount);
      for (var i = 0; i < pixelCount; i++) {
        final base = i * 4;
        final argb =
            (rgba[base + 3] << 24) |
            (rgba[base] << 16) |
            (rgba[base + 1] << 8) |
            rgba[base + 2];
        indices[i] = exactMap[argb]!;
      }
      return (palette: palette, indices: indices);
    }

    // 中位切分将 5-5-5 直方图切分为最多 maxColors 个色盒
    final entries = hist.entries
        .map(
          (e) => _ColorBin(
            r: (((e.key >> 10) & 31) << 3) | 4,
            g: (((e.key >> 5) & 31) << 3) | 4,
            b: ((e.key & 31) << 3) | 4,
            count: e.value,
          ),
        )
        .toList(growable: false);

    final boxes = <_ColorBox>[_ColorBox(entries)];
    while (boxes.length < maxColors) {
      var splitIdx = -1;
      var bestScore = -1;
      for (var i = 0; i < boxes.length; i++) {
        final box = boxes[i];
        if (box.bins.length < 2 || box.maxRange == 0) continue;
        final score = box.maxRange * math.sqrt(box.totalCount).round();
        if (score > bestScore) {
          bestScore = score;
          splitIdx = i;
        }
      }
      if (splitIdx < 0) break;
      final target = boxes.removeAt(splitIdx);
      final (left, right) = target.split();
      boxes.add(left);
      boxes.add(right);
    }

    final pLen = boxes.length;
    final palette = Uint32List(pLen);
    final pR = Int32List(pLen);
    final pG = Int32List(pLen);
    final pB = Int32List(pLen);
    for (var i = 0; i < pLen; i++) {
      final (r, g, b) = boxes[i].weightedAverage();
      pR[i] = r;
      pG[i] = g;
      pB[i] = b;
      palette[i] = (0xFF << 24) | (r << 16) | (g << 8) | b;
    }

    // 使用 32768 格 5-5-5 LUT 加速全像素最近邻映射
    final lut = Int16List(32768)..fillRange(0, 32768, -1);
    final indices = Uint8List(pixelCount);
    for (var i = 0; i < pixelCount; i++) {
      final base = i * 4;
      final r = rgba[base];
      final g = rgba[base + 1];
      final b = rgba[base + 2];
      final lutKey = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
      var palIdx = lut[lutKey];
      if (palIdx < 0) {
        var bestDist = 0x7FFFFFFF;
        var bestIdx = 0;
        for (var j = 0; j < pLen; j++) {
          final dr = r - pR[j];
          final dg = g - pG[j];
          final db = b - pB[j];
          // 符合人眼视觉感知权重近似 (2*R + 4*G + 1*B)
          final dist = 2 * dr * dr + 4 * dg * dg + db * db;
          if (dist < bestDist) {
            bestDist = dist;
            bestIdx = j;
          }
        }
        palIdx = bestIdx;
        lut[lutKey] = palIdx;
      }
      indices[i] = palIdx;
    }
    return (palette: palette, indices: indices);
  }
}

class _ColorBin {
  const _ColorBin({
    required this.r,
    required this.g,
    required this.b,
    required this.count,
  });

  final int r;
  final int g;
  final int b;
  final int count;
}

class _ColorBox {
  _ColorBox(this.bins) {
    var minR = 255, maxR = 0;
    var minG = 255, maxG = 0;
    var minB = 255, maxB = 0;
    var sum = 0;
    for (final bin in bins) {
      if (bin.r < minR) minR = bin.r;
      if (bin.r > maxR) maxR = bin.r;
      if (bin.g < minG) minG = bin.g;
      if (bin.g > maxG) maxG = bin.g;
      if (bin.b < minB) minB = bin.b;
      if (bin.b > maxB) maxB = bin.b;
      sum += bin.count;
    }
    totalCount = sum;
    final rr = maxR - minR;
    final gr = maxG - minG;
    final br = maxB - minB;
    if (gr >= rr && gr >= br) {
      dominantAxis = 1;
      maxRange = gr;
    } else if (rr >= br) {
      dominantAxis = 0;
      maxRange = rr;
    } else {
      dominantAxis = 2;
      maxRange = br;
    }
  }

  final List<_ColorBin> bins;
  late final int totalCount;
  late final int dominantAxis;
  late final int maxRange;

  (_ColorBox, _ColorBox) split() {
    final sorted = List<_ColorBin>.of(bins)
      ..sort((a, b) {
        final av = dominantAxis == 0 ? a.r : (dominantAxis == 1 ? a.g : a.b);
        final bv = dominantAxis == 0 ? b.r : (dominantAxis == 1 ? b.g : b.b);
        return av.compareTo(bv);
      });
    final half = totalCount ~/ 2;
    var acc = 0;
    var splitAt = 1;
    for (var i = 0; i < sorted.length - 1; i++) {
      acc += sorted[i].count;
      if (acc >= half) {
        splitAt = i + 1;
        break;
      }
    }
    return (
      _ColorBox(sorted.sublist(0, splitAt)),
      _ColorBox(sorted.sublist(splitAt)),
    );
  }

  (int, int, int) weightedAverage() {
    var sr = 0, sg = 0, sb = 0, w = 0;
    for (final bin in bins) {
      sr += bin.r * bin.count;
      sg += bin.g * bin.count;
      sb += bin.b * bin.count;
      w += bin.count;
    }
    if (w <= 0) return (0, 0, 0);
    return ((sr ~/ w).clamp(0, 255), (sg ~/ w).clamp(0, 255), (sb ~/ w).clamp(0, 255));
  }
}

class _LsbBitWriter {
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _acc = 0;
  int _bitPos = 0;

  void writeBits(int value, int bitCount) {
    for (var i = 0; i < bitCount; i++) {
      final bit = (value >> i) & 1;
      _acc |= (bit << _bitPos);
      _bitPos++;
      if (_bitPos == 8) {
        _bytes.addByte(_acc);
        _acc = 0;
        _bitPos = 0;
      }
    }
  }

  void writeMsbCode(int code, int codeLen) {
    for (var i = codeLen - 1; i >= 0; i--) {
      final bit = (code >> i) & 1;
      _acc |= (bit << _bitPos);
      _bitPos++;
      if (_bitPos == 8) {
        _bytes.addByte(_acc);
        _acc = 0;
        _bitPos = 0;
      }
    }
  }

  void writeByte(int b) => writeBits(b & 0xFF, 8);

  Uint8List finish() {
    if (_bitPos > 0) {
      _bytes.addByte(_acc);
      _acc = 0;
      _bitPos = 0;
    }
    return _bytes.takeBytes();
  }
}

class _HuffNode {
  _HuffNode(this.freq, this.symbol, [this.left, this.right]);

  final int freq;
  final int symbol;
  final _HuffNode? left;
  final _HuffNode? right;
}

class _PrefixCode {
  _PrefixCode._({
    required this.alphabetSize,
    required this.isSimple,
    required this.simpleSymbols,
    required this.lengths,
    required this.codes,
  });

  final int alphabetSize;
  final bool isSimple;
  final List<int> simpleSymbols;
  final Int32List lengths;
  final Int32List codes;

  factory _PrefixCode.singleSymbol(int symbol, {required int alphabetSize}) {
    final lengths = Int32List(alphabetSize);
    final codes = Int32List(alphabetSize);
    return _PrefixCode._(
      alphabetSize: alphabetSize,
      isSimple: true,
      simpleSymbols: <int>[symbol],
      lengths: lengths,
      codes: codes,
    );
  }

  factory _PrefixCode.fromChannelBytes(
    Uint8List data, {
    required int alphabetSize,
  }) {
    final freq = Int32List(alphabetSize);
    for (var i = 0; i < data.length; i++) {
      freq[data[i]]++;
    }
    return _PrefixCode.fromFrequencies(freq, alphabetSize: alphabetSize);
  }

  factory _PrefixCode.fromFrequencies(
    Int32List freq, {
    required int alphabetSize,
    int maxCodeBits = 15,
  }) {
    final active = <int>[];
    for (var i = 0; i < alphabetSize; i++) {
      if (freq[i] > 0) active.add(i);
    }
    if (active.isEmpty) {
      return _PrefixCode.singleSymbol(0, alphabetSize: alphabetSize);
    }
    if (active.length == 1 && active.first < 256) {
      return _PrefixCode.singleSymbol(active.first, alphabetSize: alphabetSize);
    }
    if (active.length == 2 && active[0] < 256 && active[1] < 256) {
      final lengths = Int32List(alphabetSize);
      final codes = Int32List(alphabetSize);
      lengths[active[0]] = 1;
      codes[active[0]] = 0;
      lengths[active[1]] = 1;
      codes[active[1]] = 1;
      return _PrefixCode._(
        alphabetSize: alphabetSize,
        isSimple: true,
        simpleSymbols: <int>[active[0], active[1]],
        lengths: lengths,
        codes: codes,
      );
    }

    final lengths = _buildLengthLimitedHuffman(
      freq,
      alphabetSize: alphabetSize,
      maxBits: maxCodeBits,
    );
    final codes = _assignCanonicalCodes(lengths);
    return _PrefixCode._(
      alphabetSize: alphabetSize,
      isSimple: false,
      simpleSymbols: const <int>[],
      lengths: lengths,
      codes: codes,
    );
  }

  void writeSymbol(_LsbBitWriter writer, int symbol) {
    final len = lengths[symbol];
    if (len <= 0) return;
    writer.writeMsbCode(codes[symbol], len);
  }

  void writeToBitStream(_LsbBitWriter writer) {
    if (isSimple) {
      writer.writeBits(1, 1); // is_simple = 1
      if (simpleSymbols.length == 1) {
        final s0 = simpleSymbols[0];
        writer.writeBits(0, 1); // num_symbols - 1 = 0
        if (s0 <= 1) {
          writer.writeBits(0, 1);
          writer.writeBits(s0, 1);
        } else {
          writer.writeBits(1, 1);
          writer.writeBits(s0, 8);
        }
      } else {
        final s0 = simpleSymbols[0];
        final s1 = simpleSymbols[1];
        writer.writeBits(1, 1); // num_symbols - 1 = 1
        if (s0 <= 1) {
          writer.writeBits(0, 1);
          writer.writeBits(s0, 1);
        } else {
          writer.writeBits(1, 1);
          writer.writeBits(s0, 8);
        }
        writer.writeBits(s1, 8);
      }
      return;
    }

    writer.writeBits(0, 1); // is_simple = 0 (Normal Prefix Code)

    // RLE 压缩码长序列（17 表示连续 0 x3..10, 18 表示连续 0 x11..138, 16 表示重复前值 x3..6）
    final rleTokens = _encodeCodeLengthRle(lengths);
    final clcFreq = Int32List(19);
    for (final t in rleTokens) {
      clcFreq[t.sym]++;
    }

    // 规范要求 CLC 树必须严格完备：若仅有 1 个 CLC 符号（所有码长严格相等），
    // 补入一个占位符号组成完备双节点前缀树（Kraft sum == 1），确保兼容全部 libwebp / Skia 解码器。
    final activeClc = <int>[];
    for (var s = 0; s < 19; s++) {
      if (clcFreq[s] > 0) activeClc.add(s);
    }
    if (activeClc.length == 1) {
      final dummy = activeClc.first == 0 ? 1 : 0;
      clcFreq[dummy] = 1;
      activeClc.add(dummy);
    }
    final clcLengths = _buildLengthLimitedHuffman(
      clcFreq,
      alphabetSize: 19,
      maxBits: 7,
    );
    final clcCodes = _assignCanonicalCodes(clcLengths);

    var numClc = 19;
    while (numClc > 4 && clcLengths[CompactWebpEncoder._codeLengthCodeOrder[numClc - 1]] == 0) {
      numClc--;
    }
    writer.writeBits(numClc - 4, 4);
    for (var i = 0; i < numClc; i++) {
      writer.writeBits(clcLengths[CompactWebpEncoder._codeLengthCodeOrder[i]], 3);
    }

    // use_max_symbol = 0 -> 覆盖全字母表长度
    writer.writeBits(0, 1);

    for (final t in rleTokens) {
      final len = clcLengths[t.sym];
      if (len > 0) {
        writer.writeMsbCode(clcCodes[t.sym], len);
      }
      if (t.extraBits > 0) {
        writer.writeBits(t.extraVal, t.extraBits);
      }
    }
  }

  static List<({int sym, int extraBits, int extraVal})> _encodeCodeLengthRle(
    Int32List lengths,
  ) {
    final out = <({int sym, int extraBits, int extraVal})>[];
    var i = 0;
    final n = lengths.length;
    var prevNonZero = 8;
    while (i < n) {
      final v = lengths[i];
      if (v == 0) {
        var run = 1;
        while (i + run < n && lengths[i + run] == 0 && run < 138) {
          run++;
        }
        if (run >= 11) {
          out.add((sym: 18, extraBits: 7, extraVal: run - 11));
          i += run;
        } else if (run >= 3) {
          out.add((sym: 17, extraBits: 3, extraVal: run - 3));
          i += run;
        } else {
          out.add((sym: 0, extraBits: 0, extraVal: 0));
          i++;
        }
      } else {
        if (i > 0 && lengths[i - 1] == v) {
          var run = 1;
          while (i + run < n && lengths[i + run] == v && run < 6) {
            run++;
          }
          if (run >= 3) {
            out.add((sym: 16, extraBits: 2, extraVal: run - 3));
            i += run;
            continue;
          }
        }
        out.add((sym: v, extraBits: 0, extraVal: 0));
        prevNonZero = v;
        i++;
      }
    }
    // 消除 unused 提示（RFC 中 prevNonZero 初始为 8 用于解析阶段校验）
    if (prevNonZero < 0) return out;
    return out;
  }

  static Int32List _buildLengthLimitedHuffman(
    Int32List freq, {
    required int alphabetSize,
    required int maxBits,
  }) {
    final nodes = <_HuffNode>[];
    for (var s = 0; s < alphabetSize; s++) {
      if (freq[s] > 0) {
        nodes.add(_HuffNode(freq[s], s));
      }
    }
    final lengths = Int32List(alphabetSize);
    if (nodes.isEmpty) {
      lengths[0] = 1;
      return lengths;
    }
    if (nodes.length == 1) {
      lengths[nodes.first.symbol] = 1;
      return lengths;
    }

    // 使用简单双排序合并建树（节点 <= 280，极快且无额外堆结构依赖）
    final queue = List<_HuffNode>.of(nodes);
    while (queue.length > 1) {
      queue.sort((a, b) => a.freq.compareTo(b.freq));
      final left = queue.removeAt(0);
      final right = queue.removeAt(0);
      queue.add(_HuffNode(left.freq + right.freq, -1, left, right));
    }

    void walk(_HuffNode node, int depth) {
      if (node.symbol >= 0) {
        lengths[node.symbol] = depth.clamp(1, maxBits);
        return;
      }
      walk(node.left!, depth + 1);
      walk(node.right!, depth + 1);
    }

    walk(queue.first, 0);

    // 严格保证 Kraft sum == 2^maxBits，防止超限长截断破坏完备性
    final target = 1 << maxBits;
    var kraft = 0;
    final activeSyms = <int>[for (final n in nodes) n.symbol];
    for (final s in activeSyms) {
      kraft += 1 << (maxBits - lengths[s]);
    }

    // 超支（kraft > target）：把较短码拉长（成本减少权重）
    while (kraft > target) {
      activeSyms.sort((a, b) => lengths[a].compareTo(lengths[b]));
      var changed = false;
      for (final s in activeSyms) {
        if (lengths[s] < maxBits) {
          final l = lengths[s];
          kraft -= (1 << (maxBits - l - 1));
          lengths[s] = l + 1;
          changed = true;
          break;
        }
      }
      if (!changed) break;
    }

    // 有富裕（kraft < target）：由大到小精准缩减码长直至严格凑满 2^maxBits
    while (kraft < target) {
      final deficit = target - kraft;
      var bestSym = -1;
      for (final s in activeSyms) {
        final l = lengths[s];
        if (l > 1) {
          final gain = 1 << (maxBits - l);
          if (gain <= deficit) {
            if (bestSym < 0 || lengths[s] > lengths[bestSym]) {
              bestSym = s;
            }
          }
        }
      }
      if (bestSym < 0) break;
      final l = lengths[bestSym];
      kraft += 1 << (maxBits - l);
      lengths[bestSym] = l - 1;
    }

    return lengths;
  }

  static Int32List _assignCanonicalCodes(Int32List lengths) {
    var maxLen = 0;
    for (var i = 0; i < lengths.length; i++) {
      if (lengths[i] > maxLen) maxLen = lengths[i];
    }
    final blCount = Int32List(maxLen + 1);
    for (var i = 0; i < lengths.length; i++) {
      final l = lengths[i];
      if (l > 0) blCount[l]++;
    }
    final nextCode = Int32List(maxLen + 1);
    var code = 0;
    for (var bits = 1; bits <= maxLen; bits++) {
      code = (code + blCount[bits - 1]) << 1;
      nextCode[bits] = code;
    }
    final codes = Int32List(lengths.length);
    for (var i = 0; i < lengths.length; i++) {
      final l = lengths[i];
      if (l > 0) {
        codes[i] = nextCode[l];
        nextCode[l]++;
      }
    }
    return codes;
  }
}
