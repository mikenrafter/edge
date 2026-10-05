// At most one insightsRevision bump per 1500 ms while a pass
// commits days, with a trailing flush so the LAST committed day always
// publishes.
//
// API (lib/state/revision_coalescer.dart, new, pure Dart):
//
//   class RevisionCoalescer {
//     RevisionCoalescer({
//       required void Function() fire,         // the publish (AppState: refresh
//                                              // freshness, then bumpInsights)
//       required int Function() nowMs,         // injected clock
//       Duration minGap = const Duration(milliseconds: 1500),
//       Timer Function(Duration, void Function()) timer = Timer.new,
//     });
//     void request();      // a day just committed
//     void dispose();      // cancels the pending trailing timer; later
//                          // request()s do nothing
//     bool get pending;    // a trailing fire is scheduled
//   }
//
// Rules pinned below:
//   * request() with no fire yet, or >= minGap since the last fire -> fires
//     synchronously, no timer.
//   * request() inside the gap -> ONE trailing timer for the REMAINING gap
//     (minGap - elapsed); further requests in the same gap add nothing.
//   * the gap is measured from the last fire, trailing fires included.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/state/revision_coalescer.dart';

class _FakeTimer implements Timer {
  _FakeTimer(this.at, this.cb, this.duration);
  final int at;
  final void Function() cb;
  final Duration duration;
  bool cancelled = false;
  bool fired = false;
  @override
  void cancel() => cancelled = true;
  @override
  bool get isActive => !cancelled && !fired;
  @override
  int get tick => 0;
}

class _World {
  int now = 0;
  final timers = <_FakeTimer>[];
  final fires = <int>[];

  late final RevisionCoalescer c = RevisionCoalescer(
    fire: () => fires.add(now),
    nowMs: () => now,
    timer: (d, cb) {
      final t = _FakeTimer(now + d.inMilliseconds, cb, d);
      timers.add(t);
      return t;
    },
  );

  /// Move time forward, firing due timers in order.
  void advanceTo(int ms) {
    while (true) {
      final due = timers.where((t) => t.isActive && t.at <= ms).toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final t = due.first;
      now = t.at;
      t.fired = true;
      t.cb();
    }
    now = ms;
  }

  int get active => timers.where((t) => t.isActive).length;
}

void main() {
  test('the first request fires at once, with no timer', () {
    final w = _World();
    w.c.request();
    expect(w.fires, [0]);
    expect(w.timers, isEmpty);
    expect(w.c.pending, isFalse);
  });

  test('a request inside the gap waits for the REMAINING gap', () {
    final w = _World();
    w.c.request(); // t=0
    w.advanceTo(400);
    w.c.request();
    expect(w.fires, [0], reason: 'not inside the gap');
    expect(w.c.pending, isTrue);
    expect(w.timers.single.duration, const Duration(milliseconds: 1100));
    w.advanceTo(1499);
    expect(w.fires, [0]);
    w.advanceTo(1500);
    expect(w.fires, [0, 1500]);
    expect(w.c.pending, isFalse);
  });

  test('many requests in one gap make ONE trailing fire (last day publishes)',
      () {
    final w = _World();
    w.c.request();
    for (var t = 100; t <= 900; t += 100) {
      w.advanceTo(t);
      w.c.request();
    }
    expect(w.active, 1);
    w.advanceTo(3000);
    expect(w.fires, [0, 1500]);
  });

  test('after the gap has passed the next request fires immediately', () {
    final w = _World();
    w.c.request();
    w.advanceTo(2000);
    w.c.request();
    expect(w.fires, [0, 2000]);
    expect(w.timers, isEmpty);
  });

  test('the gap is measured from the trailing fire too', () {
    final w = _World();
    w.c.request(); // 0
    w.advanceTo(200);
    w.c.request(); // trailing @1500
    w.advanceTo(1500);
    expect(w.fires, [0, 1500]);
    w.advanceTo(1600);
    w.c.request(); // 100 ms after the trailing fire -> deferred again
    expect(w.fires, [0, 1500]);
    expect(w.timers.last.duration, const Duration(milliseconds: 1400));
    w.advanceTo(3000);
    expect(w.fires, [0, 1500, 3000]);
  });

  test('never more than one fire per 1500 ms under a steady stream', () {
    final w = _World();
    for (var t = 0; t < 20000; t += 37) {
      w.advanceTo(t);
      w.c.request();
    }
    w.advanceTo(30000);
    expect(w.fires.length, greaterThan(5));
    for (var i = 1; i < w.fires.length; i++) {
      expect(w.fires[i] - w.fires[i - 1], greaterThanOrEqualTo(1500),
          reason: 'fires ${w.fires[i - 1]} -> ${w.fires[i]}');
    }
    // The last request's day must have been published: a fire at or after it.
    expect(w.fires.last, greaterThanOrEqualTo(19980 - 1500));
    expect(w.c.pending, isFalse);
  });

  test('dispose cancels the pending trailing fire and silences the instance',
      () {
    final w = _World();
    w.c.request();
    w.advanceTo(100);
    w.c.request();
    expect(w.c.pending, isTrue);
    w.c.dispose();
    expect(w.timers.single.cancelled, isTrue);
    w.advanceTo(5000);
    expect(w.fires, [0]);
    w.c.request();
    expect(w.fires, [0], reason: 'a disposed coalescer must not publish');
  });
}
