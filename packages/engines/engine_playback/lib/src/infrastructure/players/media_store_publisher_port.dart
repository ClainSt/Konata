import 'dart:io';

/// 移动端系统相册原子发布端口（替代 `MethodChannel('konata/media_store')`）。
abstract interface class MediaStorePublisherPort {
  /// 将已落盘的临时原画截图通过 `MediaStore` 事务写入系统相册并返回内容 `URI`。
  Future<String?> saveImageToGallery({
    required File tempFile,
    required String displayName,
    required String albumName,
    String mimeType = 'image/png',
  });
}
