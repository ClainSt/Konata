import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/asn1/primitives/asn1_object_identifier.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/credentials.dart';
import 'package:smb_connect/src/crypto/crypto.dart';
import 'package:smb_connect/src/smb/authentication_type.dart';
import 'package:smb_connect/src/smb/spnego_context.dart';
import 'package:smb_connect/src/utils/base.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/strings.dart';

import '../spnego/neg_token_init.dart';
import 'ntlm_context.dart';
import 'ntlm_util.dart';
import 'ssp_context.dart';

///
/// 保存并按需派生 NTLM/LM/NTLMv2 会话响应及摘要密钥的用户凭据管理器。
///
///
///
class NtlmPasswordAuthenticator implements Credentials {
  static const int serialVersionUID = -5;

  AuthenticationType type = AuthenticationType.ANONYMOUS;
  late String domain;
  late String username;
  late String password;
  Uint8List? clientChallenge;

  AuthenticationType guessAuthenticationType() {
    AuthenticationType t = AuthenticationType.USER;
    if (Configuration.guestUsername.equalsIgnoreCase(username)) {
      t = AuthenticationType.GUEST;
    } else if ((getUserDomain().isEmpty) &&
        getUsername().isEmpty &&
        (getPassword().isEmpty)) {
      t = AuthenticationType.ANONYMOUS;
    }
    return t;
  }

  NtlmPasswordAuthenticator(
      {AuthenticationType? type,
      this.domain = "",
      this.username = "",
      this.password = ""}) {
    int ci = username.indexOf('@');
    if (ci > 0) {
      domain = username.substring(ci + 1);
      username = username.substring(0, ci);
    } else {
      ci = username.indexOf('\\');
      if (ci > 0) {
        domain = username.substring(0, ci);
        username = username.substring(ci + 1);
      }
    }

    if (type == null) {
      this.type = guessAuthenticationType();
    } else {
      this.type = type;
    }
  }

  @protected
  NtlmPasswordAuthenticator.userInfo(
      String? userInfo, String? defDomain, String? defUser, String? defPassword,
      [AuthenticationType? type]) {
    String? dom, user, pass;
    if (userInfo != null) {
      try {
        userInfo = unescape(userInfo);
      } catch (uee) {
        //
        throw SmbRuntimeException("UnsupportedEncodingException", uee);
      }
      int i, u = 0;
      int end = userInfo.length;
      for (i = 0; i < end; i++) {
        var c = userInfo[i];
        if (c == ';') {
          dom = userInfo.substring(0, i);
          u = i + 1;
        } else if (c == ':') {
          pass = userInfo.substring(i + 1);
          break;
        }
      }
      user = userInfo.substring(u, i);
    }

    domain = dom ?? defDomain ?? "";
    username = user ?? defUser ?? "";
    password = pass ?? defPassword ?? "";

    if (type == null) {
      this.type = guessAuthenticationType();
    } else {
      this.type = type;
    }
  }

  @override
  SSPContext createContext(Configuration config, String? targetDomain,
      String host, Uint8List? initialToken, bool doSigning) {
    if (Configuration.isUseRawNTLM) {
      return setupTargetName(host, NtlmContext(config, this, doSigning));
    }

    if (initialToken != null && initialToken.isNotEmpty) {
      NegTokenInit tok = NegTokenInit.parse(initialToken);
      final mechanisms = tok.getMechanisms();
      if (mechanisms != null &&
          mechanisms.findFirst((element) =>
                  element.objectIdentifierAsString ==
                  NtlmContext.NTLMSSP_OID.objectIdentifierAsString) ==
              null) {
        throw SmbUnsupportedOperationException(
            "Server does not support NTLM authentication");
      }
    }

    return SpnegoContext.supp(
        setupTargetName(host, NtlmContext(config, this, doSigning)));
  }

  static SSPContext setupTargetName(String? host, NtlmContext ntlmContext) {
    if (host != null && Configuration.isSendNTLMTargetName) {
      ntlmContext.targetName = "cifs/$host";
    }
    return ntlmContext;
  }

  /// 获取当前凭据关联的域名或工作组名称。
  @override
  String getUserDomain() => domain;

  String getSpecifiedUserDomain() => domain;

  /// 获取当前凭据的登录用户名。
  String getUsername() => username;

  /// 返回账户明文密码（若凭据由哈希透传构造，则返回空）。
  String getPassword() => password;

  /// 按 `域\用户名` 标准格式返回账户显示标识。
  String getName() {
    return domain.isNotEmpty ? "$domain\\$username" : username;
  }

  @override
  String toString() => getName();

  @override
  bool isAnonymous() => type == AuthenticationType.ANONYMOUS;

  @override
  bool isGuest() => type == AuthenticationType.GUEST;

  static String unescape(String str) {
    Uint8List b = Uint8List(1);

    int len = str.length;
    List<String> outStr = [];
    int state = 0;
    for (var i = 0; i < len; i++) {
      switch (state) {
        case 0:
          String ch = str[i];
          if (ch == '%') {
            state = 1;
          } else {
            outStr.add(ch);
          }
          break;
        case 1:

          /// 取 ASCII 十六进制字符码值用于兼容平台编解码。
          b[0] = (int.parse(str.substring(i, i + 2), radix: 16) & 0xFF);
          outStr.add(ascii.decode(b));
          i++;
          state = 0;
      }
    }
    return outStr.join("");
  }

  bool isPreferredMech(ASN1ObjectIdentifier? mechanism) {
    return NtlmContext.NTLMSSP_OID == mechanism;
  }

  /// 基于 8 字节服务端质询随机数与明文密码计算 24 字节 ANSI LM 响应摘要。
  Uint8List getAnsiHash(Configuration config, Uint8List chlng) {
    switch (Configuration.lanManCompatibility) {
      case 0:
      case 1:
        return NtlmUtil.getPreNTLMResponse(config, password, chlng);
      case 2:
        return NtlmUtil.getNTLMResponsePass(password, chlng);
      case 3:
      case 4:
      case 5:
        clientChallenge ??= config.random.nextBytes(8);
        return NtlmUtil.getLMv2ResponsePass(
            domain, username, password, chlng, clientChallenge!);
      default:
        return NtlmUtil.getPreNTLMResponse(config, password, chlng);
    }
  }

  /// 基于 8 字节服务端质询随机数与 Unicode 密码计算 24 字节 NTLM v1 响应摘要。
  Uint8List getUnicodeHash(Configuration config, Uint8List chlng) {
    switch (Configuration.lanManCompatibility) {
      case 0:
      case 1:
      case 2:
        return NtlmUtil.getNTLMResponsePass(password, chlng);
      case 3:
      case 4:
      case 5:
        return Uint8List(0);
      default:
        return NtlmUtil.getNTLMResponsePass(password, chlng);
    }
  }

  Uint8List? getSigningKey(Configuration config, Uint8List chlng) {
    switch (Configuration.lanManCompatibility) {
      case 0:
      case 1:
      case 2:
        Uint8List signingKey = Uint8List(40);
        getUserSessionKeyBuff(config, chlng, signingKey, 0);
        byteArrayCopy(
            src: getUnicodeHash(config, chlng),
            srcOffset: 0,
            dst: signingKey,
            dstOffset: 16,
            length: 24);
        buffFillTo(signingKey, 40);
        return signingKey;
      case 3:
      case 4:
      case 5:

        /// 仅当服务端未启用扩展会话安全性时才调用传统用户会话密钥派生逻辑。
        throw SmbException(
            "NTLMv2 requires extended security (useExtendedSecurity must be true if lmCompatibility >= 3)");
    }
    return null;
  }

  /// 计算并返回当前认证上下文的有效用户签名/加密会话密钥。
  Uint8List? getUserSessionKey(Configuration config, Uint8List chlng) {
    Uint8List key = Uint8List(16);
    getUserSessionKeyBuff(config, chlng, key, 0);
    return key;
  }

  /// 根据认证级别（NTLMv1/NTLMv2/LM）推导有效会话密钥。
  void getUserSessionKeyBuff(
      Configuration config, Uint8List chlng, Uint8List dest, int offset) {
    MessageDigest md4 = Crypto.getMD4();
    Uint8List ntHash = getNTHash();
    switch (Configuration.lanManCompatibility) {
      case 0:
      case 1:
      case 2:
        md4.updateBuff(ntHash);
        md4.digestTo(dest, offset, 16);
        break;
      case 3:
      case 4:
      case 5:
        clientChallenge ??= config.random.nextBytes(8);

        MessageDigest hmac = Crypto.getHMACT64(ntHash);
        hmac.updateBuff(username.toUpperCase().getUNIBytes());
        hmac.updateBuff(domain.toUpperCase().getUNIBytes());
        Uint8List ntlmv2Hash = hmac.digest();
        hmac = Crypto.getHMACT64(ntlmv2Hash);
        hmac.updateBuff(chlng);
        hmac.updateBuff(clientChallenge!);
        MessageDigest userKey = Crypto.getHMACT64(ntlmv2Hash);
        userKey.updateBuff(hmac.digest());
        userKey.digestTo(dest, offset, 16);
        break;
      default:
        md4.updateBuff(ntHash);
        md4.digestTo(dest, offset, 16);
        break;
    }
  }

  Uint8List getNTHash() {
    MessageDigest md4 = Crypto.getMD4();
    md4.updateBuff(password.getUNIBytes());
    Uint8List ntHash = md4.digest();
    return ntHash;
  }
}
