import 'dart:async';
import 'dart:io';
import 'debug_log.dart';

/// Raw byte relay. Never slices a 200 response or invents a 206 response.
/// One instance belongs to one revocable media ticket, not a global semaphore.
class WebDavStream {
  WebDavStream({
    required this.target,
    this.authorization,
    this.username = '',
    this.password = '',
    this.purpose = 'playback',
    this.diagnosticSession,
    this.headerTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  });
  final Uri target;
  final String? authorization;
  final String username, password, purpose;
  final String? diagnosticSession;
  final _streamId = DebugLog.newId('dav');
  int _requestSerial = 0;
  final Duration headerTimeout, idleTimeout;
  final _clients = <HttpClient>{};
  HttpClient? _idleClient;
  Timer? _idleTimer;
  bool _closed = false;
  int get activeRequests => _clients.length;
  void close() {
    _closed = true;
    _idleTimer?.cancel();
    _idleClient?.close(force: true);
    _idleClient = null;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
  }

  bool _origin(Uri uri) =>
      uri.scheme == target.scheme &&
      uri.host == target.host &&
      uri.port == target.port;

  Future<void> serve(HttpRequest req) async {
    // A completed read may leave one reusable connection for this ticket.
    // Active requests keep separate clients so cancelling a seek cannot kill
    // another read. Never drain a cancelled media response just to reuse it.
    final connectionReused = _idleClient != null;
    var client =
        _idleClient ??
        (HttpClient()
          ..autoUncompress = false
          ..connectionTimeout = headerTimeout);
    _idleTimer?.cancel();
    _idleClient = null;
    var reusable = false;
    var bytes = 0, status = 0;
    var headersMs = -1;
    var firstByteMs = -1, lastDataMs = -1, maxObservedGapMs = 0;
    var phase = 'request', failure = 'none';
    var streaming = false, finished = false, cancelled = false;
    Socket? downstream;
    StreamSubscription<List<int>>? downstreamInput;
    final clock = Stopwatch()..start();
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final requested = range == null ? null : _RequestedRange.parse(range);
    final requestId = '$_streamId-${++_requestSerial}';
    void record(String event, {String level = 'INFO'}) {
      DebugLog.event('WebDAVStream', event, {
        'session': diagnosticSession,
        'request': requestId,
        'method': req.method == 'HEAD'
            ? 'HEAD'
            : req.method == 'GET'
            ? 'GET'
            : 'OTHER',
        'purpose': ['preview', 'subtitle'].contains(purpose)
            ? purpose
            : 'playback',
        'connectionReused': connectionReused,
        'rangeStart': requested?.first,
        'rangeEnd': requested?.last,
        'rangeBytes': requested?.boundedLength ?? -1,
        'status': req.response.statusCode,
        'upstreamStatus': status,
        'bytes': bytes,
        'elapsedMs': clock.elapsedMilliseconds,
        'headersMs': headersMs,
        'firstByteMs': firstByteMs,
        'maxObservedGapMs': maxObservedGapMs,
        'cancelled': cancelled || _closed,
        'phase': phase,
        'failure': failure,
      }, level: level);
    }

    record('request_start');
    final waiting = Timer(const Duration(seconds: 3), () {
      if (!finished && !cancelled && !_closed && firstByteMs < 0) {
        record('initial_wait', level: 'WARN');
      }
    });
    final clients = <HttpClient>{client};
    _clients.add(client);
    void cancel() {
      if (!finished) cancelled = true;
      for (final c in clients) {
        c.close(force: true);
      }
      downstream?.destroy();
    }

    // A downstream disconnect must cancel a stalled upstream read too.
    unawaited(
      req.response.done.then<void>(
        (_) {
          if (!finished && !streaming) cancel();
        },
        onError: (Object e, StackTrace s) {
          if (!streaming) cancel();
        },
      ),
    );
    try {
      if (_closed) {
        req.response.statusCode = HttpStatus.gone;
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        req.response.statusCode = HttpStatus.methodNotAllowed;
        req.response.headers.set(HttpHeaders.allowHeader, 'GET, HEAD');
        return;
      }
      if (range != null && requested == null) {
        req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      var uri = target;
      HttpClientResponse? response;
      for (var hop = 0; hop <= 5; hop++) {
        if (_closed) throw const HttpException('Ticket closed');
        status = 0;
        phase = 'connect';
        client.authenticate = (url, scheme, realm) async {
          if (username.isEmpty || !_origin(url)) return false;
          client.addCredentials(
            url,
            realm ?? '',
            scheme.toLowerCase() == 'digest'
                ? HttpClientDigestCredentials(username, password)
                : HttpClientBasicCredentials(username, password),
          );
          return true;
        };
        final upstream = await client
            .openUrl(req.method, uri)
            .timeout(headerTimeout);
        upstream.followRedirects = false;
        upstream.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (_origin(uri) && authorization != null) {
          upstream.headers.set(HttpHeaders.authorizationHeader, authorization!);
        }
        if (range != null) upstream.headers.set(HttpHeaders.rangeHeader, range);
        final ifRange = req.headers.value(HttpHeaders.ifRangeHeader);
        if (ifRange != null) {
          upstream.headers.set(HttpHeaders.ifRangeHeader, ifRange);
        }
        phase = 'headers';
        response = await upstream.close().timeout(headerTimeout);
        status = response.statusCode;
        if (![301, 302, 303, 307, 308].contains(status)) break;
        phase = 'redirect';
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || hop == 5) {
          throw const HttpException('Invalid redirect');
        }
        final next = uri.resolve(location);
        if (!['http', 'https'].contains(next.scheme) ||
            next.userInfo.isNotEmpty ||
            (uri.scheme == 'https' && next.scheme != 'https')) {
          throw const HttpException('Unsafe redirect');
        }
        // Never drain a redirect body or forward DAV credentials to a CDN.
        client.close(force: true);
        _clients.remove(client);
        client = HttpClient()
          ..autoUncompress = false
          ..connectionTimeout = headerTimeout;
        clients.add(client);
        _clients.add(client);
        uri = next;
      }
      final upstream = response!;
      headersMs = clock.elapsedMilliseconds;
      record('headers', level: 'DEBUG');
      if (status != 200 && status != 206) {
        failure = 'upstreamHttp';
        req.response.statusCode = status;
        if (status == 416) {
          final contentRange = upstream.headers.value(
            HttpHeaders.contentRangeHeader,
          );
          if (contentRange != null &&
              RegExp(r'^bytes \*/[0-9]+$').hasMatch(contentRange)) {
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              contentRange,
            );
          }
        }
        req.response.contentLength = 0;
        return;
      }
      phase = 'validate';
      final encoding = upstream.headers.value(
        HttpHeaders.contentEncodingHeader,
      );
      if (encoding != null && encoding.toLowerCase() != 'identity') {
        throw const HttpException('Encoded representation');
      }
      final length = upstream.contentLength;
      final rawRange = upstream.headers.value(HttpHeaders.contentRangeHeader);
      int? expected = length < 0 ? null : length;
      if (status == 206) {
        final actual = _ResponseRange.parse(rawRange);
        if (requested == null ||
            actual == null ||
            !requested.accepts(actual) ||
            (length >= 0 && length != actual.length)) {
          throw const HttpException('Invalid partial response');
        }
        expected = actual.length;
      } else {
        if (rawRange != null) {
          throw const HttpException('Range on full response');
        }
        if (req.method != 'HEAD' &&
            requested != null &&
            !requested.acceptsFull(length)) {
          throw const HttpException('Upstream ignored range');
        }
      }
      req.response.statusCode = status;
      for (final header in [
        'content-range',
        'accept-ranges',
        'content-type',
        'etag',
        'last-modified',
      ]) {
        final value = upstream.headers.value(header);
        if (value != null) req.response.headers.set(header, value);
      }
      if (expected != null) req.response.contentLength = expected;
      if (req.method == 'HEAD') {
        await upstream.drain<void>().timeout(idleTimeout);
        reusable = _origin(uri) && upstream.persistentConnection;
        return;
      }
      req.response.persistentConnection = false;
      req.response.headers.chunkedTransferEncoding = expected == null;
      phase = 'stream';
      streaming = true;
      final socket = await req.response.detachSocket();
      downstream = socket;
      downstreamInput = socket.listen(
        (_) {},
        onDone: () {
          if (!finished) cancel();
        },
        onError: (Object e) {
          cancel();
        },
      );
      final payload = upstream.timeout(idleTimeout).map((chunk) {
        if (chunk.isNotEmpty) {
          final now = clock.elapsedMilliseconds;
          if (firstByteMs < 0) {
            firstByteMs = now;
            waiting.cancel();
            record('first_body');
          }
          if (lastDataMs >= 0 && now - lastDataMs > maxObservedGapMs) {
            maxObservedGapMs = now - lastDataMs;
          }
          lastDataMs = now;
        }
        if (expected != null && bytes + chunk.length > expected) {
          throw const HttpException('Excess body bytes');
        }
        bytes += chunk.length;
        return chunk;
      });
      // Unknown full-response lengths use real HTTP chunk framing. Framing is
      // outside the media bytes; no probing bytes enter the representation.
      await socket.addStream(
        expected != null
            ? payload
            : payload.expand(
                (chunk) => [
                  '${chunk.length.toRadixString(16)}\r\n'.codeUnits,
                  chunk,
                  '\r\n'.codeUnits,
                ],
              ),
      );
      if (expected != null && bytes != expected) {
        throw const HttpException('Truncated body');
      }
      if (expected == null) socket.add('0\r\n\r\n'.codeUnits);
      await socket.flush();
      finished = true;
      // Only keep a fully consumed, validated response from the original
      // origin. Redirect/CDN credentials and connections remain isolated.
      reusable = _origin(uri) && upstream.persistentConnection;
      await socket.close();
    } catch (e) {
      reusable = false;
      failure = e.runtimeType.toString();
      if (!streaming) {
        try {
          req.response.statusCode = HttpStatus.badGateway;
          req.response.contentLength = 0;
        } catch (_) {}
      } else {
        // Committed headers cannot become a successful replacement response.
        downstream?.destroy();
      }
    } finally {
      waiting.cancel();
      finished = true;
      downstream?.destroy();
      await downstreamInput?.cancel();
      try {
        await req.response.close();
      } catch (_) {}
      for (final c in clients) {
        _clients.remove(c);
        if (identical(c, client) &&
            reusable &&
            !cancelled &&
            !_closed &&
            _idleClient == null) {
          _idleClient = c;
          // Bound both idle sockets and their lifetime; no byte cache is added.
          _idleTimer = Timer(const Duration(seconds: 5), () {
            _idleClient?.close(force: true);
            _idleClient = null;
          });
        } else {
          c.close(force: true);
        }
      }
      record(
        'request_end',
        level: cancelled || _closed
            ? 'INFO'
            : failure != 'none'
            ? 'ERROR'
            : headersMs >= 3000 ||
                  firstByteMs >= 3000 ||
                  maxObservedGapMs >= 3000
            ? 'WARN'
            : 'INFO',
      );
    }
  }
}

class _RequestedRange {
  const _RequestedRange(this.first, this.last);
  final int? first, last;
  int? get boundedLength =>
      first != null && last != null ? last! - first! + 1 : null;
  static _RequestedRange? parse(String text) {
    final m = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(text);
    if (m == null) return null;
    final first = int.tryParse(m[1]!), last = int.tryParse(m[2]!);
    if (first == null && (m[1]!.isNotEmpty || last == null || last <= 0)) {
      return null;
    }
    if (first != null &&
        (first < 0 ||
            (m[2]!.isNotEmpty && last == null) ||
            (last != null && last < first))) {
      return null;
    }
    return _RequestedRange(first, last);
  }

  bool acceptsFull(int length) =>
      first == 0 && (last == null || (length >= 0 && length <= last! + 1)) ||
      first == null && length >= 0 && length <= last!;
  bool accepts(_ResponseRange r) {
    if (first == null) {
      return r.total != null &&
          r.first == (r.total! - last!).clamp(0, r.total!) &&
          r.last == r.total! - 1;
    }
    return r.first == first && (last == null || r.last <= last!);
  }
}

class _ResponseRange {
  const _ResponseRange(this.first, this.last, this.total);
  final int first, last;
  final int? total;
  int get length => last - first + 1;
  static _ResponseRange? parse(String? text) {
    final m = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(text ?? '');
    if (m == null) return null;
    final first = int.tryParse(m[1]!),
        last = int.tryParse(m[2]!),
        total = int.tryParse(m[3]!);
    if (first == null ||
        last == null ||
        last < first ||
        (m[3] != '*' && (total == null || total <= last))) {
      return null;
    }
    return _ResponseRange(first, last, total);
  }
}
