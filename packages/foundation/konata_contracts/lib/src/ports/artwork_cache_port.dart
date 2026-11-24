import 'dart:typed_data';

/// 统一 `photos/` 根目录下的五类规范图片子目录。
enum PhotoSubfolder {
  /// 作品竖版封面图。
  posters('posters'),

  /// 作品详情页横版背景画作。
  backdrops('backdrops'),

  /// 作品官方透明标题徽标。
  logos('logos'),

  /// 单集分集剧照缩略图（可再生）。
  thumbnails('thumbnails'),

  /// 扫图微缩图（可再生）。
  scans('scans');

  const PhotoSubfolder(this.dirName);

  /// 磁盘子目录名。
  final String dirName;
}

/// 供引擎与业务层按需读写的图片缓存抽象接口（零界面框架与数据库静态依赖）。
abstract interface class ArtworkCacheStore {
  /// 读取满足最低质量分档要求的缓存图片字节。
  Future<Uint8List?> read(
    String key, {
    int minimumQuality = 0,
    String? owner,
    PhotoSubfolder? subfolder,
  });

  /// 写入或更新缓存图片字节并关联所有者。
  Future<void> write(
    String key,
    Uint8List bytes, {
    String? owner,
    int quality = 0,
    PhotoSubfolder? subfolder,
  });

  /// 按作品标识与子目录兜底读取本地图片文件（用于作品改名或便携目录迁移后兼容既有路径）。
  Future<Uint8List?> readLocalWorkFile({
    required String owner,
    required PhotoSubfolder subfolder,
    required String fileName,
  });
}
