import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateFileWNative =
    IntPtr Function(
      Pointer<Utf16> lpFileName,
      Uint32 dwDesiredAccess,
      Uint32 dwShareMode,
      Pointer<Void> lpSecurityAttributes,
      Uint32 dwCreationDisposition,
      Uint32 dwFlagsAndAttributes,
      IntPtr hTemplateFile,
    );

/// Win32 `CreateFileW` Dart 函数签名。
typedef Win32CreateFileWDart =
    int Function(
      Pointer<Utf16> lpFileName,
      int dwDesiredAccess,
      int dwShareMode,
      Pointer<Void> lpSecurityAttributes,
      int dwCreationDisposition,
      int dwFlagsAndAttributes,
      int hTemplateFile,
    );

typedef _PeekNamedPipeNative =
    Int32 Function(
      IntPtr hNamedPipe,
      Pointer<Void> lpBuffer,
      Uint32 nBufferSize,
      Pointer<Uint32> lpBytesRead,
      Pointer<Uint32> lpTotalBytesAvail,
      Pointer<Uint32> lpBytesLeftThisMessage,
    );

/// Win32 `PeekNamedPipe` Dart 函数签名。
typedef Win32PeekNamedPipeDart =
    int Function(
      int hNamedPipe,
      Pointer<Void> lpBuffer,
      int nBufferSize,
      Pointer<Uint32> lpBytesRead,
      Pointer<Uint32> lpTotalBytesAvail,
      Pointer<Uint32> lpBytesLeftThisMessage,
    );

typedef _ReadFileNative =
    Int32 Function(
      IntPtr hFile,
      Pointer<Uint8> lpBuffer,
      Uint32 nNumberOfBytesToRead,
      Pointer<Uint32> lpNumberOfBytesRead,
      Pointer<Void> lpOverlapped,
    );

/// Win32 `ReadFile` Dart 函数签名。
typedef Win32ReadFileDart =
    int Function(
      int hFile,
      Pointer<Uint8> lpBuffer,
      int nNumberOfBytesToRead,
      Pointer<Uint32> lpNumberOfBytesRead,
      Pointer<Void> lpOverlapped,
    );

typedef _WriteFileNative =
    Int32 Function(
      IntPtr hFile,
      Pointer<Uint8> lpBuffer,
      Uint32 nNumberOfBytesToWrite,
      Pointer<Uint32> lpNumberOfBytesWritten,
      Pointer<Void> lpOverlapped,
    );

/// Win32 `WriteFile` Dart 函数签名。
typedef Win32WriteFileDart =
    int Function(
      int hFile,
      Pointer<Uint8> lpBuffer,
      int nNumberOfBytesToWrite,
      Pointer<Uint32> lpNumberOfBytesWritten,
      Pointer<Void> lpOverlapped,
    );

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);

/// Win32 `CloseHandle` Dart 函数签名。
typedef Win32CloseHandleDart = int Function(int hObject);

/// Win32 `EnumWindows` 原生回调签名。
typedef Win32EnumWindowsProcNative = Int32 Function(IntPtr hWnd, IntPtr lParam);
typedef _EnumWindowsNative =
    Int32 Function(
      Pointer<NativeFunction<Win32EnumWindowsProcNative>> lpEnumFunc,
      IntPtr lParam,
    );

/// Win32 `EnumWindows` Dart 函数签名。
typedef Win32EnumWindowsDart =
    int Function(
      Pointer<NativeFunction<Win32EnumWindowsProcNative>> lpEnumFunc,
      int lParam,
    );

typedef _GetWindowThreadProcessIdNative =
    Uint32 Function(IntPtr hWnd, Pointer<Uint32> lpdwProcessId);

/// Win32 `GetWindowThreadProcessId` Dart 函数签名。
typedef Win32GetWindowThreadProcessIdDart =
    int Function(int hWnd, Pointer<Uint32> lpdwProcessId);

typedef _GetClassNameWNative =
    Int32 Function(IntPtr hWnd, Pointer<Utf16> lpClassName, Int32 nMaxCount);

/// Win32 `GetClassNameW` Dart 函数签名。
typedef Win32GetClassNameWDart =
    int Function(int hWnd, Pointer<Utf16> lpClassName, int nMaxCount);

typedef _IsWindowNative = Int32 Function(IntPtr hWnd);

/// Win32 `IsWindow` Dart 函数签名。
typedef Win32IsWindowDart = int Function(int hWnd);

typedef _SendMessageWNative =
    IntPtr Function(IntPtr hWnd, Uint32 msg, IntPtr wParam, IntPtr lParam);

/// Win32 `SendMessageW` Dart 函数签名。
typedef Win32SendMessageWDart =
    int Function(int hWnd, int msg, int wParam, int lParam);

/// `EnumWindows` 单次遍历的原生局部上下文结构体（经 `lParam` 指针传入回调，零全局可变静态状态）。
final class _Win32EnumWindowsContext extends Struct {
  @Uint32()
  external int targetPid;

  @Int32()
  external int count;

  @Int32()
  external int capacity;

  external Pointer<IntPtr> handles;
}

bool _isPotPlayerMainWindowClass(String cls) {
  return cls == 'PotPlayer64' || cls == 'PotPlayer';
}

int _win32EnumWindowsCallback(int hWnd, int lParam) {
  if (lParam == 0) {
    return 0;
  }
  final bindings = Win32FfiBindings.instance;
  if (bindings == null) {
    return 0;
  }

  final cls = bindings.getWindowClassName(hWnd);
  if (!_isPotPlayerMainWindowClass(cls)) {
    return 1;
  }

  final ctxPtr = Pointer<_Win32EnumWindowsContext>.fromAddress(lParam);
  final targetPid = ctxPtr.ref.targetPid;
  if (targetPid > 0 && bindings.getWindowProcessId(hWnd) != targetPid) {
    return 1;
  }

  final count = ctxPtr.ref.count;
  if (count < ctxPtr.ref.capacity) {
    ctxPtr.ref.handles[count] = hWnd;
    ctxPtr.ref.count = count + 1;
  }
  return 1;
}

/// 纯 `dart:ffi` + `package:ffi` Windows 命名管道与 `user32` 窗口控制底层封装。
///
/// 仅在 Windows 平台按需打开 `kernel32.dll` 与 `user32.dll`，保持其余平台零原生崩溃。
class Win32FfiBindings {
  Win32FfiBindings._(DynamicLibrary kernel32, DynamicLibrary user32)
    : createFileW = kernel32
          .lookupFunction<_CreateFileWNative, Win32CreateFileWDart>(
            'CreateFileW',
          ),
      peekNamedPipe = kernel32
          .lookupFunction<_PeekNamedPipeNative, Win32PeekNamedPipeDart>(
            'PeekNamedPipe',
          ),
      readFile = kernel32.lookupFunction<_ReadFileNative, Win32ReadFileDart>(
        'ReadFile',
      ),
      writeFile = kernel32.lookupFunction<_WriteFileNative, Win32WriteFileDart>(
        'WriteFile',
      ),
      closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, Win32CloseHandleDart>(
            'CloseHandle',
          ),
      enumWindows = user32
          .lookupFunction<_EnumWindowsNative, Win32EnumWindowsDart>(
            'EnumWindows',
          ),
      getWindowThreadProcessId = user32
          .lookupFunction<
            _GetWindowThreadProcessIdNative,
            Win32GetWindowThreadProcessIdDart
          >('GetWindowThreadProcessId'),
      getClassNameW = user32
          .lookupFunction<_GetClassNameWNative, Win32GetClassNameWDart>(
            'GetClassNameW',
          ),
      isWindow = user32.lookupFunction<_IsWindowNative, Win32IsWindowDart>(
        'IsWindow',
      ),
      sendMessageW = user32
          .lookupFunction<_SendMessageWNative, Win32SendMessageWDart>(
            'SendMessageW',
          );

  /// 当前平台惰性只读 Win32 FFI 绑定（非 Windows 平台返回 `null`）。
  static final Win32FfiBindings? instance = Platform.isWindows
      ? Win32FfiBindings._(
          DynamicLibrary.open('kernel32.dll'),
          DynamicLibrary.open('user32.dll'),
        )
      : null;

  /// Win32 `GENERIC_READ | GENERIC_WRITE` 访问权限掩码。
  static const int genericReadWrite = 0x80000000 | 0x40000000;

  /// Win32 `OPEN_EXISTING` 创建模式。
  static const int openExisting = 3;

  final Win32CreateFileWDart createFileW;
  final Win32PeekNamedPipeDart peekNamedPipe;
  final Win32ReadFileDart readFile;
  final Win32WriteFileDart writeFile;
  final Win32CloseHandleDart closeHandle;
  final Win32EnumWindowsDart enumWindows;
  final Win32GetWindowThreadProcessIdDart getWindowThreadProcessId;
  final Win32GetClassNameWDart getClassNameW;
  final Win32IsWindowDart isWindow;
  final Win32SendMessageWDart sendMessageW;

  static final Pointer<NativeFunction<Win32EnumWindowsProcNative>> _enumPtr =
      Pointer.fromFunction<Win32EnumWindowsProcNative>(
        _win32EnumWindowsCallback,
        0,
      );

  /// 读取给定窗口句柄对应的宿主进程 PID。
  int getWindowProcessId(int hWnd) {
    final pidPtr = calloc<Uint32>();
    try {
      getWindowThreadProcessId(hWnd, pidPtr);
      return pidPtr.value;
    } finally {
      calloc.free(pidPtr);
    }
  }

  /// 读取给定窗口句柄的 Win32 窗口类名（如 `PotPlayer64`）。
  String getWindowClassName(int hWnd) {
    const maxLen = 128;
    final buf = calloc<Uint16>(maxLen);
    try {
      final copied = getClassNameW(hWnd, buf.cast<Utf16>(), maxLen);
      if (copied <= 0) {
        return '';
      }
      return buf.cast<Utf16>().toDartString(length: copied);
    } finally {
      calloc.free(buf);
    }
  }

  /// 枚举指定 PID（或回退全局）下全部真实的 `PotPlayer64` / `PotPlayer` 顶层主窗口句柄。
  List<int> findPotPlayerWindows({required int targetPid}) {
    const maxHandles = 64;
    final handlesBuf = calloc<IntPtr>(maxHandles);
    final ctx = calloc<_Win32EnumWindowsContext>();
    try {
      ctx.ref.capacity = maxHandles;
      ctx.ref.handles = handlesBuf;

      if (targetPid > 0) {
        ctx.ref.targetPid = targetPid;
        ctx.ref.count = 0;
        enumWindows(_enumPtr, ctx.address);
        if (ctx.ref.count > 0) {
          return List<int>.generate(
            ctx.ref.count,
            (i) => handlesBuf[i],
            growable: false,
          );
        }
      }

      ctx.ref.targetPid = 0;
      ctx.ref.count = 0;
      enumWindows(_enumPtr, ctx.address);
      return List<int>.generate(
        ctx.ref.count,
        (i) => handlesBuf[i],
        growable: false,
      );
    } finally {
      calloc.free(ctx);
      calloc.free(handlesBuf);
    }
  }

  /// 定位指定 PID（或回退匹配 PotPlayer 主窗口类）对应的首个 PotPlayer 主窗口句柄。
  int findPotPlayerWindow({required int targetPid}) {
    final windows = findPotPlayerWindows(targetPid: targetPid);
    return windows.isNotEmpty ? windows.first : 0;
  }
}
