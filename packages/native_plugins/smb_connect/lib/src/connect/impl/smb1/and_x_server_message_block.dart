import 'dart:typed_data';

import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_nt_create_and_x_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb_com_constants.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/strings.dart';

import 'server_message_block.dart';

abstract class AndXServerMessageBlock extends ServerMessageBlock {
  static const int ANDX_COMMAND_OFFSET = 1;
  static const int ANDX_RESERVED_OFFSET = 2;
  static const int ANDX_OFFSET_OFFSET = 3;

  int andxCommand = 0xFF;
  int andxOffset = 0;

  ServerMessageBlock? andx;

  AndXServerMessageBlock(super.config, {super.command, String? name, this.andx})
      : super(path: name) {
    if (andx != null) {
      andxCommand = andx!.getCommand();
    }
  }

  @override
  ServerMessageBlock? getNext() {
    return andx;
  }

  @override
  ServerMessageBlock? getNextResponse() {
    return andx;
  }

  int getBatchLimit(Configuration cfg, int cmd) {
    ///
    /// 默认批处理上限为 0（即该命令前不允许拼接其他前驱消息）。
    return 0;
  }

  ///
  /// 覆写父类序列化入口，确保 `AndX` 链式后续消息仅输出参数字与字节载荷而不重复写入公共 SMB 包头。
  ////

  @override
  int encode(Uint8List dst, int dstIndex) {
    int start = headerStart = dstIndex;

    dstIndex += writeHeaderWireFormat(dst, dstIndex);
    dstIndex += writeAndXWireFormat(dst, dstIndex);
    length = dstIndex - start;

    digest?.sign(dst, headerStart, length, this,
        getResponse() as CommonServerMessageBlockResponse?);

    return length;
  }

  ///
  /// 覆写父类反序列化入口，递归解析 `AndX` 链条中后续不带包头的参数字与字节数据区。
  ////

  @override
  int decode(Uint8List buffer, int bufferIndex) {
    int start = headerStart = bufferIndex;

    bufferIndex += readHeaderWireFormat(buffer, bufferIndex);
    bufferIndex += readAndXWireFormat(buffer, bufferIndex);

    int len = bufferIndex - start;
    length = len;

    if (isRetainPayload()) {
      Uint8List payload = Uint8List(len);
      byteArrayCopy(
          src: buffer, srcOffset: 4, dst: payload, dstOffset: 0, length: len);
      setRawPayload(payload);
    }

    if (!verifySignature(buffer, 4, len)) {
      throw SmbProtocolDecodingException(
          "Signature verification failed for ${runtimeType.toString()}");
    }
    return len;
  }

  int writeAndXWireFormat(Uint8List dst, int dstIndex) {
    int start = dstIndex;

    wordCount =
        writeParameterWordsWireFormat(dst, start + ANDX_OFFSET_OFFSET + 2);
    wordCount += 4; // for command, reserved, and offset
    dstIndex += wordCount + 1;
    wordCount = wordCount ~/ 2;
    dst[start] = (wordCount & 0xFF);

    byteCount = writeBytesWireFormat(dst, dstIndex + 2);
    dst[dstIndex++] = (byteCount & 0xFF);
    dst[dstIndex++] = ((byteCount >> 8) & 0xFF);
    dstIndex += byteCount;

    ///
    /// 批处理控制条件：当超出允许拼接深度或类型不兼容时中止继续打包并直接跳过空 `AndX` 响应，
    /// 从而通知上层继续独立发送后续分段报文。
    if (andx == null ||
        !config.isUseBatching ||
        batchLevel >= getBatchLimit(config, andx!.getCommand())) {
      andxCommand = 0xFF;
      andx = null;

      dst[start + ANDX_COMMAND_OFFSET] = 0xFF;
      dst[start + ANDX_RESERVED_OFFSET] = 0x00;
      dst[start + ANDX_OFFSET_OFFSET] = 0xde;
      dst[start + ANDX_OFFSET_OFFSET + 1] = 0xde;

      // 未携带后续 `AndX` 命令，直接结束链式序列化并返回。
      return dstIndex - start;
    }

    ///
    /// 当前待拼接子报文允许更高的批处理深度，递增计数后递归编码该链式子消息。
    andx!.batchLevel = batchLevel + 1;

    dst[start + ANDX_COMMAND_OFFSET] = andxCommand;
    dst[start + ANDX_RESERVED_OFFSET] = 0x00;
    andxOffset = dstIndex - headerStart;
    SMBUtil.writeInt2(andxOffset, dst, start + ANDX_OFFSET_OFFSET);

    andx!.setUseUnicode(isUseUnicode());
    if (andx is AndXServerMessageBlock) {
      ///
      /// 将外层主报文 UID 等必要头部字段透传给子 `AndX` 消息，保证日志与签名上下文一致。
      ///
      andx!.uid = uid;
      dstIndex +=
          (andx as AndXServerMessageBlock).writeAndXWireFormat(dst, dstIndex);
    } else {
      // 当前后续子报文并非可继续嵌套的 `AndX` 类型，直接原地写入并结束。
      int andxStart = dstIndex;
      andx!.wordCount = andx!.writeParameterWordsWireFormat(dst, dstIndex);
      dstIndex += andx!.wordCount + 1;
      andx!.wordCount = andx!.wordCount ~/ 2;
      dst[andxStart] = (andx!.wordCount & 0xFF);

      andx!.byteCount = andx!.writeBytesWireFormat(dst, dstIndex + 2);
      dst[dstIndex++] = (andx!.byteCount & 0xFF);
      dst[dstIndex++] = ((andx!.byteCount >> 8) & 0xFF);
      dstIndex += andx!.byteCount;
    }

    return dstIndex - start;
  }

  int readAndXWireFormat(Uint8List buffer, int bufferIndex) {
    int start = bufferIndex;

    wordCount = buffer[bufferIndex++];

    if (wordCount != 0) {
      ///
      /// 写入所有 `AndX` 链式指令共享的标准偏移与命令码前缀。
      andxCommand = buffer[bufferIndex];
      andxOffset = SMBUtil.readInt2(buffer, bufferIndex + 2);

      if (andxOffset == 0) {
        /// 兼容旧版 Snap Server 设备响应格式异常的规避处理。
        andxCommand = 0xFF;
      }

      ///
      /// 兼容 Win98 等不返回 `OptionalSupport` 的旧服务端：无剩余参数字时直接跳过读取。
      if (wordCount > 2) {
        readParameterWordsWireFormat(buffer, bufferIndex + 4);

        ///
        /// `SMB_COM_NT_CREATE_ANDX` 响应的 `wordCount` 常少算 16 字节客户端缓存结构；
        /// 需在此向上校准偏移字节数，以保障后续报文长度统计与签名验证无误。
        if (getCommand() == SmbComConstants.SMB_COM_NT_CREATE_ANDX &&
            (this as SmbComNTCreateAndXResponse).isExtended() &&
            (this as SmbComNTCreateAndXResponse).getFileType() != 1) {
          wordCount += 8;
        }
      }

      bufferIndex = start + 1 + (wordCount * 2);
    }

    byteCount = SMBUtil.readInt2(buffer, bufferIndex);
    bufferIndex += 2;

    if (byteCount != 0) {
      readBytesWireFormat(buffer, bufferIndex);
      bufferIndex += byteCount;
    }

    ///
    /// 若后续响应仍为 `AndX` 则递归解码，否则直接按常规非链式报文读取其参数与载荷，
    /// 并依 `andxOffset` 同步推进缓冲区游标。
    final andx = this.andx;
    if (errorCode != 0 || andxCommand == 0xFF) {
      andxCommand = 0xFF;
      this.andx = null;
    } else if (andx == null) {
      andxCommand = 0xFF;
      throw SmbRuntimeException("no andx command supplied with response");
    } else {
      ///
      // 根据 `andxOffset` 定位链式子报文起始下标。
      bufferIndex = headerStart + andxOffset;

      andx.headerStart = headerStart;
      andx.setCommand(andxCommand);
      andx.setErrorCode(getErrorCode());
      andx.setFlags(getFlags());
      andx.setFlags2(getFlags2());
      andx.setTid(getTid());
      andx.setPid(getPid());
      andx.setUid(getUid());
      andx.setMid(getMid());
      andx.setUseUnicode(isUseUnicode());

      if (andx is AndXServerMessageBlock) {
        bufferIndex += andx.readAndXWireFormat(buffer, bufferIndex);
      } else {
        ///
        /// 普通非 `AndX` 报文响应，按标准包体流程解码。
        buffer[bufferIndex++] = (andx.wordCount & 0xFF);

        if (andx.wordCount != 0) {
          ///
          /// 兼容 Win98 等不返回 `OptionalSupport` 的旧服务端：无剩余参数字时直接跳过读取。
          if (andx.wordCount > 2) {
            bufferIndex +=
                andx.readParameterWordsWireFormat(buffer, bufferIndex);
          }
        }

        andx.byteCount = SMBUtil.readInt2(buffer, bufferIndex);
        bufferIndex += 2;

        if (andx.byteCount != 0) {
          andx.readBytesWireFormat(buffer, bufferIndex);
          bufferIndex += andx.byteCount;
        }
      }
      andx.setReceived();
    }

    return bufferIndex - start;
  }

  @override
  String toString() {
    return "${super.toString()},andxCommand=0x${Hexdump.toHexString(andxCommand, 2)},andxOffset=$andxOffset";
  }
}
