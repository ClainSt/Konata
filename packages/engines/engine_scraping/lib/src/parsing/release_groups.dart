import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:konata_contracts/konata_contracts.dart';

/// 基于随包 FileBot 词表判定独立发行标签。
abstract final class ReleaseGroups {
  static const _assetPath = 'assets/data/release_groups.bin.gz';
  static AssetDataLoaderPort? _loader;
  static Uint8List? _archive;
  static Future<Uint8List>? _pending;
  static Set<String>? _decoded;

  /// 配置按需读取的宿主资产入口。
  static void configure(AssetDataLoaderPort? loader) => _loader = loader;

  /// 发行组词表是否已经读取。
  static bool get isLoaded => _archive != null;

  /// 扫描或刮削开始时装载压缩资产，供当前及后台隔离线程复用。
  static Future<Uint8List> prepare() async {
    final cached = _archive;
    if (cached != null) return cached;
    final pending = _pending ??= _readBundled();
    try {
      final bytes = await pending;
      if (identical(_pending, pending)) _archive = bytes;
      return bytes;
    } finally {
      if (identical(_pending, pending)) _pending = null;
    }
  }

  static Future<Uint8List> _readBundled() async =>
      await _loader?.loadBytes(_assetPath) ?? _readFromCheckout();

  /// 接收宿主已读取的压缩词表。
  static void usePrepared(Uint8List bytes) => _archive ??= bytes;

  /// 释放已读词表并作废仍在等待的缓存写入。
  static void release() {
    _pending = null;
    _archive = null;
    _decoded = null;
  }

  static Set<String> get _names => _decoded ??= utf8
      .decode(gzip.decode(_archive ??= _readFromCheckout()))
      .split('\n')
      .toSet();

  static Uint8List _readFromCheckout() {
    var directory = Directory.current.absolute;
    while (true) {
      final file = File.fromUri(
        directory.uri.resolve('apps/konata/$_assetPath'),
      );
      if (file.existsSync()) return file.readAsBytesSync();
      final parent = directory.parent;
      if (parent.path == directory.path) throw StateError('未装载发行组词表');
      directory = parent;
    }
  }

  static const _caseSensitive = <String>{
    'DECADE',
    'JACKAL',
    'LiFE',
    'MARS',
    'ONe',
    'REiGN',
    'TiTAN',
    'WAR',
    'WoLF',
    'eXterminator',
    'iNTERNAL',
  };
  static bool contains(String value) =>
      // 结合该字幕组官方字幕仓库核验补充的别名：
      // 仓库地址：https://github.com/Nekomoekissaten-SUB/Nekomoekissaten-Subs
      value.trim().toLowerCase() == 'nekomoe kissaten' ||
      // 结合本地 129 份命名基准样板核验的精确复合标签；
      // 禁止仅凭 '&' 或局部子串推断字幕组归属。
      value.trim().toLowerCase() == 'txxz&a.i.r.nessub' ||
      _caseSensitive.contains(value.trim()) ||
      _names.contains(value.trim().toLowerCase());
}
