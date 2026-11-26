import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:mutex/mutex.dart';
import 'package:smb_connect/src/buffer_cache.dart';
import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_request.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';
import 'package:smb_connect/src/connect/common/request.dart' as request2;
import 'package:smb_connect/src/connect/common/smb_negotiation.dart';
import 'package:smb_connect/src/connect/common/smb_negotiation_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_blank_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_negotiate.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_negotiate_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/com/smb_com_read_and_x_response.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb_com_constants.dart';
import 'package:smb_connect/src/connect/impl/smb1/trans/smb_com_transaction.dart';
import 'package:smb_connect/src/connect/impl/smb1/trans/smb_com_transaction_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/nego/smb2_negotiate_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/nego/smb2_negotiate_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/server_message_block2_request.dart';
import 'package:smb_connect/src/connect/impl/smb2/server_message_block2_response.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/connect/transport/request.dart';
import 'package:smb_connect/src/connect/transport/response.dart';
import 'package:smb_connect/src/crypto/crypto.dart';
import 'package:smb_connect/src/dialect_version.dart';
import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/fixes/atomic_integer.dart';
import 'package:smb_connect/src/smb/nt_status.dart';
import 'package:smb_connect/src/smb/request_param.dart';
import 'package:smb_connect/src/smb_constants.dart';
import 'package:smb_connect/src/utils/base.dart';
import 'package:smb_connect/src/utils/bytes.dart';
import 'package:smb_connect/src/utils/encdec.dart';
import 'package:smb_connect/src/utils/extensions.dart';
import 'package:smb_connect/src/utils/socket/socket_reader.dart';
import 'package:smb_connect/src/utils/socket/socket_writer.dart';

import '../fixes/semaphore.dart';

typedef CompleteResponse = ({
  CommonServerMessageBlockResponse response,
  Completer<CommonServerMessageBlockResponse> completer
});

typedef OnSmbDisconnect = Function(SmbTransport transport);

class SmbTransport {
  bool _smb2 = false;
  final Configuration config;
  OnSmbDisconnect? onDisconnect;
  final String host;
  int _port;

  final Uint8List _sbuf = Uint8List(1024);
  final _mid = AtomicInteger(0);

  Socket? _socket;
  SocketReader2? _reader;
  SocketReader2 get _inp => _reader!;
  late SocketWriter _out;
  Future<void>? _closing;

  late final bool _signingEnforced;
  /* 沿用协议状态字段可变定义，保留静态规则豁免 */ // ignore: prefer_final_fields
  int _desiredCredits = 512;
  final Semaphore _credits = Semaphore(1, true);
  SmbNegotiationResponse? _negotiated;
  Uint8List _preauthIntegrityHash = Uint8List(64);

  final Map<int, CompleteResponse> responses = {};
  bool _reading = false;
  Object? _readerFailure;
  StackTrace? _readerFailureStack;

  void onReaderFailure(Object error, StackTrace stack) {
    _readerFailure ??= error;
    _readerFailureStack ??= stack;
    final pending = responses.values.toList();
    responses.clear();
    for (final item in pending) {
      if (!item.completer.isCompleted) {
        item.completer.completeError(error, stack);
      }
    }
  }

  SmbTransport(
    this.config,
    this.host, [
    this._port = 0,
    this._signingEnforced =
        false, //_signingEnforced = forceSigning || config.isSigningEnforced();
  ]);

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (config.debugPrint) {
      print("Smb transport close called");
    }
    try {
      await _reader?.close();
    } finally {
      // 兼容处理读取器尚未就绪前提前失败的场景；即便取消流订阅报错也必须完成资源销毁。
      _socket?.destroy();
    }
  }

  SmbNegotiationResponse? getNegotiatedResponse() => _negotiated;

  Future<bool> ensureConnected() async {
    if (_closing != null) return false;
    if (_negotiated != null) {
      return true;
    }
    return await _connect();
  }

  /// SMB 协议版本与能力协商请求及响应处理。
  Future<bool> _connect() async {
    try {
      SmbNegotiation resp = await _negotiate();

      // }

      if (!resp.response.isValid(resp.request)) {
        throw SmbException("This client is not compatible with the server.");
      }

      // }

      // 根据协商应答报文修正本连接的缓冲区与签名限制参数。
      _negotiated = resp.response;
      if (resp.response.getSelectedDialect()?.atLeast(DialectVersion.SMB311) ==
          true) {
        _updatePreauthHash(resp.requestBuffer!);
        _updatePreauthHash(resp.responseBuffer!);
      }
      return true;
    } catch (e) {
      if (config.debugPrint) print("SMB 协商失败：${e.runtimeType}");
      return false;
    }
  }

  Future<bool> disconnect(bool hard, [bool inUse = true]) async {
    if (config.debugPrint) {
      print("SmbTransport was disconnect call");
    }
    await _socket?.close();
    return true;
  }

  void onListenReader() async {
    if (_reading) return;
    _reading = true;
    try {
      if (responses.isNotEmpty) {
        var key = await _peekKey();
        while (key != null) {
          var completer = responses.remove(key);
          if (completer != null) {
            try {
              await _doRecv(completer.response);
            } catch (error, stack) {
              completer.completer.completeError(error, stack);
              rethrow;
            }
            completer.response.setReceived();
            if (completer.response.isReceived()) {
              completer.completer.complete(completer.response);
            } else {
              responses[key] = completer;
            }
          } else {
            print("Error complete response $key");
          }
          key = null;
          if (responses.isNotEmpty && _inp.available() > 0) {
            key = await _peekKey();
          }
        }
      }
    } catch (error, stack) {
      onReaderFailure(error, stack);
    } finally {
      _reading = false;
    }
  }

  Future<SmbNegotiation> _negotiate() async {
    // 在 `doConnect()` 完成握手前传输监听循环尚未启动，暂不通过通用 `sendrecv()` 收发以免提前泄露常规报文。
    //
    if (_port == 139) {
      await _ssn139();
    } else {
      if (_port == 0) {
        _port = SmbConstants.DEFAULT_PORT; // 445
      }
      var socket = await Socket.connect(host, SmbConstants.DEFAULT_PORT,
          timeout: Duration(milliseconds: config.soTimeout));
      // 当 TCP 建链仍在等待返回期间，外层可能已并发触发 `close()` 关闭传输层。
      if (_closing != null) {
        socket.destroy();
        throw const SocketException('SMB transport closed during connection');
      }
      _socket = socket;
      /* 底层传输泵异步派发，无需同步等待返回 */ // ignore: unawaited_futures
      socket.done.then((e) {
        if (config.debugPrint) {
          print("Smb socket diconnected from done");
        }
        onDisconnect?.call(this);
      }, onError: (Object error, StackTrace stack) {
        onReaderFailure(error, stack);
        onDisconnect?.call(this);
      });

      _reader = SocketReader2(socket, onListenReader,
          debugPrint: config.debugPrintLowLevel, onFailure: onReaderFailure);
      _out = SocketWriter(socket, debugPrint: config.debugPrintLowLevel);
    }

    if (isSMB2()) {
      return await _negotiate2(null);
    }

    SmbComNegotiate comNeg = SmbComNegotiate(config, _signingEnforced);
    await _negotiateWrite(comNeg, true);
    await _negotiatePeek();

    SmbNegotiationResponse? resp;

    if (!isSMB2()) {
      if (config.minimumVersion.isSMB2()) {
        throw SmbConnectException("Server does not support SMB2");
      }
      resp = SmbComNegotiateResponse(config);
      resp.decode(_sbuf, 4);
      resp.setReceived();
      _sbuf.fill();
    } else {
      Smb2NegotiateResponse r = Smb2NegotiateResponse(config);
      r.decode(_sbuf, 4);
      r.setReceived();
      _sbuf.fill();

      if (r.dialectRevision == Smb2Constants.SMB2_DIALECT_ANY) {
        return await _negotiate2(r);
      } else if (r.dialectRevision != Smb2Constants.SMB2_DIALECT_0202) {
        throw SmbConnectException(
            "Server returned invalid dialect verison in multi protocol negotiation");
      }
      int permits = r.getInitialCredits();
      if (permits > 0) {
        _credits.release(permits);
      }
      return SmbNegotiation(
          Smb2NegotiateRequest(
              config,
              _signingEnforced
                  ? Smb2Constants.SMB2_NEGOTIATE_SIGNING_REQUIRED
                  : Smb2Constants.SMB2_NEGOTIATE_SIGNING_ENABLED),
          r,
          null,
          null);
    }

    int permits = resp.getInitialCredits();
    if (permits > 0) {
      _credits.release(permits);
    }
    _sbuf.fill();
    return SmbNegotiation(comNeg, resp, null, null);
  }

  Future<void> _ssn139() async {
    // do {


    //     // }
    //   }
    //       // }
    //       }
    //   }

    throw SmbIOException(
        "Failed to establish session with $host on port $_port");
  }

  Future<int> _negotiateWrite(
      CommonServerMessageBlockRequest req, bool setmid) async {
    if (setmid) {
      makeKey(req);
    } else {
      req.setMid(0);
      _mid.set(1);
    }
    int n = req.encode(_sbuf, 4);
    Encdec.encUint32BE(n & 0xFFFF, _sbuf, 0);

    /// NetBIOS 会话消息 4 字节固定头部。
    _out.write(_sbuf, 0, 4 + n);
    await _out.flush();
    _sbuf.fill();
    return n;
  }

  Future<void> _negotiatePeek() async {
    /// 此时传输读取泵尚未接管套接字，可安全直接阻塞读取协议协商头部。
    if (await _peekKey() == null) {
      /// 尝试先预读 4 字节传输头。
      throw "transport closed in negotiate"; //IOException("transport closed in negotiate")
    }
    int size = Encdec.decUint16BE(_sbuf, 2) & 0xFFFF;
    if (size < 33 || (4 + size) > _sbuf.length) {
      throw "Invalid payload size: $size"; //IOException("Invalid payload size: $size")
    }
    int hdrSize = isSMB2()
        ? Smb2Constants.SMB2_HEADER_LENGTH
        : SmbConstants.SMB1_HEADER_LENGTH;
    await readn(_inp, _sbuf, 4 + hdrSize, size - hdrSize);
  }

  Future<SmbNegotiation> _negotiate2(Smb2NegotiateResponse? first) async {
    int securityMode = _getRequestSecurityMode(first);

    // 仍需后续交互报文完成协商流程。
    Smb2NegotiateRequest smb2neg = Smb2NegotiateRequest(config, securityMode);
    Smb2NegotiateResponse? r;
    Uint8List? negoReqBuffer;
    Uint8List? negoRespBuffer;
    try {
      smb2neg.setRequestCredits(
          max(1, _desiredCredits - _credits.availablePermits()));

      int reqLen = await _negotiateWrite(smb2neg, first != null);
      bool doPreauth = config.maximumVersion.atLeast(DialectVersion.SMB311);
      if (doPreauth) {
        negoReqBuffer = Uint8List(reqLen);
        byteArrayCopy(
            src: _sbuf,
            srcOffset: 4,
            dst: negoReqBuffer,
            dstOffset: 0,
            length: reqLen);
      }

      await _negotiatePeek();

      r = smb2neg.initResponse(config);
      int respLen = r.decode(_sbuf, 4);
      r.setReceived();
      _sbuf.fill();

      if (doPreauth) {
        negoRespBuffer = Uint8List(respLen);
        byteArrayCopy(
            src: _sbuf,
            srcOffset: 4,
            dst: negoRespBuffer,
            dstOffset: 0,
            length: respLen);
      } else {
        negoReqBuffer = null;
      }
      return SmbNegotiation(smb2neg, r, negoReqBuffer, negoRespBuffer);
    } finally {
      int grantedCredits = r?.getGrantedCredits() ?? 0;
      if (grantedCredits == 0) {
        grantedCredits = 1;
      }
      _credits.release(grantedCredits);
      _sbuf.fill();
    }
  }

  int makeKey(Request request) {
    int m = _mid.incrementAndGet() - 1;
    if (!isSMB2()) {
      m = (m % 32000);
    }
    (request as CommonServerMessageBlock).setMid(m);
    return m;
  }

  Future<int?> _peekKey() async {
    do {
      var n = await readn(_inp, _sbuf, 0, 4);
      if (n < 4) {
        return null;
      }
    } while (_sbuf[0] == 0x85);

    /// 跳过 NetBIOS Keep-Alive 保活空包（消息类型 `0x85`）。
    /// 读取 SMB 协议公共头魔数及长度前缀。
    if ((await readn(_inp, _sbuf, 4, SmbConstants.SMB1_HEADER_LENGTH)) <
        SmbConstants.SMB1_HEADER_LENGTH) {
      return null;
    }

    while (true) {
      ///
      /// 01234567
      /// 报头魔数布局：`00 SS FSMB`（`S` 为载荷长度，`FSMB` 为 SMB1 标志，SMB2/3 为 `0xFE SMB`）。
      /// 0 - 0's

      if (_sbuf[0] == 0x00 &&
          _sbuf[4] == 0xFE &&
          _sbuf[5] == Bytes.S_Byte && //'S'
          _sbuf[6] == Bytes.M_Byte && //'M'
          _sbuf[7] == Bytes.B_Byte) {
        //'B'
        _smb2 = true;
        // 继续读完报头其余固定字段部分。
        int lenDiff =
            Smb2Constants.SMB2_HEADER_LENGTH - SmbConstants.SMB1_HEADER_LENGTH;
        if (await readn(
                _inp, _sbuf, 4 + SmbConstants.SMB1_HEADER_LENGTH, lenDiff) <
            lenDiff) {
          return null;
        }
        return Encdec.decUint64LE(_sbuf, 28);
      }

      if (_sbuf[0] == 0x00 &&
          _sbuf[1] == 0x00 &&
          (_sbuf[4] == 0xFF) &&
          _sbuf[5] == Bytes.S_Byte && //'S'
          _sbuf[6] == Bytes.M_Byte && //'M'
          _sbuf[7] == Bytes.B_Byte) {
        //'B'
        break;

        /// 报文头合法有效，准备解码对应 SMB 响应体。
      }

      /// 疑似字节流边界错位，尝试向前按字节滑动窗口重新同步魔数。
      for (int i = 0; i < 35; i++) {
        _sbuf[i] = _sbuf[i + 1];
      }
      int b;
      if ((b = await _inp.readByte()) == -1) {
        return null;
      }
      _sbuf[35] = b;
    }

    ///
    /// 仅由传输监听主泵独占顺序读取并调用 `doRecv()`，故 `_sbuf` 缓冲数据在拷贝期间保持安全不变。

    return Encdec.decUint16LE(_sbuf, 34) & 0xFFFF;
  }

  int _getRequestSecurityMode(Smb2NegotiateResponse? first) {
    int securityMode = Smb2Constants.SMB2_NEGOTIATE_SIGNING_ENABLED;
    if (_signingEnforced || (first != null && first.isSigningRequired())) {
      securityMode = Smb2Constants.SMB2_NEGOTIATE_SIGNING_REQUIRED |
          Smb2Constants.SMB2_NEGOTIATE_SIGNING_ENABLED;
    }

    return securityMode;
  }

  void _updatePreauthHash(Uint8List input) {
    _preauthIntegrityHash =
        calculatePreauthHash(input, 0, input.length, _preauthIntegrityHash);
  }

  Uint8List calculatePreauthHash(
      Uint8List input, int off, int len, Uint8List? oldHash) {
    if (!_smb2 || _negotiated == null) {
      throw SmbUnsupportedOperationException();
    }

    Smb2NegotiateResponse resp = _negotiated as Smb2NegotiateResponse;
    if (resp.getSelectedDialect()?.atLeast(DialectVersion.SMB311) != true) {
      throw SmbUnsupportedOperationException();
    }

    MessageDigest dgst;
    switch (resp.selectedPreauthHash) {
      case 1:
        dgst = Crypto.getSHA512();
        break;
      default:
        throw SmbUnsupportedOperationException();
    }

    if (oldHash != null) {
      dgst.updateBuff(oldHash);
    }
    dgst.update(input, off, len);
    return dgst.digest();
  }

  BufferCache getBufferCache() {
    return BufferCacheImpl(config.maximumBufferSize); // getBufferCacheSize());
  }

  Future<T?> send<T extends CommonServerMessageBlockResponse>(
      CommonServerMessageBlockRequest request, T? response) async {
    try {
      var resp = response ?? request.getResponse() as T;
      await doSend(request);
      return resp;
    } catch (e) {
      return null;
    }
  }

  final Mutex sendrecvMutex = Mutex();

  Future<SmbComTransactionResponse> sendrecvComTransaction(
      SmbComTransaction request, SmbComTransactionResponse response,
      [Set<RequestParam>? params]) async {
    response.setCommand(request.getCommand());
    SmbComTransaction req = request; // as SmbComTransaction;
    SmbComTransactionResponse resp = response; // as SmbComTransactionResponse;
    resp.reset();
    _negotiated?.setupRequest(request);

    ///
    /// 发送首个请求并等待中间临时确认应答。
    ///
    try {
      req.setBuffer(config.bufferCache.getBuffer());
      req.nextElement();
      if (req.hasMoreElements()) {
        SmbComBlankResponse interim = SmbComBlankResponse(config);
        await sendrecv(req, response: interim, params: params);
        if (interim.getErrorCode() != 0) {
        }
        req.nextElement().getMid();
      } else {
        makeKey(req);
      }

      try {
        resp.clearReceived();
        int timeout = getResponseTimeout(req);
        if (params?.contains(RequestParam.NO_TIMEOUT) != true) {
          resp.setExpiration(currentTimeMillis() + timeout);
        } else {
          resp.setExpiration(null);
        }

        final txbuf = config.bufferCache.getBuffer();
        resp.setBuffer(txbuf);

        ///
        /// 连续分片发送大块事务消息载荷。
        ///
        bool hasMore;
        do {
          await doSend(req, params);
          hasMore = req.hasMoreElements();
          if (hasMore) {
            req.nextElement();
          }
        } while (hasMore);

        ///
        /// 连续分片接收并重组多段响应数据。
        ///
        await waitResponse(req.getMid(), response);

        if (resp.getErrorCode() != 0) {
        }
        return response;
      } finally {
        var buff = resp.releaseBuffer();
        if (buff != null) {
          config.bufferCache.releaseBuffer(buff);
        }
      }
    } catch (ie) {
    } finally {
      var buff = req.releaseBuffer();
      if (buff != null) {
        config.bufferCache.releaseBuffer(buff);
      }
    }
    return response;
  }

  Future<T> sendrecv<T extends CommonServerMessageBlockResponse>(
    CommonServerMessageBlockRequest request, {
    CommonServerMessageBlockResponse? response,
    Set<RequestParam>? params,
  }) async {
    await sendrecvMutex.acquire();
    try {
      if (response == null) {
        if (request is request2.Request) {
          response = request.initResponse(config);
        } else {
          response = request.getResponse()!;
        }
      } else {
        response.setCommand(request.getCommand());
      }
      response.reset();
      _negotiated?.setupRequest(request);

      final attempts = params?.contains(RequestParam.NO_RETRY) == true ? 1 : 5;
      for (var i = 0; i < attempts; i++) {
        await doSend(request, params);

        if (params?.contains(RequestParam.RETAIN_PAYLOAD) == true) {
          response.setRetainPayload();
        }

        try {
          var resp = await waitResponse(request.getMid(), response);
          if (config.debugPrint) {
            print("SMB 接收响应类型：${resp.runtimeType}");
          }
          return resp as T;
        } on TimeoutException catch (_) {
          if (config.debugPrint) {
            print("SmbTransport sent TimeoutException $i");
          }
        }
      }
      throw SmbException("SmbTransport cant send request: $request");
    } finally {
      sendrecvMutex.release();
    }
  }

  AtomicInteger nextMessageId = AtomicInteger(2);

  @protected
  Future<void> doSend(CommonServerMessageBlockRequest request,
      [Set<RequestParam>? params]) async {
    CommonServerMessageBlockRequest? chain = request;
    while (chain != null) {
      if (chain.getMid() == 0) {
        chain.setMid(nextMessageId.getAndIncrement());
      }
      chain = chain.getNext();
    }

    int reqCredits = 1;
    if (request.getCreditCost() == 0) {
      request.setRequestCredits(reqCredits);
    } else if (request is ServerMessageBlock2Request && request.credit == 0) {
      request.credit = 1;
    }
    if (config.debugPrint) {
      print("SMB 发送请求类型：${request.runtimeType}");
    }
    CommonServerMessageBlock smb = request as CommonServerMessageBlock;
    Uint8List buffer = getBufferCache().getBuffer();
    try {
      // 对报文编码与套接字写出加序同步，保证 SMB1 MAC 签名递增序号严格按发送顺序一致。
      int n = smb.encode(buffer, 4);
      Encdec.encUint32BE(
          n & 0xFFFF, buffer, 0); /* 4 byte session message header */
      //
      // 部分网络环境下大帧写出偶现被切分为附加续传帧，保持整段缓冲读取即可兼容。
      _out.write(buffer, 0, 4 + n);
      await _out.flush();
    } finally {
      getBufferCache().releaseBuffer(buffer);
    }
    // }
  }

  Duration waitResponseTimeout = Duration(seconds: 3);

  Future<CommonServerMessageBlockResponse> waitResponse(
    int key,
    CommonServerMessageBlockResponse response,
  ) async {
    if (_readerFailure != null) {
      Error.throwWithStackTrace(_readerFailure!, _readerFailureStack!);
    }
    _inp.checkReadable();
    Completer<CommonServerMessageBlockResponse> completer = Completer();
    responses[key] = (response: response, completer: completer);
    final result = completer.future.timeout(waitResponseTimeout);
    // 高速服务端可能在本端冲刷缓冲区期间即提前回包，先消费已落入暂存队列的响应。
    if (_inp.available() > 0) onListenReader();
    try {
      return await result;
    } finally {
      if (identical(responses[key]?.completer, completer)) {
        responses.remove(key);
      }
    }
  }

  @protected
  Future<void> _doRecv(Response response) async {
    CommonServerMessageBlock resp = response as CommonServerMessageBlock;
    _negotiated!.setupResponse(response);
    if (isSMB2()) {
      await _doRecvSMB2(resp);
    } else {
      await _doRecvSMB1(resp);
    }
  }

  Future<void> _doRecvSMB2(CommonServerMessageBlock response) async {
    int size =
        (Encdec.decUint16BE(_sbuf, 2) & 0xFFFF) | (_sbuf[1] & 0xFF) << 16;
    if (size < (Smb2Constants.SMB2_HEADER_LENGTH + 1)) {
      throw SmbIOException("Invalid payload size: $size");
    }

    if (_sbuf[0] != 0x00 ||
            _sbuf[4] != 0xFE ||
            _sbuf[5] != Bytes.S_Byte || // 'S' ||
            _sbuf[6] != Bytes.M_Byte || // 'M' ||
            _sbuf[7] != Bytes.B_Byte //'B'
        ) {
      throw SmbIOException("Houston we have a synchronization problem");
    }

    int nextCommand = Encdec.decUint32LE(_sbuf, 4 + 20);
    int maximumBufferSize = config.maximumBufferSize;
    int msgSize = nextCommand != 0 ? nextCommand : size;
    if (msgSize > maximumBufferSize) {
      throw SmbIOException(
          "Message size $msgSize exceeds maxiumum buffer size $maximumBufferSize");
    }

    ServerMessageBlock2Response? cur = response as ServerMessageBlock2Response;
    Uint8List buffer = getBufferCache().getBuffer();
    try {
      int rl = nextCommand != 0 ? nextCommand : size;

      // 优先读取并解码首段分片应答正文。
      byteArrayCopy(
          src: _sbuf,
          srcOffset: 4,
          dst: buffer,
          dstOffset: 0,
          length: Smb2Constants.SMB2_HEADER_LENGTH);
      await readn(_inp, buffer, Smb2Constants.SMB2_HEADER_LENGTH,
          rl - Smb2Constants.SMB2_HEADER_LENGTH);

      cur.setReadSize(rl);
      int len = cur.decode(buffer, 0);

      if (len > rl) {
        throw SmbIOException("WHAT? ( read $rl decoded $len ): $cur");
      } else if (nextCommand != 0 && len > nextCommand) {
        throw SmbIOException("Overlapping commands");
      }
      size -= rl;

      while (size > 0 && nextCommand != 0) {
        cur = cur?.getNextResponse() as ServerMessageBlock2Response?;
        if (cur == null) {
          await _inp.skip(size);
          break;
        }

        // 继续读取后续分片的协议头定位偏移。
        await readn(_inp, buffer, 0, Smb2Constants.SMB2_HEADER_LENGTH);
        nextCommand = Encdec.decUint32LE(buffer, 20);

        if ((nextCommand != 0 && nextCommand > maximumBufferSize) ||
            (nextCommand == 0 && size > maximumBufferSize)) {
          throw SmbIOException(
              "Message size ${nextCommand != 0 ? nextCommand : size} exceeds maxiumum buffer size $maximumBufferSize");
        }

        rl = nextCommand != 0 ? nextCommand : size;

        cur.setReadSize(rl);
        await readn(_inp, buffer, Smb2Constants.SMB2_HEADER_LENGTH,
            rl - Smb2Constants.SMB2_HEADER_LENGTH);

        len = cur.decode(buffer, 0, compound: true);
        if (len > rl) {
          throw SmbIOException("WHAT? ( read $rl decoded $len ): $cur");
        } else if (nextCommand != 0 && len > nextCommand) {
          throw SmbIOException("Overlapping commands");
        }
        size -= rl;
      }
    } finally {
      getBufferCache().releaseBuffer(buffer);
    }
  }

  Future<void> _doRecvSMB1(CommonServerMessageBlock resp) async {
    Uint8List buffer = getBufferCache().getBuffer();
    try {
      byteArrayCopy(
        src: _sbuf,
        srcOffset: 0,
        dst: buffer,
        dstOffset: 0,
        length: 4 + SmbConstants.SMB1_HEADER_LENGTH,
      );
      int size = (Encdec.decUint16BE(buffer, 2) & 0xFFFF);
      if (size < (SmbConstants.SMB1_HEADER_LENGTH + 1) ||
          (4 + size) > min(0xFFFF, config.maximumBufferSize)) {
        throw SmbIOException("Invalid payload size: $size");
      }
      int errorCode = Encdec.decUint32LE(buffer, 9) & 0xFFFFFFFF;
      if (resp.getCommand() == SmbComConstants.SMB_COM_READ_ANDX &&
          (errorCode == 0 || errorCode == NtStatus.NT_STATUS_BUFFER_OVERFLOW)) {
        // 命名管道读取出现缓冲区溢出状态码属正常分段提示，忽略继续。
        SmbComReadAndXResponse r = resp as SmbComReadAndXResponse;
        int off = SmbConstants.SMB1_HEADER_LENGTH;

        /// `WordCount` 至 `dataOffset` 区间长度固定为 27 字。
        await readn(_inp, buffer, 4 + off, 27);
        off += 27;
        resp.decode(buffer, 4);

        /// 兼容 EMC 存储设备在无数据时仍附带额外填充字节的实现。
        int pad = r.getDataOffset() - off;
        if (r.getByteCount() > 0 && pad > 0 && pad < 4) {
          await readn(_inp, buffer, 4 + off, pad);
        }

        if (r.getDataLength() > 0) {
          await readn(_inp, r.getData()!, r.getOffset(), r.getDataLength());

          /// 直接按字节流偏移读出载荷。
        }
      } else {
        await readn(_inp, buffer, 4 + SmbConstants.SMB1_HEADER_LENGTH,
            size - SmbConstants.SMB1_HEADER_LENGTH);
        resp.decode(buffer, 4);
      }
    } finally {
      getBufferCache().releaseBuffer(buffer);
    }
  }

  //   }
  //       // }
  //   }
  //   }
  // }

  @protected
  int getResponseTimeout(Request req) {
    if (req is CommonServerMessageBlockRequest) {
      int? overrideTimeout = req.getOverrideTimeout();
      if (overrideTimeout != null) {
        return overrideTimeout;
      }
    }
    return config.responseTimeout;
  }

  bool isSMB2() {
    if (config.forceSmb1) {
      return false;
    }
    return _smb2;
  }

  bool isSigningEnforced() => _signingEnforced;

  /// 从底层输入流持续读取指定字节数写入目标缓冲区。
  static Future<int> readn(
      SocketReader inp, Uint8List b, int off, int len) async {
    int i = 0, n = -5;

    if (off + len > b.length) {
      throw SmbIOException("Buffer too short, bufsize ${b.length} read $len");
    }

    while (i < len) {
      n = await inp.read(b, off + i, len - i);
      if (n <= 0) {
        break;
      }
      i += n;
    }

    return i;
  }
}

class BufferCacheImpl extends BufferCache {
  final int bufferSize;
  BufferCacheImpl(this.bufferSize);

  @override
  Uint8List getBuffer() {
    return Uint8List(bufferSize);
  }

  @override
  void releaseBuffer(Uint8List buf) {}
}
