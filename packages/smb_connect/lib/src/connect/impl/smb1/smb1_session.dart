import 'dart:typed_data';

import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/smb_session.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_blank_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_logoff_and_x.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_negotiate_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_session_setup_and_x.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_session_setup_and_x_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/server_message_block.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb1_signing_digest.dart';
import 'package:smb_connect/src/smb/nt_status.dart';
import 'package:smb_connect/src/smb/ntlm_password_authenticator.dart';
import 'package:smb_connect/src/smb/ssp_context.dart';
import 'package:smb_connect/src/smb_constants.dart';

class Smb1Session extends SmbSession {
  Smb1Session(super.config, super.transport, [super.credentials]);

  @override
  Future<bool> setup(
      {ServerMessageBlock? andx, ServerMessageBlock? andxResponse}) async {
    var res = await transport.ensureConnected();
    if (!res) {
      if (config.debugPrint) {
        print("Can't connect!");
      }
      return false;
    }
    var negoResp =
        transport.getNegotiatedResponse()! as SmbComNegotiateResponse;

    bool anonymous = credentials.isAnonymous();
    if (transport
            .getNegotiatedResponse()
            ?.haveCapabilitiy(SmbConstants.CAP_EXTENDED_SECURITY) ==
        true) {
      String host = getTargetHost();
      String? tdomain = config.domain;
      final doSigning = !anonymous &&
          (negoResp.getNegotiatedFlags2() &
                  SmbConstants.FLAGS2_SECURITY_SIGNATURES) !=
              0;
      final ctx = credentials.createContext(config, tdomain, host,
          negoResp.getServerData().encryptionKey!, doSigning);

      var resp1 =
          await ntlmSSP(ctx, anonymous, doSigning, negoResp, Uint8List(0));
      var nextToken = resp1?.blob;
      if (nextToken == null) {
        var errorCode = resp1?.errorCode ?? NtStatus.NT_STATUS_LOGON_FAILURE;
        throw SmbAuthException(SmbException.getMessageByCode(errorCode));
      }
      var resp2 = await ntlmSSP(ctx, anonymous, doSigning, negoResp, nextToken);
      nextToken = resp2?.blob;
      if (nextToken == null) {
        var errorCode = resp2?.errorCode ?? NtStatus.NT_STATUS_LOGON_FAILURE;
        throw SmbAuthException(SmbException.getMessageByCode(errorCode));
      }
      nextToken = ctx.initSecContext(nextToken, 0, nextToken.length);
      if (ctx.isEstablished()) {
        sessionKey = ctx.getSigningKey();
        // }
        return true;
      } else if (!anonymous && isSignatureSetupRequired()) {
        final signingKey = ctx.getSigningKey();
        if (signingKey != null) {
          setDigest(SMB1SigningDigest(signingKey, signSequence: 2));
        } else if (Configuration.isSigningEnabled) {
          throw SmbException("Signing required but no session key available");
        }
        sessionKey = signingKey;
        return true;
      }
      return false;
    } else {
      // }
      if (credentials is! NtlmPasswordAuthenticator) {
        throw SmbAuthException("Incompatible credentials");
      }
      NtlmPasswordAuthenticator npa = credentials as NtlmPasswordAuthenticator;

      var request = SmbComSessionSetupAndX(config, negoResp, andx, credentials);
      // 若当前传输连接已安装签名摘要器，则复用现有摘要实例。
      request.setDigest(getDigest());
      var response = SmbComSessionSetupAndXResponse(config, andx: andxResponse);
      response.setExtendedSecurity(false);

      /// 按需初始化 SMB 消息签名摘要器（仅首个携带非空凭据的会话建立报文初始化一次）。

      if (!anonymous && isSignatureSetupRequired()) {

        //   }
        Uint8List? signingKey =
            npa.getSigningKey(config, negoResp.getServerData().encryptionKey!);
        if (signingKey == null) {
          throw SmbException(
              "Need a signature key but the server did not provide one");
        }
        request.setDigest(SMB1SigningDigest(signingKey, bypass: false));
        // }
      }

      await transport.sendrecv(request, response: response);
      if (response.errorCode != 0) {
        throw "Can't create session";
      }

      if (response.isLoggedInAsGuest && //!config.isAllowGuestFallback() &&
          negoResp.getServerData().security != SmbConstants.SECURITY_SHARE &&
          !(credentials.isGuest() || credentials.isAnonymous())) {
        throw SmbAuthException(
            SmbException.getMessageByCode(NtStatus.NT_STATUS_LOGON_FAILURE));
      } else if (!credentials.isAnonymous() && response.isLoggedInAsGuest) {
        anonymous = true;
      }

      // }

      uid = response.getUid(); //setUid(response.getUid());

      var digest = request.getDigest();
      if (digest != null) {
        setDigest(digest);
      } else if (!anonymous && isSignatureSetupRequired()) {
        throw SmbException("Signing required but no session key available");
      }

      return true;
    }
  }

  Future<SmbComSessionSetupAndXResponse?> ntlmSSP(
      SSPContext ctx,
      bool anonymous,
      bool doSigning,
      SmbComNegotiateResponse negoResp,
      Uint8List prevToken) async {

    //             }

    //         });
    //     }

    //         {
    //         }
    //     }
    // }
    var nextToken = ctx.initSecContext(prevToken, 0, prevToken.length);
    if (nextToken == null) {
      return null;
    }
    var request = SmbComSessionSetupAndX(config, negoResp, null, nextToken);
    // 若当前传输连接已安装签名摘要器，则复用现有摘要实例。
    request.setDigest(getDigest());
    if (doSigning && ctx.isEstablished() && isSignatureSetupRequired()) {
      var signingKey = ctx.getSigningKey();
      if (signingKey != null) {
        request.setDigest(SMB1SigningDigest(signingKey));
      }
      sessionKey = signingKey;
    } else {
    }

    var response = SmbComSessionSetupAndXResponse(config, andx: null);
    response.setExtendedSecurity(true);
    request.setUid(uid);
    uid = 0;

    await transport.sendrecv(request, response: response);
    // }
    // }
    //     ex = se;
    //     }
    //     /*
    //      */
    //     }
    //     }
    // }

    if (response.isLoggedInAsGuest && //!config.isAllowGuestFallback() &&
        !(credentials.isGuest() || credentials.isAnonymous())) {
      throw SmbAuthException(
          SmbException.getMessageByCode(NtStatus.NT_STATUS_LOGON_FAILURE));
    } else if (!credentials.isAnonymous() && response.isLoggedInAsGuest) {
      anonymous = true;
    }

    // }

    uid = response.getUid();
    var digest = request.getDigest();
    if (digest != null) {
      /// 认证与签名协商成功，安装当前会话签名摘要器。
      setDigest(digest);
    }
    return response; //.blob;
  }

  @override
  Future close() async {
    bool shareSecurity =
        (transport.getNegotiatedResponse() as SmbComNegotiateResponse)
                .getServerData()
                .security ==
            SmbConstants.SECURITY_SHARE;
    if (!shareSecurity) {
      SmbComLogoffAndX request = SmbComLogoffAndX(config, null);
      request.setDigest(getDigest());
      request.setUid(uid);
      try {
        await transport.send(request, SmbComBlankResponse(config));
      } catch (se) {
      }
      uid = 0;
    }
  }
}
