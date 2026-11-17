import 'dart:typed_data';

import 'package:smb_connect/src/configuration.dart';
import 'package:smb_connect/src/encodable.dart';
import 'package:smb_connect/src/connect/impl/smb2/server_message_block2.dart';
import 'package:smb_connect/src/connect/impl/smb2/smb2_constants.dart';
import 'package:smb_connect/src/utils/extensions.dart';

import '../../../smb_util.dart';
import '../request_with_file_id.dart';
import '../server_message_block2_request.dart';
import 'smb2_ioctl_response.dart';

/// MS-SMB2 2.2.31 节 IOCTL 控制请求报文结构定义。
class Smb2IoctlRequest extends ServerMessageBlock2Request<Smb2IoctlResponse>
    implements RequestWithFileId {
  static const int FSCTL_PIPE_WAIT = 0x00110018;
  static const int FSCTL_PIPE_TRANSCEIVE = 0x0011C017;
  static const int FSCTL_LRM_REQUEST_RESILENCY = 0x001401D4;
  static const int FSCTL_QUERY_NETWORK_INTERFACE_INFO = 0x001401FC;
  static const int FSCTL_SET_REPARSE_POINT = 0x000900A4;
  static const int FSCTL_DFS_GET_REFERRALS_EX = 0x000601B0;
  static const int FSCTL_FILE_LEVEL_TRIM = 0x00098208;

  static const int SMB2_O_IOCTL_IS_FSCTL = 0x1;

  Uint8List fileId;
  final int controlCode;
  Uint8List? outputBuffer;
  final int maxOutputResponse;
  final int maxInputResponse;
  final int flags2;
  final Encodable? inputData;
  final Encodable? outputData;

  Smb2IoctlRequest(
    super.config,
    this.controlCode, {
    Uint8List? fileId,
    this.outputBuffer,
    this.maxInputResponse = 0,
    int? maxOutputResponse,
    this.flags2 = 0,
    this.inputData,
    this.outputData,
  })  : fileId = fileId ?? Smb2Constants.UNSPECIFIED_FILEID,
        maxOutputResponse = maxOutputResponse ??
            outputBuffer?.length ??
            (config.transactionBufferSize & ~0x7),
        super(command: Smb2Constants.SMB2_IOCTL);

  @override
  void setFileId(Uint8List nextFileId) {
    fileId = nextFileId;
  }

  @override
  Smb2IoctlResponse createResponse(
      Configuration config, ServerMessageBlock2Request<Smb2IoctlResponse> req) {
    return Smb2IoctlResponse(config,
        outputBuffer: outputBuffer, ctlCode: controlCode);
  }

  @override
  int size() {
    int size = Smb2Constants.SMB2_HEADER_LENGTH + 56;
    int dataLength = 0;
    if (inputData != null) {
      dataLength += inputData!.size();
    }
    if (outputData != null) {
      dataLength += outputData!.size();
    }
    return ServerMessageBlock2.size8(size + dataLength);
  }

  @override
  int writeBytesWireFormat(Uint8List dst, int dstIndex) {
    int start = dstIndex;
    SMBUtil.writeInt2(57, dst, dstIndex);
    dstIndex += 4;
    SMBUtil.writeInt4(controlCode, dst, dstIndex);
    dstIndex += 4;
    byteArrayCopy(
        src: fileId, srcOffset: 0, dst: dst, dstOffset: dstIndex, length: 16);
    dstIndex += 16;

    int inputOffsetOffset = dstIndex;
    dstIndex += 4;
    int inputLengthOffset = dstIndex;
    dstIndex += 4;
    SMBUtil.writeInt4(maxInputResponse, dst, dstIndex);
    dstIndex += 4;

    int outputOffsetOffset = dstIndex;
    dstIndex += 4;
    int outputLengthOffset = dstIndex;
    dstIndex += 4;
    SMBUtil.writeInt4(maxOutputResponse, dst, dstIndex);
    dstIndex += 4;

    SMBUtil.writeInt4(flags2, dst, dstIndex);
    dstIndex += 4;
    dstIndex += 4; // Reserved2

    if (inputData != null) {
      SMBUtil.writeInt4(dstIndex - getHeaderStart(), dst, inputOffsetOffset);
      int len = inputData!.encode(dst, dstIndex);
      SMBUtil.writeInt4(len, dst, inputLengthOffset);
      dstIndex += len;
    } else {
      SMBUtil.writeInt4(0, dst, inputOffsetOffset);
      SMBUtil.writeInt4(0, dst, inputLengthOffset);
    }

    if (outputData != null) {
      SMBUtil.writeInt4(dstIndex - getHeaderStart(), dst, outputOffsetOffset);
      int len = outputData!.encode(dst, dstIndex);
      SMBUtil.writeInt4(len, dst, outputLengthOffset);
      dstIndex += len;
    } else {
      SMBUtil.writeInt4(0, dst, outputOffsetOffset);
      SMBUtil.writeInt4(0, dst, outputLengthOffset);
    }

    return dstIndex - start;
  }

  @override
  int readBytesWireFormat(Uint8List buffer, int bufferIndex) {
    return 0;
  }
}
