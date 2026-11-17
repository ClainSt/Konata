import 'dart:typed_data';

import 'package:smb_connect/src/buffer_cache.dart';
import 'package:smb_connect/src/credentials.dart';
import 'package:smb_connect/src/smb_constants.dart';
import 'package:smb_connect/src/utils/base.dart';
import 'package:smb_connect/src/utils/encoding.dart';
import 'package:smb_connect/src/utils/time_zone.dart';

import 'dialect_version.dart';

abstract class Configuration {
  bool get debugPrint;
  bool get debugPrintLowLevel;
  bool get forceSmb1;

  /// 供协议会话加密与随机数生成的随机源。
  SecureRandom get random;

  BufferCache get bufferCache;

  /// 是否禁用 DFS 分布式文件系统查询（默认为 false）。
  static const isDfsDisabled = true;

  /// 允许协商的最低 SMB 协议版本（默认为 SMB1）。
  DialectVersion get minimumVersion;

  /// 允许协商的最高 SMB 协议版本（默认为 SMB210）。
  DialectVersion get maximumVersion;

  /// 是否强制执行安全协议版本协商校验（默认为 true）。
  /// 当允许回退 SMB1 时无法提供真正的防降级保护，
  /// 且部分未正确对错误响应签名的旧版 SMB2 服务端可能会连接失败。
  static const isRequireSecureNegotiate = true;

  /// 是否启用 NetBIOS 139 端口连接失败回退（默认为 false）。
  bool get isPort139FailoverEnabled;

  /// 协商阶段是否声明支持 Unicode 字符串编码（默认为 true）。
  bool get isUseUnicode;

  /// 是否启用 SMB1 AndX 链式批处理命令打包（默认为 false）。
  bool get isUseBatching;

  /// 向服务端通告的客户端操作系统名称标识。
  String get nativeOs;

  /// 向服务端通告的 Lanman 客户端版本标识（默认为 smb_connect）。
  String get nativeLanman;

  /// 单次接收网络缓冲区大小上限（单位：字节，默认为 65535）。
  int get receiveBufferSize;

  /// 单次发送网络缓冲区大小上限（单位：字节，默认为 65535）。
  int get sendBufferSize;

  /// 底层套接字读写超时时长（单位：毫秒，默认为 35000）。
  int get soTimeout;

  /// 建立 TCP 套接字连接的超时时长（单位：毫秒，默认为 35000）。
  int get connTimeout;

  /// SMB 会话空闲超时时长（单位：毫秒，默认为 35000）。

  /// 等待单个 SMB 响应报文返回的超时时长（单位：毫秒，默认为 30000）。
  int get responseTimeout;

  /// 向对端通告的本地 NetBIOS 主机短名称。
  static const String? netbiosHostname = null;

  Credentials get credentials;

  /// 认证凭据所属的域名或工作组名称。
  String? get domain;

  /// 认证凭据对应的登录用户名。
  String? get username;

  /// 认证凭据对应的账户密码明文。
  String? get password;

  /// Lanman 认证协议兼容级别配置（默认级别 3，即仅限 NTLMv2）。
  /// 0 或 1：允许发送 LM 与 NTLM 响应。
  /// 2：仅发送 NTLM 响应。
  /// 3 至 5：仅发送 NTLMv2 安全性更高响应。
  /// Lanman 兼容级别配置（默认为 3，即仅允许 NTLMv2）。
  static const int lanManCompatibility = 3;

  /// 是否直接发送原始 NTLMSSP 令牌而非包裹为 SPNEGO 令牌（默认为 false）。
  static const isUseRawNTLM = false;

  /// 建链时通告的虚拟通道序号。
  static const vcNumber = 1;

  /// 自定义声明的客户端能力标志位掩码。
  int get capabilities;

  /// 自定义 SMB 请求头 Flags2 标志位。
  int get flags2;

  /// 使用的 OEM 字符集编码名称（默认为 Cp850）。
  CharEncoding get oemEncoding;

  /// 本地时区配置对象，用于 SMB 时间戳换算。
  TimeZone get localTimezone;

  /// 随请求发送的进程号 PID（未设置时随机生成）。
  int get pid;

  /// 通告支持的最大并发请求数量上限（默认为 10）。
  static const int maxMpxCount = SmbConstants.DEFAULT_MAX_MPX_COUNT;

  /// 服务端支持时是否对全部报文启用 SMB 消息签名（默认为 false）。
  static const bool isSigningEnabled = false;

  /// 实验性配置：仅用于在协议协商期间向对端声明支持标志，
  /// 当前尚未实装完整的 SMB3 传输载荷加密功能。
  /// 是否启用 SMB 传输加密标志（默认为 false）。
  static const isEncryptionEnabled = false;

  /// I/O 读写缓冲区尺寸上限，同时约束单条消息最大分片大小。
  int get maximumBufferSize;

  /// SMB Transaction 请求默认允许携带的最大数据长度。
  int get transactionBufferSize;

  /// 缓冲区复用池中保留的闲置缓冲块数量（默认为 16）。
  int get bufferCacheSize;

  /// 单次目录枚举请求最多拉取的文件条目上限（默认为 200）。
  int get listCount;

  /// 列举/查询请求允许返回的最大数据负载（已扣除报文头固定开销，默认 65435）。
  int get listSize;

  /// 指定 SMB 命令码对应的 AndX 最大批处理条数。
  int getBatchLimit(int cmd); //String cmd);

  /// 客户端唯一机器标识种子（32 字节），用于派生 ClientGuid 等参数。
  /// 32 字节客户端机器标识符字节序列。
  Uint8List get machineId;

  /// 是否禁用 SPNEGO mechListMIC 的生成与校验（默认为 false）。
  static const isDisableSpnegoIntegrity = false;

  /// 是否强制校验对端返回的 SPNEGO mechListMIC（默认为 false）。
  static const isEnforceSpnegoIntegrity = false;

  /// NTLM 认证交互时是否附带 AvTargetName 属性对（默认为 true）。
  static const isSendNTLMTargetName = true;

  /// 以访客模式发起连接时使用的用户名（默认为 GUEST）。
  static const String guestUsername = "GUEST";

  /// 以访客模式发起连接时使用的密码（默认为空字符串）。
  static const String guestPassword = "";

}
