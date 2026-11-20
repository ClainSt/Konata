import 'dart:typed_data';

/// 纯领域图像文件头像素尺寸解析器（仅读取帧头，零完整解码与磁盘依赖）。
///
/// 支持 PNG、WebP（VP8L / VP8 / VP8X）、JPEG（SOF 标记）、GIF 与 BMP 格式，
/// 供 Scan 扫图微缩图缓存与本地磁盘画册快速提取自然宽高比。
abstract final class ImageHeaderParser {
  /// 宽高比合法钳制下界（防止极端长条图破坏画廊排布）。
  static const double minAspectRatio = 0.25;

  /// 宽高比合法钳制上界（防止极端超宽图破坏画廊排布）。
  static const double maxAspectRatio = 4.0;

  /// 从图像文件头字节片段中提取像素宽高；无法识别时返回 `null`。
  static ({int width, int height})? parseDimensions(Uint8List bytes) {
    if (bytes.length < 10) return null;

    // 1. PNG：8 字节魔数 + IHDR 块（偏移 16..23 存放大端宽高）
    if (bytes.length >= 24 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint32(16, Endian.big);
      final h = bd.getUint32(20, Endian.big);
      return _validDims(w, h);
    }

    // 2. WebP：RIFF....WEBP + VP8L / VP8X / VP8 帧头
    if (bytes.length >= 26 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return _parseWebp(bytes);
    }

    // 3. JPEG：SOI (0xFF 0xD8) 起顺序跳过分段直至 SOF 帧头
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return _parseJpeg(bytes);
    }

    // 4. GIF：GIF87a / GIF89a（偏移 6..9 存放小端 16 位宽高）
    if (bytes.length >= 10 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38 &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint16(6, Endian.little);
      final h = bd.getUint16(8, Endian.little);
      return _validDims(w, h);
    }

    // 5. BMP：BM 头（偏移 18..25 存放小端有符号 32 位宽高）
    if (bytes.length >= 26 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getInt32(18, Endian.little).abs();
      final h = bd.getInt32(22, Endian.little).abs();
      return _validDims(w, h);
    }

    return null;
  }

  /// 从图像文件头提取钳制后的自然宽高比（`width / height`）；无法识别时返回 `null`。
  static double? parseAspectRatio(Uint8List bytes) {
    final dims = parseDimensions(bytes);
    if (dims == null) return null;
    final ratio = dims.width / dims.height;
    if (!ratio.isFinite || ratio <= 0) return null;
    return ratio.clamp(minAspectRatio, maxAspectRatio);
  }

  static ({int width, int height})? _parseWebp(Uint8List bytes) {
    final c0 = bytes[12];
    final c1 = bytes[13];
    final c2 = bytes[14];
    final c3 = bytes[15];

    // VP8L 无损帧头：偏移 20 为 0x2F，偏移 21..24 为 14 位宽与 14 位高（均需 +1）
    if (c0 == 0x56 &&
        c1 == 0x50 &&
        c2 == 0x38 &&
        c3 == 0x4C &&
        bytes.length >= 25 &&
        bytes[20] == 0x2F) {
      final bd = ByteData.sublistView(bytes);
      final bits = bd.getUint32(21, Endian.little);
      final w = (bits & 0x3FFF) + 1;
      final h = ((bits >> 14) & 0x3FFF) + 1;
      return _validDims(w, h);
    }

    // VP8X 扩展画布头：偏移 24..26 为 24 位宽 - 1，偏移 27..29 为 24 位高 - 1
    if (c0 == 0x56 &&
        c1 == 0x50 &&
        c2 == 0x38 &&
        c3 == 0x58 &&
        bytes.length >= 30) {
      final w = (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)) + 1;
      final h = (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)) + 1;
      return _validDims(w, h);
    }

    // VP8 有损关键帧头：偏移 23..25 为 0x9D 0x01 0x2A，后接 16 位小端宽高（低 14 位）
    if (c0 == 0x56 &&
        c1 == 0x50 &&
        c2 == 0x38 &&
        c3 == 0x20 &&
        bytes.length >= 30 &&
        bytes[23] == 0x9D &&
        bytes[24] == 0x01 &&
        bytes[25] == 0x2A) {
      final bd = ByteData.sublistView(bytes);
      final w = bd.getUint16(26, Endian.little) & 0x3FFF;
      final h = bd.getUint16(28, Endian.little) & 0x3FFF;
      return _validDims(w, h);
    }

    return null;
  }

  static ({int width, int height})? _parseJpeg(Uint8List bytes) {
    final len = bytes.length;
    var offset = 2;
    while (offset + 4 < len) {
      // 跳过填充 0xFF 字节定位段标记
      if (bytes[offset] != 0xFF) {
        offset++;
        continue;
      }
      while (offset < len && bytes[offset] == 0xFF) {
        offset++;
      }
      if (offset >= len) return null;
      final marker = bytes[offset];
      offset++;

      // 独立标记（RST0..RST7、TEM、SOI）无长度字段
      if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
        continue;
      }
      // 到达扫描流起点或文件尾则终止
      if (marker == 0xD9 || marker == 0xDA) {
        return null;
      }
      if (offset + 2 > len) return null;
      final segLen = (bytes[offset] << 8) | bytes[offset + 1];
      if (segLen < 2) return null;

      // SOF 标记族（排除 DHT 0xC4、JPG 0xC8、DAC 0xCC）
      final isSof =
          (marker >= 0xC0 && marker <= 0xCF) &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        if (offset + 7 > len) return null;
        final h = (bytes[offset + 3] << 8) | bytes[offset + 4];
        final w = (bytes[offset + 5] << 8) | bytes[offset + 6];
        return _validDims(w, h);
      }

      offset += segLen;
    }
    return null;
  }

  static ({int width, int height})? _validDims(int width, int height) {
    if (width <= 0 || height <= 0 || width > 65536 || height > 65536) {
      return null;
    }
    return (width: width, height: height);
  }
}
