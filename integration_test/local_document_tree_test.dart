import 'dart:developer' as developer;
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ccplayer/core/local_media.dart';
import 'package:file_picker/file_picker.dart';
import 'package:android_file_picker/android_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit/src/player/native/utils/android_content_uri_provider.dart';
// Test-only VM service access forces collection to check the native finalizer.
// ignore: depend_on_referenced_packages
import 'package:vm_service/vm_service_io.dart';
// ignore: depend_on_referenced_packages
import 'package:ffi/ffi.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'granted document descriptors close and respect live Media references',
    (tester) async {
      MediaKit.ensureInitialized();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Select KonataValidation20261107')),
        ),
      );
      debugPrint('SAF_PICKER_READY');
      final root = await FilePicker.getDirectoryPath(
        androidOptions: const FilePickerAndroidOptions(
          safOptions: AndroidSAFOptions(grant: AndroidSAFGrant.lifetime),
        ),
      );
      expect(root, startsWith('content://'));
      final listing = await LocalMedia.list(root!);
      expect(listing.any((file) => file.name == '86-E01.mkv'), isTrue);
      final uri = await LocalMedia.uri(root, '86-E01.mkv');
      final libc = DynamicLibrary.open('libc.so');
      final read = libc
          .lookupFunction<
            IntPtr Function(Int32, Pointer<Uint8>, UintPtr),
            int Function(int, Pointer<Uint8>, int)
          >('read');
      final fcntl = libc
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'fcntl',
          );
      bool isOpen(int fd) => fcntl(fd, 1) >= 0; // F_GETFD; no extra vararg.
      for (var round = 0; round < 16; round++) {
        final fd = AndroidContentUriProvider.openFileDescriptorSync(uri);
        expect(fd, greaterThanOrEqualTo(0));
        // Read the granted descriptor itself. Reopening /proc/self/fd would
        // discard SAF's grant and is denied by Android scoped storage.
        final bytes = calloc<Uint8>(4);
        try {
          expect(read(fd, bytes, 4), 4);
          expect(bytes.asTypedList(4), [0x1a, 0x45, 0xdf, 0xa3]);
        } finally {
          calloc.free(bytes);
        }
        if (round.isEven) {
          await AndroidContentUriProvider.closeFileDescriptor('fd://$fd');
        } else {
          AndroidContentUriProvider.closeFileDescriptorSync('fd://$fd');
        }
        expect(isOpen(fd), isFalse);
      }
      final info = await developer.Service.getInfo();
      debugPrint('SAF_VM_PORT ${info.serverWebSocketUri!.port}');
      final service = await () async {
        for (var i = 0; i < 16; i++) {
          try {
            return await vmServiceConnectUri(
              info.serverWebSocketUri.toString(),
            );
          } on SocketException {
            if (i == 15) rethrow;
            await Future<void>.delayed(const Duration(milliseconds: 500));
          }
        }
        throw StateError('VM service unavailable');
      }();
      addTearDown(service.dispose);
      final isolate = developer.Service.getIsolateId(Isolate.current)!;
      Future<void> collect() async {
        await service.getAllocationProfile(isolate, gc: true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      Future<WeakReference<Media>> temporaryReference() async =>
          WeakReference(Media(uri));
      Future<({String uri, WeakReference<Media> weak, String target})>
      releaseOneWhileKeepingAnother() async {
        final kept = Media(uri);
        final other = await temporaryReference();
        for (var i = 0; i < 20; i++) {
          await collect();
          if (other.target == null && Media.ref[kept.uri] == 1) break;
        }
        expect(other.target, isNull);
        expect(Media.ref[kept.uri], 1);
        expect(isOpen(int.parse(Uri.parse(kept.uri).authority)), isTrue);
        return (
          uri: kept.uri,
          weak: WeakReference(kept),
          target: Link(
            '/proc/self/fd/${Uri.parse(kept.uri).authority}',
          ).targetSync(),
        );
      }

      final released = await releaseOneWhileKeepingAnother();
      final descriptor = int.parse(Uri.parse(released.uri).authority);
      bool sameFileOpen() {
        try {
          return Link('/proc/self/fd/$descriptor').targetSync() ==
              released.target;
        } on FileSystemException {
          return false;
        }
      }

      for (var i = 0; i < 20; i++) {
        await collect();
        if (released.weak.target == null && !sameFileOpen()) break;
      }
      debugPrint(
        'SAF_FINAL_REFERENCE collected=${released.weak.target == null} refs=${Media.ref[released.uri]} open=${sameFileOpen()}',
      );
      expect(released.weak.target, isNull);
      expect(sameFileOpen(), isFalse);
      debugPrint(
        'SAF_DESCRIPTOR_PASS 16 reopen/close cycles; shared Media lifetime; final release',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
