import 'package:ccplayer/core/watched_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('intervals merge overlaps and replay without counting gaps', () {
    final timeline = WatchedTimeline([
      const WatchedRange(2000, 3000),
      const WatchedRange(0, 1000),
      const WatchedRange(500, 1500),
      const WatchedRange(1500, 2000),
      const WatchedRange(0, 1000),
      const WatchedRange(-1, 1000),
      const WatchedRange(9, 1),
      const WatchedRange(4000, 5000),
    ]);
    expect(timeline.coveredMilliseconds(5000), 4000);
    expect(timeline.reaches(5000, 80), true);
    expect(timeline.reaches(5000, 90), false);
    expect(timeline.coveredMilliseconds(2500), 2500);
    expect(timeline.coveredMilliseconds(0), 0);
    expect(
      WatchedTimeline.decode(timeline.encode()).encode(),
      timeline.encode(),
    );
  });
  test(
    'malformed and unknown historical interval data never grants credit',
    () {
      for (final raw in [
        null,
        '{}',
        'invalid',
        '[["0",1000],[-1,1000],[500,0]]',
      ]) {
        expect(WatchedTimeline.decode(raw).coveredMilliseconds(10000), 0);
      }
    },
  );

  void sample(
    WatchedTracker tracker,
    int position,
    int clock, {
    bool playing = true,
    bool buffering = false,
    double rate = 1,
    bool visible = true,
    int duration = 100000,
  }) => tracker.sample(
    position: position,
    duration: duration,
    clock: clock,
    playing: playing,
    buffering: buffering,
    rate: rate,
    visible: visible,
  );

  test(
    'normal playback credits time; seek to ending and replay do not inflate it',
    () {
      final tracker = WatchedTracker();
      for (var i = 0; i <= 10; i++) {
        sample(tracker, i * 1000, i * 1000);
      }
      expect(tracker.timeline.coveredMilliseconds(100000), 10000);
      sample(tracker, 99000, 11000);
      expect(tracker.timeline.coveredMilliseconds(100000), 10000);
      sample(tracker, 100000, 12000);
      expect(tracker.timeline.coveredMilliseconds(100000), 11000);
      sample(tracker, 0, 13000);
      for (var i = 1; i <= 10; i++) {
        sample(tracker, i * 1000, 13000 + i * 1000);
      }
      expect(tracker.timeline.coveredMilliseconds(100000), 11000);
    },
  );
  test(
    'pause, buffering, hidden app and unknown duration break continuity',
    () {
      for (final state in ['paused', 'buffering', 'hidden', 'unknown']) {
        final tracker = WatchedTracker();
        sample(tracker, 0, 0);
        sample(
          tracker,
          1000,
          1000,
          playing: state != 'paused',
          buffering: state == 'buffering',
          visible: state != 'hidden',
          duration: state == 'unknown' ? 0 : 100000,
        );
        sample(tracker, 2000, 2000);
        expect(tracker.timeline.coveredMilliseconds(100000), 0, reason: state);
        sample(tracker, 3000, 3000);
        expect(
          tracker.timeline.coveredMilliseconds(100000),
          1000,
          reason: state,
        );
      }
    },
  );
  test(
    'speed uses elapsed clock budget and state reset never bridges positions',
    () {
      final tracker = WatchedTracker();
      sample(tracker, 0, 0, rate: 2);
      sample(tracker, 2000, 1000, rate: 2);
      expect(tracker.timeline.coveredMilliseconds(100000), 2000);
      sample(tracker, 3000, 2000, rate: 1);
      expect(tracker.timeline.coveredMilliseconds(100000), 2000);
      sample(tracker, 4000, 3000);
      expect(tracker.timeline.coveredMilliseconds(100000), 3000);
      tracker.reset();
      sample(tracker, 90000, 4000);
      expect(tracker.timeline.coveredMilliseconds(100000), 3000);
      sample(tracker, 91000, 5000);
      expect(tracker.timeline.coveredMilliseconds(100000), 4000);
    },
  );
  test(
    'sleep, clock reversal, duplicates, invalid speed and out of bounds add nothing',
    () {
      final tracker = WatchedTracker();
      sample(tracker, 0, 0);
      sample(tracker, 50000, 50000);
      sample(tracker, 51000, 49000);
      sample(tracker, 51000, 50000);
      sample(tracker, 52000, 51000, rate: double.nan);
      sample(tracker, 53000, 52000);
      sample(tracker, -1, 53000);
      sample(tracker, 100001, 54000);
      expect(tracker.timeline.coveredMilliseconds(100000), 0);
    },
  );
  test('jitter allowance is never counted as additional playback time', () {
    final tracker = WatchedTracker();
    sample(tracker, 0, 0);
    sample(tracker, 1100, 1000);
    sample(tracker, 2200, 2000);
    expect(tracker.timeline.coveredMilliseconds(100000), 2000);
    expect(tracker.timeline.ranges.first.start, 100);
  });
}
