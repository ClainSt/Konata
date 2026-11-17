import 'package:smb_connect/src/decodable.dart';

abstract class NegotiateContextResponse extends Decodable {
  // 返回当前协商上下文的类型枚举编号。
  int getContextType();
}
