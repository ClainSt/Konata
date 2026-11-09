import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'request_budget.dart';

/// Shared lifetime for resources used by one visible optional feature.
/// Obtain through OptionalFeatures.openScope; creating a scope starts no IO.
class OptionalFeatureScope {
  OptionalFeatureScope(this._onDispose);

  VoidCallback? _onDispose;
  final _resources = HashMap<Object, VoidCallback>.identity();
  final _cancelled = Completer<void>();
  bool _disposed = false;
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
      final client = acquire(
        () => clientFactory?.call() ?? HttpClient(),
        (client) => client.close(force: true),
      );
      client.connectionTimeout = const Duration(seconds: 8);
      final deadline = timer(timeout, () => release(client));
      var finished = false;
      requestCancelled?.then((_) {
        if (!finished) release(client);
      });
      try {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Konata/1 (optional details)',
        );
        headers.forEach(request.headers.set);
        final response = await request.close();
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
          if (bytes.length + chunk.length > limit) {
            throw const FormatException('Response limit');
          }
          bytes.add(chunk);
        }
        checkActive();
        return bytes.takeBytes();
      } finally {
        finished = true;
        release(deadline);
        release(client);
      }
    },
    cancelled: requestCancelled == null
        ? cancelled
        : Future.any([cancelled, requestCancelled]),
  );
}
