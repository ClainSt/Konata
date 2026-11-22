import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../domain/formatting/image_header_parser.dart';

/// 音频专辑封面落盘压缩器（复用 `ImageHeaderParser` 零全量解码探测尺寸，仅在严格减小体积时替换原字节）。
///
/// 针对 BDRip FLAC 内嵌或同目录超大未压缩 PNG/BMP（动辄 3~12 MiB），将其按原宽高比等比缩放至
/// 最大边不超过 [maxDimensionPx] 后编码落盘；对本就轻量的 JPEG/WebP 或缩放后未更小的图片直接原样保留。
abstract final class AlbumCoverCompactor {
  /// 触发磁盘压缩的最小原始字节阈值（384 KiB 以下已足够紧凑，零额外解码开销）。
  static const int minBytesToCompact = 384 * 1024;

  /// 落盘专辑封面长边上限（720 px，兼顾高分屏沉浸音频页清晰度与低存储占用）。
  static const int maxDimensionPx = 720;

  /// 在严格保证不增大体积的前提下，将超大专辑封面等比压缩后返回适合落盘的字节流。
  static Future<Uint8List> compactForDisk(
    Uint8List rawBytes, {
    int minBytesThreshold = minBytesToCompact,
    int maxEdgePx = maxDimensionPx,
  }) async {
    if (rawBytes.length <= minBytesThreshold || maxEdgePx <= 0) {
      return rawBytes;
    }

    final headerDims = ImageHeaderParser.parseDimensions(rawBytes);
    final int? targetWidth;
    final int? targetHeight;
    if (headerDims != null) {
      final maxSide = math.max(headerDims.width, headerDims.height);
      if (maxSide <= maxEdgePx) {
        return rawBytes;
      }
      if (headerDims.width >= headerDims.height) {
        targetWidth = maxEdgePx;
        targetHeight = null;
      } else {
        targetWidth = null;
        targetHeight = maxEdgePx;
      }
    } else {
      targetWidth = maxEdgePx;
      targetHeight = null;
    }

    ui.Codec? codec;
    ui.Image? image;
    try {
      codec = await ui.instantiateImageCodec(
        rawBytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return rawBytes;
      final encoded = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      if (encoded.isNotEmpty && encoded.length < rawBytes.length) {
        return encoded;
      }
      return rawBytes;
    } on Object catch (error) {
      developer.log(
        '专辑封面压缩降级保留原字节',
        name: 'konata.album_cover_compactor',
        error: error,
      );
      return rawBytes;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
  }
}
