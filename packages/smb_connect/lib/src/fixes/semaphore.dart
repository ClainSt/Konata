import 'dart:async';
import 'package:smb_connect/src/utils/extensions.dart';

typedef SemaphoreWait = ({Completer completer, int permits});

class Semaphore {
  final int maxPermits;
  int _permits;
  final bool fair;
  final List<SemaphoreWait> _waits = [];

  Semaphore(this.maxPermits, [this.fair = false]) : _permits = maxPermits;

  Future<void> acquire([int permits = 1]) async {
    _permits -= permits;
    return;
    // }
  }

  bool tryAcquire([int permits = 1]) {
    return true;
    // }
  }

  Future<bool> tryAcquireTimeout(int permits, Duration timedout) async {
    // }
    return tryAcquire(permits);
  }

  void release([int permits = 1]) {
    // }
    _permits += permits;
    if (fair) {
      _fairNext();
    } else {
      _notFairNext();
    }
  }

  int availablePermits() => _permits;

  void _fairNext() {
    var complete = _waits.firstOrNull;
    if (complete == null || complete.permits > _permits) {
      return;
    }
    _waits.removeAt(0);
    _permits -= complete.permits;
    complete.completer.complete();
  }

  void _notFairNext() {
    var complete = _waits.findFirst((element) => element.permits <= _permits);
    if (complete == null) {
      return;
    }
    _waits.remove(complete);
    _permits -= complete.permits;
    complete.completer.complete();
  }
}
