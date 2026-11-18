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

/// 基于 Windows `kernel32.dll` (`MultiByteToWideChar`) 的高精度 CP932 / GB18030(CP936) / Big5(CP950) 解码器。
///
/// 仅由 Windows 组装根注入，确保 Android 入口静态导入图零 `kernel32.dll` 残留。
class WindowsCodePageDecoder {
  WindowsCodePageDecoder._();

  static _MultiByteToWideCharDart? _cachedFn;

  /// 将 Shift-JIS (CP932)、GB18030/GBK (CP54936/CP936) 或 Big5 (CP950) 原始字节转换为 Unicode 字符串。
  static String? decode(List<int> bytes, LegacyTextEncoding encoding) {
    if (!Platform.isWindows || bytes.isEmpty) return null;
    try {
      final fn = _cachedFn ??= DynamicLibrary.open('kernel32.dll')
          .lookupFunction<_MultiByteToWideCharNative, _MultiByteToWideCharDart>(
            'MultiByteToWideChar',
          );
      final primaryCodePage = switch (encoding) {
        LegacyTextEncoding.shiftJis => 932,
        LegacyTextEncoding.gbk => 54936,
        LegacyTextEncoding.big5 => 950,
      };
      final decoded = _decodeWithCodePage(fn, bytes, primaryCodePage);
      if (decoded != null) return decoded;
      if (encoding == LegacyTextEncoding.gbk) {
        return _decodeWithCodePage(fn, bytes, 936);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static String? _decodeWithCodePage(
    _MultiByteToWideCharDart fn,
    List<int> bytes,
    int codePage,
  ) {
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
  }
}
