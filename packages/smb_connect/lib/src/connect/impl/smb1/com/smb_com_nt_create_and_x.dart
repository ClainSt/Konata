import 'dart:typed_data';

import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/connect/impl/smb1/smb_com_constants.dart';
import 'package:smb_connect/src/connect/smb_util.dart';
import 'package:smb_connect/src/smb_constants.dart';
import 'package:smb_connect/src/utils/strings.dart';

import '../../../common/request.dart';
import '../and_x_server_message_block.dart';
import '../server_message_block.dart';
import 'smb_com_nt_create_and_x_response.dart';

class SmbComNTCreateAndX extends AndXServerMessageBlock
    implements Request<SmbComNTCreateAndXResponse> {
  // 沿用 `SmbFile` 构造函数声明的共享访问标志。

  // 文件创建/打开处置策略参数（CreateDisposition）。

  static const int FILE_SUPERSEDE = 0x0;

  static const int FILE_OPEN = 0x1;

  static const int FILE_CREATE = 0x2;

  static const int FILE_OPEN_IF = 0x3;

  static const int FILE_OVERWRITE = 0x4;

  static const int FILE_OVERWRITE_IF = 0x5;

  // 文件创建附加选项掩码（CreateOptions）。
  static const int FILE_WRITE_THROUGH = 0x00000002;
  static const int FILE_SEQUENTIAL_ONLY = 0x00000004;
  static const int FILE_SYNCHRONOUS_IO_ALERT = 0x00000010;
  static const int FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;

  // 安全描述符与模拟级别标志位（SecurityFlags）。
  static const int SECURITY_CONTEXT_TRACKING = 0x01;
  static const int SECURITY_EFFECTIVE_ONLY = 0x02;

  int rootDirectoryFid = 0,
      extFileAttributes = 0,
      shareAccess = 0,
      createDisposition = 0,
      createOptions = 0,
      impersonationLevel = 0;
  int allocationSize = 0;
  int securityFlags = 0;
  int namelenIndex = 0;

  int flags0 = 0, desiredAccess = 0;

  SmbComNTCreateAndX(
      super.config,
      String name,
      int flags,
      int access,
      int shareAccess,
      int extFileAttributes,
      int createOptions,
      ServerMessageBlock? andx)
      : super(
            command: SmbComConstants.SMB_COM_NT_CREATE_ANDX,
            name: name,
            andx: andx) {
    desiredAccess = access;
    desiredAccess |= SmbConstants.FILE_READ_DATA |
        SmbConstants.FILE_READ_EA |
        SmbConstants.FILE_READ_ATTRIBUTES;

    // 扩展文件属性位掩码。
    extFileAttributes = extFileAttributes;

    // 文件共享访问控制模式。
    shareAccess = shareAccess;

    // 打开或新建文件处置语义。
    if ((flags & SmbConstants.O_TRUNC) == SmbConstants.O_TRUNC) {
      // 目标文件存在时清零截断原内容。
      if ((flags & SmbConstants.O_CREAT) == SmbConstants.O_CREAT) {
        // 若文件不存在则创建新文件。
        createDisposition = FILE_OVERWRITE_IF;
      } else {
        createDisposition = FILE_OVERWRITE;
      }
    } else {
      // 打开已有文件并保留原有数据内容。
      if ((flags & SmbConstants.O_CREAT) == SmbConstants.O_CREAT) {
        // 若文件不存在则创建新文件。
        if ((flags & SmbConstants.O_EXCL) == SmbConstants.O_EXCL) {
          // 若文件已存在则令请求失败返回冲突错误。
          createDisposition = FILE_CREATE;
        } else {
          createDisposition = FILE_OPEN_IF;
        }
      } else {
        createDisposition = FILE_OPEN;
      }
    }

    if ((createOptions & 0x0001) == 0) {
      createOptions = createOptions | 0x0040;
    } else {
      createOptions = createOptions;
    }
    impersonationLevel = 0x02; // As seen on NT :~)
    securityFlags = 0x03; // SECURITY_CONTEXT_TRACKING | SECURITY_EFFECTIVE_ONLY
  }

  @override
  SmbComNTCreateAndXResponse? getResponse() {
    return super.getResponse() as SmbComNTCreateAndXResponse;
  }

  @override
  SmbComNTCreateAndXResponse initResponse(Configuration config) {
    SmbComNTCreateAndXResponse resp = SmbComNTCreateAndXResponse(config);
    setResponse(resp);
    return resp;
  }

  void addFlags0(int fl) {
    flags0 |= fl;
  }

  @override
  int writeParameterWordsWireFormat(Uint8List dst, int dstIndex) {
    int start = dstIndex;

    dst[dstIndex++] = 0x00;
    // 目标名称字节长度（不含结尾空终止符）。
    namelenIndex = dstIndex;
    dstIndex += 2;
    SMBUtil.writeInt4(flags0, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(rootDirectoryFid, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(desiredAccess, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt8(allocationSize, dst, dstIndex);
    dstIndex += 8;
    SMBUtil.writeInt4(extFileAttributes, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(shareAccess, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(createDisposition, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(createOptions, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(impersonationLevel, dst, dstIndex);
    dstIndex += 4;
    dst[dstIndex++] = securityFlags;

    return dstIndex - start;
  }

  @override
  int writeBytesWireFormat(Uint8List dst, int dstIndex) {
    int n;
    n = writeString(path!, dst, dstIndex);
    SMBUtil.writeInt2(
        (isUseUnicode() ? path!.length * 2 : n), dst, namelenIndex);
    return n;
  }

  @override
  int readParameterWordsWireFormat(Uint8List buffer, int bufferIndex) {
    return 0;
  }

  @override
  int readBytesWireFormat(Uint8List buffer, int bufferIndex) {
    return 0;
  }

  @override
  String toString() {
    return "SmbComNTCreateAndX[${super.toString()},flags=0x${Hexdump.toHexString(flags0, 2)},rootDirectoryFid=$rootDirectoryFid,desiredAccess=0x${Hexdump.toHexString(desiredAccess, 4)},allocationSize=$allocationSize,extFileAttributes=0x${Hexdump.toHexString(extFileAttributes, 4)},shareAccess=0x${Hexdump.toHexString(shareAccess, 4)},createDisposition=0x${Hexdump.toHexString(createDisposition, 4)},createOptions=0x${Hexdump.toHexString(createOptions, 8)},impersonationLevel=0x${Hexdump.toHexString(impersonationLevel, 4)},securityFlags=0x${Hexdump.toHexString(securityFlags, 2)},name=$path]";
  }
}
