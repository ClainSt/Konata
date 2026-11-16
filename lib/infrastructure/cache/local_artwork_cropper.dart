import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../domain/sources/artwork_crop_math.dart';
import 'photos_storage.dart';

/// 已完整解码进内存的本地原图资源句柄（按真实原图分辨率解码，严禁降采样）。
class LoadedLocalArtwork {
  /// 创建本地原图句柄。
  const LoadedLocalArtwork({
    required this.sourcePath,
    required this.fullImage,
    required this.width,
    required this.height,
  });

  /// 原始磁盘文件路径。
  final String sourcePath;

  /// 原始未降采样位图对象。
  final ui.Image fullImage;

  /// 原图真实像素宽度。
  final int width;

  /// 原图真实像素高度。
  final int height;

  /// 释放底层解码图像资源。
  void dispose() => fullImage.dispose();
}

/// 本地图片原分辨率解码、像素级框选裁切与统一 `photos/` 落盘服务。
abstract final class LocalArtworkCropper {
  /// 从本地磁盘读取并按原始真实像素分辨率完整解码图像。
  static Future<LoadedLocalArtwork> loadFullResolution(String filePath) async {
    final cleanPath = filePath.trim();
    if (cleanPath.isEmpty) {
      throw ArgumentError.value(filePath, 'filePath', '本地图片路径不能为空');
    }
    final file = File(cleanPath);
    if (!await file.exists()) {
      throw FileSystemException('本地图片文件不存在', cleanPath);
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw StateError('本地图片文件为空: $cleanPath');
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final image = frame.image;
      return LoadedLocalArtwork(
        sourcePath: cleanPath,
        fullImage: image,
        width: image.width,
        height: image.height,
      );
    } finally {
      codec.dispose();
    }
  }

  /// 按归一化选框精确映射回本地原图真实像素坐标，执行无损比例裁切并返回 PNG 字节流。
  static Future<Uint8List> cropToPngBytes({
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
  }) async {
    final px = ArtworkCropMath.toSourcePixelRect(
      cropRect,
      imageWidth: source.width,
      imageHeight: source.height,
    );
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final srcRect = ui.Rect.fromLTWH(
      px.left.toDouble(),
      px.top.toDouble(),
      px.width.toDouble(),
      px.height.toDouble(),
    );
    final dstRect = ui.Rect.fromLTWH(
      0,
      0,
      px.width.toDouble(),
      px.height.toDouble(),
    );
    final paint = ui.Paint()..filterQuality = ui.FilterQuality.high;
    canvas.drawImageRect(source.fullImage, srcRect, dstRect, paint);

    final picture = recorder.endRecording();
    late final ui.Image croppedImage;
    try {
      croppedImage = await picture.toImage(px.width, px.height);
    } finally {
      picture.dispose();
    }

    try {
      final byteData = await croppedImage.toByteData(
        format: ui.ImageByteFormat.png,
      );
      if (byteData == null) {
        throw StateError('无法编码裁切后的图像数据');
      }
      return byteData.buffer.asUint8List();
    } finally {
      croppedImage.dispose();
    }
  }

  /// 执行原图高分辨率裁切并直接写入统一 `photos/<作品名 [ID]>/<posters|backdrops>/` 目录，返回落盘文件路径。
  static Future<String> cropAndSaveToPhotos({
    required LoadedLocalArtwork source,
    required ArtworkNormalizedCropRect cropRect,
    required PhotosStorage photosStorage,
    required String workId,
    required String workTitle,
    required PhotoSubfolder subfolder,
  }) async {
    final pngBytes = await cropToPngBytes(source: source, cropRect: cropRect);
    final px = ArtworkCropMath.toSourcePixelRect(
      cropRect,
      imageWidth: source.width,
      imageHeight: source.height,
    );
    final sig =
        '${source.sourcePath}::${px.left},${px.top},${px.width}x${px.height}::${DateTime.now().microsecondsSinceEpoch}';
    final fileKey = 'local_crop_${PhotosStorage.shortDigest(sig)}.png';

    final savedFile = await photosStorage.writeArtwork(
      workId: workId,
      title: workTitle,
      subfolder: subfolder,
      fileKey: fileKey,
      bytes: pngBytes,
    );
    if (savedFile == null) {
      throw StateError('写入裁切图片失败：$fileKey');
    }
    return savedFile.path;
  }
}
