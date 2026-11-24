import 'uuid.dart';

abstract class DcerpcConstants {
  static final UUID DCERPC_UUID_SYNTAX_NDR =
      UUID.str("8a885d04-1ceb-11c9-9fe8-08002b104860");

  /// 标识分片序列的首个 RPC PDU 帧。
  static const int DCERPC_FIRST_FRAG = 0x01;

  /// 标识分片序列的最后一个 RPC PDU 帧。
  static const int DCERPC_LAST_FRAG = 0x02;

  /// 标识发送端挂起了取消请求标志。
  static const int DCERPC_PENDING_CANCEL = 0x04;
  static const int DCERPC_RESERVED_1 = 0x08;

  /// 标识连接支持并发多路复用请求。
  static const int DCERPC_CONC_MPX = 0x10;
  static const int DCERPC_DID_NOT_EXECUTE = 0x20;

  /// 请求“至多尝试一次”（maybe）幂等调用语义。
  static const int DCERPC_MAYBE = 0x40;

  /// 若置位则报文中包含非空 Object UUID 字段。
  static const int DCERPC_OBJECT_UUID = 0x80;
}
