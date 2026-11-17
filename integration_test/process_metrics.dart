import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 读取当前进程累计处理器时间，避免以墙钟等待时间代替实际处理器开销。
int processCpuMicroseconds() {
  if (Platform.isWindows) {
    final library = DynamicLibrary.open('kernel32.dll');
    final current = library.lookupFunction<Pointer<Void> Function(),
        Pointer<Void> Function()>('GetCurrentProcess');
    final times = library.lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>, Pointer<Uint64>),
        int Function(Pointer<Void>, Pointer<Uint64>, Pointer<Uint64>,
            Pointer<Uint64>, Pointer<Uint64>)>('GetProcessTimes');
    final values = calloc<Uint64>(4);
    try {
      if (times(current(), values, values + 1, values + 2, values + 3) == 0) {
        throw StateError('无法读取进程处理器时间');
      }
      return (values[2] + values[3]) ~/ 10;
    } finally {
      calloc.free(values);
    }
  }
  if (Platform.isAndroid) {
    final clock = DynamicLibrary.open('libc.so')
        .lookupFunction<Int64 Function(), int Function()>('clock');
    final value = clock();
    if (value < 0) throw StateError('无法读取进程处理器时间');
    return value;
  }
  throw UnsupportedError('尚未实现当前平台的处理器采集');
}
