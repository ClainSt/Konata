import 'package:smb_connect/src/connect/common/common_server_message_block.dart';
import 'package:smb_connect/src/connect/common/common_server_message_block_response.dart';

import '../transport/request.dart';

abstract class CommonServerMessageBlockRequest
    implements CommonServerMessageBlock, Request {
  @override
  CommonServerMessageBlockRequest? getNext();

  int size();

  void setTid(int t);

  /// 为当前单次请求单独覆盖的响应超时时间。
  int? getOverrideTimeout();

  @override
  CommonServerMessageBlockResponse? getResponse();
}
