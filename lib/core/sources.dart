import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:smb_connect/smb_connect.dart';
import 'catalog.dart';

class DavEntry {
  DavEntry(this.uri, this.name, this.isDirectory, this.size);
  final Uri uri;
  final String name;
  final bool isDirectory;
  final int? size;
}

class WebDav {
  factory WebDav(Map<String, Object?> source) =>
      source['kind'] == 'smb' ? SmbSource(source) : WebDav._(source);
  WebDav._(Map<String, Object?> source)
    : root = Uri.parse(
        source['location'].toString().endsWith('/')
            ? source['location'].toString()
            : '${source['location']}/',
      ),
      username = source['username']?.toString() ?? '',
      password = source['password']?.toString() ?? '';
  final Uri root;
  final String username, password;
  String get auth =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';
  Uri fileUri(String relative) =>
      root.resolve(relative.split('/').map(Uri.encodeComponent).join('/'));
  Uri directoryUri(String relative) {
    final normalized = Catalog.normalizeRoot(relative);
    return normalized.isEmpty
        ? root
        : root.resolve(
            '${normalized.split('/').map(Uri.encodeComponent).join('/')}/',
          );
  }

  Future<List<DavEntry>> list(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    client.authenticate = (url, scheme, realm) async {
      if (username.isEmpty ||
          url.host != root.host ||
          url.port != root.port ||
          url.scheme != root.scheme) {
        return false;
      }
      final credentials = scheme.toLowerCase() == 'digest'
          ? HttpClientDigestCredentials(username, password)
          : HttpClientBasicCredentials(username, password);
      client.addCredentials(url, realm ?? '', credentials);
      return true;
    };
    try {
      final request = await client.openUrl('PROPFIND', uri);
      request.headers.set('Depth', '1');
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      if (username.isNotEmpty) request.headers.set('Authorization', auth);
      request.write(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:allprop/></d:propfind>',
      );
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode != 207) {
        throw HttpException('PROPFIND HTTP ${response.statusCode}', uri: uri);
      }
      final doc = XmlDocument.parse(body);
      final entries = <DavEntry>[];
      // WebDAV PROPFIND Depth:1 includes the queried directory itself.
      // Compare decoded path *segments* and require exactly one child level.
      // Comparing URI strings alone can fail for Chinese characters, spaces,
      // percent-encoding variants and trailing slashes.
      final parentSegments = uri.pathSegments
          .where((s) => s.isNotEmpty)
          .toList();
      final seen = <String>{};
      for (final item in doc.descendants.whereType<XmlElement>().where(
        (e) => e.name.local == 'response',
      )) {
        final href = item.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'href')
            .firstOrNull
            ?.innerText;
        if (href == null) continue;
        final target = uri.resolve(href);
        if (target.scheme != root.scheme ||
            target.host != root.host ||
            target.port != root.port) {
          continue;
        }
        final segments = target.pathSegments
            .where((x) => x.isNotEmpty)
            .toList();
        if (segments.length != parentSegments.length + 1) continue;
        var directChild = true;
        for (var i = 0; i < parentSegments.length; i++) {
          if (segments[i] != parentSegments[i]) {
            directChild = false;
            break;
          }
        }
        if (!directChild) continue;
        final key = segments.join('/');
        if (!seen.add(key)) continue;
        final dir = item.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == 'collection',
        );
        final length = item.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'getcontentlength')
            .firstOrNull
            ?.innerText;
        entries.add(
          DavEntry(target, segments.last, dir, int.tryParse(length ?? '')),
        );
      }
      return entries;
    } finally {
      client.close(force: true);
    }
  }
}

/// Read-only SMB adapter using the same client vendored by NipaPlay Personal.
/// It exposes the directory interface shared by browsing, scanning and subtitles.
class SmbSource extends WebDav {
  SmbSource(Map<String, Object?> source, {this.connector}) : super._(source) {
    validateLocation(source['location'].toString());
  }
  final Future<SmbConnect> Function()? connector;

  static Uri validateLocation(String location) {
    if (location
        .replaceAll(RegExp('%2e', caseSensitive: false), '.')
        .replaceAll(RegExp('%2f|%5c', caseSensitive: false), '/')
        .replaceAll('\\', '/')
        .split('/')
        .any((s) => s == '..' || s == '.')) {
      throw ArgumentError('SMB 地址不能包含相对路径');
    }
    final uri = Uri.tryParse(location.trim());
    if (uri == null ||
        uri.scheme != 'smb' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.hasPort && uri.port != 445) ||
        uri.pathSegments.where((s) => s.isNotEmpty).isEmpty ||
        uri.pathSegments.any(
          (s) => s == '..' || s == '.' || s.contains('\\'),
        )) {
      throw ArgumentError('请输入 SMB 共享地址，例如 smb://192.168.1.2/共享目录');
    }
    return uri;
  }

  Future<SmbConnect> connect() {
    if (connector != null) return connector!();
    final split = username.indexOf('\\');
    return SmbConnect.connectAuth(
      host: root.host,
      domain: split < 0 ? '' : username.substring(0, split),
      username: split < 0 ? username : username.substring(split + 1),
      password: password,
    );
  }

  String _path(Uri uri) {
    if (uri.host != root.host ||
        uri.scheme != 'smb' ||
        !uri.path.startsWith(root.path) ||
        uri.pathSegments.any((s) => s == '..')) {
      throw ArgumentError('SMB 路径不在媒体源内');
    }
    return '/${uri.pathSegments.where((s) => s.isNotEmpty).join('/')}';
  }

  @override
  Future<List<DavEntry>> list(Uri uri) async {
    final path = _path(uri);
    final client = await connect();
    try {
      final folder = await client.file(path);
      final files = await client.listFiles(folder);
      return files
          .where((f) => f.name != '.' && f.name != '..')
          .map(
            (file) => DavEntry(
              uri.resolve(
                '${Uri.encodeComponent(file.name)}${file.isDirectory() ? '/' : ''}',
              ),
              file.name,
              file.isDirectory(),
              file.size,
            ),
          )
          .toList();
    } finally {
      await client.close();
    }
  }

  Future<void> serve(HttpRequest request, String relative) async {
    SmbConnect? client;
    try {
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final path = _path(fileUri(relative));
      client = await connect();
      final file = await client.file(path);
      if (!file.isExists || file.isDirectory()) {
        request.response.statusCode = HttpStatus.notFound;
        return;
      }
      final size = file.size;
      SmbByteRange range;
      try {
        range = SmbByteRange.parse(
          request.headers.value(HttpHeaders.rangeHeader),
          size,
        );
      } on FormatException {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes */$size',
        );
        return;
      }
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      request.response.headers.contentType = ContentType.binary;
      request.response.contentLength = range.end - range.start;
      if (range.partial) {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes ${range.start}-${range.end - 1}/$size',
        );
      }
      if (request.method != 'HEAD' && range.end > range.start) {
        await request.response.addStream(
          await client.openRead(file, range.start, range.end),
        );
      }
    } catch (_) {
      request.response.statusCode = HttpStatus.badGateway;
    } finally {
      try {
        await request.response.close();
      } finally {
        await client?.close();
      }
    }
  }
}

class SmbByteRange {
  const SmbByteRange(this.start, this.end, this.partial);
  final int start, end;
  final bool partial;
  static SmbByteRange parse(String? header, int size) {
    if (header == null) return SmbByteRange(0, size, false);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null || size <= 0) {
      throw const FormatException('Invalid range');
    }
    final first = int.tryParse(match[1]!);
    final last = int.tryParse(match[2]!);
    if (first == null) {
      if (last == null || last <= 0) {
        throw const FormatException('Invalid suffix');
      }
      return SmbByteRange(max(0, size - last), size, true);
    }
    if (first >= size || (last != null && last < first)) {
      throw const FormatException('Invalid range');
    }
    return SmbByteRange(first, last == null ? size : min(size, last + 1), true);
  }
}

class Scanner {
  static Future<int> scan(Map<String, Object?> source) async {
    final cat = Catalog.instance;
    source = await cat.withCredentials(source);
    final id = source['id'].toString();
    var count = 0;
    cat.updateStatus('扫描中：${source['label']}', true);
    try {
      if (source['kind'] == 'local') {
        final folder = Directory(source['location'].toString());
        if (!await folder.exists()) throw StateError('目录不存在');
        await for (final entity in folder.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File || !Catalog.isVideo(entity.path)) continue;
          final relative = p
              .relative(entity.path, from: folder.path)
              .replaceAll('\\', '/');
          if (!relative.contains('/')) continue;
          await cat.indexVideo(id, relative, (await entity.stat()).size);
          count++;
          if (count % 100 == 0) cat.updateStatus('扫描到 $count 个视频', true);
        }
      } else {
        final dav = WebDav(source);
        final pending = <({Uri uri, String relative})>[
          (uri: dav.root, relative: ''),
        ];
        final visited = <String>{};
        while (pending.isNotEmpty) {
          final directory = pending.removeLast();
          if (!visited.add(directory.uri.toString())) continue;
          final children = await dav.list(directory.uri);
          for (final entry in children) {
            final relative = directory.relative.isEmpty
                ? entry.name
                : '${directory.relative}/${entry.name}';
            if (entry.isDirectory) {
              if (RegExp(
                r'^(CDs?|Scans?)$',
                caseSensitive: false,
              ).hasMatch(entry.name)) {
                continue;
              }
              pending.add((uri: entry.uri, relative: relative));
            } else if (Catalog.isVideo(entry.name) && relative.contains('/')) {
              await cat.indexVideo(id, relative, entry.size);
              count++;
            }
          }
          if (visited.length % 10 == 0) {
            cat.updateStatus('已扫描 ${visited.length} 个目录、$count 个视频', true);
          }
        }
      }
      await cat.reload();
      cat.updateStatus('扫描完成：$count 个视频');
      return count;
    } catch (e) {
      cat.updateStatus('扫描失败：$e');
      rethrow;
    }
  }
}

/// Local loopback file broker for media and subtitle resources.
class StreamBroker {
  StreamBroker._();
  static final instance = StreamBroker._();
  HttpServer? _server;
  bool _listening = false;
  final Map<String, ({Map<String, Object?> source, String path})> _tickets = {};
  Future<Uri> issue(Map<String, Object?> source, String path) async {
    _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    if (!_listening) {
      _listening = true;
      _server!.listen(_handle);
    }
    final random = Random.secure();
    final ticket = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    _tickets[ticket] = (
      source: await Catalog.instance.withCredentials(source),
      path: path,
    );
    return Uri.parse('http://127.0.0.1:${_server!.port}/file/$ticket');
  }

  Future<void> _handle(HttpRequest req) async {
    final ticket = req.uri.pathSegments.isEmpty
        ? ''
        : req.uri.pathSegments.last;
    final info = _tickets[ticket];
    if (info == null) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    if (info.source['kind'] == 'smb') {
      await SmbSource(info.source).serve(req, info.path);
      return;
    }
    final client = HttpClient()..autoUncompress = false;
    try {
      final dav = WebDav(info.source);
      final upstream = await client.openUrl(req.method, dav.fileUri(info.path));
      if (dav.username.isNotEmpty) {
        upstream.headers.set('Authorization', dav.auth);
      }
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
      final response = await upstream.close();
      req.response.statusCode = response.statusCode;
      for (final header in [
        'content-length',
        'content-range',
        'accept-ranges',
        'content-type',
        'etag',
        'last-modified',
      ]) {
        final value = response.headers.value(header);
        if (value != null) req.response.headers.set(header, value);
      }
      if (req.method != 'HEAD') await req.response.addStream(response);
    } catch (e) {
      req.response.statusCode = 502;
    } finally {
      await req.response.close();
      client.close(force: true);
    }
  }

  Future<List<String>> subtitles(
    Map<String, Object?> source,
    String relative,
  ) async {
    source = await Catalog.instance.withCredentials(source);
    if (source['kind'] == 'local') {
      final file = File(
        p.join(
          source['location'].toString(),
          relative.replaceAll('/', Platform.pathSeparator),
        ),
      );
      final folder = file.parent;
      if (!await folder.exists()) return [];
      final stem = p.basenameWithoutExtension(file.path).toLowerCase();
      final entries = await folder
          .list()
          .where((f) => f is File)
          .cast<File>()
          .toList();
      return entries
          .where(
            (f) =>
                Catalog.isSubtitle(f.path) &&
                p
                    .basenameWithoutExtension(f.path)
                    .toLowerCase()
                    .startsWith(stem),
          )
          .map(
            (f) => p
                .relative(f.path, from: source['location'].toString())
                .replaceAll('\\', '/'),
          )
          .toList();
    }
    final dav = WebDav(source);
    final idx = relative.lastIndexOf('/');
    final dirname = idx < 0 ? '' : relative.substring(0, idx);
    final stem = p.posix.basenameWithoutExtension(relative).toLowerCase();
    final url = dirname.isEmpty
        ? dav.root
        : dav.root.resolve(
            '${dirname.split('/').map(Uri.encodeComponent).join('/')}/',
          );
    final entries = await dav.list(url);
    return entries
        .where(
          (e) =>
              !e.isDirectory &&
              Catalog.isSubtitle(e.name) &&
              p.posix
                  .basenameWithoutExtension(e.name)
                  .toLowerCase()
                  .startsWith(stem),
        )
        .map((e) => dirname.isEmpty ? e.name : '$dirname/${e.name}')
        .toList();
  }
}
