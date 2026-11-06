import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'metadata_servers.dart';
import 'debug_log.dart';
import 'request_budget.dart';

class ImageStore {
  static Directory? root;
  static final Map<String, DateTime> _unhealthy = {};
  static final Map<String, Future<Uint8List>> _pending = {};
  static Future<Directory> directory() async => root ??= Directory(
    p.join((await getApplicationSupportDirectory()).path, 'artwork'),
  );
  static String identity(String raw) {
    final uri = Uri.parse(raw);
    final resource = MetadataServers.imageResource(raw);
    if (resource != null) {
      return '${resource.$1 == 1 ? "tmdb" : "bangumi"}:${resource.$2}${uri.hasQuery ? "?${uri.query}" : ""}';
    }
    return raw;
  }

  static Future<Uint8List> load(String raw) {
    final key = identity(raw);
    return _pending.putIfAbsent(
      key,
      () => _load(raw).whenComplete(() {
        // Do not return the removed future: it is this same future, so
        // whenComplete would wait on itself and never notify the image widget.
        _pending.remove(key);
      }),
    );
  }

  static Future<Uint8List> _load(String raw) async {
    if (raw.startsWith('artwork:')) {
      if (!RegExp(
        r'^artwork:(original|crop)_[a-f0-9]{64}\.png$',
      ).hasMatch(raw)) {
        throw const FormatException('无效图片资源 ID');
      }
      return File(
        p.join((await directory()).path, raw.substring(8)),
      ).readAsBytes();
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !['http', 'https'].contains(uri.scheme)) {
      return File(raw).readAsBytes();
    }
    final dir = await directory();
    await dir.create(recursive: true);
    final file = File(
      p.join(dir.path, 'cache_${sha256.convert(utf8.encode(identity(raw)))}'),
    );
    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        await validate(bytes);
        return bytes;
      } catch (_) {
        await file.delete();
      }
    }
    final targets = [MetadataServers.mapImage(raw)];
    if (MetadataServers.fallback) {
      final u = Uri.parse(raw);
      final resource = MetadataServers.imageResource(raw);
      if (resource != null) {
        targets.add(
          MetadataServers.endpoint(
            resource.$1,
            resource.$2,
            base: MetadataServers.official[resource.$1],
          ).replace(query: u.hasQuery ? u.query : null).toString(),
        );
      }
    }
    for (final target in targets.toSet()) {
      final host = Uri.parse(target).host;
      if (_unhealthy[host]?.isAfter(DateTime.now()) == true) continue;
      try {
        final bytes = await download(target);
        try {
          await file.writeAsBytes(bytes, flush: true);
          await trim(dir);
        } catch (_) {
          DebugLog.write('Image', 'cache write failed', level: 'WARN');
        }
        return bytes;
      } catch (e) {
        if (e is IOException) {
          _unhealthy[host] = DateTime.now().add(const Duration(seconds: 45));
        }
        DebugLog.write(
          'Image',
          'download failed host=${Uri.parse(target).host} type=${e.runtimeType}',
          level: 'WARN',
        );
      }
    }
    throw const HttpException('图片下载失败');
  }

  static Future<Uint8List> download(String url, {http.Client? client}) =>
      client == null
      ? RequestBudget.run(() => _download(url))
      : _download(url, client: client);

  static Future<Uint8List> _download(String url, {http.Client? client}) async {
    final owned = client == null;
    final c = client ?? http.Client();
    try {
      final response = await c
          .send(http.Request('GET', Uri.parse(url)))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      if (!(response.headers['content-type'] ?? '').toLowerCase().startsWith(
        'image/',
      )) {
        throw const FormatException('图片 Content-Type 无效');
      }
      final builder = BytesBuilder();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 20),
      )) {
        builder.add(chunk);
        if (builder.length > 32 * 1024 * 1024) {
          throw const FormatException('图片超过 32 MB');
        }
      }
      final bytes = builder.takeBytes();
      await validate(bytes);
      return bytes;
    } finally {
      if (owned) c.close();
    }
  }

  static Future<void> validate(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        if (descriptor.width * descriptor.height > 64000000) {
          throw const FormatException('图片像素过大');
        }
      } finally {
        descriptor.dispose();
      }
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
    } finally {
      buffer.dispose();
    }
  }

  static Future<String> save(Uint8List bytes, String kind) async {
    final dir = await directory();
    await dir.create(recursive: true);
    final id = '${kind}_${sha256.convert(bytes)}.png';
    final file = File(p.join(dir.path, id));
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return 'artwork:$id';
  }

  static Future<void> trim(Directory dir) async {
    final files = await dir
        .list()
        .where((f) => p.basename(f.path).startsWith('cache_'))
        .cast<File>()
        .toList();
    final ages = <File, DateTime>{};
    var total = 0;
    for (final f in files) {
      total += await f.length();
      ages[f] = await f.lastModified();
    }
    files.sort((a, b) => ages[a]!.compareTo(ages[b]!));
    for (final f in files) {
      if (total <= 256 * 1024 * 1024) break;
      final length = await f.length();
      await f.delete();
      total -= length;
    }
  }
}
