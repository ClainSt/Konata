import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';
import 'package:smb_connect/smb_connect.dart';
import 'catalog.dart';
import 'cloud_media_asset_presentation.dart';
import 'cloud_media_file_classifier.dart';
import 'personal_filename_parser.dart';
import 'library_foundation.dart';
import 'webdav_stream.dart';
import 'local_media.dart';
import 'debug_log.dart';

enum SourceAccessProblem implements Exception {
  authentication,
  permission,
  path,
  network,
  timeout,
  tls,
  unknown;

  static SourceAccessProblem from(Object error) {
    if (error is SourceAccessProblem) return error;
    if (error is TimeoutException) return timeout;
    if (error is HandshakeException) return tls;
    if (error is SocketException) return network;
    if (error is PathAccessException) return permission;
    if (error is PathNotFoundException) return path;
    if (error is SmbAuthException) return authentication;
    // The vendored SMB transport also throws decoded NT status strings.
    final status = error is SmbException ? error.message : error;
    if (status is String) {
      const codes = {
        NtStatus.NT_STATUS_LOGON_FAILURE: authentication,
        NtStatus.NT_STATUS_ACCESS_DENIED: permission,
        NtStatus.NT_STATUS_NETWORK_ACCESS_DENIED: permission,
        NtStatus.NT_STATUS_BAD_NETWORK_NAME: path,
        NtStatus.NT_STATUS_OBJECT_NAME_NOT_FOUND: path,
        NtStatus.NT_STATUS_OBJECT_PATH_NOT_FOUND: path,
        NtStatus.NT_STATUS_NOT_A_DIRECTORY: path,
        NtStatus.NT_STATUS_CONNECTION_REFUSED: network,
      };
      for (final entry in codes.entries) {
        if (SmbException.getMessageByCode(entry.key) == status) {
          return entry.value;
        }
      }
    }
    return unknown;
  }
}

class DavEntry {
  DavEntry(this.uri, this.name, this.isDirectory, this.size);
  final Uri uri;
  final String name;
  final bool isDirectory;
  final int? size;
}

class WebDav {
  factory WebDav(Map<String, Object?> source, {bool reuseListings = false}) =>
      source['kind'] == 'smb'
      ? SmbSource(source)
      : WebDav._(source, reuseListings: reuseListings);
  WebDav._(Map<String, Object?> source, {this.reuseListings = false})
    : root = Uri.parse(
        source['location'].toString().endsWith('/')
            ? source['location'].toString()
            : '${source['location']}/',
      ),
      username = source['username']?.toString() ?? '',
      password = source['password']?.toString() ?? '';
  final Uri root;
  final String username, password;
  final bool reuseListings;
  HttpClient? _listingClient;
  final _listingAuthRetries = <Uri>{};

  void close() {
    _listingClient?.close(force: true);
    _listingClient = null;
    _listingAuthRetries.clear();
  }
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

  HttpClient _openListingClient(Set<Uri> retries) {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    client.authenticate = (url, scheme, realm) async {
      if (username.isEmpty ||
          url.host != root.host ||
          url.port != root.port ||
          url.scheme != root.scheme ||
          (!reuseListings && retries.isNotEmpty) ||
          !retries.add(url)) {
        return false;
      }
      final credentials = scheme.toLowerCase() == 'digest'
          ? HttpClientDigestCredentials(username, password)
          : HttpClientBasicCredentials(username, password);
      client.addCredentials(url, realm ?? '', credentials);
      return true;
    };
    return client;
  }

  Future<List<DavEntry>> list(Uri uri, {bool requireComplete = false}) async {
    final client = reuseListings
        ? _listingClient ??= _openListingClient(_listingAuthRetries)
        : _openListingClient(<Uri>{});
    HttpClientRequest? opened;
    try {
      final request = opened = await client.openUrl('PROPFIND', uri);
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
      final response = await request.close().timeout(
        const Duration(seconds: 18),
      );
      if (response.statusCode != 207) {
        request.abort();
        throw switch (response.statusCode) {
          401 => SourceAccessProblem.authentication,
          403 => SourceAccessProblem.permission,
          404 || 410 => SourceAccessProblem.path,
          _ => HttpException('PROPFIND HTTP ${response.statusCode}'),
        };
      }
      final body = await utf8.decodeStream(
        response.timeout(const Duration(seconds: 18)),
      );
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
      var sawDirectory = false;
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
        final self = segments.length == parentSegments.length;
        if ((!requireComplete || !self) &&
            segments.length != parentSegments.length + 1) {
          continue;
        }
        var directChild = true;
        for (var i = 0; i < parentSegments.length; i++) {
          if (segments[i] != parentSegments[i]) {
            directChild = false;
            break;
          }
        }
        if (!directChild) continue;
        if (requireComplete) {
          final responseStatus = item.childElements
              .where((e) => e.name.local == 'status')
              .firstOrNull;
          final properties = item.childElements.where(
            (e) => e.name.local == 'propstat',
          );
          final typed = properties.any((property) {
            final status = property.childElements
                .where((e) => e.name.local == 'status')
                .firstOrNull;
            return RegExp(
                  r'\s2\d\d(?:\s|$)',
                ).hasMatch(status?.innerText ?? '') &&
                property.descendants.whereType<XmlElement>().any(
                  (e) => e.name.local == 'resourcetype',
                );
          });
          if (responseStatus != null &&
                  !RegExp(
                    r'\s2\d\d(?:\s|$)',
                  ).hasMatch(responseStatus.innerText) ||
              !typed) {
            throw const FormatException('Incomplete WebDAV directory response');
          }
        }
        final dir = item.descendants.whereType<XmlElement>().any(
          (e) => e.name.local == 'collection',
        );
        if (self) {
          sawDirectory = dir;
          continue;
        }
        final key = segments.join('/');
        if (!seen.add(key)) continue;
        final length = item.descendants
            .whereType<XmlElement>()
            .where((e) => e.name.local == 'getcontentlength')
            .firstOrNull
            ?.innerText;
        entries.add(
          DavEntry(target, segments.last, dir, int.tryParse(length ?? '')),
        );
      }
      if (requireComplete && !sawDirectory) {
        throw const FormatException(
          'WebDAV listing did not verify its directory',
        );
      }
      return entries;
    } on TimeoutException {
      opened?.abort();
      rethrow;
    } finally {
      if (reuseListings) {
        _listingAuthRetries.remove(uri);
      } else {
        client.close(force: true);
      }
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
  final _activeReads = <Future<void> Function()>{};
  bool _closed = false;

  @override
  void close() {
    _closed = true;
    for (final disconnect in _activeReads.toList()) {
      unawaited(
        disconnect().catchError((Object error, StackTrace stack) {
          DebugLog.exception('SMB', 'cancel_close_failed', error, stack);
        }),
      );
    }
  }

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
  Future<List<DavEntry>> list(Uri uri, {bool requireComplete = false}) async {
    final path = _path(uri);
    final client = await connect();
    try {
      final folder = await client.file(path);
      if (!folder.isExists) throw SourceAccessProblem.path;
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
    Socket? downstream;
    StreamSubscription<List<int>>? downstreamInput;
    Future<dynamic>? disconnecting;
    Future<void> disconnect() async {
      if (client != null) await (disconnecting ??= client.close());
    }

    Future<void> cancel() async {
      downstream?.destroy();
      await disconnect();
    }

    _activeReads.add(cancel);
    var streaming = false;
    Socket? abortedResponse;
    try {
      if (_closed) {
        request.response.statusCode = HttpStatus.gone;
        return;
      }
      if (request.method != 'GET' && request.method != 'HEAD') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      final path = _path(fileUri(relative));
      client = await connect();
      // Revocation may arrive while the connection handshake is pending.
      if (_closed) throw const SocketException('SMB ticket revoked');
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
        final payload = await client.openRead(file, range.start, range.end);
        // This detached socket is closed after the payload; do not advertise
        // keep-alive and let clients race to reuse a connection being closed.
        request.response.persistentConnection = false;
        streaming = true;
        downstream = await request.response.detachSocket();
        if (_closed) throw const SocketException('SMB ticket revoked');
        void disconnected() {
          unawaited(
            cancel().catchError((Object error, StackTrace stack) {
              DebugLog.exception(
                'SMB',
                'disconnect_close_failed',
                error,
                stack,
              );
            }),
          );
        }

        downstreamInput = downstream.listen(
          (_) {},
          onDone: disconnected,
          onError: (Object _) => disconnected(),
        );
        await downstream.addStream(payload);
        await downstream.flush();
        await downstream.close();
      }
    } catch (error) {
      DebugLog.event('SMB', 'read_failed', {
        'type': error.runtimeType.toString(),
        'message': error.toString(),
        'streaming': streaming,
      }, level: 'DEBUG');
      if (!streaming) {
        request.response.statusCode = HttpStatus.badGateway;
        request.response.contentLength = 0;
      } else {
        // Once streaming begins, an interrupted body cannot be replaced with
        // a new status/header block. Abort the downstream connection instead.
        try {
          abortedResponse =
              downstream ??
              await request.response.detachSocket(writeHeaders: false);
          abortedResponse.destroy();
        } catch (_) {
          // The downstream may already have disconnected.
        }
      }
    } finally {
      try {
        if (downstream != null) {
          await downstreamInput?.cancel();
          downstream.destroy();
        } else if (abortedResponse == null) {
          await request.response.close();
        }
      } catch (error, stack) {
        DebugLog.exception('SMB', 'response_close_failed', error, stack);
      } finally {
        try {
          await disconnect();
        } catch (error, stack) {
          // A cancelled read may already have lost its peer. Transport.close
          // still releases the socket; cleanup must not escape the HTTP task.
          DebugLog.exception('SMB', 'close_failed', error, stack);
        } finally {
          _activeReads.remove(cancel);
        }
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
    final id = source['id'].toString();
    final locationRevision = cat.foundationEnabled
        ? await LibraryFoundation.sourceRevision(cat.db, id)
        : null;
    source = await cat.withCredentials(source);
    var count = 0;
    cat.updateStatus('扫描中：${source['label']}', true);
    try {
      if (source['kind'] == 'local') {
        final pending = <String>[''];
        while (pending.isNotEmpty) {
          final directory = pending.removeLast();
          final entries = await LocalMedia.list(
            source['location'].toString(),
            directory,
          );
          for (final entry in entries) {
            final relative = directory.isEmpty
                ? entry.name
                : '$directory/${entry.name}';
            if (entry.directory) {
              pending.add(relative);
            } else if (Catalog.isVideo(entry.name) && relative.contains('/')) {
              await cat.indexVideo(
                id,
                relative,
                entry.size,
                expectedLocationRevision: locationRevision,
              );
              count++;
              if (count % 100 == 0) cat.updateStatus('扫描到 $count 个视频', true);
            }
          }
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
              await cat.indexVideo(
                id,
                relative,
                entry.size,
                expectedLocationRevision: locationRevision,
              );
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
  Future<HttpServer>? _server;
  final Map<String, ({Map<String, Object?> source, String path})> _tickets = {};
  final _relays = <String, WebDavStream>{};
  final _smbRelays = <String, SmbSource>{};

  Future<HttpServer> _startServer() async {
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(_handle);
      return server;
    } catch (_) {
      // A failed listener must not leave a bound server behind. Keep the shared
      // initialization pending until cleanup finishes, then allow a retry.
      try {
        await server?.close(force: true);
      } catch (_) {}
      _server = null;
      rethrow;
    }
  }

  Future<Uri> issue(
    Map<String, Object?> source,
    String path, {
    String purpose = 'playback',
    String? diagnosticSession,
  }) async {
    final server = await (_server ??= _startServer());
    final random = Random.secure();
    final ticket = base64UrlEncode(
      List<int>.generate(32, (_) => random.nextInt(256)),
    ).replaceAll('=', '');
    _tickets[ticket] = (
      source: await Catalog.instance.withCredentials(source),
      path: path,
    );
    if (source['kind'] == 'smb') {
      _smbRelays[ticket] = SmbSource(_tickets[ticket]!.source);
    } else {
      final dav = WebDav(_tickets[ticket]!.source);
      _relays[ticket] = WebDavStream(
        target: dav.fileUri(path),
        username: dav.username,
        password: dav.password,
        authorization: dav.username.isEmpty ? null : dav.auth,
        purpose: purpose,
        diagnosticSession: diagnosticSession,
      );
    }
    return Uri.parse('http://127.0.0.1:${server.port}/file/$ticket');
  }

  void revoke(Uri uri) {
    final ticket = uri.pathSegments.lastOrNull;
    if (ticket == null) return;
    _tickets.remove(ticket);
    _relays.remove(ticket)?.close();
    _smbRelays.remove(ticket)?.close();
  }

  bool interruptedWebDavRead(Uri uri) =>
      _relays[uri.pathSegments.lastOrNull]?.interruptedRead ?? false;

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
      await _smbRelays[ticket]!.serve(req, info.path);
      return;
    }
    await _relays[ticket]!.serve(req);
  }

  Future<List<String>> subtitles(
    Map<String, Object?> source,
    String relative,
  ) async => [
    for (final match in await subtitleMatches(source, relative)) match.path,
  ];

  Future<List<({String path, bool automatic})>> subtitleMatches(
    Map<String, Object?> source,
    String relative,
  ) async {
    source = await Catalog.instance.withCredentials(source);
    final parent = p.posix.dirname(relative);
    final folder = parent == '.' ? '' : parent;
    final List<String> names;
    if (source['kind'] == 'local') {
      final entries = await LocalMedia.list(
        source['location'].toString(),
        folder,
      );
      names = [
        for (final entry in entries)
          if (!entry.directory) entry.name,
      ];
    } else {
      final dav = WebDav(source);
      try {
        final entries = await dav.list(dav.directoryUri(folder));
        names = [
          for (final entry in entries)
            if (!entry.isDirectory) entry.name,
        ];
      } finally {
        if (dav is SmbSource) dav.close();
      }
    }
    return _matchSubtitles(folder, p.posix.basename(relative), names);
  }

  static final _subtitleLanguageSuffix = RegExp(
    r'(?:[ ._-]+|\[)(?:chs|cht|sc|tc|gb|big5|zh(?:[-_](?:cn|tw|hk|hans|hant))?|'
    r'chi|zho|chinese|ja|jp|jpn|en|eng|english|japanese|简中|繁中|简体|繁體|中文|日语|日語|简日|繁日)\]?$',
    caseSensitive: false,
  );

  static List<({String path, bool automatic})> _matchSubtitles(
    String folder,
    String video,
    List<String> names,
  ) {
    String stem(String name) => p.posix.basenameWithoutExtension(name);
    final videoStem = stem(video).toLowerCase();
    final exact = <String>[];
    final renamed = <String>[];
    final episode = _subtitleEpisode(folder, videoStem);
    for (final name in names.where(Catalog.isSubtitle).toSet()) {
      final subtitleStem = stem(name).toLowerCase();
      final base = subtitleStem.replaceFirst(_subtitleLanguageSuffix, '');
      if (subtitleStem == videoStem || base == videoStem) {
        exact.add(name);
      } else if (episode != null &&
          _sameSubtitleEpisode(episode, _subtitleEpisode(folder, base))) {
        renamed.add(name);
      }
    }
    // A same-episode fallback cannot distinguish two cuts or works sharing
    // a directory. Keep those choices visible without choosing one silently.
    var uniqueRename = exact.isEmpty && renamed.length == 1;
    if (uniqueRename) {
      final renamedEpisode = _subtitleEpisode(folder, stem(renamed.single));
      uniqueRename = !names.any(
        (name) =>
            name != video &&
            Catalog.isVideo(name) &&
            _sameSubtitleEpisode(
              renamedEpisode,
              _subtitleEpisode(folder, stem(name)),
            ),
      );
    }
    String path(String name) => folder.isEmpty ? name : '$folder/$name';
    return [
      for (final name in exact) (path: path(name), automatic: true),
      for (final name in renamed) (path: path(name), automatic: uniqueRename),
    ];
  }

  static ({int? season, int number})? _subtitleEpisode(
    String folder,
    String stem,
  ) {
    final name = stem.replaceFirst(_subtitleLanguageSuffix, '');
    if (CloudMediaFileClassifier.isClearlySupplementary(folder, name)) {
      return null;
    }
    final number =
        CloudMediaFileClassifier.episodeNumberFromNameInDirectory(
          folder,
          name,
        ) ??
        PersonalFilenameParser.bareEpisode('$name.mkv')?.episode;
    if (number == null) return null;
    return (
      season: CloudMediaAssetPresentation.explicitSeasonNumber({
        'name': name,
        'relative_path': folder,
      }),
      number: number,
    );
  }

  static bool _sameSubtitleEpisode(
    ({int? season, int number})? a,
    ({int? season, int number})? b,
  ) =>
      a != null &&
      b != null &&
      a.number == b.number &&
      (a.season == null || b.season == null || a.season == b.season);
}
