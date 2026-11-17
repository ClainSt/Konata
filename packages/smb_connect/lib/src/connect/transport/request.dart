import 'package:smb_connect/src/connect/transport/response.dart';

import 'message.dart';

abstract class Request extends Message {
  /// 发送本条请求需要消耗的 SMB2 信用额度。
  int getCreditCost();

  /// 本次请求附带申请的 SMB2 信用额度数量。
  void setRequestCredits(int credits);

  /// 当前报文是否为取消请求控制指令。

  /// 复合链中挂载的下一条子请求引用。
  Request? getNext();

  /// 与当前请求配对关联的响应对象。
  Response? getResponse();
}
