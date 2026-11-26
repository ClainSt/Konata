import 'dart:typed_data';

import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/smb2/nego/smb2_negotiate_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/session/smb2_logoff_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/session/smb2_session_setup_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/session/smb2_session_setup_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_signing_digest.dart';
import 'package:smb_connect/src/connect/smb_session.dart';
import 'package:smb_connect/src/dialect_version.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/smb/request_param.dart';
import 'package:smb_connect/src/smb/ssp_context.dart';

class Smb2Session extends SmbSession {
  Smb2Session(super.config, super.transport, [super.credentials]);

  @override
  Future close() async {
    Smb2LogoffRequest logoffReq = Smb2LogoffRequest(config);
    prepareRequest(logoffReq);
    await transport.sendrecv(logoffReq);
  }

  @override
  Future<bool> setup() async {
    var res = await transport.ensureConnected();
    if (!res) {
      if (config.debugPrint) {
        print("SMB 连接失败");
      }
      return false;
    }
    var negoResp = transport.getNegotiatedResponse()! as Smb2NegotiateResponse;

    var token = negoResp.securityBuffer;
    int securityMode = ((negoResp.securityMode &
                    Smb2Constants.SMB2_NEGOTIATE_SIGNING_REQUIRED) !=
                0) ||
            transport.isSigningEnforced()
        ? Smb2Constants.SMB2_NEGOTIATE_SIGNING_REQUIRED
        : Smb2Constants.SMB2_NEGOTIATE_SIGNING_ENABLED;
    bool anonymous = credentials.isAnonymous();

    String? tdomain;
    SSPContext ctx = createContext(tdomain, negoResp, !anonymous);

    token = createToken(ctx, token!);

    var request1 = Smb2SessionSetupRequest(
        config, securityMode, negoResp.commonCapabilities, 0, token,
        retainPayload: true, credit: 512);
    Smb2SessionSetupResponse response1 = await transport
        .sendrecv(request1, params: {RequestParam.RETAIN_PAYLOAD});
    if (config.debugPrint) {
      print("SMB 初次会话应答已接收");
    }
    token = response1.blob;


    token = createToken(ctx, token!);
    var request2 = Smb2SessionSetupRequest(
        config, securityMode, negoResp.commonCapabilities, 0, token,
        credit: 512, retainPayload: true);
    request2.setSessionId(response1.sessionId);
    Smb2SessionSetupResponse response2 = await transport
        .sendrecv(request2, params: {RequestParam.RETAIN_PAYLOAD});
    token = response2.blob;
    if (token == null) {
      final s = SmbException.getMessageByCode(response2.status);
      throw SmbAuthException(s);
    }

    token = createToken(ctx, token);

    if (token == null && ctx.isEstablished()) {
      sessionId = response2.getSessionId();
      Uint8List? signingKey = sessionKey = ctx.getSigningKey();
      if (config.debugPrint) {
        print("SMB 会话认证完成");
      }
      bool signed = response2.isSigned();
      if (!anonymous && (isSignatureSetupRequired() || signed)) {
        if (signingKey != null) {
          Smb2SigningDigest dgst = Smb2SigningDigest(
              sessionKey!, negoResp.dialectRevision, preauthIntegrityHash);
          // 在此显式核验服务端返回的响应签名（因复合/协商期可能未托管统一摘要器）。
          // 对低于 SMB 3.0 的协议放宽末条响应缺失签名（规范允许且兼容 EMC Isilon 等存储设备）。
          if (negoResp.getSelectedDialect()?.atLeast(DialectVersion.SMB300) ==
                  true ||
              response2.isSigned()) {
            response2.setDigest(dgst);
            Uint8List? payload = response2.getRawPayload();
            if (payload == null ||
                !response2.verifySignature(payload, 0, payload.length)) {
              throw SmbException("Signature validation failed");
            }
          }
          setDigest(dgst);
        } else if (Configuration.isSigningEnabled) {
          throw SmbException("Signing enabled but no session key available");
        }
      }
      return true;
    }
    return false;
  }

  SSPContext createContext(
      String? tdomain, Smb2NegotiateResponse negoResp, bool doSigning) {
    String? host = getTargetHost();
    return credentials.createContext(
        config, tdomain, host, negoResp.securityBuffer!, doSigning);
  }

  static Uint8List? createToken(SSPContext ctx, Uint8List token) {
    return ctx.initSecContext(token, 0, token.length);
  }
}
