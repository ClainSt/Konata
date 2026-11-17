import 'dart:typed_data';
import 'package:smb_connect/src/connect/transport/message.dart';

abstract class Response extends Message {
  /// 标识对端应答报文是否已成功送达并完成解码。
  bool isReceived();

  /// 标记当前请求已收到有效应答。
  void setReceived();

  /// 清除当前请求的已接收状态标记。
  void clearReceived();

  /// 本条响应中服务端实际批准授予的信用额度。
  int getGrantedCredits();

  /// 服务端返回的 NTSTATUS 状态码。
  int getErrorCode();

  void setMid(int k);

  /// 唯一标识当前事务请求/响应配对的消息 ID。
  int getMid();

  /// 响应报文签名校验是否通过。
  bool verifySignature(Uint8List buffer, int i, int size);

  /// 响应报文签名校验是否失败。
  bool isVerifyFailed();

  /// 判断响应是否携带有失败/异常状态码。
  bool isError();

  /// 记录响应解码或协议处理阶段发生的异常状态。
  void error();

  /// 当前请求允许的独立等待超时时间。
  int? getExpiration();

  /// 返回当前请求适用的等待超时时间。
  void setExpiration(int? exp);

  void reset();

  /// 与本次请求失败状态绑定的异常详情实例。
  Exception? getException();

  void setException(Exception? e);

  /// 复合响应链中的下一条应答消息对象。
  Response? getNextResponse();
}
