/// 远程或本地目录项强类型描述。
class RemoteEntry {
  /// 创建目录项实例。
  const RemoteEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    this.size = 0,
    this.modifiedAt,
  });

  /// 文件或子目录名称。
  final String name;

  /// 相对于媒体源根目录的规范化 POSIX 路径（以 `/` 分隔）。
  final String relativePath;

  /// 是否为目录。
  final bool isDirectory;

  /// 文件字节大小（目录为 0）。
  final int size;

  /// 最后修改时间（若协议提供）。
  final DateTime? modifiedAt;
}

/// 只读虚拟文件系统抽象接口（隔离 Local / WebDAV / SMB 协议细节）。
abstract interface class MediaSourceGateway {
  /// 列出指定相对目录下的直接子项（非递归）。
  Future<List<RemoteEntry>> listDirectory(String relativePath);

  /// 读取小文本文件（如 `.nfo` / `.cue`），限制最大读取字节防止误读大文件。
  Future<String?> readTextFile(
    String relativePath, {
    int maxBytes = 256 * 1024,
  });

  /// 测试媒体源连通性，连通成功返回 `null`，失败返回可读错误说明。
  Future<String?> testConnection();

  /// 释放底层网络连接或会话资源。
  Future<void> close();
}
