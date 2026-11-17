import 'dart:typed_data';

import 'common_server_message_block.dart';

abstract class SMBSigningDigest {
  ///
  /// 执行 SMB1 MAC 报文签名：先将签名字段覆写为请求序号，
  /// 再对“MAC 签名密钥 + 整包报文”计算 MD5 摘要，
  /// 最后取摘要前 8 字节回填入 SMB 头部签名字段。
  ///
  void sign(Uint8List data, int offset, int length,
      CommonServerMessageBlock request, CommonServerMessageBlock response);

  ///
  /// 执行 SMB1 MAC 报文签名核验：按同算法重算摘要并与报头签名比对。
  ///
  bool verify(Uint8List data, int offset, int length, int extraPad,
      CommonServerMessageBlock msg);
}
