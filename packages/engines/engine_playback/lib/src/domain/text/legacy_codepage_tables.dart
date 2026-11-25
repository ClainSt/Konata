import 'dart:io';
import 'dart:typed_data';

import 'playback_table_assets.dart';

/// 三个旧编码映射表的共享二进制资产及按页解析入口。
abstract final class LegacyCodePageTables {
  static final _asset = PlaybackTableAsset('legacy_codepages.bin.gz');
  static const _pageLengths = [23940, 19782, 11280];
  static final _tables = List<Uint16List?>.filled(3, null);
  static List<({int start, int end})>? _memberRanges;

  /// 是否已读取传统编码资产。
  static bool get isLoaded => _asset.isLoaded;

  /// 只统计已被实际请求的页。
  static int get loadedPageCount => _tables.whereType<Uint16List>().length;

  /// 首次需要纯 Dart 传统代码页解码时读取资产。
  static Future<Uint8List> prepare() => _asset.prepare();

  /// 后台隔离线程接收宿主已经读取的旧编码资产。
  static void usePrepared(Uint8List bytes) => _asset.usePrepared(bytes);

  /// 播放退出时释放源数据与已初始化的代码页。
  static void release() {
    _asset.release();
    _memberRanges = null;
    _tables.fillRange(0, _tables.length, null);
  }

  /// 取指定代码页的只读定长映射。
  static Uint16List table(int page) => _tables[page] ??= _readTable(page);

  static Uint16List _readTable(int page) {
    final archive = _asset.bytes;
    final ranges = _memberRanges ??= _readMemberRanges(archive);
    final range = ranges[page];
    final section = Uint8List.fromList(
      gzip.decode(Uint8List.sublistView(archive, range.start, range.end)),
    );
    final length = _pageLengths[page];
    if (section.length != length * 2) {
      throw FormatException('传统代码页长度不一致：$page');
    }
    if (Endian.host == Endian.little) {
      return Uint16List.sublistView(section).asUnmodifiableView();
    }
    final view = ByteData.sublistView(section);
    final table = Uint16List(length);
    for (var i = 0; i < length; i++) {
      table[i] = view.getUint16(i * 2, Endian.little);
    }
    return table.asUnmodifiableView();
  }

  static List<({int start, int end})> _readMemberRanges(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final ranges = <({int start, int end})>[];
    var start = 0;
    for (var page = 0; page < _pageLengths.length; page++) {
      if (start + 20 > bytes.length ||
          data.getUint32(start) != 0x1f8b0804 ||
          data.getUint16(start + 10, Endian.little) != 8 ||
          data.getUint16(start + 12) != 0x4b50 ||
          data.getUint16(start + 14, Endian.little) != 4) {
        throw FormatException('旧编码压缩头无效：$page');
      }
      final end = start + data.getUint32(start + 16, Endian.little);
      if (end < start + 28 || end > bytes.length) {
        throw FormatException('旧编码压缩区间无效：$page');
      }
      ranges.add((start: start, end: end));
      start = end;
    }
    if (start != bytes.length) throw const FormatException('旧编码资产存在多余数据');
    return ranges;
  }
}
