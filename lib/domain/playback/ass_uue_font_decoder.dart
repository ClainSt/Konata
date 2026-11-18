import 'dart:typed_data';

/// 从 ASS `[Fonts]` 段落提取出的单个内嵌字体二进制记录。
class AssEmbeddedFontEntry {
  /// 创建内嵌字体条目。
  const AssEmbeddedFontEntry({
    required this.fontName,
    required this.bytes,
  });

  /// ASS `fontname:` 声明的原始字体文件名。
  final String fontName;

  /// UUEncode 精确还原后的字体二进制内容。
  final Uint8List bytes;
}

/// ASS `[Fonts]` 专用 UUEncode 编解码器与 SFNT/OpenType 字体头魔数校验器（纯领域算法）。
///
/// 严格遵循 ASS/SSA `[Fonts]` 编码规范：
/// - 无传统 Unix uuencode 的行首长度字节，直接对 3 字节分组执行 6-bit 切片并加偏移 33 (`'!'`)；
/// - 末尾不足 4 字符的余数块（2 字符还原 1 字节、3 字符还原 2 字节）执行精确截断，
///   严禁错误输出尾部填充零字节导致 TrueType/OpenType 表校验和破坏。
class AssUueFontDecoder {
  AssUueFontDecoder._();

  /// 每行编码输出的常规字符宽度（符合 Aegisub/libass 惯例）。
  static const int lineWidth = 80;

  /// 将原始字体字节流编码为 ASS `[Fonts]` 规范的 UUEncode 文本块。
  static String encode(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    final rawChars = <int>[];
    var i = 0;
    while (i + 3 <= bytes.length) {
      final b0 = bytes[i];
      final b1 = bytes[i + 1];
      final b2 = bytes[i + 2];
      final v = (b0 << 16) | (b1 << 8) | b2;
      rawChars
        ..add(((v >> 18) & 0x3F) + 33)
        ..add(((v >> 12) & 0x3F) + 33)
        ..add(((v >> 6) & 0x3F) + 33)
        ..add((v & 0x3F) + 33);
      i += 3;
    }

    final rem = bytes.length - i;
    if (rem == 1) {
      final b0 = bytes[i];
      rawChars
        ..add(((b0 >> 2) & 0x3F) + 33)
        ..add(((b0 << 4) & 0x3F) + 33);
    } else if (rem == 2) {
      final b0 = bytes[i];
      final b1 = bytes[i + 1];
      final v = (b0 << 8) | b1;
      rawChars
        ..add(((v >> 10) & 0x3F) + 33)
        ..add(((v >> 4) & 0x3F) + 33)
        ..add(((v << 2) & 0x3F) + 33);
    }

    final out = StringBuffer();
    for (var pos = 0; pos < rawChars.length; pos += lineWidth) {
      final end = (pos + lineWidth < rawChars.length)
          ? pos + lineWidth
          : rawChars.length;
      if (pos > 0) out.write('\n');
      out.write(String.fromCharCodes(rawChars.sublist(pos, end)));
    }
    return out.toString();
  }

  /// 将 ASS `[Fonts]` UUEncode 文本精确解码为原始字节流（不含传统行首长度字节、精确截断末尾余数）。
  static Uint8List decode(String encoded) {
    final sixBits = <int>[];
    for (var i = 0; i < encoded.length; i++) {
      final cu = encoded.codeUnitAt(i);
      if (cu == 0x0A || cu == 0x0D || cu == 0x20 || cu == 0x09) {
        continue;
      }
      if (cu < 33 || cu > 96) {
        throw FormatException('ASS 内嵌字体包含非法 UUEncode 字符码点: $cu');
      }
      sixBits.add((cu - 33) & 0x3F);
    }

    final fullGroups = sixBits.length ~/ 4;
    final remainder = sixBits.length % 4;
    if (remainder == 1) {
      throw const FormatException('ASS 内嵌字体 UUEncode 末尾存在非法单字符余数');
    }

    final outLen = fullGroups * 3 + (remainder == 2 ? 1 : (remainder == 3 ? 2 : 0));
    final result = Uint8List(outLen);
    var src = 0;
    var dst = 0;

    for (var g = 0; g < fullGroups; g++) {
      final v =
          (sixBits[src] << 18) |
          (sixBits[src + 1] << 12) |
          (sixBits[src + 2] << 6) |
          sixBits[src + 3];
      result[dst] = (v >> 16) & 0xFF;
      result[dst + 1] = (v >> 8) & 0xFF;
      result[dst + 2] = v & 0xFF;
      src += 4;
      dst += 3;
    }

    if (remainder == 2) {
      result[dst] = ((sixBits[src] << 2) | (sixBits[src + 1] >> 4)) & 0xFF;
    } else if (remainder == 3) {
      result[dst] = ((sixBits[src] << 2) | (sixBits[src + 1] >> 4)) & 0xFF;
      result[dst + 1] =
          (((sixBits[src + 1] & 0x0F) << 4) | (sixBits[src + 2] >> 2)) & 0xFF;
    }

    return result;
  }

  /// 从完整 ASS 字幕文本的 `[Fonts]` 段落中提取全部内嵌字体条目。
  static List<AssEmbeddedFontEntry> extractEmbeddedFonts(String assContent) {
    final lines = assContent.split(RegExp(r'\r?\n'));
    var inFontsSection = false;
    String? currentFontName;
    final currentPayload = StringBuffer();
    final results = <AssEmbeddedFontEntry>[];

    void flushCurrent() {
      final name = currentFontName;
      if (name == null || name.isEmpty) return;
      final payload = currentPayload.toString();
      if (payload.isNotEmpty) {
        results.add(
          AssEmbeddedFontEntry(
            fontName: name,
            bytes: decode(payload),
          ),
        );
      }
      currentFontName = null;
      currentPayload.clear();
    }

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        if (inFontsSection) {
          flushCurrent();
        }
        inFontsSection = trimmed.toLowerCase() == '[fonts]';
        continue;
      }
      if (!inFontsSection) continue;
      if (trimmed.toLowerCase().startsWith('fontname:')) {
        flushCurrent();
        currentFontName = trimmed.substring('fontname:'.length).trim();
        continue;
      }
      if (currentFontName != null) {
        currentPayload.write(trimmed);
      }
    }
    if (inFontsSection) {
      flushCurrent();
    }
    return results;
  }

  /// 校验字体文件前 4 字节是否符合 TrueType / OpenType / TrueType Collection 合法 SFNT 魔数。
  static bool isValidFontMagic(List<int> bytes) {
    if (bytes.length < 12) return false;
    final b0 = bytes[0];
    final b1 = bytes[1];
    final b2 = bytes[2];
    final b3 = bytes[3];
    // 标准 TrueType 轮廓魔数 (0x00010000)
    if (b0 == 0x00 && b1 == 0x01 && b2 == 0x00 && b3 == 0x00) return true;
    // OpenType CFF 轮廓魔数 ('OTTO')
    if (b0 == 0x4F && b1 == 0x54 && b2 == 0x54 && b3 == 0x4F) return true;
    // TrueType 集合字库魔数 ('ttcf')
    if (b0 == 0x74 && b1 == 0x74 && b2 == 0x63 && b3 == 0x66) return true;
    // 苹果 TrueType 轮廓魔数 ('true')
    if (b0 == 0x74 && b1 == 0x72 && b2 == 0x75 && b3 == 0x65) return true;
    return false;
  }

  /// 判断文件名是否属于 libass 支持的字库文件扩展名。
  static bool isSupportedFontFileName(String fileName) {
    final lower = fileName.toLowerCase();
    return lower.endsWith('.ttf') ||
        lower.endsWith('.otf') ||
        lower.endsWith('.ttc') ||
        lower.endsWith('.otc');
  }
}
