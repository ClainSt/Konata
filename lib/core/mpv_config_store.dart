import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:android_file_picker/android_file_picker.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit_video/media_kit_video.dart';

enum VideoDecodeMode { automatic, hardwarePreferred, software, custom }

/// App-owned native MPV profile. Never writes the system-wide mpv directory.
class MpvConfigStore {
  MpvConfigStore({Directory? rootOverride}) : _override = rootOverride;
  static final instance = MpvConfigStore();
  static const maxConfigBytes = 256 * 1024;

  final Directory? _override;
  Directory? _root;
  bool _initialized = false;
  bool _enabled = false;
  String? _folder;
  String? get externalFolder => _folder;
  static const _names = ['mpv.conf', 'input.conf'];
  static const _channel = MethodChannel('ccplayer/mpv_profile');
  VideoDecodeMode _decodeMode = VideoDecodeMode.automatic;
  VideoDecodeMode get decodeMode => _decodeMode;
  VideoControllerConfiguration get videoConfiguration =>
      VideoControllerConfiguration(
        hwdec: switch (_decodeMode) {
          VideoDecodeMode.software => 'no',
          VideoDecodeMode.hardwarePreferred =>
            Platform.isAndroid ? 'auto-safe' : 'auto',
          _ => null,
        },
      );

  bool get enabled => _enabled;

  Future<Directory> get directory async => _root ??=
      _override ??
      Directory(p.join((await getApplicationSupportDirectory()).path, 'mpv'));

  PlayerConfiguration get playerConfiguration => configurationFor(
    _initialized && _enabled && _folder == null ? _root : null,
  );

  PlayerConfiguration configurationFor(Directory? profile) =>
      PlayerConfiguration(
        libass: Platform.isWindows || Platform.isAndroid,
        mpvConfigurationDirectory: profile?.path,
        mpvRespectRenderingConfiguration:
            profile != null && _decodeMode == VideoDecodeMode.custom,
      );

  Future<void> initialize() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool('mpv_config_enabled') ?? false;
    _folder = prefs.getString('mpv_external_folder');
    _decodeMode = VideoDecodeMode.values.firstWhere(
      (mode) => mode.name == prefs.getString('video_decode_mode'),
      orElse: () => VideoDecodeMode.automatic,
    );
    final dir = await directory;
    await dir.create(recursive: true);
    for (final name in _names) {
      final file = File(p.join(dir.path, name));
      if (!await file.exists()) {
        await file.writeAsString(
          '# Konata native MPV configuration\n'
          '# Empty by default: existing player behavior is unchanged.\n'
          '# Changes apply when the next player opens.\n',
          flush: true,
        );
      }
    }
    _initialized = true;
  }

  Future<Map<String, Uint8List>> _readFolder(String folder) async {
    if (Platform.isAndroid) {
      final files = await _channel.invokeMapMethod<String, Uint8List>('read', {
        'folder': folder,
        'limit': maxConfigBytes,
      });
      if (files == null) throw const FileSystemException('Folder unavailable');
      for (final bytes in files.values) {
        utf8.decode(bytes);
      }
      return files;
    }
    if (!await Directory(folder).exists()) {
      throw const FileSystemException('Folder unavailable');
    }
    final files = <String, Uint8List>{};
    for (final name in _names) {
      final file = File(p.join(folder, name));
      final type = await FileSystemEntity.type(file.path);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) throw FormatException(name);
      final input = await file.open();
      try {
        final bytes = await input.read(maxConfigBytes + 1);
        if (bytes.length > maxConfigBytes) {
          throw FormatException('Too large: $name');
        }
        utf8.decode(bytes);
        files[name] = bytes;
      } finally {
        await input.close();
      }
    }
    return files;
  }

  Future<void> _release(String? folder) async {
    if (folder == null || !Platform.isAndroid) return;
    await AndroidSAFHandle(
      accessMode: AndroidSAFAccessMode.readOnly,
      uri: Uri.parse(folder),
    ).releaseGrant();
  }

  Future<void> selectFolder(String? folder) async {
    await initialize();
    final previous = _folder;
    final prefs = await SharedPreferences.getInstance();
    try {
      if (folder != null) await _readFolder(folder);
      final ok = folder == null
          ? await prefs.remove('mpv_external_folder')
          : await prefs.setString('mpv_external_folder', folder);
      if (!ok) throw const FileSystemException('Could not save folder');
    } catch (_) {
      if (previous != folder) await _release(folder);
      rethrow;
    }
    _folder = folder;
    if (previous != folder) await _release(previous);
  }

  // libmpv expects filesystem paths even for Android document providers.
  // Give each player its own immutable pair and dispose it with that player.
  Future<Directory> snapshot(String folder) async {
    final files = await _readFolder(folder);
    final cache = _override ?? await getTemporaryDirectory();
    final profiles = Directory(p.join(cache.path, 'ccplayer-mpv-profiles'));
    await profiles.create(recursive: true);
    // Recover abandoned snapshots after a process exit.
    final cutoff = DateTime.now().subtract(const Duration(days: 1));
    await for (final entry in profiles.list(followLinks: false)) {
      if (entry is Directory &&
          p.basename(entry.path).startsWith('play-') &&
          (await entry.stat()).modified.isBefore(cutoff)) {
        try {
          await entry.delete(recursive: true);
        } on FileSystemException {
          /* in use */
        }
      }
    }
    final dir = await profiles.createTemp('play-');
    try {
      for (final name in _names) {
        await File(
          p.join(dir.path, name),
        ).writeAsBytes(files[name] ?? const []);
      }
      return dir;
    } catch (_) {
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  Future<void> setConfigEnabled(bool value) async {
    await initialize();
    if (!await (await SharedPreferences.getInstance()).setBool(
      'mpv_config_enabled',
      value,
    )) {
      throw const FileSystemException('Failed to save MPV setting');
    }
    _enabled = value;
  }

  Future<void> setDecodeMode(VideoDecodeMode mode) async {
    await initialize();
    if (!await (await SharedPreferences.getInstance()).setString(
      'video_decode_mode',
      mode.name,
    )) {
      throw const FileSystemException('Failed to save decoding mode');
    }
    _decodeMode = mode;
  }

  static void validateConfigName(String name) {
    if (name != 'mpv.conf' && name != 'input.conf') {
      throw const FormatException('Unsupported MPV config name');
    }
  }

  Future<String> readConfig(String name) async {
    validateConfigName(name);
    await initialize();
    final file = File(p.join((await directory).path, name));
    if (await file.length() > maxConfigBytes) {
      throw const FormatException('MPV config exceeds size limit');
    }
    return file.readAsString();
  }

  Future<void> saveConfig(String name, String value) async {
    validateConfigName(name);
    if (utf8.encode(value).length > maxConfigBytes) {
      throw const FormatException('MPV config exceeds size limit');
    }
    await initialize();
    final file = File(p.join((await directory).path, name));
    if (await file.exists()) {
      await file.copy('${file.path}.bak');
    }
    await file.writeAsString(value.replaceAll('\r\n', '\n'), flush: true);
  }

  Future<void> restoreConfig(String name) async {
    validateConfigName(name);
    await saveConfig(
      name,
      '# Konata: reset configuration\n'
      '# No additional MPV options enabled.\n',
    );
  }
}
