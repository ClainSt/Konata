import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'metadata_servers.dart';
import 'debug_log.dart';
import 'request_budget.dart';
import 'artwork_cache.dart';
import 'package:flutter/foundation.dart';

class ImageStore {
  static Directory? root;
  static ArtworkCache? _cache;
  static final changed = ValueNotifier<int>(0);
  static final _removedOwners = <String>{};
  static Future<ArtworkCache> get cache async {
    final dir = await directory();
    if (_cache?.root.path != dir.path) {
      await _cache?.close();
      _cache = ArtworkCache(dir);
    }
    return _cache!;
  }

  static Future<void> close() async {
    await _cache?.close();
    _cache = null;
    _removedOwners.clear();
  }

  static Future<void> retain(String owner, Iterable<String> urls) async {
    if (_removedOwners.contains(owner)) return;
    final keys = urls
        .where((url) => url.startsWith('http'))
        .map(identity)
        .toSet();
    if (keys.isNotEmpty) await (await cache).retain(owner, keys);
  }

  static Iterable<String> artworkUrls(Object? value) sync* {
    if (value is String && value.startsWith('http')) {
      if (MetadataServers.imageResource(value) != null) yield value;
    } else if (value is Map) {
      for (final child in value.values) {
        yield* artworkUrls(child);
      }
    } else if (value is List) {
      for (final child in value) {
        yield* artworkUrls(child);
      }
    }
  }

  static void restoreOwner(String owner) => _removedOwners.remove(owner);
  static void checkOwner(String? owner) {
    if (owner != null && _removedOwners.contains(owner)) {
      throw StateError('Work removed');
    }
  }

  static Future<void> removeWork(String owner) async {
    _removedOwners.add(owner);
    if (root == null) return;
    await (await cache).removeOwner(owner);
    changed.value++;
  }

  static Future<Uint8List?> readCached(
    String raw, {
    void Function()? checkActive,
  }) async {
    checkActive?.call();
    final result = await (await cache).read(
      identity(raw),
      minimumQuality: quality(raw),
    );
    checkActive?.call();
    if (result != null) {
      try {
        await validate(result);
        return result;
      } catch (_) {
        checkActive?.call();
        await (await cache).invalidate(identity(raw));
      }
    }
    // Import the previous URL-keyed cache on access without a second download.
    final legacy = File(
      p.join(
        (await directory()).path,
        'cache_${sha256.convert(utf8.encode(legacyIdentity(raw)))}',
      ),
    );
    if (await legacy.exists()) {
      try {
        final bytes = await legacy.readAsBytes();
        await validate(bytes);
        await storeCached(raw, bytes, checkActive: checkActive);
        await legacy.delete();
        return bytes;
      } catch (_) {
        /* Keep unreadable legacy files for manual recovery. */
      }
    }
    return null;
  }

  static Future<void> storeCached(
    String raw,
    Uint8List bytes, {
    void Function()? checkActive,
  }) async {
    await (await cache).write(
      identity(raw),
      bytes,
      checkActive: checkActive,
      quality: quality(raw),
    );
    changed.value++;
  }

  /// Measured file bytes, including original artwork and the small cache index.
  /// Runs only on the cache settings screen, not per downloaded image.
  static Future<int> diskBytes() async {
    final dir = await directory();
    if (!await dir.exists()) return 0;
    var bytes = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          bytes += await entity.length();
        } on FileSystemException {
          /* Concurrent removal. */
        }
      }
    }
    return bytes;
  }

  static final Map<String, DateTime> _unhealthy = {};
  static final Map<String, Future<Uint8List>> _pending = {};
  static Future<Directory> directory() async => root ??= Directory(
    p.join((await getApplicationSupportDirectory()).path, 'artwork'),
  );
  static String identity(String raw) {
    final resource = MetadataServers.imageResource(raw);
    if (resource?.$1 == 1 &&
        RegExp(r'^(?:w\d+|h\d+|original)/').hasMatch(resource!.$2)) {
      final uri = Uri.parse(raw);
      return 'tmdb:${resource.$2.substring(resource.$2.indexOf('/') + 1)}${uri.hasQuery ? '?${uri.query}' : ''}';
    }
    return legacyIdentity(raw);
  }

  static int quality(String raw) {
    final resource = MetadataServers.imageResource(raw);
    if (resource?.$1 != 1) return 0;
    final size = resource!.$2.split('/').first;
    return size == 'original'
        ? 100000
        : size.length < 2
        ? 0
        : int.tryParse(size.substring(1)) ?? 0;
  }

  static String tmdbDisplayUrl(
    String raw,
    int physicalWidth, {
    required bool backdrop,
  }) {
    final resource = MetadataServers.imageResource(raw);
    if (resource?.$1 != 1 || !resource!.$2.contains('/')) return raw;
    final size = backdrop
        ? (physicalWidth <= 780
              ? 'w780'
              : physicalWidth <= 1280
              ? 'w1280'
              : 'original')
        : (physicalWidth <= 300 ? 'w300' : 'original');
    final path = resource.$2.substring(resource.$2.indexOf('/') + 1);
    return MetadataServers.endpoint(1, '$size/$path')
        .replace(query: Uri.parse(raw).hasQuery ? Uri.parse(raw).query : null)
        .toString();
  }

  static String legacyIdentity(String raw) {
    final uri = Uri.parse(raw);
    final resource = MetadataServers.imageResource(raw);
    if (resource != null) {
      return '${resource.$1 == 1 ? "tmdb" : "bangumi"}:${resource.$2}${uri.hasQuery ? "?${uri.query}" : ""}';
    }
    return raw;
  }

  static Future<Uint8List> load(String raw, {String? owner}) async {
    checkOwner(owner);
    if (owner != null) {
      try {
        await retain(owner, [raw]);
      } catch (_) {
        DebugLog.write('Image', 'cache ownership unavailable', level: 'WARN');
      }
    }
    final bytes = await _load(raw, owner: owner);
    checkOwner(owner);
    return bytes;
  }

  static Future<Uint8List> _load(String raw, {String? owner}) async {
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
    Uint8List? cached;
    try {
      cached = await readCached(raw, checkActive: () => checkOwner(owner));
    } catch (_) {
      DebugLog.write('Image', 'cache read failed', level: 'WARN');
    }
    checkOwner(owner);
    if (cached != null) return cached;
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
      checkOwner(owner);
      final host = Uri.parse(target).host;
      if (_unhealthy[host]?.isAfter(DateTime.now()) == true) continue;
      try {
        // Share only transport bytes. Each consumer retains its own lifetime
        // checks and cache write, so removing one work cannot cancel another.
        final bytes = await _pending.putIfAbsent(
          target,
          () => download(target).whenComplete(() {
            _pending.remove(target);
          }),
        );
        checkOwner(owner);
        try {
          await storeCached(raw, bytes, checkActive: () => checkOwner(owner));
          if (owner == null) await (await cache).trimUnowned();
        } catch (_) {
          DebugLog.write('Image', 'cache write failed', level: 'WARN');
        }
        return bytes;
      } catch (e) {
        checkOwner(owner);
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
        // Validation needs only a small decoded frame. Reuse the descriptor's
        // buffer, never enlarge tiny images, and keep both axes within 64 px.
        final scale = math.min(
          1.0,
          64 / math.max(descriptor.width, descriptor.height),
        );
        final codec = await descriptor.instantiateCodec(
          targetWidth: math.max(1, (descriptor.width * scale).round()),
          targetHeight: math.max(1, (descriptor.height * scale).round()),
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
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
    if (!await file.exists()) {
      await file.writeAsBytes(bytes, flush: true);
      changed.value++;
    }
    return 'artwork:$id';
  }

  static Future<void> trim(Directory dir) async {
    await (await cache).trimUnowned();
  }
}
