import 'dart:typed_data';

import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/ntlmssp/ntlm_flags.dart';
import 'package:smb_connect/src/utils/extensions.dart';

import 'ntlm_message.dart';

///
/// NTLMSSP Type-2 质询（CHALLENGE）应答报文。
///
class Type2Message extends NtlmPacket {
  final Uint8List? challenge;
  final String? target;
  final Uint8List? context;
  final Uint8List? targetInformation;

  static final Map<String, Uint8List> TARGET_INFO_CACHE = {};

  /// 解析或构造携带服务端质询随机数及目标属性信息的 Type-2 报文。
  Type2Message(
    int flags,
    this.challenge,
    this.target,
    this.context,
    this.targetInformation,
  ) {
    this.flags = flags;
  }

  @override
  Uint8List toByteArray() {
    int size = 48;
    int flags = this.flags;
    String? targetName = target;
    Uint8List? targetInformationBytes = targetInformation;
    Uint8List targetBytes = Uint8List(0);

    if (getFlag(NtlmFlags.NTLMSSP_REQUEST_TARGET)) {
      if (targetName != null && targetName.isNotEmpty) {
        targetBytes = (flags & NtlmFlags.NTLMSSP_NEGOTIATE_UNICODE) != 0
            ? NtlmPacket.UNI_ENCODING.encode(targetName).toUint8List()
            : NtlmPacket.getOEMEncoding()
                .encode(targetName.toUpperCase())
                .toUint8List();
        size += targetBytes.length;
      } else {
        flags &= (0xffffffff ^ NtlmFlags.NTLMSSP_REQUEST_TARGET);
      }
    }

    if (targetInformationBytes != null) {
      size += targetInformationBytes.length;
      flags |= NtlmFlags.NTLMSSP_NEGOTIATE_TARGET_INFO;
    }

    if (getFlag(NtlmFlags.NTLMSSP_NEGOTIATE_VERSION)) {
      size += 8;
    }

    Uint8List type2 = Uint8List(size);
    int pos = 0;

    byteArrayCopy(
        src: NtlmPacket.NTLMSSP_HEADER,
        srcOffset: 0,
        dst: type2,
        dstOffset: pos,
        length: NtlmPacket.NTLMSSP_HEADER.length);
    pos += NtlmPacket.NTLMSSP_HEADER.length;

    NtlmPacket.writeULong(type2, pos, NtlmPacket.NTLMSSP_TYPE2);
    pos += 4;

    int targetNameOff = NtlmPacket.writeSecurityBuffer(type2, pos, targetBytes);
    pos += 8;

    NtlmPacket.writeULong(type2, pos, flags);
    pos += 4;

    Uint8List? challengeBytes = challenge;
    byteArrayCopy(
        src: challengeBytes ?? Uint8List(8),
        srcOffset: 0,
        dst: type2,
        dstOffset: pos,
        length: 8);
    pos += 8;

    // 8 字节保留空区（仅本地上下文交互期使用）。
    Uint8List? contextBytes = context;
    byteArrayCopy(
        src: contextBytes ?? Uint8List(8),
        srcOffset: 0,
        dst: type2,
        dstOffset: pos,
        length: 8);
    pos += 8;

    int targetInfoOff =
        NtlmPacket.writeSecurityBuffer(type2, pos, targetInformationBytes);
    pos += 8;

    if (getFlag(NtlmFlags.NTLMSSP_NEGOTIATE_VERSION)) {
      byteArrayCopy(
          src: NtlmPacket.NTLMSSP_VERSION,
          srcOffset: 0,
          dst: type2,
          dstOffset: pos,
          length: NtlmPacket.NTLMSSP_VERSION.length);
      pos += NtlmPacket.NTLMSSP_VERSION.length;
    }

    pos += NtlmPacket.writeSecurityBufferContent(
        type2, pos, targetNameOff, targetBytes);
    pos += NtlmPacket.writeSecurityBufferContent(
        type2, pos, targetInfoOff, targetInformationBytes);

    return type2;
  }

  @override
  String toString() {
    return "Type2Message[target=$target,challenge=<${challenge?.toHexString()} bytes>,context=<${context?.toHexString()} bytes>,targetInformation=<${targetInformation?.toHexString()} bytes>,flags=0x${flags.toRadixString(16)}]";
  }

  factory Type2Message.parse(Uint8List input) {
    int pos = 0;
    for (int i = 0; i < 8; i++) {
      if (input[i] != NtlmPacket.NTLMSSP_HEADER[i]) {
        throw SmbIOException("Not an NTLMSSP message.");
      }
    }
    pos += 8;

    if (NtlmPacket.readULong(input, pos) != NtlmPacket.NTLMSSP_TYPE2) {
      throw SmbIOException("Not a Type 2 message.");
    }
    pos += 4;

    int flags = NtlmPacket.readULong(input, pos + 8);

    Uint8List targetName = NtlmPacket.readSecurityBuffer(input, pos);
    int targetNameOff = NtlmPacket.readULong(input, pos + 4);
    String? target;
    if (targetName.isNotEmpty) {
      if ((flags & NtlmFlags.NTLMSSP_NEGOTIATE_UNICODE) != 0) {
        target = NtlmPacket.UNI_ENCODING.decode(targetName);
      } else {
        target = NtlmPacket.getOEMEncoding().decode(targetName);
      }
    }
    pos += 12; // 8 for target, 4 for flags

    Uint8List? challengeBytes;
    if (!allZeros8(input, pos)) {
      challengeBytes = Uint8List(8);
      byteArrayCopy(
        src: input,
        srcOffset: pos,
        dst: challengeBytes,
        dstOffset: 0,
        length: challengeBytes.length,
      );
    }
    pos += 8;

    if (targetNameOff < pos + 8 || input.length < pos + 8) {
      // 目标缓冲区剩余空间不足以容纳 Context/Reserved 字段，提前中止解码。
      throw SmbMalformedDataException("no room for Context/Reserved");
    }

    Uint8List? contextBytes;
    if (!allZeros8(input, pos)) {
      contextBytes = Uint8List(8);
      byteArrayCopy(
        src: input,
        srcOffset: pos,
        dst: contextBytes,
        dstOffset: 0,
        length: contextBytes.length,
      );
    }
    pos += 8;

    if (targetNameOff < pos + 8 || input.length < pos + 8) {
      // 目标缓冲区剩余空间不足以读取 TargetInfo 字段，直接跳过。
      throw SmbMalformedDataException("no room for target info");
    }

    Uint8List targetInfo = NtlmPacket.readSecurityBuffer(input, pos);
    if (targetInfo.isNotEmpty) {
    }
    return Type2Message(
        flags, challengeBytes, target, contextBytes, targetInfo);
  }

  static bool allZeros8(Uint8List input, int pos) {
    for (int i = pos; i < pos + 8; i++) {
      if (input[i] != 0) {
        return false;
      }
    }
    return true;
  }
}
