import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'metadata_http.dart';
import 'metadata_servers.dart';
import 'scrape_tasks.dart';
import 'request_budget.dart';

class MetadataFailure implements Exception {
  const MetadataFailure(this.category, this.notBefore);
  final String category;
  final int notBefore;
}

class MetadataResource {
  MetadataResource({
    required this.service,
    required this.resource,
    required this.routes,
    this.headers = const {},
    this.parameters = const {},
    this.method = 'GET',
    this.body = '',
    this.trustCustom = false,
    this.accept,
    this.listResponse = false,
  });
  final bool listResponse;
  final bool Function(Map<String, dynamic>)? accept;
  final String service, resource, method, body;
  final List<Uri> routes;
  final Map<String, String> headers, parameters;
  final bool trustCustom;
  static String _hash(Object value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();
  static Map<String, String> _sorted(Map<String, String> value) => {
    for (final k in (value.keys.toList()..sort())) k: value[k]!,
  };
  // Persist only opaque fingerprints. Tokens and private endpoint URLs never enter logs/DB.
  String get serviceKey =>
      'service:${_hash([
        service,
        _sorted({for (final e in headers.entries)
          if (e.key.toLowerCase() == 'authorization') 'authorization': e.value}),
        parameters['api_key'],
      ])}';
  String get key =>
      'resource:${_hash([
        serviceKey,
        resource,
        method,
        _sorted({for (final e in headers.entries) e.key.toLowerCase(): e.value}),
        _sorted(parameters),
        body,
        if (listResponse) 'list-response',
      ])}';
}

class _Flight {
  final abort = Completer<void>();
  final users = <TaskLease, int>{};
  final paused = <TaskLease, Completer<void>>{};
  http.Client? client;
  late Future<Map<String, dynamic>> result;
  void stop() {
    if (!abort.isCompleted) abort.complete();
    client?.close();
  }
}

/// In-flight sharing only. A cancelled consumer cannot close another's request.
/// Cooldowns are database-backed; retry does not erase service rate limits.
class SharedMetadataRequests {
  SharedMetadataRequests(
    this.tasks, {
    this.clientFactory,
    this.deadline = const Duration(seconds: 25),
    this.retryDelays = const [Duration(seconds: 2), Duration(seconds: 6)],
    double Function()? jitter,
  }) : jitter = jitter ?? Random().nextDouble;
  final ScrapeTasks tasks;
  final http.Client Function()? clientFactory;
  final Duration deadline;
  final List<Duration> retryDelays;
  final double Function() jitter;
  final _flights = <String, _Flight>{};
  final _downloads = <http.Client>{};
  final _providerClients = <bool, MetadataHttp>{};
  void Function(TaskLease lease)? onRequestStart;
  // One recognition step may consult the same season/subject several times.
  // Keep only successful JSON within that lease; a rescan gets fresh evidence.
  var _completed = Expando<Map<String, String>>();
  Map<String, String>? _recognitionBatch;
  void beginRecognitionBatch() => _recognitionBatch = {};
  void endRecognitionBatch() => _recognitionBatch = null;
  bool _closed = false;
  int? githubRemaining;
  int get activeRequests => _flights.length;
  void close() {
    _closed = true;
    endRecognitionBatch();
    _completed = Expando<Map<String, String>>();
    for (final client in _downloads) {
      client.close();
    }
    _downloads.clear();
    for (final f in _flights.values) {
      f.stop();
    }
    _flights.clear();
    for (final client in _providerClients.values) {
      client.close();
    }
    _providerClients.clear();
  }

  Future<Map<String, dynamic>> get(
    MetadataResource resource,
    TaskLease lease, {
    bool manualRetry = false,
    bool reuseCompleted = false,
    Future<void>? consumerDeadline,
  }) async {
    lease.check();
    if (_closed ||
        resource.routes.isEmpty ||
        resource.routes.length > 3 ||
        !['GET', 'POST'].contains(resource.method) ||
        resource.body.length > 32768) {
      throw const TaskStopped();
    }
    await tasks.beforeNextRequest(lease);
    final entries = !reuseCompleted ? null :
        (!manualRetry ? _recognitionBatch : null) ??
        (_completed[lease] ??= <String, String>{});
    final flightKey = MetadataResource._hash([
      resource.key, resource.trustCustom, resource.routes.map((uri) => uri.toString()).toList(),
    ]);
    if (entries != null) {
      final cached = entries[flightKey];
      if (cached != null) {
        final body = jsonDecode(cached) as Map<String, dynamic>;
        if (resource.accept?.call(body) != false) return body;
      }
    }
    var flight = _flights[flightKey];
    if (flight == null) {
      if (_flights.length >= 64) throw StateError('Shared request capacity');
      flight = _Flight();
      flight.users[lease] = 1;
      _flights[flightKey] = flight;
      final owned = flight;
      owned.result = _fetch(resource, owned, manualRetry).whenComplete(() {
        if (identical(_flights[flightKey], owned)) {
          _flights.remove(flightKey);
        }
        owned.client?.close();
      });
    } else {
      flight.users.update(lease, (count) => count + 1, ifAbsent: () => 1);
    }
    final shared = flight;
    final paused = shared.paused.putIfAbsent(lease, Completer<void>.new);
    try {
      final result = await Future.any([
        shared.result,
        paused.future.then<Map<String, dynamic>>(
          (_) => throw const TaskPaused(),
        ),
        lease.cancelled.then<Map<String, dynamic>>(
          (_) => throw const TaskStopped(),
        ),
        if (consumerDeadline != null)
          consumerDeadline.then<Map<String, dynamic>>(
            (_) => throw const MetadataFailure('candidate_budget', 0),
          ),
      ]);
      lease.check();
      if (!await tasks.valid(lease)) throw const TaskStopped();
      if (entries != null) {
        final encoded = jsonEncode(result);
        // Bound retained JSON to 4 MiB per batch (or standalone lease).
        if (encoded.length <= 2 * 1024 * 1024) {
          entries.remove(flightKey);
          while (entries.isNotEmpty && (entries.length >= 128 ||
              entries.values.fold<int>(0, (n, value) => n + value.length) + encoded.length > 2 * 1024 * 1024)) {
            entries.remove(entries.keys.first);
          }
          entries[flightKey] = encoded;
        }
      }
      return result;
    } finally {
      final consumers = shared.users[lease] ?? 0;
      if (consumers > 1) {
        shared.users[lease] = consumers - 1;
      } else {
        shared.users.remove(lease);
        shared.paused.remove(lease);
      }
      if (shared.users.keys.every((u) => !u.active)) {
        shared.stop();
        if (identical(_flights[flightKey], shared)) {
          _flights.remove(flightKey);
        }
      }
    }
  }

  void _active(_Flight f) {
    if (_closed || f.abort.isCompleted || !f.users.keys.any((u) => u.active)) {
      throw const TaskStopped();
    }
  }

  Future<void> _delay(_Flight f, Duration duration) async {
    final ready = Completer<void>();
    final timer = Timer(duration, ready.complete);
    try {
      await Future.any([ready.future, f.abort.future]);
      _active(f);
    } finally {
      timer.cancel();
    }
  }

  Future<void> _allowed(MetadataResource r, bool manual) async {
    final rows = await tasks.db.query(
      'scrape_network',
      where: 'key IN (?,?)',
      whereArgs: [r.key, r.serviceKey],
    );
    for (final row in rows) {
      if (row['category'] == 'authentication' ||
          ((row['not_before'] as int) > tasks.now &&
              (row['key'] == r.serviceKey || !manual))) {
        throw MetadataFailure(
          row['category'] as String,
          row['not_before'] as int,
        );
      }
    }
    if (rows.isEmpty &&
        (await tasks.db.rawQuery(
                  'SELECT COUNT(*) AS n FROM scrape_network',
                )).single['n']
                as int >=
            ScrapeTasks.maxNetwork - 1) {
      throw StateError('Retry control capacity reached');
    }
  }

  Future<int> _failure(String key, String category, {int? retryAt}) async {
    return tasks.db.transaction((tx) async {
      final rows = await tx.query(
        'scrape_network',
        where: 'key=?',
        whereArgs: [key],
      );
      final failures = rows.isEmpty
          ? 1
          : min(1000000, (rows.single['failures'] as int) + 1);
      if (rows.isEmpty &&
          (await tx.rawQuery(
                    'SELECT COUNT(*) AS n FROM scrape_network',
                  )).single['n']
                  as int >=
              ScrapeTasks.maxNetwork) {
        throw StateError('Retry control capacity reached');
      }
      final delays = [
        const Duration(minutes: 5),
        const Duration(minutes: 30),
        const Duration(hours: 2),
      ];
      final delay = delays[min(failures - 1, 2)].inMilliseconds;
      final until = max(
        retryAt ?? tasks.now + delay + (delay * .1 * jitter()).round(),
        rows.isEmpty ? 0 : rows.single['not_before'] as int,
      );
      await tx.insert('scrape_network', {
        'key': key,
        'failures': failures,
        'not_before': max(
          until,
          rows.isEmpty ? 0 : rows.single['not_before'] as int,
        ),
        'category': category,
        'updated_at': tasks.now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return until;
    });
  }

  int _retryAfter(String? value) {
    final seconds = int.tryParse(value ?? '');
    if (seconds != null) return tasks.now + max(0, seconds) * 1000;
    try {
      return max(tasks.now, HttpDate.parse(value!).millisecondsSinceEpoch);
    } catch (_) {
      return tasks.now + 30000;
    }
  }

  Future<void> _githubQuota(
    MetadataResource r,
    int status,
    Map<String, String> headers,
    String body,
  ) async {
    if (r.service != 'github') return;
    final remaining = int.tryParse(headers['x-ratelimit-remaining'] ?? '');
    if (remaining != null) githubRemaining = remaining;
    final limited =
        status == 429 ||
        (status == 403 &&
            (remaining == 0 ||
                headers.containsKey('retry-after') ||
                body.toLowerCase().contains('rate limit')));
    if (remaining == 0 || limited) {
      final reset = int.tryParse(headers['x-ratelimit-reset'] ?? '');
      final until = await _failure(
        r.serviceKey,
        'rate_limit',
        retryAt: headers.containsKey('retry-after')
            ? _retryAfter(headers['retry-after'])
            : reset != null && reset * 1000 > tasks.now
            ? reset * 1000
            : null,
      );
      // No reset hint uses the persistent 5m/30m/2h ladder, exceeding GitHub's 1m minimum.
      if (limited) throw MetadataFailure('rate_limit', until);
    }
  }

  /// One streaming bulk acquisition at a time is enforced by the mapping
  /// coordinator. It shares service cooldowns and the global IO budget with GET.
  /// No response-sized byte array or permanent connection pool is allocated.
  Future<void> download(
    MetadataResource r,
    TaskLease lease,
    File destination, {
    required int maxBytes,
    required String digest,
    void Function()? checkActive,
  }) async {
    if (_closed ||
        r.service != 'github' ||
        r.routes.length != 1 ||
        r.headers.keys.any((k) => k.toLowerCase() == 'authorization')) {
      throw const TaskStopped();
    }
    final uri = r.routes.single;
    if (uri.scheme != 'https' ||
        uri.host != 'api.github.com' ||
        !RegExp(
          r'^/repos/open-ani/bangumi-tmdb/releases/assets/\d+$',
        ).hasMatch(uri.path)) {
      throw const FormatException('Invalid mapping asset endpoint');
    }
    var category = 'transport';
    for (var attempt = 0; attempt < 3; attempt++) {
      checkActive?.call();
      await tasks.beforeNextRequest(lease);
      await _allowed(r, false);
      if (!await tasks.valid(lease, cache: true)) throw const TaskStopped();
      final client = clientFactory?.call() ?? http.Client();
      _downloads.add(client);
      var done = false;
      unawaited(
        lease.cancelled.then((_) {
          if (!done) client.close();
        }),
      );
      try {
        await RequestBudget.run(() async {
          final elapsed = Stopwatch()..start();
          var target = uri;
          http.StreamedResponse? response;
          for (var redirect = 0; redirect < 4; redirect++) {
            lease.check();
            final request = http.Request('GET', target)
              ..followRedirects = false;
            request.headers.addAll({
              'User-Agent': MetadataHttp.userAgent,
              'Accept': 'application/octet-stream',
            });
            response = await Future.any<http.StreamedResponse>([
              client.send(request).timeout(const Duration(seconds: 25)),
              lease.cancelled.then<http.StreamedResponse>(
                (_) => throw const TaskStopped(),
              ),
            ]);
            if (target.host == 'api.github.com') {
              await _githubQuota(r, response.statusCode, response.headers, '');
            }
            if (![301, 302, 303, 307, 308].contains(response.statusCode)) break;
            final location = response.headers['location'];
            if (location == null || redirect == 3) {
              throw const FormatException('Asset redirect limit');
            }
            final next = target.resolve(location);
            if (next.scheme != 'https' ||
                next.userInfo.isNotEmpty ||
                next.host != 'release-assets.githubusercontent.com') {
              throw const FormatException('Untrusted asset redirect');
            }
            await response.stream.drain<void>().timeout(
              const Duration(seconds: 5),
            );
            target = next;
          }
          if (response!.statusCode == 429 || response.statusCode == 403) {
            final body = <int>[];
            await for (final chunk in response.stream.timeout(
              const Duration(seconds: 25),
            )) {
              if (body.length + chunk.length > 16384) break;
              body.addAll(chunk);
            }
            await _githubQuota(
              r,
              response.statusCode,
              response.headers,
              utf8.decode(body, allowMalformed: true),
            );
            throw MetadataFailure(
              'authentication',
              await _failure(r.key, 'authentication'),
            );
          }
          if (response.statusCode != 200) {
            throw HttpException('Mapping asset HTTP ${response.statusCode}');
          }
          if ((response.contentLength ?? 0) > maxBytes) {
            throw const FormatException('Mapping download size');
          }
          final handle = await destination.open(mode: FileMode.write);
          final chunks = StreamIterator(
            response.stream.timeout(const Duration(seconds: 25)),
          );
          var bytes = 0;
          try {
            while (await Future.any([
              chunks.moveNext(),
              lease.cancelled.then<bool>((_) => throw const TaskStopped()),
            ])) {
              lease.check();
              if (_closed) throw const TaskStopped();
              checkActive?.call();
              await tasks.beforeNextRequest(lease);
              if (elapsed.elapsed > const Duration(minutes: 5)) {
                throw TimeoutException('Mapping transfer deadline');
              }
              final chunk = chunks.current;
              bytes += chunk.length;
              if (bytes > maxBytes) {
                throw const FormatException('Mapping download size');
              }
              await handle.writeFrom(chunk);
            }
            await handle.flush();
          } finally {
            await chunks.cancel();
            await handle.close();
          }
          if ((await sha256.bind(destination.openRead()).first).toString() !=
              digest) {
            throw const FormatException('Mapping download checksum');
          }
          if (!await tasks.valid(lease, cache: true)) throw const TaskStopped();
          await tasks.db.delete(
            'scrape_network',
            where: 'key=?',
            whereArgs: [r.key],
          );
        }, cancelled: lease.cancelled);
        return;
      } on MetadataFailure {
        rethrow;
      } on TaskStopped {
        rethrow;
      } on FormatException {
        category = 'protocol';
      } on TimeoutException {
        category = 'timeout';
      } on IOException {
        category = 'transport';
      } on http.ClientException {
        category = 'transport';
      } finally {
        done = true;
        client.close();
        _downloads.remove(client);
      }
      if (await destination.exists()) await destination.delete();
      if (attempt < 2 && retryDelays.isNotEmpty) {
        final ready = Completer<void>();
        final timer = Timer(
          retryDelays[min(attempt, retryDelays.length - 1)],
          ready.complete,
        );
        try {
          await Future.any([ready.future, lease.cancelled]);
          lease.check();
        } finally {
          timer.cancel();
        }
      }
    }
    throw MetadataFailure(category, await _failure(r.key, category));
  }

  Future<Map<String, dynamic>> _fetch(
    MetadataResource r,
    _Flight f,
    bool manual,
  ) async {
    var category = 'transport';
    final providerRoute = r.service == 'tmdb' || r.service == 'bangumi';
    final hasAuthorization =
        r.headers.keys.any((key) => key.toLowerCase() == 'authorization');
    final trustedHosts = r.service == 'tmdb'
        ? const {'api.themoviedb.org', 'api.tmdb.org'}
        : const {'api.bgm.tv'};
    final allowed = r.routes.where((route) {
      final hasAuth = hasAuthorization || r.parameters.containsKey('api_key') ||
          route.queryParameters.containsKey('api_key');
      return !hasAuth || route.isScheme('https') &&
          (trustedHosts.contains(route.host) || r.trustCustom);
    }).toList();
    if (allowed.isEmpty) throw const MetadataFailure('untrusted_endpoint', 0);
    final routes = providerRoute ? MetadataServers.tryOrder(allowed) : allowed;
    for (var attempt = 0; attempt < 3; attempt++) {
      _active(f);
      for (final user in f.users.keys.toList()) {
        try {
          await tasks.beforeNextRequest(user);
        } on TaskPaused {
          final signal = f.paused[user];
          if (signal != null && !signal.isCompleted) signal.complete();
          f.users.remove(user);
        } on TaskStopped {
          f.users.remove(user);
        }
      }
      if (f.users.isEmpty) throw const TaskPaused();
      // Another resource may have just received a service-wide 429.
      await _allowed(r, manual);
      final route = routes[min(attempt, routes.length - 1)];
      final changingRoute = providerRoute && attempt + 1 < routes.length;
      final uri = r.parameters.isEmpty ? route : route.replace(
        queryParameters: {...route.queryParameters, ...r.parameters},
      );
      final pooled = clientFactory == null && providerRoute;
      MetadataHttp createClient() => MetadataHttp(
        inner: pooled ? IOClient(HttpClient()
          ..idleTimeout = const Duration(seconds: 15)
          ..maxConnectionsPerHost = 6) : null,
        raw: true,
        fresh: true,
        responseLimit: 2 * 1024 * 1024,
        trustCustom: r.trustCustom,
      );
      final client =
          clientFactory?.call() ??
          (pooled ? _providerClients.putIfAbsent(r.trustCustom, createClient)
              : createClient());
      if (!pooled) f.client = client;
      try {
        final req = http.Request(r.method, uri)
          ..headers.addAll(r.headers)
          ..body = r.body
          ..followRedirects = false;
        final attemptDeadline = MetadataServers.attemptTimeout(
          deadline,
          hasBackup: changingRoute,
        );
        void notifyStarted() {
          for (final lease in f.users.keys) {
            if (lease.active) onRequestStart?.call(lease);
          }
        }
        if (client is! MetadataHttp) notifyStarted();
        final response = await Future.any([
          if (client is MetadataHttp)
            client.sendWithDeadline(req, attemptDeadline,
                cancelled: f.abort.future, onStart: notifyStarted)
          else
            client.send(req).then(http.Response.fromStream).timeout(attemptDeadline),
          f.abort.future.then<http.Response>((_) => throw const TaskStopped()),
        ]);
        _active(f);
        await _githubQuota(
          r,
          response.statusCode,
          response.headers,
          response.body,
        );
        if (response.statusCode == 429 ||
            response.statusCode == 403 &&
                response.headers.containsKey('retry-after')) {
          final until = await _failure(
            r.serviceKey,
            'rate_limit',
            retryAt: _retryAfter(response.headers['retry-after']),
          );
          throw MetadataFailure('rate_limit', until);
        }
        if (response.statusCode == 401 || response.statusCode == 403) {
          final until = await _failure(r.key, 'authentication');
          throw MetadataFailure('authentication', until);
        }
        if (response.statusCode == 404) {
          final until = await _failure(
            r.key,
            'not_found',
            retryAt: tasks.now + const Duration(hours: 1).inMilliseconds,
          );
          throw MetadataFailure('not_found', until);
        }
        if (response.statusCode >= 500) {
          throw const HttpException('Server unavailable');
        }
        if (response.statusCode != 200 ||
            response.bodyBytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Invalid response');
        }
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final body = r.listResponse && decoded is List
            ? <String, dynamic>{'data': decoded} : decoded;
        if (r.listResponse && decoded is! List) {
          throw const FormatException('Expected JSON list');
        }
        if (body is! Map<String, dynamic> ||
            body['success'] == false ||
            body.containsKey('error') ||
            r.accept?.call(body) == false) {
          throw const FormatException('Invalid JSON payload');
        }
        _active(f);
        // Transport success alone is not permission to adopt/cache for any user.
        if (!(await Future.wait(f.users.keys.map(tasks.valid))).any((v) => v)) {
          throw const TaskStopped();
        }
        if (providerRoute) MetadataServers.reachedRoute(uri);
        await tasks.db.delete(
          'scrape_network',
          where: 'key=?',
          whereArgs: [r.key],
        );
        return body;
      } on TaskStopped {
        rethrow;
      } on MetadataFailure {
        rethrow;
      } on FormatException {
        category = 'protocol';
      } on TimeoutException {
        category = 'timeout';
      } on IOException {
        category = 'transport';
      } on http.ClientException {
        _active(f);
        category = 'transport';
      } finally {
        if (!pooled) client.close();
        if (identical(f.client, client)) f.client = null;
      }
      if (providerRoute && routes.length > 1) MetadataServers.failedRoute(uri);
      if (attempt < 2 && !changingRoute && retryDelays.isNotEmpty) {
        await _delay(f, retryDelays[min(attempt, retryDelays.length - 1)]);
      }
    }
    _active(f);
    final until = await _failure(r.key, category);
    throw MetadataFailure(category, until);
  }
}
