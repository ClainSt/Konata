import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:win32/win32.dart';

/// Windows secure storage backed by the current user's Windows Credential
/// Manager. Credential Manager protects generic credential blobs with DPAPI.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  static const _targetPrefix = 'NipaPlay.Personal.SecureStorage.';

  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  String _target(String key) => '$_targetPrefix$key';

  @override
  Future<void> write({
    required String key,
    required String value,
    required Map<String, String> options,
  }) async {
    final target = _target(key).toNativeUtf16();
    final username = 'NipaPlay Personal'.toNativeUtf16();
    final bytes = Uint8List.fromList(utf8.encode(value));
    final blob = calloc<Uint8>(bytes.length);
    final credential = calloc<CREDENTIAL>();
    try {
      blob.asTypedList(bytes.length).setAll(0, bytes);
      credential.ref
        ..Type = CRED_TYPE_GENERIC
        ..TargetName = PWSTR(target.cast())
        ..UserName = PWSTR(username.cast())
        ..CredentialBlobSize = bytes.length
        ..CredentialBlob = blob
        ..Persist = CRED_PERSIST_LOCAL_MACHINE;
      final result = CredWrite(credential, 0);
      if (!result.value) {
        throw StateError('Windows Credential Manager rejected the credential.');
      }
    } finally {
      calloc.free(credential);
      calloc.free(blob);
      calloc.free(username);
      calloc.free(target);
    }
  }

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) async {
    final target = _target(key).toNativeUtf16();
    final credential = calloc<Pointer<CREDENTIAL>>();
    try {
      final result =
          CredRead(PCWSTR(target.cast()), CRED_TYPE_GENERIC, credential);
      if (!result.value) {
        if (result.error == ERROR_NOT_FOUND) return null;
        throw StateError(
            'Windows Credential Manager could not read the credential.');
      }
      final entry = credential.value.ref;
      return utf8.decode(
        entry.CredentialBlob.asTypedList(entry.CredentialBlobSize),
      );
    } finally {
      if (credential.value != nullptr) CredFree(credential.value.cast());
      calloc.free(credential);
      calloc.free(target);
    }
  }

  @override
  Future<bool> containsKey({
    required String key,
    required Map<String, String> options,
  }) async =>
      await read(key: key, options: options) != null;

  @override
  Future<void> delete({
    required String key,
    required Map<String, String> options,
  }) async {
    final target = _target(key).toNativeUtf16();
    try {
      final result = CredDelete(PCWSTR(target.cast()), CRED_TYPE_GENERIC);
      if (!result.value && result.error != ERROR_NOT_FOUND) {
        throw StateError(
            'Windows Credential Manager could not delete the credential.');
      }
    } finally {
      calloc.free(target);
    }
  }

  @override
  Future<Map<String, String>> readAll({
    required Map<String, String> options,
  }) async =>
      const {};

  @override
  Future<void> deleteAll({
    required Map<String, String> options,
  }) async {
    await delete(
      key: 'cloud_media_tmdb_read_access_token',
      options: options,
    );
  }
}
