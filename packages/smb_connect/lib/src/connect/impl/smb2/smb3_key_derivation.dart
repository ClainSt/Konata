import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/extensions/kdf/kdf_counter_bytes_generator.dart';
import 'package:smb_connect/src/utils/extensions/kdf/kdf_counter_parameters.dart';
import 'package:smb_connect/src/utils/strings.dart';

///
/// 基于 NIST SP 800-108 计数器模式的 SMB3 会话密钥派生实现。
///
///
class Smb3KeyDerivation {
  static final Uint8List SIGNCONTEXT_300 = toCBytes("SmbSign");
  static final Uint8List SIGNLABEL_300 = toCBytes("SMB2AESCMAC");
  static final Uint8List SIGNLABEL_311 = toCBytes("SMBSigningKey");

  static final Uint8List APPCONTEXT_300 = toCBytes("SmbRpc");
  static final Uint8List APPLABEL_300 = toCBytes("SMB2APP");
  static final Uint8List APPLABEL_311 = toCBytes("SMBAppKey");

  static final Uint8List ENCCONTEXT_300 =
      toCBytes("ServerIn "); // there really is a space there
  static final Uint8List ENCLABEL_300 = toCBytes("SMB2AESCCM");
  static final Uint8List ENCLABEL_311 = toCBytes("SMB2C2SCipherKey");

  static final Uint8List DECCONTEXT_300 = toCBytes("ServerOut");
  static final Uint8List DECLABEL_300 = toCBytes("SMB2AESCCM");
  static final Uint8List DECLABEL_311 = toCBytes("SMB2S2CCipherKey");

  Smb3KeyDerivation();

  static Uint8List deriveSigningKey(
      int dialect, Uint8List sessionKey, Uint8List preauthIntegrity) {
    return derive(
        sessionKey,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? SIGNLABEL_311
            : SIGNLABEL_300,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? preauthIntegrity
            : SIGNCONTEXT_300);
  }

  static Uint8List dervieApplicationKey(
      int dialect, Uint8List sessionKey, Uint8List preauthIntegrity) {
    return derive(
        sessionKey,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? APPLABEL_311
            : APPLABEL_300,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? preauthIntegrity
            : APPCONTEXT_300);
  }

  static Uint8List deriveEncryptionKey(
      int dialect, Uint8List sessionKey, Uint8List preauthIntegrity) {
    return derive(
        sessionKey,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? ENCLABEL_311
            : ENCLABEL_300,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? preauthIntegrity
            : ENCCONTEXT_300);
  }

  static Uint8List deriveDecryptionKey(
      int dialect, Uint8List sessionKey, Uint8List preauthIntegrity) {
    return derive(
        sessionKey,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? DECLABEL_311
            : DECLABEL_300,
        dialect == Smb2Constants.SMB2_DIALECT_0311
            ? preauthIntegrity
            : DECCONTEXT_300);
  }

  static Uint8List derive(
      Uint8List sessionKey, Uint8List label, Uint8List context) {
    var gen = KDFCounterBytesGenerator(Mac("SHA-256/HMAC"));

    int r = 32;
    Uint8List suffix = Uint8List(label.length + context.length + 5);
    // 参数组织格式对齐经典 BouncyCastle SP800-108 计数器前置规范：
    // K(i) := PRF(KI, [i]_2 || Label || 0x00 || Context || [L]_2)，固定后缀依次拼装标签、空字节、上下文与大端比特长度 L。

    // 拼接派生用途标签（Label）
    byteArrayCopy(
        src: label,
        srcOffset: 0,
        dst: suffix,
        dstOffset: 0,
        length: label.length);
    // 拼接 1 字节分隔空字节 `0x00`
    // 拼接上下文协商摘要（Context）
    byteArrayCopy(
        src: context,
        srcOffset: 0,
        dst: suffix,
        dstOffset: label.length + 1,
        length: context.length);
    // 拼接 4 字节大端输出密钥位长 L
    suffix[suffix.length - 1] = 128;

    var param = KDFCounterParameters(sessionKey, null, suffix, r);
    gen.init(param);

    Uint8List derived = Uint8List(16);
    gen.generateBytes(derived, 0, 16);
    return derived;
  }

  static Uint8List toCBytes(String string) {
    Uint8List data = Uint8List(string.length + 1);
    byteArrayCopy(
        src: string.getASCIIBytes(),
        srcOffset: 0,
        dst: data,
        dstOffset: 0,
        length: string.length);
    return data;
  }
}
