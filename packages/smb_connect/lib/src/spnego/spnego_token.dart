import 'dart:typed_data';

import 'package:smb_connect/src/utils/extensions.dart';

///
/// SPNEGO（RFC 4178）认证响应 ASN.1 报文封装（NegTokenTarg / NegTokenResp）。
///
///
abstract class SpnegoToken {
  Uint8List? mechanismToken;

  Uint8List? mechanismListMIC;

  SpnegoToken({this.mechanismToken, this.mechanismListMIC});

  Uint8List toByteArray();

  @override
  String toString() =>
      'SpnegoToken(mechanismToken: ${mechanismToken?.toHexString()}, mechanismListMIC: ${mechanismListMIC?.toHexString()})';
}
