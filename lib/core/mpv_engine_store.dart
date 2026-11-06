import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Optional Windows libmpv engine, never bundled with the default installer.
///
/// Downloads a pinned upstream release only after user action, verifies both
/// the archive and the extracted DLL, and stages the DLL in app support data.
/// A failed check never replaces Konata's bundled media_kit DLL.
class MpvEngineStore {
  MpvEngineStore({
    this.rootOverride,
    this.archiveHash = releaseArchiveSha256,
    this.dllHash = releaseDllSha256,
  });

  static final instance = MpvEngineStore();
  static const release = '20261105';
  static const releaseArchiveSha256 =
      'f463cc69a7a1610937688b837be9f005cf163c26f2e35e50aec8cc7bde2894b4';
  static const releaseDllSha256 =
      '1d3c4067692048c6cab7735954e2299664b94c098fcdb8f7bc700e6a6a133ed6';
  static const downloadUrl =
      'https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261105/'
      'mpv-dev-x86_64-20261105-git-3138fc8eea.7z';
  static const maxArchiveBytes = 50 * 1024 * 1024;
  static const maxDllBytes = 160 * 1024 * 1024;
  static const _preferenceKey = 'mpv_enhanced_engine_enabled';

  final Directory? rootOverride;
  final String archiveHash;
  final String dllHash;
  Directory? _root;
  bool _loaded = false;
  bool _enabled = false;
  bool _running = false;

  bool get enabled => _enabled;
  bool get activeThisSession => _running;

  Future<Directory> get directory async =>
      _root ??= rootOverride ??
          Directory(p.join(
            (await getApplicationSupportDirectory()).path,
            'mpv-engine',
          ));

  Future<File> get libraryFile async =>
      File(p.join((await directory).path, 'libmpv-2.dll'));

  Future<void> initialize() async {
    if (_loaded) return;
    _enabled =
        (await SharedPreferences.getInstance()).getBool(_preferenceKey) ?? false;
    _loaded = true;
  }

  Future<bool> isInstalledAndValid() async {
    final file = await libraryFile;
    if (!await file.exists()) return false;
    final length = await file.length();
    if (length < 1024 || length > maxDllBytes) return false;
    return (await _sha(file)) == dllHash;
  }

  Future<String?> preferredStartupLibrary() async {
    await initialize();
    if (!_enabled || !Platform.isWindows) return null;
    return await isInstalledAndValid() ? (await libraryFile).path : null;
  }

  /// Only startup code invokes this after NativeLibrary initialization.
  void recordStartupResult({required bool enhanced}) {
    _running = enhanced;
  }

  Future<void> setEnabled(bool enabled) async {
    await initialize();
    if (enabled && (!Platform.isWindows || !await isInstalledAndValid())) {
      throw StateError('Install a verified enhanced engine before enabling it');
    }
    if (!await (await SharedPreferences.getInstance())
        .setBool(_preferenceKey, enabled)) {
      throw const FileSystemException('Failed to persist MPV engine selection');
    }
    _enabled = enabled;
  }

  /// Extracts only the exact pinned DLL, with a capped stream and verified hash.
  /// Never loads or runs the DLL; startup activation is a separate choice.
  Future<void> installFromArchive(File archive) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    if (!await archive.exists() ||
        await archive.length() > maxArchiveBytes ||
        await _sha(archive) != archiveHash) {
      throw const FormatException('Unrecognized MPV archive or checksum');
    }
    final dir = await directory;
    await dir.create(recursive: true);
    if (await isInstalledAndValid()) return;

    final temporary = await Directory.systemTemp.createTemp('ccplayer-mpv-extract-');
    try {
      final extracted = File(p.join(temporary.path, 'libmpv-2.dll'));
      final process = await Process.start(
        'tar',
        ['-xOf', archive.path, 'libmpv-2.dll'],
        runInShell: false,
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = extracted.openWrite();
      var length = 0;
      try {
        await for (final chunk in process.stdout) {
          length += chunk.length;
          if (length > maxDllBytes) {
            process.kill();
            throw const FormatException('Extracted DLL is too large');
          }
          output.add(chunk);
        }
        await output.flush();
      } finally {
        await output.close();
      }
      final code = await process.exitCode;
      if (code != 0) {
        throw FormatException('Archive extraction failed: ${await errors}');
      }
      if (length < 1024 || await _sha(extracted) != dllHash) {
        throw const FormatException('Extracted DLL checksum mismatch');
      }

      final destination = await libraryFile;
      final staged = File(p.join(dir.path, 'libmpv-2.dll.new'));
      if (await staged.exists()) await staged.delete();
      try {
        await extracted.copy(staged.path);
        if (await _sha(staged) != dllHash) {
          throw const FormatException('Staged DLL checksum mismatch');
        }
        File? previous;
        if (await destination.exists()) {
          previous = File(p.join(
            dir.path,
            'libmpv-2.dll.previous-${DateTime.now().toUtc().microsecondsSinceEpoch}',
          ));
          await destination.rename(previous.path);
        }
        try {
          await staged.rename(destination.path);
        } catch (_) {
          if (previous != null && await previous.exists()) {
            await previous.rename(destination.path);
          }
          rethrow;
        }
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    } finally {
      try {
        await temporary.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Explicit user-triggered download. Callers can display byte progress.
  Future<void> downloadAndInstall({
    void Function(int received, int? total)? onProgress,
  }) async {
    if (!Platform.isWindows) throw UnsupportedError('Windows only');
    final temp = await Directory.systemTemp.createTemp('ccplayer-mpv-download-');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final request = await client.getUrl(Uri.parse(downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'Konata/0.1.0');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('Download HTTP ${response.statusCode}');
      }
      final archive = File(p.join(temp.path, 'enhanced.7z'));
      final sink = archive.openWrite();
      var received = 0;
      try {
        await for (final bytes in response.timeout(const Duration(seconds: 40))) {
          received += bytes.length;
          if (received > maxArchiveBytes) {
            throw const FormatException('Downloaded archive is too large');
          }
          sink.add(bytes);
          onProgress?.call(
            received,
            response.contentLength > 0 ? response.contentLength : null,
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      await installFromArchive(archive);
    } finally {
      client.close(force: true);
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<String> _sha(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}
