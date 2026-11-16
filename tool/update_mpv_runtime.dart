import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Konata 原生 `libmpv` 运行时换核、符号与对齐校验及 Manifest 更新工具。
///
/// 用法示例：
/// - 严格校验现有清单与二进制：`dart run tool/update_mpv_runtime.dart --check`
/// - 换核后重新生成清单：`dart run tool/update_mpv_runtime.dart --platform all`
Future<void> main(List<String> args) async {
  final options = _CliOptions.parse(args);
  if (options.showHelp) {
    _printUsage();
    return;
  }

  final root = Directory(options.nativeRoot).absolute;
  if (!root.existsSync()) {
    stderr.writeln('原生运行时目录不存在: ${root.path}');
    exitCode = 2;
    return;
  }

  final targets = switch (options.platform) {
    'windows' => const ['windows'],
    'android' => const ['android'],
    'all' => const ['windows', 'android'],
    _ => <String>[],
  };
  if (targets.isEmpty) {
    stderr.writeln('不支持的平台参数: ${options.platform}');
    exitCode = 2;
    return;
  }

  var hasFailure = false;
  for (final target in targets) {
    try {
      if (target == 'windows') {
        await _processWindows(root, options);
      } else {
        await _processAndroid(root, options);
      }
    } catch (error) {
      hasFailure = true;
      stderr.writeln('[$target] 校验或更新失败: $error');
    }
  }

  if (hasFailure) {
    exitCode = 1;
  }
}

class _CliOptions {
  _CliOptions({
    required this.platform,
    required this.nativeRoot,
    required this.checkOnly,
    required this.showHelp,
    this.mpvVersionOverride,
    this.ffmpegVersionOverride,
  });

  final String platform;
  final String nativeRoot;
  final bool checkOnly;
  final bool showHelp;
  final String? mpvVersionOverride;
  final String? ffmpegVersionOverride;

  static _CliOptions parse(List<String> args) {
    var platform = 'all';
    var nativeRoot =
        Platform.environment['KONATA_NATIVE_ROOT'] ??
        p.join(Directory.current.path, 'native', 'konata-native');
    var checkOnly = false;
    var showHelp = false;
    String? mpvVersion;
    String? ffmpegVersion;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--help' || arg == '-h') {
        showHelp = true;
      } else if (arg == '--check') {
        checkOnly = true;
      } else if (arg == '--platform' && i + 1 < args.length) {
        platform = args[++i].trim().toLowerCase();
      } else if (arg == '--root' && i + 1 < args.length) {
        nativeRoot = args[++i];
      } else if (arg == '--mpv-version' && i + 1 < args.length) {
        mpvVersion = args[++i].trim();
      } else if (arg == '--ffmpeg-version' && i + 1 < args.length) {
        ffmpegVersion = args[++i].trim();
      }
    }
    return _CliOptions(
      platform: platform,
      nativeRoot: nativeRoot,
      checkOnly: checkOnly,
      showHelp: showHelp,
      mpvVersionOverride: mpvVersion,
      ffmpegVersionOverride: ffmpegVersion,
    );
  }
}

void _printUsage() {
  stdout.writeln('''
Konata libmpv 原生运行时换核与校验工具

选项:
  --platform <windows|android|all>  指定目标平台（默认 all）
  --root <dir>                      原生库根目录（默认 native/konata-native 或 KONATA_NATIVE_ROOT）
  --check                           仅严格校验导出符号、对齐及 Manifest SHA-256，不改写文件
  --mpv-version <ver>               覆盖写入 manifest 的 mpv 版本号
  --ffmpeg-version <ver>            覆盖写入 manifest 的 ffmpeg 版本号
  -h, --help                        显示帮助信息
''');
}

const List<String> _requiredMpvSymbols = [
  'mpv_client_api_version',
  'mpv_create',
  'mpv_initialize',
  'mpv_terminate_destroy',
  'mpv_destroy',
  'mpv_error_string',
  'mpv_free',
  'mpv_free_node_contents',
  'mpv_set_option',
  'mpv_set_option_string',
  'mpv_set_property',
  'mpv_set_property_string',
  'mpv_get_property',
  'mpv_get_property_string',
  'mpv_observe_property',
  'mpv_unobserve_property',
  'mpv_command',
  'mpv_command_ret',
  'mpv_command_async',
  'mpv_request_log_messages',
  'mpv_set_wakeup_callback',
  'mpv_wait_event',
  'mpv_wakeup',
  'mpv_render_context_create',
  'mpv_render_context_set_update_callback',
  'mpv_render_context_update',
  'mpv_render_context_render',
  'mpv_render_context_report_swap',
  'mpv_render_context_free',
];

Future<void> _processWindows(Directory root, _CliOptions options) async {
  final winDir = Directory(p.join(root.path, 'windows'));
  final dllFile = File(p.join(winDir.path, 'libmpv-2.dll'));
  if (!dllFile.existsSync()) {
    throw StateError('缺少 Windows 原生库: ${dllFile.path}');
  }

  final dllBytes = await dllFile.readAsBytes();
  final exports = _PeExportParser.parseExportedSymbols(dllBytes);
  final missing = _requiredMpvSymbols
      .where((sym) => !exports.contains(sym))
      .toList(growable: false);
  if (missing.isNotEmpty) {
    throw StateError('libmpv-2.dll 缺少必需导出符号: ${missing.join(', ')}');
  }

  final manifestFile = File(p.join(root.path, 'windows-manifest.json'));
  final existingManifest = manifestFile.existsSync()
      ? jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>
      : <String, dynamic>{};

  final runtimeVersions = _probeWindowsVersions(dllFile.path);
  final mpvVer =
      options.mpvVersionOverride ??
      runtimeVersions.mpvVersion ??
      (existingManifest['mpv'] as String?) ??
      'unknown';
  final ffmpegVer =
      options.ffmpegVersionOverride ??
      runtimeVersions.ffmpegVersion ??
      (existingManifest['ffmpeg'] as String?) ??
      'unknown';

  final filesMap = await _collectFileHashes(
    baseDir: winDir,
    root: root,
    skipTopFolders: const {'reference'},
    includePredicate: (_) => true,
  );

  if (options.checkOnly) {
    _verifyManifestMatches(
      manifestFile: manifestFile,
      existing: existingManifest,
      expectedPlatform: 'windows-x64',
      actualFiles: filesMap,
    );
    stdout.writeln(
      '[windows] 校验通过: 导出符号(${exports.length}), '
      'mpv=$mpvVer, ffmpeg=$ffmpegVer, 文件=${filesMap.length}',
    );
    return;
  }

  final updated = <String, dynamic>{
    'mpv': mpvVer,
    'ffmpeg': ffmpegVer,
    'platform': 'windows-x64',
    'files': filesMap,
    if (existingManifest['patches'] != null)
      'patches': existingManifest['patches'],
  };
  await manifestFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(updated)}\n',
  );
  stdout.writeln(
    '[windows] 已更新 windows-manifest.json: '
    'mpv=$mpvVer, ffmpeg=$ffmpegVer, 文件=${filesMap.length}',
  );
}

Future<void> _processAndroid(Directory root, _CliOptions options) async {
  final abiDir = Directory(p.join(root.path, 'android', 'arm64-v8a'));
  if (!abiDir.existsSync()) {
    throw StateError('缺少 Android ARM64 目录: ${abiDir.path}');
  }

  final soFiles = abiDir
      .listSync(followLinks: false)
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.so'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (soFiles.isEmpty) {
    throw StateError('目录中未找到 .so 动态库: ${abiDir.path}');
  }

  File? libMpvSo;
  for (final so in soFiles) {
    final bytes = await so.readAsBytes();
    final report = _Elf64Inspector.inspect(bytes, p.basename(so.path));
    if (!report.isAarch64) {
      throw StateError('${p.basename(so.path)} 不是 AArch64 架构 ELF 动态库');
    }
    if (!report.has16KbPageAlignment) {
      throw StateError(
        '${p.basename(so.path)} 未满足 16 KB (0x4000) ELF PT_LOAD 对齐要求: '
        'alignments=${report.loadAlignments.map((v) => '0x${v.toRadixString(16)}').join(',')}',
      );
    }
    if (p.basename(so.path) == 'libmpv.so') {
      libMpvSo = so;
      final missing = _requiredMpvSymbols
          .where((sym) => !report.exportedSymbols.contains(sym))
          .toList(growable: false);
      if (missing.isNotEmpty) {
        throw StateError('libmpv.so 缺少必需导出符号: ${missing.join(', ')}');
      }
    }
  }
  if (libMpvSo == null) {
    throw StateError('android/arm64-v8a 中缺少 libmpv.so');
  }

  final manifestFile = File(p.join(root.path, 'android-manifest.json'));
  final existingManifest = manifestFile.existsSync()
      ? jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>
      : <String, dynamic>{};

  final mpvVer =
      options.mpvVersionOverride ??
      (existingManifest['mpv'] as String?) ??
      'unknown';
  final ffmpegVer =
      options.ffmpegVersionOverride ??
      (existingManifest['ffmpeg'] as String?) ??
      'unknown';

  final filesMap = await _collectFileHashes(
    baseDir: Directory(p.join(root.path, 'android')),
    root: root,
    skipTopFolders: const {},
    includePredicate: (file) => file.path.toLowerCase().endsWith('.so'),
  );

  if (options.checkOnly) {
    _verifyManifestMatches(
      manifestFile: manifestFile,
      existing: existingManifest,
      expectedPlatform: 'android-arm64',
      actualFiles: filesMap,
    );
    stdout.writeln(
      '[android] 校验通过: ${soFiles.length} 个 .so 全部满足 16KB 对齐, '
      'mpv=$mpvVer, ffmpeg=$ffmpegVer',
    );
    return;
  }

  final updated = <String, dynamic>{
    'mpv': mpvVer,
    'ffmpeg': ffmpegVer,
    'platform': 'android-arm64',
    'files': filesMap,
    if (existingManifest['patches'] != null)
      'patches': existingManifest['patches'],
  };
  await manifestFile.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(updated)}\n',
  );
  stdout.writeln(
    '[android] 已更新 android-manifest.json: '
    '${soFiles.length} 个 .so (16KB 对齐通过), mpv=$mpvVer, ffmpeg=$ffmpegVer',
  );
}

Future<Map<String, Map<String, dynamic>>> _collectFileHashes({
  required Directory baseDir,
  required Directory root,
  required Set<String> skipTopFolders,
  required bool Function(File file) includePredicate,
}) async {
  final files = <File>[];
  await for (final entity in baseDir.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final relToBase = p.relative(entity.path, from: baseDir.path);
    final firstSegment = p.split(relToBase).first;
    if (skipTopFolders.contains(firstSegment)) continue;
    if (!includePredicate(entity)) continue;
    files.add(entity);
  }
  files.sort(
    (a, b) => p
        .relative(a.path, from: root.path)
        .replaceAll('\\', '/')
        .compareTo(p.relative(b.path, from: root.path).replaceAll('\\', '/')),
  );

  final result = <String, Map<String, dynamic>>{};
  for (final file in files) {
    final rel = p.relative(file.path, from: root.path).replaceAll('\\', '/');
    final bytes = await file.readAsBytes();
    result[rel] = <String, dynamic>{
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
    };
  }
  return result;
}

void _verifyManifestMatches({
  required File manifestFile,
  required Map<String, dynamic> existing,
  required String expectedPlatform,
  required Map<String, Map<String, dynamic>> actualFiles,
}) {
  if (!manifestFile.existsSync()) {
    throw StateError('缺少清单文件: ${manifestFile.path}');
  }
  if (existing['platform'] != expectedPlatform) {
    throw StateError('清单 platform 异常: ${existing['platform']}');
  }
  final mpv = existing['mpv']?.toString().trim() ?? '';
  final ffmpeg = existing['ffmpeg']?.toString().trim() ?? '';
  if (mpv.isEmpty || ffmpeg.isEmpty) {
    throw StateError('清单缺少 mpv 或 ffmpeg 版本字段');
  }
  final expectedFiles = existing['files'] as Map<String, dynamic>? ?? const {};
  if (expectedFiles.length != actualFiles.length) {
    throw StateError(
      '清单文件数量(${expectedFiles.length})与磁盘(${actualFiles.length})不一致，请不带 --check 重新生成清单',
    );
  }
  for (final entry in actualFiles.entries) {
    final exp = expectedFiles[entry.key] as Map<String, dynamic>?;
    if (exp == null) {
      throw StateError('清单缺少文件记录: ${entry.key}');
    }
    if (exp['sha256'] != entry.value['sha256'] ||
        exp['bytes'] != entry.value['bytes']) {
      throw StateError('文件哈希或字节数不一致: ${entry.key}');
    }
  }
}

({String? mpvVersion, String? ffmpegVersion}) _probeWindowsVersions(
  String dllPath,
) {
  if (!Platform.isWindows) {
    return (mpvVersion: null, ffmpegVersion: null);
  }
  Pointer<Void>? ctx;
  try {
    final lib = DynamicLibrary.open(dllPath);
    final create = lib
        .lookup<NativeFunction<Pointer<Void> Function()>>('mpv_create')
        .asFunction<Pointer<Void> Function()>();
    final init = lib
        .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>('mpv_initialize')
        .asFunction<int Function(Pointer<Void>)>();
    final getProp = lib
        .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>>(
          'mpv_get_property_string',
        )
        .asFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>();
    final freeFn = lib
        .lookup<NativeFunction<Void Function(Pointer<Void>)>>('mpv_free')
        .asFunction<void Function(Pointer<Void>)>();
    final destroy = lib
        .lookup<NativeFunction<Void Function(Pointer<Void>)>>(
          'mpv_terminate_destroy',
        )
        .asFunction<void Function(Pointer<Void>)>();

    ctx = create();
    if (ctx == nullptr) return (mpvVersion: null, ffmpegVersion: null);
    if (init(ctx) < 0) return (mpvVersion: null, ffmpegVersion: null);

    String? readProp(String name) {
      final keyPtr = name.toNativeUtf8();
      try {
        final rawPtr = getProp(ctx!, keyPtr);
        if (rawPtr == nullptr) return null;
        try {
          return rawPtr.toDartString().trim();
        } finally {
          freeFn(rawPtr.cast<Void>());
        }
      } finally {
        calloc.free(keyPtr);
      }
    }

    final rawMpv = readProp('mpv-version');
    final rawFfmpeg = readProp('ffmpeg-version');
    destroy(ctx);
    ctx = null;

    final mpvMatch = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(rawMpv ?? '');
    final ffMatch = RegExp(r'(\d+\.\d+(?:\.\d+)?)').firstMatch(rawFfmpeg ?? '');
    return (
      mpvVersion: mpvMatch?.group(1),
      ffmpegVersion: ffMatch?.group(1),
    );
  } catch (_) {
    return (mpvVersion: null, ffmpegVersion: null);
  }
}

class _PeSection {
  _PeSection({
    required this.virtualAddress,
    required this.virtualSize,
    required this.pointerToRawData,
    required this.sizeOfRawData,
  });

  final int virtualAddress;
  final int virtualSize;
  final int pointerToRawData;
  final int sizeOfRawData;
}

class _PeExportParser {
  static Set<String> parseExportedSymbols(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 64 || data.getUint16(0, Endian.little) != 0x5A4D) {
      throw const FormatException('无效 PE DOS 头');
    }
    final peOffset = data.getUint32(0x3C, Endian.little);
    if (peOffset + 24 > bytes.length ||
        data.getUint32(peOffset, Endian.little) != 0x00004550) {
      throw const FormatException('无效 PE 签名');
    }
    final coffOffset = peOffset + 4;
    final sectionCount = data.getUint16(coffOffset + 2, Endian.little);
    final optHeaderSize = data.getUint16(coffOffset + 16, Endian.little);
    final optOffset = coffOffset + 20;
    final magic = data.getUint16(optOffset, Endian.little);
    if (magic != 0x20B) {
      throw FormatException('仅支持 PE32+ (x64) DLL, magic=0x${magic.toRadixString(16)}');
    }
    // PE32+ Optional Header: DataDirectory starts at optOffset + 112.
    final exportRva = data.getUint32(optOffset + 112, Endian.little);
    final exportSize = data.getUint32(optOffset + 116, Endian.little);
    if (exportRva == 0 || exportSize == 0) {
      return const {};
    }

    final sections = <_PeSection>[];
    final secTableOffset = optOffset + optHeaderSize;
    for (var i = 0; i < sectionCount; i++) {
      final off = secTableOffset + i * 40;
      sections.add(
        _PeSection(
          virtualSize: data.getUint32(off + 8, Endian.little),
          virtualAddress: data.getUint32(off + 12, Endian.little),
          sizeOfRawData: data.getUint32(off + 16, Endian.little),
          pointerToRawData: data.getUint32(off + 20, Endian.little),
        ),
      );
    }

    int? rvaToOffset(int rva) {
      for (final s in sections) {
        final span = s.virtualSize > s.sizeOfRawData
            ? s.virtualSize
            : s.sizeOfRawData;
        if (rva >= s.virtualAddress && rva < s.virtualAddress + span) {
          final fileOff = s.pointerToRawData + (rva - s.virtualAddress);
          return fileOff < bytes.length ? fileOff : null;
        }
      }
      return null;
    }

    final exportOff = rvaToOffset(exportRva);
    if (exportOff == null) {
      throw const FormatException('无法定位 PE Export Directory');
    }
    final numNames = data.getUint32(exportOff + 24, Endian.little);
    final namePtrRva = data.getUint32(exportOff + 32, Endian.little);
    final namesOff = rvaToOffset(namePtrRva);
    if (namesOff == null) {
      return const {};
    }

    final symbols = <String>{};
    for (var i = 0; i < numNames; i++) {
      final symRva = data.getUint32(namesOff + i * 4, Endian.little);
      final symOff = rvaToOffset(symRva);
      if (symOff == null) continue;
      final end = bytes.indexOf(0, symOff);
      if (end > symOff) {
        symbols.add(ascii.decode(bytes.sublist(symOff, end), allowInvalid: true));
      }
    }
    return symbols;
  }
}

class _ElfReport {
  _ElfReport({
    required this.isAarch64,
    required this.has16KbPageAlignment,
    required this.loadAlignments,
    required this.exportedSymbols,
  });

  final bool isAarch64;
  final bool has16KbPageAlignment;
  final List<int> loadAlignments;
  final Set<String> exportedSymbols;
}

class _Elf64Inspector {
  static _ElfReport inspect(Uint8List bytes, String fileName) {
    final data = ByteData.sublistView(bytes);
    if (bytes.length < 64 ||
        bytes[0] != 0x7F ||
        bytes[1] != 0x45 ||
        bytes[2] != 0x4C ||
        bytes[3] != 0x46) {
      throw FormatException('$fileName 不是有效的 ELF 文件');
    }
    if (bytes[4] != 2 || bytes[5] != 1) {
      throw FormatException('$fileName 不是 64-bit little-endian ELF');
    }
    final machine = data.getUint16(18, Endian.little);
    final isAarch64 = machine == 183;

    final phOff = data.getUint64(32, Endian.little);
    final shOff = data.getUint64(40, Endian.little);
    final phEntSize = data.getUint16(54, Endian.little);
    final phNum = data.getUint16(56, Endian.little);
    final shEntSize = data.getUint16(58, Endian.little);
    final shNum = data.getUint16(60, Endian.little);

    final alignments = <int>[];
    var pageAligned = true;
    for (var i = 0; i < phNum; i++) {
      final off = phOff + i * phEntSize;
      final pType = data.getUint32(off, Endian.little);
      if (pType != 1) continue; // PT_LOAD = 1
      final pOffset = data.getUint64(off + 8, Endian.little);
      final pVaddr = data.getUint64(off + 16, Endian.little);
      final pAlign = data.getUint64(off + 48, Endian.little);
      alignments.add(pAlign);
      if (pAlign < 0x4000 || (pVaddr % 0x4000) != (pOffset % 0x4000)) {
        pageAligned = false;
      }
    }

    final symbols = <String>{};
    if (shOff > 0 && shNum > 0) {
      for (var i = 0; i < shNum; i++) {
        final secOff = shOff + i * shEntSize;
        final shType = data.getUint32(secOff + 4, Endian.little);
        if (shType != 11) continue; // SHT_DYNSYM = 11
        final symOffset = data.getUint64(secOff + 24, Endian.little);
        final symSize = data.getUint64(secOff + 32, Endian.little);
        final strIndex = data.getUint32(secOff + 40, Endian.little);
        final symEntSize = data.getUint64(secOff + 56, Endian.little);
        if (strIndex >= shNum || symEntSize < 24) continue;
        final strSecOff = shOff + strIndex * shEntSize;
        final strOffset = data.getUint64(strSecOff + 24, Endian.little);
        final strSize = data.getUint64(strSecOff + 32, Endian.little);

        final count = symSize ~/ symEntSize;
        for (var j = 0; j < count; j++) {
          final entryOff = symOffset + j * symEntSize;
          final stName = data.getUint32(entryOff, Endian.little);
          final stShndx = data.getUint16(entryOff + 6, Endian.little);
          if (stName == 0 || stShndx == 0 || stName >= strSize) continue;
          final nameStart = strOffset + stName;
          final nameEnd = bytes.indexOf(0, nameStart);
          if (nameEnd > nameStart && nameEnd <= strOffset + strSize) {
            symbols.add(
              utf8.decode(bytes.sublist(nameStart, nameEnd), allowMalformed: true),
            );
          }
        }
      }
    }

    return _ElfReport(
      isAarch64: isAarch64,
      has16KbPageAlignment: alignments.isNotEmpty && pageAligned,
      loadAlignments: alignments,
      exportedSymbols: symbols,
    );
  }
}
