import 'dart:typed_data';

import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/smb/ssp_context.dart';

/// 不透明认证凭据数据模型统一接口契约。
abstract class Credentials {
  /// 用户账户所属的域或认证工作组名称。
  String getUserDomain();

  /// 当前凭据是否代表空用户名/匿名身份。
  bool isAnonymous();

  /// 当前凭据是否代表来宾（Guest）登录身份。
  bool isGuest();

  SSPContext createContext(Configuration config, String? targetDomain,
      String host, Uint8List initialToken, bool doSigning);
}
