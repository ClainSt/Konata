import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 播放引擎词表的宿主资产入口及纯 Dart 文件兜底。
abstract final class PlaybackTableAssets {
  static AssetDataLoaderPort? _loader;

  /// 注册宿主读取端口，真正用到词表时再发起读取。
  static void configure(AssetDataLoaderPort? loader) => _loader = loader;

  /// 读取打包资产，纯 Dart 工具和测试使用同一份仓内资源。
  static Future<Uint8List> load(String name) async {
    final bytes = await _loader?.loadBytes('assets/data/$name');
    return bytes ?? loadFromCheckout(name);
  }

  /// 独立纯 Dart 同步调用从检出的项目目录读取同一份打包数据。
  static Uint8List loadFromCheckout(String name) {
    var directory = Directory.current.absolute;
    while (true) {
      final file = File.fromUri(
        directory.uri.resolve('apps/konata/assets/data/$name'),
      );
      if (file.existsSync()) return file.readAsBytesSync();
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw StateError('未装载播放词表 $name');
      }
      directory = parent;
    }
  }

  /// 校验版本与数据段边界，然后返回共享底层字节的只读视图。
  static List<Uint8List> decodeSections(
    Uint8List compressed,
    String magic,
    int count,
  ) {
    final bytes = Uint8List.fromList(gzip.decode(compressed));
    var offset = 4 + count * 4;
    if (bytes.length < offset || ascii.decode(bytes.sublist(0, 4)) != magic) {
      throw FormatException('无效的播放词表格式 $magic');
    }
    final data = ByteData.sublistView(bytes);
    final sections = <Uint8List>[];
    for (var i = 0; i < count; i++) {
      final end = offset + data.getUint32(4 + i * 4, Endian.little);
      if (end <= offset || end > bytes.length) {
        throw FormatException('无效的播放词表区间 $magic#$i');
      }
      sections.add(
        Uint8List.sublistView(bytes, offset, end).asUnmodifiableView(),
      );
      offset = end;
    }
    if (offset != bytes.length) throw FormatException('播放词表存在多余数据 $magic');
    return sections;
  }
}

/// 每个隔离线程独立持有的压缩词表缓存。
final class PlaybackTableAsset {
  /// 指定打包词表的文件名。
  PlaybackTableAsset(this.name);

  /// 打包资产文件名。
  final String name;
  Uint8List? _bytes;
  Future<Uint8List>? _pending;

  /// 是否已经持有压缩字节。
  bool get isLoaded => _bytes != null;

  /// 取已装载字节，独立 Dart 调用可从检出目录延迟读取。
  Uint8List get bytes => _bytes ??= PlaybackTableAssets.loadFromCheckout(name);

  /// 读取一份可直接传入后台隔离线程的压缩词表。
  Future<Uint8List> prepare() async {
    final cached = _bytes;
    if (cached != null) return cached;
    final pending = _pending ??= PlaybackTableAssets.load(name);
    try {
      final bytes = await pending;
      if (identical(_pending, pending)) _bytes = bytes;
      return bytes;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  /// 接收宿主读取的同一份压缩词表。
  void usePrepared(Uint8List bytes) => _bytes ??= bytes;

  /// 清除缓存并阻止在途加载覆盖释放状态。
  void release() {
    _pending = null;
    _bytes = null;
  }
}
