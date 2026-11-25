import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 纯领域中文拼音首字母与全拼分桶自然排序器（零外部依赖，覆盖全部 20902 个标准简繁汉字）。
///
/// 采用按需解压的 20.9 KB 扁平 `Uint8List` 查找表（编码规则：`首字母序号 * 11 + 桶内拼音序`），
/// 实现 `O(1)` 单字拼音首字母与全拼相对序定位，并融合自然数字排序（如 `2 < 10`），
/// 遵循简体中文文件浏览器的标准分组顺序：符号 -> 自然数字 -> 英文字母 -> 中文拼音 -> 其他文字。
abstract final class ChinesePinyinCollator {
  static const int _cjkStart = 0x4E00;
  static const int _cjkEnd = 0x9FA5;
  static const int _subBuckets = 11;
  static const String _initials = 'abcdefghjklmnopqrstwxyz';

  static const _assetPath = 'assets/data/pinyin.bin.gz';
  static AssetDataLoaderPort? _loader;
  static Uint8List? _loadedRanks;
  static Future<Uint8List>? _pending;

  /// 配置媒体库按需读入的宿主资产。
  static void configure(AssetDataLoaderPort? loader) => _loader = loader;

  /// 汉字排序表是否已解码。
  static bool get isLoaded => _loadedRanks != null;

  /// 判断标题或发行组是否包含需要拼音表排序的汉字。
  static bool needsTable(String value) =>
      value.codeUnits.any((unit) => unit >= _cjkStart && unit <= _cjkEnd);

  /// 在有汉字排序需求时异步读取排序表。
  static Future<void> prepare() async {
    if (isLoaded) return;
    final pending = _pending ??= _readBundled();
    try {
      final ranks = await pending;
      if (identical(_pending, pending)) _loadedRanks = ranks;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  /// 释放排序表。
  static void release() {
    _pending = null;
    _loadedRanks = null;
  }

  static Future<Uint8List> _readBundled() async {
    final compressed = await _loader?.loadBytes(_assetPath);
    return compressed == null ? _readFromCheckout() : _decode(compressed);
  }

  static Uint8List get _pinyinRanks => _loadedRanks ??= _readFromCheckout();

  static Uint8List _readFromCheckout() {
    var directory = Directory.current.absolute;
    while (true) {
      final file = File.fromUri(
        directory.uri.resolve('apps/konata/$_assetPath'),
      );
      if (file.existsSync()) return _decode(file.readAsBytesSync());
      final parent = directory.parent;
      if (parent.path == directory.path) throw StateError('未装载拼音词表');
      directory = parent;
    }
  }

  static Uint8List _decode(Uint8List compressed) {
    final ranks = gzip.decode(compressed);
    if (ranks.length != _cjkEnd - _cjkStart + 1) {
      throw const FormatException('拼音词表长度不一致');
    }
    return Uint8List.fromList(ranks).asUnmodifiableView();
  }

  /// 查询单个汉字（`U+4E00..U+9FA5`）对应的汉语拼音首字母（`a..z`），非汉字返回 `null`。
  static String? pinyinInitialOfRune(int rune) {
    if (rune < _cjkStart || rune > _cjkEnd) return null;
    final rank = _pinyinRanks[rune - _cjkStart];
    final initialIdx = rank ~/ _subBuckets;
    if (initialIdx < 0 || initialIdx >= _initials.length) return null;
    return _initials[initialIdx];
  }

  /// 查询单个汉字对应的拼音压缩排序键（`0..252`，同首字母内亦按全拼有序），非汉字返回 `-1`。
  static int pinyinRankOfRune(int rune) {
    if (rune < _cjkStart || rune > _cjkEnd) return -1;
    return _pinyinRanks[rune - _cjkStart];
  }

  /// 按「符号 -> 自然数字 -> 忽略大小写英文字母 -> 中文拼音首字母及全拼序 -> 其他字符」比较两个名称。
  static int compareNames(String a, String b) {
    if (a == b) return 0;
    final left = a.trim();
    final right = b.trim();
    var i = 0;
    var j = 0;
    final lenA = left.length;
    final lenB = right.length;

    while (i < lenA && j < lenB) {
      final ca = left.codeUnitAt(i);
      final cb = right.codeUnitAt(j);

      // 连续 ASCII 数字按自然数值比较，避免 10 排在 2 之前。
      final aIsDigit = _isAsciiDigit(ca);
      final bIsDigit = _isAsciiDigit(cb);
      if (aIsDigit && bIsDigit) {
        final endA = _scanDigitsEnd(left, i);
        final endB = _scanDigitsEnd(right, j);
        final numCmp = _compareDigitSpans(left, i, endA, right, j, endB);
        if (numCmp != 0) return numCmp;
        i = endA;
        j = endB;
        continue;
      }

      final ka = _charGroupAndWeight(ca);
      final kb = _charGroupAndWeight(cb);
      if (ka != kb) return ka.compareTo(kb);
      i++;
      j++;
    }

    if (i != lenA || j != lenB) {
      return (lenA - i).compareTo(lenB - j);
    }

    // 同拼音桶或仅大小写不同的条目以原始码位作稳定兜底，保证严格弱序。
    return left.compareTo(right) != 0 ? left.compareTo(right) : a.compareTo(b);
  }

  static bool _isAsciiDigit(int cu) => cu >= 0x30 && cu <= 0x39;

  static int _scanDigitsEnd(String s, int start) {
    var idx = start;
    while (idx < s.length && _isAsciiDigit(s.codeUnitAt(idx))) {
      idx++;
    }
    return idx;
  }

  /// 无溢出比较两段十进制数字子串（先去前导零比位数，再逐位比数值，最后以原串长度破平）。
  static int _compareDigitSpans(
    String a,
    int startA,
    int endA,
    String b,
    int startB,
    int endB,
  ) {
    var nzA = startA;
    while (nzA < endA && a.codeUnitAt(nzA) == 0x30) {
      nzA++;
    }
    var nzB = startB;
    while (nzB < endB && b.codeUnitAt(nzB) == 0x30) {
      nzB++;
    }
    final sigLenA = endA - nzA;
    final sigLenB = endB - nzB;
    if (sigLenA != sigLenB) return sigLenA.compareTo(sigLenB);
    for (var k = 0; k < sigLenA; k++) {
      final diff = a.codeUnitAt(nzA + k) - b.codeUnitAt(nzB + k);
      if (diff != 0) return diff;
    }
    return (endA - startA).compareTo(endB - startB);
  }

  /// 将单码元编码为 `(分组 << 20) | 组内权重`：0 符号，1 数字，2 英文，3 中文拼音，4 其他。
  static int _charGroupAndWeight(int cu) {
    if (_isAsciiDigit(cu)) {
      return (1 << 20) | cu;
    }
    if (cu >= 0x41 && cu <= 0x5A) {
      return (2 << 20) | (cu + 0x20);
    }
    if (cu >= 0x61 && cu <= 0x7A) {
      return (2 << 20) | cu;
    }
    if (cu >= _cjkStart && cu <= _cjkEnd) {
      return (3 << 20) | _pinyinRanks[cu - _cjkStart];
    }
    if (cu < 0x80) {
      return cu;
    }
    return (4 << 20) | cu;
  }

  // 覆盖 U+4E00..U+9FA5 全部 20902 个标准简繁汉字的拼音排序分桶表（Base64 扁平编码）。
}
