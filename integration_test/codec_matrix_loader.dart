import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 解析 G01~G12 真实压缩编码样本目录（桌面直读本地目录；Android 支持经本机回环反代自动拉取至沙箱缓存）。
Future<Directory> resolveCodecMatrixDirectory({
  bool onlyNorthstarSubset = false,
}) async {
  const defineDir = String.fromEnvironment('KONATA_CODEC_MATRIX_DIR');
  const defineUrl = String.fromEnvironment('KONATA_CODEC_MATRIX_URL');
  final envDir = Platform.environment['KONATA_CODEC_MATRIX_DIR'] ?? '';
  final envUrl = Platform.environment['KONATA_CODEC_MATRIX_URL'] ?? '';
  final candidates = <String>[
    if (defineDir.trim().isNotEmpty) defineDir.trim(),
    if (envDir.trim().isNotEmpty) envDir.trim(),
    p.join(Directory.systemTemp.path, 'konata_codec_matrix'),
    if (Platform.isAndroid)
      '/sdcard/Android/data/com.anime.konata.profile/files/konata_codec_matrix',
  ];
  for (final path in candidates) {
    final dir = Directory(path);
    if (await File(p.join(dir.path, 'manifest.json')).exists()) {
      return dir;
    }
  }

  final rawUrl = defineUrl.trim().isNotEmpty
      ? defineUrl.trim()
      : (envUrl.trim().isNotEmpty
            ? envUrl.trim()
            : (Platform.isAndroid ? 'http://127.0.0.1:18923' : ''));
  if (rawUrl.isNotEmpty) {
    final targetDir = Directory(
      p.join(Directory.systemTemp.path, 'konata_codec_matrix'),
    );
    await _downloadMatrixFromLoopback(
      baseUrl: rawUrl,
      targetDir: targetDir,
      onlyNorthstarSubset: onlyNorthstarSubset,
    );
    return targetDir;
  }

  throw StateError(
    '未找到 G01~G12 真实压缩编码样本目录（manifest.json），已检查：${candidates.join(', ')}',
  );
}

Future<void> _downloadMatrixFromLoopback({
  required String baseUrl,
  required Directory targetDir,
  required bool onlyNorthstarSubset,
}) async {
  final normalizedBase = baseUrl.endsWith('/')
      ? baseUrl.substring(0, baseUrl.length - 1)
      : baseUrl;
  await targetDir.create(recursive: true);
  final http = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final manifestBytes = await _httpGetBytes(
      http,
      Uri.parse('$normalizedBase/manifest.json'),
    );
    final manifestText = utf8.decode(manifestBytes);
    final manifestJson = jsonDecode(manifestText) as Map<String, Object?>;
    final groups = manifestJson['groups']! as Map<String, Object?>;

    final relPaths = <String>{};
    for (final entry in groups.entries) {
      if (onlyNorthstarSubset &&
          entry.key != 'G01' &&
          entry.key != 'G04') {
        continue;
      }
      final g = entry.value! as Map<String, Object?>;
      for (final key in const [
        'primary',
        'secondary',
        'steady_8s',
        'wavpack',
        'dsf',
      ]) {
        final v = g[key];
        if (v is String && v.isNotEmpty) {
          relPaths.add(v);
        }
      }
      final sidecars = g['sidecars'];
      if (sidecars is List) {
        for (final item in sidecars) {
          if (item is String && item.isNotEmpty) {
            relPaths.add(item);
          }
        }
      }
    }

    for (final rel in relPaths) {
      final cleanRel = rel.replaceAll('\\', '/');
      final dest = File(p.join(targetDir.path, cleanRel));
      await dest.parent.create(recursive: true);
      final bytes = await _httpGetBytes(
        http,
        Uri.parse('$normalizedBase/$cleanRel'),
      );
      await dest.writeAsBytes(bytes, flush: true);
    }

    await File(
      p.join(targetDir.path, 'manifest.json'),
    ).writeAsBytes(manifestBytes, flush: true);
  } finally {
    http.close(force: true);
  }
}

Future<List<int>> _httpGetBytes(HttpClient http, Uri uri) async {
  final req = await http.getUrl(uri);
  final resp = await req.close();
  if (resp.statusCode != 200) {
    throw HttpException(
      '拉取编码矩阵样本失败（HTTP ${resp.statusCode}）：$uri',
      uri: uri,
    );
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in resp) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}
