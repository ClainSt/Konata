import 'package:konata_contracts/konata_contracts.dart';
import 'package:konata_storage/konata_storage.dart';

/// 作品本机艺术图目录管理端口（用于在刮削改名、多版本归并与删作时同步整理 `photos/`）。
abstract interface class WorkArtworkStoragePort {
  /// 当作品标题修改时，同步将既有的作品图片文件夹重命名为新标题目录。
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle);

  /// 合并或迁移两部作品时，将源作品名下全部已缓存图片合并迁入目标作品文件夹并清理源目录。
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  });

  /// 删除作品名下全部本地图片缓存文件夹（绝不触碰物理媒体源目录）。
  Future<void> deleteWorkPhotos(String workId);

  /// 清理已被替代的受管剧照，拒绝外部路径和跨作品文件。
  Future<bool> deleteManagedStill(String workId, String path);
}

/// 基于公共图片存储实现刮削引擎所需的目录管理端口。
final class StorageRootWorkArtworkStorage implements WorkArtworkStoragePort {
  /// 使用统一存储根解析端口创建图片目录管理器。
  StorageRootWorkArtworkStorage({required StorageRootPort storageRoot})
    : _storage = PhotosStorage(storageRoot: storageRoot);

  final PhotosStorage _storage;

  @override
  Future<void> renameWorkFolderIfNeeded(String workId, String newTitle) =>
      _storage.renameWorkFolderIfNeeded(workId, newTitle);

  @override
  Future<void> mergeWorkPhotos({
    required String sourceWorkId,
    required String targetWorkId,
    String? targetTitle,
  }) => _storage.mergeWorkPhotos(
    sourceWorkId: sourceWorkId,
    targetWorkId: targetWorkId,
    targetTitle: targetTitle,
  );

  @override
  Future<void> deleteWorkPhotos(String workId) =>
      _storage.deleteWorkPhotos(workId);

  @override
  Future<bool> deleteManagedStill(String workId, String path) =>
      _storage.deleteManagedArtworkFile(
        workId: workId,
        subfolder: PhotoSubfolder.thumbnails,
        path: path,
      );
}
