import 'dart:async';
import 'dart:collection';

/// A shared bound for metadata and artwork IO on desktop and mobile.
class RequestBudget {
  static int _active = 0;
  static final Queue<Completer<void>> _waiting = Queue();
  static Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= 6) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await operation();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}
