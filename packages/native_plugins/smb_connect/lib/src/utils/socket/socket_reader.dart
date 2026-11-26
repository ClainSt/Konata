
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:smb_connect/src/utils/extensions.dart';

abstract class SocketReader {
  final List<Uint8List> _chunks = [];
  int _chunkOffset = 0;
  int _chunkBytes = 0;

  final Socket _socket;
  SocketReader(this._socket);

  int _readedBytes() {
    return _chunkBytes - _chunkOffset;
  }

  Future<int> _readChunkFor(int bytes);

  int available() {
    return _chunkBytes - _chunkOffset;
  }

  Future<int> read(Uint8List buffer, int offset, int length) async {
    var n = await _readChunkFor(length);
    if (n < length) {
      throw "Can't read $length from Socket";
    }
    int count = 0;
    do {
      var chunk = _chunks[0];
      if (chunk.length <= length + _chunkOffset) {
        _chunks.removeAt(0);
        _chunkBytes -= chunk.length;

        var size = chunk.length - _chunkOffset;
        arrayCopy(chunk, _chunkOffset, buffer, offset, size);
        _chunkOffset = 0;
        offset += size;
        length -= size;
        count += size;
      } else {
        arrayCopy(chunk, _chunkOffset, buffer, offset, length);
        count += length;
        _chunkOffset += length;
        length = 0;
      }
    } while (length > 0);
    return count;
  }

  final Uint8List _tmpByte = Uint8List(1);

  Future<int> readByte() async {
    var res = await read(_tmpByte, 0, 1);
    return res > 0 ? _tmpByte.first : -1;
  }

  Future<int> skip(int bytes) async {
    var read = await _readChunkFor(bytes);
    if (read < 0) {
      return -1;
    }
    int length = bytes;
    do {
      var chunk = _chunks[0];
      if (chunk.length <= length + _chunkOffset) {
        _chunks.removeAt(0);
        _chunkBytes -= chunk.length;

        var size = chunk.length - _chunkOffset;
        _chunkOffset = 0;
        length -= size;
      } else {
        _chunkOffset += length;
        length = 0;
      }
    } while (length > 0);
    return bytes;
  }
}

class SocketReader1 extends SocketReader {
  SocketReader1(super._socket);

  //   }
  // }

  @override
  Future<int> _readChunkFor(int bytes) async {
    var readed = _readedBytes();
    if (bytes <= readed) {
      return readed;
    }
    await for (final chunk in _socket) {
      _chunks.add(chunk);
      _chunkBytes += chunk.length;
      readed += chunk.length;
      if (bytes < readed) {
        return readed;
      }
    }
    return -1;
  }
}

class SocketReader2 extends SocketReader {
  final bool debugPrint;
  late StreamSubscription _subscription;
  Object? _failure;
  StackTrace? _failureStack;
  final void Function(Object, StackTrace)? onFailure;

  SocketReader2(super._socket, Function update,
      {this.debugPrint = false, this.onFailure}) {
    _subscription = _socket.listen(
      (event) {
        if (debugPrint) {
          print("SMB 接收字节数：${event.length}");
        }
        _chunks.add(event);
        _chunkBytes += event.length;
        update();
      },
      onDone: () {
        if (debugPrint) {
          print("SMB 读取已关闭");
        }
        // 当输出流正绑定未完成的 flush 时对端可能突然关闭触发 EOF；安全抑制流回调中的关流异常。
        _finish(const SocketException('SMB peer closed'), StackTrace.current);
      },
      onError: (Object error, StackTrace stack) => _finish(error, stack),
    );
  }

  void _finish(Object error, StackTrace stack) {
    if (_failure != null) return;
    _failure = error;
    _failureStack = stack;
    _socket.destroy();
    // 缓冲区残留字节仍可满足进行中的读取请求；仅当缓冲耗尽时向空读立即报错。
    if (available() == 0) onFailure?.call(error, stack);
  }

  void checkReadable() {
    if (available() == 0 && _failure != null) {
      Error.throwWithStackTrace(_failure!, _failureStack!);
    }
  }

  @override
  Future<int> _readChunkFor(int bytes) async {
    var readed = _readedBytes();
    int n = 0;
    while (bytes > readed) {
      if (_failure != null) {
        Error.throwWithStackTrace(_failure!, _failureStack!);
      }
      await Future.delayed(Duration(milliseconds: 1));
      readed = _readedBytes();
      n++;
      if (n >= 3000) {
        throw "Can't read $bytes from Socket!";
      }
    }
    return readed;
  }

  Future close() async {
    _finish(const SocketException('SMB reader closed'), StackTrace.current);
    await _subscription.cancel();
  }
}
