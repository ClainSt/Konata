import 'dart:ffi';

import 'package:media_kit/ffi/ffi.dart';

/// Builds the NULL-terminated argv required by mpv_command_ret.
/// The caller retains ownership of the strings and must free the returned array.
Pointer<Pointer<Utf8>> allocateScreenshotArguments(
  List<Pointer<Utf8>> arguments, {
  Allocator allocator = calloc,
}) {
  final array = allocator<Pointer<Utf8>>(arguments.length + 1);
  for (var i = 0; i < arguments.length; i++) {
    array[i] = arguments[i];
  }
  array[arguments.length] = nullptr;
  return array;
}
