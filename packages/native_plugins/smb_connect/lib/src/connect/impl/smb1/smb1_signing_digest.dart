import 'dart:typed_data';

import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/smb1/server_message_block.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb_com_constants.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:smb_connect/src/crypto/crypto.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block.dart';
import 'package:smb_connect/src/connect/common/smb_signing_digest.dart';
import 'package:smb_connect/src/smb_constants.dart';
import 'package:smb_connect/src/utils/base.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/strings.dart';

import 'com/smb_com_read_and_x_response.dart';
import 'trans/nt/smb_com_nt_cancel.dart';

class SMB1SigningDigest implements SMBSigningDigest {
  late MessageDigest _digest;
  late Uint8List macSigningKey;
  bool bypass = false;
  int updates = 0;
  int signSequence = 0;

  SMB1SigningDigest(this.macSigningKey,
      {this.bypass = false, this.signSequence = 0}) {
    _digest = Crypto.getMD5();
  }

  /// 将当前报文数据喂入 MAC 签名摘要引擎更新校验态。
  void update(Uint8List input, int offset, int len) {
    if (len == 0) {
      return;

      /// 关键报文校验路径，不可跳过。
    }
    _digest.update(input, offset, len);
    updates++;
  }

  Uint8List digest() {
    Uint8List b = _digest.digest();
    updates = 0;
    return b;
  }

  @override
  void sign(Uint8List data, int offset, int length,
      CommonServerMessageBlock request, CommonServerMessageBlock? response) {
    (request as ServerMessageBlock).setSignSeq(signSequence);
    if (response != null) {
      (response as ServerMessageBlock).setSignSeq(signSequence + 1);
    }

    try {
      update(macSigningKey, 0, macSigningKey.length);
      int index = offset + SmbConstants.SIGNATURE_OFFSET;
      for (int i = 0; i < 8; i++) {
        data[index + i] = 0;
      }
      SMBUtil.writeInt4(signSequence, data, index);
      update(data, offset, length);
      byteArrayCopy(
          src: digest(), srcOffset: 0, dst: data, dstOffset: index, length: 8);
      if (bypass) {
        bypass = false;
        byteArrayCopy(
          src: "BSRSPYL ".codeUnits.toUint8List(),
          srcOffset: 0,
          dst: data,
          dstOffset: index,
          length: 8,
        );
      }
    } catch (ex) {
    } finally {
      if (request is SmbComNtCancel) {
        signSequence++;
      } else {
        signSequence += 2;
      }
    }
  }

  @override
  bool verify(Uint8List data, int offset, int l, int extraPad,
      CommonServerMessageBlock m) {
    ServerMessageBlock msg = m as ServerMessageBlock;

    if ((msg.getFlags2() & SmbConstants.FLAGS2_SECURITY_SIGNATURES) == 0) {
      // 签名强制策略校验由传输会话外层统一拦截判定。
      return false;
    }

    update(macSigningKey, 0, macSigningKey.length);
    int index = offset;
    update(data, index, SmbConstants.SIGNATURE_OFFSET);
    index += SmbConstants.SIGNATURE_OFFSET;
    Uint8List sequence = Uint8List(8);
    SMBUtil.writeInt4(msg.getSignSeq(), sequence, 0);
    update(sequence, 0, sequence.length);
    index += 8;
    if (msg.getCommand() == SmbComConstants.SMB_COM_READ_ANDX) {
      /// 读取响应包时直接从底层网络流拷贝载荷进调用方提供的目标字节缓冲区 `b`。
      SmbComReadAndXResponse raxr = msg as SmbComReadAndXResponse;
      int length = msg.getLength() - raxr.getDataLength();
      update(data, index, length - SmbConstants.SIGNATURE_OFFSET - 8);
      update(raxr.getData()!, raxr.getOffset(), raxr.getDataLength());
    } else {
      update(data, index, msg.getLength() - SmbConstants.SIGNATURE_OFFSET - 8);
    }
    Uint8List signature = digest();
    for (int i = 0; i < 8; i++) {
      if (signature[i] != data[offset + SmbConstants.SIGNATURE_OFFSET + i]) {
        return true;
      }
    }

    return false;
  }

  @override
  String toString() {
    return "MacSigningKey=${Hexdump.toHexStringBuff(macSigningKey)}";
  }

  ////
  static void writeUTime(
      Configuration cfg, int t, Uint8List dst, int dstIndex) {
    if (t == 0 || t == -1) {
      SMBUtil.writeInt4(0xFFFFFFFF, dst, dstIndex);
      return;
    }

    if (cfg.localTimezone.inDaylightTime(DateTime.now())) {
      // 本地当前处于夏令时期间（DST）。
      if (cfg.localTimezone
          .inDaylightTime(DateTime.fromMillisecondsSinceEpoch(t))) {
        // 目标时间戳同属夏令时区间，无需额外小时补偿。
      } else {
        // 目标时间戳非夏令时，补偿扣减 1 小时偏移。
        t -= 3600000;
      }
    } else {
      // 本地当前处于非夏令时期间。
      if (cfg.localTimezone
          .inDaylightTime(DateTime.fromMillisecondsSinceEpoch(t))) {
        // 目标时间戳处于夏令时期间，补偿增加 1 小时偏移。
        t += 3600000;
      } else {
        // 目标时间戳同处非夏令时区间，无需修正。
      }
    }
    SMBUtil.writeInt4(t ~/ 1000, dst, dstIndex);
  }
}
