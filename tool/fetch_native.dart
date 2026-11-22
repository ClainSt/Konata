import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 校验或拉取 Konata 固化原生多媒体播放内核（libmpv 与 FFmpeg）。
///
/// 优先复用本地已存在的动态库与头文件；当本地缺失或 SHA-256 校验不符时，
/// 自动从独立仓库 ClainSt/Konata-Native 的 GitHub Releases 归档包拉取并校验还原。
///
/// 用法：
/// - `dart run tool/fetch_native.dart`（默认校验并补全双端）
/// - `dart run tool/fetch_native.dart windows` / `android` / `all`
/// - `dart run tool/fetch_native.dart --root <目录> [windows|android|all]`
Future<void> main(List<String> args) async {
  var target = 'all';
  var customRoot = Platform.environment['KONATA_NATIVE_ROOT'];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--root' && i + 1 < args.length) {
      customRoot = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      stdout.writeln(
        '用法: dart run tool/fetch_native.dart [--root <原生库目录>] [windows|android|all]',
      );
      return;
    } else if (!arg.startsWith('-')) {
      target = arg.toLowerCase();
    }
  }

  final nativeRoot = Directory(
    (customRoot != null && customRoot.isNotEmpty)
        ? customRoot
        : '${Directory.current.path}${Platform.pathSeparator}native${Platform.pathSeparator}konata-native',
  ).absolute;

  if (!nativeRoot.existsSync()) {
    stderr.writeln('错误：找不到原生运行时目录：${nativeRoot.path}');
    exitCode = 1;
    return;
  }

  final runWindows =
      target == 'all' || target == 'windows' || target == 'windows-x64';
  final runAndroid =
      target == 'all' || target == 'android' || target == 'android-arm64';
  if (!runWindows && !runAndroid) {
    stderr.writeln('错误：不支持的目标平台参数 "$target"，请使用 windows、android 或 all');
    exitCode = 64;
    return;
  }

  var allOk = true;

  if (runWindows) {
    final ok = await _ensurePlatform(
      nativeRoot: nativeRoot,
      manifestName: 'windows-manifest.json',
      platformLabel: 'Windows x64',
    );
    if (!ok) allOk = false;
  }

  if (runAndroid) {
    final ok = await _ensurePlatform(
      nativeRoot: nativeRoot,
      manifestName: 'android-manifest.json',
      platformLabel: 'Android ARM64',
    );
    if (!ok) allOk = false;
  }

  if (!allOk) {
    stderr.writeln('原生依赖就绪检查未通过。');
    exitCode = 1;
    return;
  }

  stdout.writeln('原生依赖全部就绪且 SHA-256 校验通过。');
}

/// 流式计算文件 SHA-256，避免将数十 MB 动态库整块载入内存。
Future<String> _computeFileSha256(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 校验清单登记的所有本地文件是否齐全且字节数与哈希完全匹配。
Future<bool> _verifyManifestFiles({
  required Directory nativeRoot,
  required Map<String, dynamic> filesMap,
}) async {
  for (final entry in filesMap.entries) {
    final relPath = entry.key;
    final fileInfo = entry.value as Map<String, dynamic>;
    final expectedSha = (fileInfo['sha256'] as String).toLowerCase();
    final expectedBytes = fileInfo['bytes'] as int?;
    final localFile = File(
      '${nativeRoot.path}${Platform.pathSeparator}${relPath.replaceAll('/', Platform.pathSeparator)}',
    );

    if (!localFile.existsSync()) {
      return false;
    }
    if (expectedBytes != null && localFile.lengthSync() != expectedBytes) {
      return false;
    }
    final localSha = await _computeFileSha256(localFile);
    if (localSha != expectedSha) {
      return false;
    }
  }
  return true;
}

/// 检查并保证指定平台的原生文件完备且哈希一致。
Future<bool> _ensurePlatform({
  required Directory nativeRoot,
  required String manifestName,
  required String platformLabel,
}) async {
  final manifestFile = File(
    '${nativeRoot.path}${Platform.pathSeparator}$manifestName',
  );
  if (!manifestFile.existsSync()) {
    stderr.writeln('错误：找不到清单文件：${manifestFile.path}');
    return false;
  }

  final manifestJson =
      jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
  final filesMap = manifestJson['files'] as Map<String, dynamic>? ?? {};
  final releaseMap = manifestJson['release'] as Map<String, dynamic>?;

  if (filesMap.isEmpty) {
    stderr.writeln('[$platformLabel] 清单中未登记任何原生文件。');
    return false;
  }

  if (await _verifyManifestFiles(nativeRoot: nativeRoot, filesMap: filesMap)) {
    stdout.writeln('[$platformLabel] 本地原生文件已就绪，SHA-256 校验通过。');
    return true;
  }

  if (releaseMap == null) {
    stderr.writeln('[$platformLabel] 本地文件缺失且清单未提供 release 下载源。');
    return false;
  }

  stdout.writeln('[$platformLabel] 本地文件缺失或校验不符，开始从 Konata-Native 拉取预编译包...');
  final extracted = await _downloadAndExtract(
    nativeRoot: nativeRoot,
    releaseMap: releaseMap,
    platformLabel: platformLabel,
  );
  if (!extracted) {
    return false;
  }

  // 解包完成后逐文件复核字节数与 SHA-256，防止归档路径偏移或损坏。
  final verifiedAfterExtract = await _verifyManifestFiles(
    nativeRoot: nativeRoot,
    filesMap: filesMap,
  );
  if (!verifiedAfterExtract) {
    stderr.writeln('[$platformLabel] 解包后逐文件清单复核失败。');
    return false;
  }

  stdout.writeln('[$platformLabel] 归档解包完成且清单逐文件校验通过。');
  return true;
}

/// 从远程 Release 下载归档包、核对哈希并安全解压到原生根目录。
Future<bool> _downloadAndExtract({
  required Directory nativeRoot,
  required Map<String, dynamic> releaseMap,
  required String platformLabel,
}) async {
  final repo = releaseMap['repository'] as String;
  final tag = releaseMap['tag'] as String;
  final archive = releaseMap['archive'] as String;
  final expectedSha = (releaseMap['sha256'] as String).toLowerCase();
  final expectedBytes = releaseMap['bytes'] as int?;

  // 支持通过 KONATA_NATIVE_MIRROR 指定镜像前缀（格式如 https://mirror.example.com/konata-native）。
  final mirror = Platform.environment['KONATA_NATIVE_MIRROR']?.trim();
  final urlStr = (mirror != null && mirror.isNotEmpty)
      ? '${mirror.replaceAll(RegExp(r'/+$'), '')}/$tag/$archive'
      : '$repo/releases/download/$tag/$archive';

  final uri = Uri.parse(urlStr);
  final tempZip = File(
    '${nativeRoot.path}${Platform.pathSeparator}.$archive.download',
  );

  stdout.writeln('[$platformLabel] 正在下载：$uri');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    request.headers.set(HttpHeaders.userAgentHeader, 'Konata-Fetch-Native/1.0');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      stderr.writeln('[$platformLabel] 下载失败，HTTP 状态码：${response.statusCode}');
      return false;
    }

    final sink = tempZip.openWrite();
    try {
      await response.pipe(sink);
    } finally {
      await sink.close();
    }

    if (expectedBytes != null && tempZip.lengthSync() != expectedBytes) {
      stderr.writeln(
        '[$platformLabel] 归档字节数不符：期望 $expectedBytes，实际 ${tempZip.lengthSync()}',
      );
      return false;
    }

    stdout.writeln('[$platformLabel] 下载完成，正在校验归档 SHA-256...');
    final downloadedSha = await _computeFileSha256(tempZip);
    if (downloadedSha != expectedSha) {
      stderr.writeln('[$platformLabel] 归档 SHA-256 校验不符！');
      stderr.writeln('  期望：$expectedSha');
      stderr.writeln('  实际：$downloadedSha');
      return false;
    }

    stdout.writeln('[$platformLabel] 归档校验通过，正在解包...');
    final extractOk = await _extractZip(tempZip, nativeRoot);
    if (!extractOk) {
      stderr.writeln('[$platformLabel] 解包失败。');
      return false;
    }
    return true;
  } catch (e) {
    stderr.writeln('[$platformLabel] 下载或解包异常：$e');
    return false;
  } finally {
    client.close(force: true);
    if (tempZip.existsSync()) {
      try {
        tempZip.deleteSync();
      } catch (_) {}
    }
  }
}

/// 跨平台解包 ZIP 归档（优先系统内置命令，零外部 Dart 依赖）。
Future<bool> _extractZip(File zipFile, Directory targetDir) async {
  if (Platform.isWindows) {
    final res = await Process.run('tar', ['-xf', zipFile.path, '-C', targetDir.path]);
    if (res.exitCode == 0) return true;
    stderr.writeln(res.stderr);
    return false;
  }

  // Linux / macOS 优先使用 unzip，缺失时回退 bsdtar 或 python3 zipfile。
  final unzipRes = await Process.run(
    'unzip',
    ['-o', '-q', zipFile.path, '-d', targetDir.path],
  ).catchError((_) => ProcessResult(0, 127, '', ''));
  if (unzipRes.exitCode == 0) return true;

  final pyRes = await Process.run('python3', [
    '-c',
    'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])',
    zipFile.path,
    targetDir.path,
  ]);
  if (pyRes.exitCode == 0) return true;
  stderr.writeln(pyRes.stderr);
  return false;
}
