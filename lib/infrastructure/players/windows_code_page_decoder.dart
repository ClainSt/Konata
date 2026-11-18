import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../domain/playback/cue_and_lrc_parser.dart';

typedef _MultiByteToWideCharNative =
    Int32 Function(
      Uint32 codePage,
      Uint32 dwFlags,
      Pointer<Uint8> lpMultiByteStr,
      Int32 cbMultiByte,
      Pointer<Uint16> lpWideCharStr,
      Int32 cchWideChar,
    );
typedef _MultiByteToWideCharDart =
    int Function(
      int codePage,
      int dwFlags,
      Pointer<Uint8> lpMultiByteStr,
      int cbMultiByte,
      Pointer<Uint16> lpWideCharStr,
      int cchWideChar,
    );

/// 基于 Windows `kernel32.dll` (`MultiByteToWideChar`) 的高精度 CP932/CP936 解码器。
///
/// 仅由 Windows 组装根注入，确保 Android 入口静态导入图零 `kernel32.dll` 残留。
class WindowsCodePageDecoder {
  WindowsCodePageDecoder._();

  static _MultiByteToWideCharDart? _cachedFn;

  /// 将 Shift-JIS (CP932) 或 GBK (CP936) 原始字节转换为 Unicode 字符串。
  static String? decode(List<int> bytes, LegacyTextEncoding encoding) {
    if (!Platform.isWindows || bytes.isEmpty) return null;
    try {
      final fn = _cachedFn ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
            'MultiByteToWideChar',
          );
      final codePage = encoding == LegacyTextEncoding.shiftJis ? 932 : 936;
      final src = calloc<Uint8>(bytes.length);
      try {
        src.asTypedList(bytes.length).setAll(0, bytes);
        final wideLen = fn(codePage, 0, src, bytes.length, nullptr, 0);
        if (wideLen <= 0) return null;
        final dst = calloc<Uint16>(wideLen);
        try {
          final written = fn(codePage, 0, src, bytes.length, dst, wideLen);
          if (written <= 0) return null;
          return String.fromCharCodes(dst.asTypedList(written));
        } finally {
          calloc.free(dst);
        }
      } finally {
        calloc.free(src);
      }
    } catch (_) {
      return null;
    }
  }
}
