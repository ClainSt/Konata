///
/// MS-NLMP 2.2.2.5 节 NTLM 认证协商标志位掩码定义。
///
abstract class NtlmFlags {
  /// 置位表示协商并优先选用 UTF-16LE Unicode 字符串编码。
  static const int NTLMSSP_NEGOTIATE_UNICODE = 0x00000001;

  /// 置位表示请求使用默认 OEM 单字节字符集编码。
  static const int NTLMSSP_NEGOTIATE_OEM = 0x00000002;

  /// 置位要求服务端在 Type-2 Challenge 报文中返回 `TargetName`（亦名 `NTLMSSP_REQUEST_TARGET`）。
  static const int NTLMSSP_REQUEST_TARGET = 0x00000004;

  /// 置位请求为消息完整性签名协商会话密钥（NTLMSSP_NEGOTIATE_SIGN）。
  static const int NTLMSSP_NEGOTIATE_SIGN = 0x00000010;

  /// 置位请求为消息机密性加密封包协商会话密钥（NTLMSSP_NEGOTIATE_SEAL）。
  static const int NTLMSSP_NEGOTIATE_SEAL = 0x00000020;

  /// 置位请求无连接数据报认证模式（需协同密钥交换标志）。
  static const int NTLMSSP_NEGOTIATE_DATAGRAM = 0x00000040;

  /// 置位请求使用旧式 LM 会话密钥派生（与扩展会话安全性 `EXTENDED_SESSIONSECURITY` 互斥）。
  static const int NTLMSSP_NEGOTIATE_LM_KEY = 0x00000080;


  /// 置位请求启用 NTLM 会话安全认证协议。
  static const int NTLMSSP_NEGOTIATE_NTLM = 0x00000200;

  /// 置位表示请求匿名空会话认证上下文。
  static const int NTLMSSP_NEGOTIATE_ANONYMOUS = 0x00000800;

  /// 置位指示协商/认证报文中附带了客户端域名字段。
  static const int NTLMSSP_NEGOTIATE_OEM_DOMAIN_SUPPLIED = 0x00001000;

  /// 置位指示报文中携带非空 `Workstation` 客户端工作站名称字段。
  static const int NTLMSSP_NEGOTIATE_OEM_WORKSTATION_SUPPLIED = 0x00002000;

  /// 置位强制在认证交互中生成虚拟或真实签名会话密钥，以确保后续 MIC 校验可行。
  static const int NTLMSSP_NEGOTIATE_ALWAYS_SIGN = 0x00008000;

  /// 置位指示 `CHALLENGE_MESSAGE` 中 `TargetName` 为域控制器所属域名。
  static const int NTLMSSP_TARGET_TYPE_DOMAIN = 0x00010000;

  /// 置位指示 `CHALLENGE_MESSAGE` 中 `TargetName` 为单机服务器主机名。
  static const int NTLMSSP_TARGET_TYPE_SERVER = 0x00020000;


  /// 置位请求使用扩展会话安全性（NTLM2 Session Security / NTLMv2 兼容校验）。
  static const int NTLMSSP_NEGOTIATE_EXTENDED_SESSIONSECURITY = 0x00080000;

  /// 置位请求仅获取身份识别（Identify）级别访问令牌。
  static const int NTLMSSP_NEGOTIATE_IDENTIFY = 0x00100000;

  /// 置位请求使用兼容式 LM 单向杂凑函数计算凭据口令。
  static const int NTLMSSP_REQUEST_NON_NT_SESSION_KEY = 0x00400000;

  /// 置位指示 `CHALLENGE_MESSAGE` 与 `AUTHENTICATE_MESSAGE` 携带 `TargetInfo` AvPair 信息块。
  static const int NTLMSSP_NEGOTIATE_TARGET_INFO = 0x00800000;

  /// 置位指示报文中附带 8 字节 NTLM 客户端/服务端版本号字段。
  static const int NTLMSSP_NEGOTIATE_VERSION = 0x2000000;

  /// 置位请求协商 128 位高强度会话密钥。
  static const int NTLMSSP_NEGOTIATE_128 = 0x20000000;

  /// 置位请求执行显式随机导出会话密钥交换，以提升签名完整性与保密安全性。
  static const int NTLMSSP_NEGOTIATE_KEY_EXCH = 0x40000000;

  /// 置位请求支持 56 位会话加密协商。
  static const int NTLMSSP_NEGOTIATE_56 = 0x80000000;
}
