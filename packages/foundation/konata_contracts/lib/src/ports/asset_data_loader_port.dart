import 'dart:typed_data';

/// 纯 Dart 只读应用内置资产字节读取端口。
///
/// 屏蔽 Flutter `rootBundle` 与本地文件系统差异，使 `packages/engines/*`
/// 能在严格零 Flutter 依赖的前提下按需惰性加载压缩词表与离线映射表。
abstract interface class AssetDataLoaderPort {
  /// 按逻辑资产路径（如 `assets/data/release_groups.bin.gz`）异步读取字节；
  /// 资产不存在或不可读取时返回 `null`。
  Future<Uint8List?> loadBytes(String assetPath);
}
