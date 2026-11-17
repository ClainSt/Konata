import 'package:smb_connect/src/dcerpc/dcerpc_constants.dart';
import 'package:smb_connect/src/dcerpc/msrpc/msrpc_share_info1.dart';
import 'package:smb_connect/src/dcerpc/msrpc/srvsvc.dart';
import 'package:smb_connect/src/smb/file_entry.dart';

class MsrpcShareEnum extends SrvsvcShareEnumAll {
  MsrpcShareEnum(String server)
      : super("\\\\$server", 1, SrvsvcShareInfoCtr1(), -1, 0, 0) {
    ptype = 0;
    flags =
        DcerpcConstants.DCERPC_FIRST_FRAG | DcerpcConstants.DCERPC_LAST_FRAG;
  }

  List<FileEntry> getEntries() {
    /// 因底层 `ShareInfo1` 模型由 IDL 生成未实现通用条目接口，此处将其包装为统一文件条目列表。
    SrvsvcShareInfoCtr1 ctr = info as SrvsvcShareInfoCtr1;
    List<MsrpcShareInfo1> entries = List.generate(
        ctr.count, (index) => MsrpcShareInfo1.info(ctr.array![index]));
    return entries;
  }
}
