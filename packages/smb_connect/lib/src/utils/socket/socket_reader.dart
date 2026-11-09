// typedef DataBuffer = List<int>; //Uint8List;

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
      // return -1;
    }
    // int startOffset = offset, startLength = length;
    int count = 0;
    // int remain = length + _chunkOffset;
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
        // remain -= chunk.length;
      } else {
        arrayCopy(chunk, _chunkOffset, buffer, offset, length);
        count += length;
        _chunkOffset += length;
        length = 0;
        // remain -= length;
      }
    } while (length > 0);
    // print(
    //     "read[$startLength]: ${buffer.toHexString2(startOffset, startLength)}");
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
    // int remain = bytes + _chunkOffset;
    do {
      var chunk = _chunks[0];
      if (chunk.length <= length + _chunkOffset) {
        _chunks.removeAt(0);
        _chunkBytes -= chunk.length;

        var size = chunk.length - _chunkOffset;
        _chunkOffset = 0;
        length -= size;
        // remain -= chunk.length;
      } else {
        _chunkOffset += length;
        // remain -= length;
        length = 0;
      }
    } while (length > 0);
    // _chunkOffset = remain * -1;
    return bytes;
  }
}

class SocketReader1 extends SocketReader {
  SocketReader1(super._socket);

  // @override
  // int _readedBytes() {
  //   int res = 0;
  //   for (var chunk in _chunks) {
  //     res += chunk.length;
  //   }
  //   return res - _chunkOffset;
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
        // print("read chunks: ${_chunks.length}, $readed bytes (wait $bytes)");
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
          print("read[${event.length}]: ${event.toHexString()}");
          // print("listen ${event.length}");
        }
        _chunks.add(event);
        _chunkBytes += event.length;
        update();
      },
      onDone: () {
        if (debugPrint) {
          print("Smb Reader closed");
        }
        // Peer EOF can arrive while the output sink is bound to a pending
        // flush. A graceful close would throw from this stream callback.
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
    // Buffered final bytes can still satisfy an already running read. Its
    // parser reports truncation if it needs more; an empty reader fails now.
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
