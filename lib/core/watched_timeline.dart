import 'dart:convert';
import 'dart:math' as math;

class WatchedRange {
  const WatchedRange(this.start, this.end);
  final int start, end;
}

/// Millisecond intervals on the media timeline; replay never adds extra credit.
class WatchedTimeline {
  WatchedTimeline([Iterable<WatchedRange> ranges = const []]) {
    addAll(ranges);
  }
  final List<WatchedRange> _ranges = [];
  List<WatchedRange> get ranges => List.unmodifiable(_ranges);

  void addAll(Iterable<WatchedRange> ranges) {
    final sorted =
        [
            ..._ranges,
            ...ranges,
          ].where((r) => r.start >= 0 && r.end > r.start).toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    _ranges.clear();
    for (final range in sorted) {
      if (_ranges.isEmpty || range.start > _ranges.last.end) {
        _ranges.add(range);
      } else {
        final last = _ranges.removeLast();
        _ranges.add(WatchedRange(last.start, math.max(last.end, range.end)));
      }
    }
  }

  int coveredMilliseconds(int duration) {
    if (duration <= 0) return 0;
    return _ranges.fold(
      0,
      (sum, r) => sum + math.max(0, math.min(r.end, duration) - r.start),
    );
  }

  bool reaches(int duration, int percent) =>
      duration > 0 && coveredMilliseconds(duration) * 100 >= duration * percent;

  String encode() => jsonEncode([
    for (final r in _ranges) [r.start, r.end],
  ]);

  static WatchedTimeline decode(Object? raw) {
    try {
      final data = jsonDecode(raw?.toString() ?? '[]');
      if (data is! List) return WatchedTimeline();
      return WatchedTimeline([
        for (final row in data)
          if (row is List && row.length == 2 && row[0] is int && row[1] is int)
            WatchedRange(row[0] as int, row[1] as int),
      ]);
    } catch (_) {
      return WatchedTimeline();
    }
  }
}

/// Credits only small, continuous advances backed by a monotonic clock.
/// State changes, seeks, long event gaps and unknown duration break continuity.
class WatchedTracker {
  final timeline = WatchedTimeline();
  int? _position, _clock;
  bool _active = false;
  double _rate = 1;

  void reset() {
    _position = null;
    _clock = null;
    _active = false;
  }

  void sample({
    required int position,
    required int duration,
    required int clock,
    required bool playing,
    required bool buffering,
    double rate = 1,
    bool visible = true,
  }) {
    final active =
        playing &&
        !buffering &&
        visible &&
        duration > 0 &&
        rate.isFinite &&
        rate > 0 &&
        position >= 0 &&
        position <= duration;
    if (active &&
        _active &&
        _position != null &&
        _clock != null &&
        rate == _rate) {
      final elapsed = clock - _clock!;
      final advance = position - _position!;
      final budget = (elapsed * rate).floor();
      // A clock gap >3s has too little evidence to distinguish sleep/buffering
      // from playback. Up to 200ms jitter is allowed, never credited as time.
      if (elapsed > 0 &&
          elapsed <= 3000 &&
          advance > 0 &&
          advance <= budget + 200) {
        final credit = math.min(advance, budget);
        if (credit > 0) {
          timeline.addAll([WatchedRange(position - credit, position)]);
        }
      }
    }
    _position = position;
    _clock = clock;
    _active = active;
    _rate = rate;
  }
}
