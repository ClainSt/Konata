import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'request_budget.dart';
import 'transient_tls.dart';

/// Shared lifetime for resources used by one visible optional feature.
/// Obtain through OptionalFeatures.openScope; creating a scope starts no IO.
class OptionalFeatureScope {
  OptionalFeatureScope(this._onDispose);

  VoidCallback? _onDispose;
  final _resources = HashMap<Object, VoidCallback>.identity();
  final _cancelled = Completer<void>();
  bool _disposed = false;
  final _idleClients = <(HttpClient Function()?, String, HttpClient)>[];
  bool get disposed => _disposed;
  Future<void> get cancelled => _cancelled.future;
  int count<T>() => _resources.keys.whereType<T>().length;

  void checkActive() {
    if (_disposed) throw StateError('Feature stopped');
  }

  /// Registers one exclusive resource. The factory never runs after shutdown.
  T acquire<T extends Object>(T Function() create, void Function(T) destroy) {
    checkActive();
    final resource = create();
    if (_disposed) {
      destroy(resource);
      throw StateError('Feature stopped');
    }
    if (_resources.containsKey(resource)) {
      throw StateError('Resource already registered');
    }
    _resources[resource] = () => destroy(resource);
    return resource;
  }

  /// Releases early and unregisters; later scope shutdown cannot release twice.
  void release(Object resource) => _resources.remove(resource)?.call();

  /// A page batch reuses completed connections, then explicitly drops idle IO.
  void closeIdleClients() {
    final idle = _idleClients.toList();
    _idleClients.clear();
    for (final entry in idle) {
      release(entry.$3);
    }
  }

  Timer timer(Duration duration, VoidCallback callback) {
    late final Timer result;
    result = acquire(
      () => Timer(duration, () {
        release(result);
        if (!_disposed) callback();
      }),
      (timer) => timer.cancel(),
    );
    return result;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _idleClients.clear();
    _cancelled.complete();
    final releaseAll = _resources.values.toList();
    _resources.clear();
    final unregister = _onDispose;
    _onDispose = null;
    unregister?.call();
    final errors = <FlutterErrorDetails>[];
    for (final release in releaseAll) {
      try {
        release();
      } catch (error, stack) {
        errors.add(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'optional feature resources',
          ),
        );
      }
    }
    for (final error in errors) {
      FlutterError.reportError(error);
    }
  }

  /// Bounded IO shared by optional features, including queued cancellation.
  Future<Uint8List> readBytes(
    Uri uri,
    int limit, {
    Map<String, String> headers = const {},
    Future<void>? requestCancelled,
    HttpClient Function()? clientFactory,
    Duration timeout = const Duration(seconds: 12),
  }) => RequestBudget.run(
    () async {
      var idle = _idleClients.lastIndexWhere(
        (entry) => entry.$1 == clientFactory && entry.$2 == uri.origin,
      );
      if (idle < 0) {
        idle = _idleClients.lastIndexWhere(
          (entry) => entry.$1 == clientFactory,
        );
      }
      final client = idle >= 0
          ? _idleClients.removeAt(idle).$3
          : acquire(
              () => clientFactory?.call() ?? HttpClient(),
              (client) => client.close(force: true),
            );
      client.connectionTimeout = const Duration(seconds: 8);
      var stopped = false;
      var expired = false;
      var reusable = false;
      final interruption = Completer<Uint8List>();
      var finished = false;
      void stop(Object error) {
        if (finished || stopped) return;
        stopped = true;
        release(client);
        interruption.completeError(error);
      }

      final deadline = timer(timeout, () {
        expired = true;
        stop(TimeoutException('Optional request deadline'));
      });
      cancelled.then((_) => stop(StateError('Feature stopped')));
      requestCancelled?.then((_) => stop(StateError('Request stopped')));
      Future<Uint8List> read() async {
        final response = await retryInterruptedTls(() async {
          checkActive();
          if (stopped) throw StateError('Request stopped');
          final request = await client.getUrl(uri);
          if (stopped || _disposed) {
            request.abort();
            throw StateError('Request stopped');
          }
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.userAgentHeader,
            'Konata/1 (optional details)',
          );
          headers.forEach(request.headers.set);
          return request.close();
        });
        if (response.statusCode >= 500) {
          throw const HttpException('Optional details unavailable');
        }
        // Authentication, rate limits and redirects must not trigger a retry
        // against another host. Invalid/oversized bodies are not transport errors.
        if (response.statusCode != 200 || response.contentLength > limit) {
          throw const FormatException('Optional response rejected');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          checkActive();
          if (stopped) throw StateError('Request stopped');
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('Response limit');
          }
          bytes.add(chunk);
        }
        checkActive();
        if (stopped) throw StateError('Request stopped');
        return bytes.takeBytes();
      }

      try {
        // Closing HttpClient may not settle an in-flight native handshake.
        // Return at our deadline; reject late headers/body before caching.
        final bytes = await Future.any([read(), interruption.future]);
        reusable = true;
        return bytes;
      } catch (_) {
        if (expired) throw TimeoutException('Optional request deadline');
        rethrow;
      } finally {
        finished = true;
        release(deadline);
        if (reusable && !_disposed && _resources.containsKey(client)) {
          _idleClients.add((clientFactory, uri.origin, client));
        } else {
          release(client);
        }
      }
    },
    cancelled: requestCancelled == null
        ? cancelled
        : Future.any([cancelled, requestCancelled]),
  );
}
