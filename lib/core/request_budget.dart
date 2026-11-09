import 'dart:async';
import 'dart:collection';

/// A shared bound for metadata and artwork IO on desktop and mobile.
class RequestBudget {
  static int _active = 0;
  static final Queue<Completer<void>> _waiting = Queue();
  static Future<T> run<T>(
    Future<T> Function() operation, {
    Future<void>? cancelled,
  }) async {
    if (_active >= 6) {
      final ready = Completer<void>();
      _waiting.add(ready);
      final granted = cancelled == null
          ? true
          : await Future.any([
              ready.future.then((_) => true),
              cancelled.then((_) => false),
            ]);
      if (!granted) {
        // If a slot was handed over at the same time, return it to the queue.
        if (!_waiting.remove(ready)) _release();
        throw StateError('Request cancelled before starting');
      }
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      _release();
    }
  }

  static void _release() {
    if (_waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeFirst().complete();
    }
  }
}
