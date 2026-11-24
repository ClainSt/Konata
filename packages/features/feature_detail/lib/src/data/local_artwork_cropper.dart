import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:konata_contracts/konata_contracts.dart' show PhotoSubfolder;
import 'package:konata_storage/konata_storage.dart';

import 'artwork_crop_math.dart';

/// 按原始像素分辨率完整解码后的本地图片句柄。
class LoadedLocalArtwork {
  /// 创建本地图片解码句柄。
  const LoadedLocalArtwork({
    required this.image,
    required this.width,
    required this.height,
  });

  /// 原始分辨率 GPU 图像句柄（使用完毕须释放）。
  final ui.Image image;

  /// 原图像素宽度。
  final int width;

  /// 原图像素高度。
  final int height;

  /// 释放底层图像纹理资源。
  void dispose() {
    image.dispose();
  }
}

/// 本机自定义图片原分辨率解码、精确比例裁切与受管目录持久化工具。
abstract final class LocalArtworkCropper {
  /// 解码阶段强制保留最高有效边长上限，兼顾超清壁纸细节与 GPU 纹理安全限制。
  static const int maxTargetEdgePixels = 2560;

  /// 读取本地图片文件并解码为完整像素画幅 `ui.Image`。
  static Future<LoadedLocalArtwork> loadFromFilePath(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('所选本地图片文件不存在', filePath);
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('所选图片文件内容为空');
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      return LoadedLocalArtwork(
        image: frame.image,
        width: frame.image.width,
        height: frame.image.height,
      );
    } finally {
      codec.dispose();
    }
  }

  /// 读取本地图片文件（如透明 PNG / WebP 徽标），校验可解码性后直接持久化至受管目录。
  static Future<File> saveRawLocalArtwork({
    required PhotosStorage photosStorage,
    required String workId,
    required String? workTitle,
    required PhotoSubfolder subfolder,
    required String sourceFilePath,
  }) async {
    final loaded = await loadFromFilePath(sourceFilePath);
    loaded.dispose();
    final bytes = await File(sourceFilePath).readAsBytes();
    final lower = sourceFilePath.toLowerCase();
    final ext = lower.endsWith('.webp')
        ? '.webp'
        : (lower.endsWith('.jpg') || lower.endsWith('.jpeg')
              ? '.jpg'
              : '.png');
    return photosStorage.saveCustomArtwork(
      workId: workId,
      subfolder: subfolder,
      bytes: bytes,
      extension: ext,
      title: workTitle,
    );
  }

  /// 按用户最终框选比例裁切原图，编码为无损 PNG 并写入受管图库目录。
  static Future<File> cropAndSave({
    required PhotosStorage photosStorage,
    required String workId,
    required String? workTitle,
    required bool isPoster,
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
  }) async {
    final srcPx = ArtworkCropMath.toSourcePixelRect(
      cropRect,
      imageWidth: source.width,
      imageHeight: source.height,
    );

    final scaleDown = math.min(
      1.0,
      maxTargetEdgePixels / math.max(srcPx.width, srcPx.height),
    );
    final outW = math.max(1, (srcPx.width * scaleDown).round());
    final outH = math.max(1, (srcPx.height * scaleDown).round());

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final srcRect = ui.Rect.fromLTWH(
      srcPx.left.toDouble(),
      srcPx.top.toDouble(),
      srcPx.width.toDouble(),
      srcPx.height.toDouble(),
    );
    final dstRect = ui.Rect.fromLTWH(0, 0, outW.toDouble(), outH.toDouble());
    final paint = ui.Paint()
      ..isAntiAlias = true
      ..filterQuality = ui.FilterQuality.high;
    canvas.drawImageRect(source.image, srcRect, dstRect, paint);

    final picture = recorder.endRecording();
    ui.Image? cropped;
    try {
      cropped = await picture.toImage(outW, outH);
      final byteData = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('无法导出裁剪后的 PNG 图片数据');
      }
      final pngBytes = Uint8List.view(
        byteData.buffer,
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return await photosStorage.saveCustomArtwork(
        workId: workId,
        subfolder: isPoster
            ? PhotoSubfolder.posters
            : PhotoSubfolder.backdrops,
        bytes: pngBytes,
        extension: '.png',
        title: workTitle,
      );
    } finally {
      cropped?.dispose();
      picture.dispose();
    }
  }
}
