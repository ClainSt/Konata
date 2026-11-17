// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

import 'dart:ffi';
import 'dart:typed_data';

/// Win32 原生 `GUID` 内存结构体 FFI 映射表示。
// 该结构体内存布局对应微软官方文档定义。
@Packed(4)
base class GUID extends Struct {
  /// 原生 GUID `Data1` 32 位字段。
  @Uint32()
  external int data1;

  /// 原生 GUID `Data2` 16 位字段。
  @Uint16()
  external int data2;

  /// 原生 GUID `Data3` 16 位字段。
  @Uint16()
  external int data3;

  /// 原生 GUID `Data4` 64 位字段（逻辑上等同 8 字节数组）。
  @Uint64()
  external int data4;

  /// 解析允许可选花括号 `{}` 与连字符 `-` 的 GUID 字符串并写入原生结构体。
  void parse(String guid) {
    final String hexOnly = guid.replaceAll(RegExp(r'[{}-]'), '');
    if (hexOnly.length != 32) {
      throw ArgumentError.value(guid, 'guid', 'Invalid GUID string');
    }
    final ByteData bytes = ByteData(16);
    for (int i = 0; i < 16; ++i) {
      bytes.setUint8(
          i, int.parse(hexOnly.substring(i * 2, i * 2 + 2), radix: 16));
    }
    data1 = bytes.getInt32(0);
    data2 = bytes.getInt16(4);
    data3 = bytes.getInt16(6);
    // 输入序列按大端排列而宿主通常为小端序，需显式按字节顺序读取 `Data4` 并维持原字节序。
    data4 = bytes.getInt64(8, Endian.little);
  }
}
