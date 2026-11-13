import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/ffi/ffi.dart';
import 'package:media_kit/src/player/native/utils/screenshot_arguments.dart';

/// Non-zero memory ensures termination cannot accidentally rely on calloc.
class _CheckedAllocator implements Allocator {
  final allocations = <int, int>{};
  int? lastByteCount;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    lastByteCount = byteCount;
    final memory = calloc.allocate<T>(byteCount, alignment: alignment);
    memory.cast<Uint8>().asTypedList(byteCount).fillRange(0, byteCount, 0xa5);
    allocations[memory.address] = byteCount;
    return memory;
  }

  @override
  void free(Pointer pointer) {
    expect(allocations.remove(pointer.address), isNotNull);
    calloc.free(pointer);
  }
}

void main() {
  for (final args in <List<String>>[
    ['screenshot-raw', 'video'],
    ['screenshot-raw', 'subtitles'],
    [],
    ['截图', 'x' * 256],
  ]) {
    test(
      'screenshot argv follows pointer ABI for ${args.map((s) => s.length).toList()}',
      () {
        final allocator = _CheckedAllocator();
        final strings = args.map((s) => s.toNativeUtf8()).toList();
        try {
          for (var repeat = 0; repeat < 3; repeat++) {
            final argv = allocateScreenshotArguments(
              strings,
              allocator: allocator,
            );
            try {
              // Assert allocated capacity BEFORE reading the terminator slot.
              expect(
                allocator.lastByteCount,
                (args.length + 1) * sizeOf<Pointer<Utf8>>(),
              );
              for (var i = 0; i < args.length; i++) {
                expect(argv[i], strings[i]);
                expect(argv[i].toDartString(), args[i]);
              }
              expect(argv[args.length], nullptr);
            } finally {
              allocator.free(argv);
            }
            expect(allocator.allocations, isEmpty);
            // Freeing argv does not consume the caller's strings.
            expect(strings.map((p) => p.toDartString()).toList(), args);
          }
        } finally {
          strings.forEach(calloc.free);
        }
      },
    );
  }
}
