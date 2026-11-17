import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/smb/ntlm_password_authenticator.dart';

///
/// 可由上层扩展继承的 NTLM 交互式凭据回调器基类；鉴权失败时允许返回新凭据以重试请求。
///
abstract class NtlmAuthenticator {
  static NtlmAuthenticator? auth;

  String? url;
  SmbAuthException? sae;

  /// 注册全局默认 `NtlmAuthenticator` 实例；首次设置后锁定生效，重复调用无效。
  static void setDefault(NtlmAuthenticator a) {
    if (auth != null) {
      return;
    }
    auth = a;
  }

  static NtlmAuthenticator? getDefault() {
    return auth;
  }

  String? getRequestingURL() => url;

  SmbAuthException? getRequestingException() => sae;

  /// 当派生类重写弹窗回调收集用户新凭据时由此入口返回认证结果。
  static NtlmPasswordAuthenticator? requestNtlmPasswordAuthentication(
      NtlmAuthenticator? a, String url, SmbAuthException? sae) {
    if (a == null) {
      return null;
    }
    a.url = url;
    a.sae = sae;
    return a.getNtlmPasswordAuthentication();
  }

  /// 派生类实现此方法后可在触发 `SmbAuthException` 时按请求 URL 与异常上下文提示用户输入新凭据；返回空则原样抛出异常。
  NtlmPasswordAuthenticator? getNtlmPasswordAuthentication() {
    return null;
  }
}
