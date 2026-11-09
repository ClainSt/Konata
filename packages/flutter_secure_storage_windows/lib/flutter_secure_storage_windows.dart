import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart';

/// Ciphertext stays beside Konata; DPAPI protects it for the Windows account.
/// Legacy Credential Manager values are read only for migration, never changed.
class FlutterSecureStorageWindows extends FlutterSecureStoragePlatform {
  FlutterSecureStorageWindows({this.directory, this.readLegacy});
  final Directory? directory;
  final Future<String?> Function(String)? readLegacy;
  static const _targetPrefix = 'Konata.SecureStorage.';

  static void registerWith() {
    FlutterSecureStoragePlatform.instance = FlutterSecureStorageWindows();
  }

  Future<Directory> get _root async {
    final root = directory ??
        Directory('${(await getApplicationSupportDirectory()).path}/secrets');
    await root.create(recursive: true);
    return root;
  }

  String _name(String key) {
    final encoded = base64Url.encode(utf8.encode(key));
    if (encoded.length > 200) throw ArgumentError('Credential key is too long');
    return '$encoded.bin';
  }

  Uint8List _crypt(Uint8List bytes, {required bool protect}) {
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final buffer = calloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      input.ref
        ..cbData = bytes.length
        ..pbData = buffer;
      // CRYPTPROTECT_UI_FORBIDDEN; never prompt or fall back to plaintext.
      final result = protect
          ? CryptProtectData(input, null, null, null, 1, output)
          : CryptUnprotectData(input, null, null, null, 1, output);
      if (!result.value) {
        throw StateError('Windows could not protect or unlock this credential');
      }
      return Uint8List.fromList(
          output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      buffer.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      if (output.ref.pbData != nullptr) {
        output.ref.pbData
            .asTypedList(output.ref.cbData)
            .fillRange(0, output.ref.cbData, 0);
        LocalFree(HLOCAL(output.ref.pbData.cast()));
      }
      calloc.free(buffer);
      calloc.free(input);
      calloc.free(output);
    }
  }

  Future<void> _save(String key, String? value) async {
    final root = await _root;
    final file = File('${root.path}/${_name(key)}');
    final encoded = _crypt(Uint8List.fromList(utf8.encode(jsonEncode(value))),
        protect: true);
    final staging = await root.createTemp('.write-');
    try {
      final pending = await File('${staging.path}/value')
          .writeAsBytes(encoded, flush: true);
      await pending.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  @override
  Future<void> write(
          {required String key,
          required String value,
          required Map<String, String> options}) =>
      _save(key, value);

  @override
  Future<String?> read(
      {required String key, required Map<String, String> options}) async {
    final root = await _root;
    final file = File('${root.path}/${_name(key)}');
    if (await file.exists()) {
      if (await file.length() > 1024 * 1024) return null;
      Uint8List? plaintext;
      try {
        plaintext = _crypt(await file.readAsBytes(), protect: false);
        final value = jsonDecode(utf8.decode(plaintext));
        return value is String ? value : null;
      } on StateError {
        // DPAPI is account-bound. A moved/corrupt file is unavailable, not a
        // reason to prevent library startup or to replace the original file.
        return null;
      } on FormatException {
        return null;
      } finally {
        plaintext?.fillRange(0, plaintext.length, 0);
      }
    }
    if (await File('${root.path}/legacy-disabled').exists()) return null;
    final value = await (readLegacy ?? _readLegacy)(key);
    // Tombstones also prevent re-importing deleted or absent legacy values.
    await _save(key, value);
    return value;
  }

  Future<String?> _readLegacy(String key) async {
    final target = '$_targetPrefix$key'.toNativeUtf16();
    final credential = calloc<Pointer<CREDENTIAL>>();
    try {
      final result =
          CredRead(PCWSTR(target.cast()), CRED_TYPE_GENERIC, credential);
      if (!result.value) {
        if (result.error == ERROR_NOT_FOUND) return null;
        throw StateError('Could not read legacy Windows credential');
      }
      final entry = credential.value.ref;
      return utf8
          .decode(entry.CredentialBlob.asTypedList(entry.CredentialBlobSize));
    } finally {
      if (credential.value != nullptr) CredFree(credential.value.cast());
      calloc.free(credential);
      calloc.free(target);
    }
  }

  @override
  Future<bool> containsKey(
          {required String key, required Map<String, String> options}) async =>
      await read(key: key, options: options) != null;

  @override
  Future<void> delete(
          {required String key, required Map<String, String> options}) =>
      _save(key, null);

  @override
  Future<Map<String, String>> readAll(
      {required Map<String, String> options}) async {
    final result = <String, String>{};
    await for (final file in (await _root).list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.bin')) continue;
      final name = file.uri.pathSegments.last;
      final key =
          utf8.decode(base64Url.decode(name.substring(0, name.length - 4)));
      final value = await read(key: key, options: options);
      if (value != null) result[key] = value;
    }
    return result;
  }

  @override
  Future<void> deleteAll({required Map<String, String> options}) async {
    final root = await _root;
    await File('${root.path}/legacy-disabled').writeAsString('1', flush: true);
    await for (final file in root.list(followLinks: false)) {
      if (file is File && file.path.endsWith('.bin')) await file.delete();
    }
  }
}
