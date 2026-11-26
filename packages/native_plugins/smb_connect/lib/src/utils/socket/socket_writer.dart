import 'dart:io';
import 'dart:typed_data';

class SocketWriter {
  final bool debugPrint;
  final Socket _socket;

  SocketWriter(this._socket, {this.debugPrint = false});

  int lastWrite = 0;

  void write(Uint8List buffer, int offset, int length) {
    var buf = Uint8List.view(buffer.buffer, offset, length);
    _socket.add(buf);
    lastWrite += buf.length;
    if (debugPrint) {
      print("SMB 发送字节数：$length");
    }
  }

  Future<void> flush() async {
    if (debugPrint) {
      print("SMB 刷新字节数：$lastWrite");
    }
    await _socket.flush();
    lastWrite = 0;
  }
}
