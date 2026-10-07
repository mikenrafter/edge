// The haptic budget rules of the band queue (the rolling command limit,
// 30 per 2 minutes by default) for gesture haptics and for everything else.
//
// A GESTURE's haptics are the cues one gesture plays: its start cue, one
// follow-up per count increment, and its confirm (or failure) cue, plus the
// confirm that acknowledges a plain double tap. They are queued inside
// `BandHapticQueue.asGesture(gestureId, work)`; every job queued inside it
// belongs to gesture `gestureId` (the same string for every haptic of one
// gesture, a different one for the next gesture). Anything queued outside it
// (alerts, previews, breathing cues, the relay, water and medication buzzes)
// is a NON-gesture job.
//
// Owner's rules pinned here:
//   1. Mid-gesture exemption: once a gesture's first haptic has started, every
//      later haptic of that gesture plays, even if the window runs out.
//   2. Never late: a gesture haptic that cannot play now (no allowance in the
//      window, the gesture not yet started) is dropped as rejected on the
//      spot. It is never queued for when the window frees.
//   3. A NON-gesture job over the limit is not dropped: it waits for the
//      window, however long, then plays, in order, a minimum gap apart. Its
//      start deadline (`startBy`) does not drop it while it waits for the
//      window.
//   5. No overdraw: a gesture bigger than the remaining allowance plays all of
//      it, but the ledger never counts more than the limit (the remaining
//      slots are filled, the rest is not counted), and the counted writes
//      leave the window on the normal schedule (2 minutes after each write).
//   6. The limit is configurable, 10..60 (default 30), clamped, read at every
//      use by the ledger and the queue.
// (Rule 4, no action without its haptic, is pinned at the gesture dispatcher.)
//
// New API pinned: `BandHapticQueue.asGesture<T>(String gestureId, T Function()
// work)`, `BandCommandLedger({int Function()? limit})` (read on every use,
// clamped to kBandCommandLimitMin..kBandCommandLimitMax, null = 30).
//
// Times are fake (fake_async): the queue reads `clock`, never DateTime.now.
// Where a test needs a ledger entry that expires soon, it records the writes
// in the past (`record(n, at)`), so no test waits.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const Duration _s = Duration(seconds: 1);
const Duration _window = Duration(minutes: 2);

/// A queue with the vocabulary's minimum gap (1 s) and a recorder of what the
/// jobs did, all on the fake clock.
class _Rig {
  _Rig(this.async, {int Function()? limit})
      : ledger = BandCommandLedger(limit: limit) {
    queue = BandHapticQueue(ledger: ledger, minGap: () => _s);
    t0 = clock.now();
  }

  final FakeAsync async;
  final BandCommandLedger ledger;
  late final BandHapticQueue queue;
  late final DateTime t0;

  /// Job name to the elapsed time it started, its result, and every write
  /// (a job name per command written, in order).
  final started = <String, Duration>{};
  final results = <String, BuzzDelivery>{};
  final wrote = <String>[];

  Future<BuzzDelivery> Function(BandJobToken) _job(
    String name,
    int writes,
    Duration takes,
  ) =>
      (t) async {
        started[name] = async.elapsed;
        for (var i = 0; i < writes; i++) {
          await t.write(() async {
            wrote.add(name);
            return true;
          });
        }
        if (takes > Duration.zero) await Future<void>.delayed(takes);
        return BuzzDelivery.complete;
      };

  /// A job outside any gesture.
  void plain(
    String name, {
    int commands = 1,
    int? writes,
    Duration takes = Duration.zero,
    Duration startBy = kBandQueueWait,
  }) {
    unawaited(queue
        .run(_job(name, writes ?? commands, takes),
            commands: commands,
            timeout: const Duration(seconds: 30),
            startBy: startBy)
        .then((v) => results[name] = v));
  }

  /// A job queued inside gesture [gestureId].
  void gesture(
    String gestureId,
    String name, {
    int commands = 1,
    int? writes,
    Duration takes = Duration.zero,
  }) {
    unawaited(queue.asGesture(
      gestureId,
      () => queue
          .run(_job(name, writes ?? commands, takes),
              commands: commands, timeout: const Duration(seconds: 30))
          .then((v) => results[name] = v),
    ));
  }

  /// Elapsed since the start of the test.
  Duration get now => async.elapsed;

  /// Commands the ledger would still allow [after] the start of the test.
  int leftAt(Duration after) => ledger.commandsLeft(t0.add(after));
}

void main() {
  group('rule 1: once a gesture has started, all of it plays', () {
    test('the window runs out partway: every later haptic still plays', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(26, clock.now()); // 4 left
        r.gesture('g', 'start', commands: 2);
        async.flushMicrotasks();
        expect(r.started.containsKey('start'), isTrue);
        // 2 + 1 + 1 + 1 + 2 = 7 commands against 4 left.
        r.gesture('g', 'f1');
        r.gesture('g', 'f2');
        r.gesture('g', 'f3');
        r.gesture('g', 'confirm', commands: 2);
        async.elapse(const Duration(seconds: 30));
        expect(r.results, {
          'start': BuzzDelivery.complete,
          'f1': BuzzDelivery.complete,
          'f2': BuzzDelivery.complete,
          'f3': BuzzDelivery.complete,
          'confirm': BuzzDelivery.complete,
        });
        expect(r.wrote,
            ['start', 'start', 'f1', 'f2', 'f3', 'confirm', 'confirm'],
            reason: 'every command of every cue was written, in order');
      });
    });

    test('the window is already spent by the first cue: the follow-up and '
        'the confirm still play', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(29, clock.now()); // 1 left: the start cue takes it
        r.gesture('g', 'start');
        async.flushMicrotasks();
        expect(r.ledger.commandsLeft(clock.now()), 0);
        r.gesture('g', 'f1');
        r.gesture('g', 'confirm');
        async.elapse(const Duration(seconds: 10));
        expect(r.results, {
          'start': BuzzDelivery.complete,
          'f1': BuzzDelivery.complete,
          'confirm': BuzzDelivery.complete,
        });
        expect(r.wrote, ['start', 'f1', 'confirm']);
      });
    });

    test('the exemption is the gesture\'s own: another gesture starting with '
        'no allowance is dropped while the first one carries on', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(29, clock.now());
        r.gesture('g1', 'g1.start');
        async.flushMicrotasks();
        r.gesture('g2', 'g2.start'); // no allowance left, not started
        async.elapse(const Duration(seconds: 5));
        expect(r.results['g2.start'], BuzzDelivery.rejected,
            reason: 'dropped, not kept for when the window frees');
        r.gesture('g1', 'g1.confirm');
        async.elapse(const Duration(seconds: 10));
        expect(r.results['g1.confirm'], BuzzDelivery.complete);
        expect(r.wrote, ['g1.start', 'g1.confirm']);
        expect(r.started.containsKey('g2.start'), isFalse);
      });
    });
  });

  group('rule 2: a gesture haptic is never played late', () {
    test('no allowance when the gesture starts: rejected on the spot, nothing '
        'queued, nothing played later', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(30, clock.now());
        r.gesture('g', 'start');
        async.flushMicrotasks();
        expect(r.results['start'], BuzzDelivery.rejected);
        expect(r.queue.pending, 0);
        async.elapse(const Duration(minutes: 5));
        expect(r.started, isEmpty, reason: 'the job body never ran');
        expect(r.wrote, isEmpty);
      });
    });

    test('even when the window would free before the job\'s own start '
        'deadline, it is dropped now, not played when it frees', () {
      fakeAsync((async) {
        final r = _Rig(async);
        // 30 written 115 s ago: they leave the window in 5 s, well inside the
        // 15 s start deadline.
        r.ledger.record(30, clock.now().subtract(const Duration(seconds: 115)));
        r.gesture('g', 'start');
        async.flushMicrotasks();
        expect(r.results['start'], BuzzDelivery.rejected);
        expect(r.queue.pending, 0);
        async.elapse(const Duration(minutes: 3));
        expect(r.started, isEmpty);
        expect(r.wrote, isEmpty);
      });
    });

    test('a gesture haptic behind a non-gesture job waiting for the window '
        'is answered soon: it plays now or is dropped, it does not wait for '
        'the window to free', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(27, clock.now()); // 3 left
        r.plain('A', takes: const Duration(seconds: 3)); // plays, writes 1
        async.flushMicrotasks();
        // B needs 3, 2 are left: it waits for the window.
        r.plain('B', commands: 3);
        async.elapse(const Duration(seconds: 1));
        r.gesture('g', 'start');
        // A ends at 3 s and the gap after it at 4 s: by 6 s the gesture haptic
        // has had its chance. (The old queue parks it behind B until its own
        // 15 s deadline.)
        async.elapse(const Duration(seconds: 5));
        expect(r.results.containsKey('start'), isTrue,
            reason: 'answered, not parked behind B');
        final at = r.started['start'];
        expect(at == null || at < const Duration(seconds: 6), isTrue,
            reason: 'if it played, it played now, not when the window freed');
        // B, a non-gesture job, is still waiting (rule 3), not dropped, and
        // plays once the window has room.
        expect(r.results.containsKey('B'), isFalse);
        async.elapse(const Duration(minutes: 3));
        expect(r.results['B'], BuzzDelivery.complete);
        expect(r.started['B'], greaterThanOrEqualTo(const Duration(seconds: 100)));
        final late = r.started['start'];
        expect(late == null || late < const Duration(seconds: 6), isTrue,
            reason: 'never played late');
      });
    });
  });

  group('rule 3: a non-gesture job over the limit waits and plays later', () {
    for (final startBy in const [Duration(seconds: 1), kBandQueueWait]) {
      test('queued with the window spent (start deadline ${startBy.inSeconds} '
          's): not dropped, plays when the window has room', () {
        fakeAsync((async) {
          final r = _Rig(async);
          r.ledger.record(30, clock.now());
          r.plain('a', startBy: startBy);
          async.elapse(const Duration(seconds: 119));
          expect(r.results.containsKey('a'), isFalse,
              reason: 'still waiting, not rejected at its deadline');
          expect(r.started.containsKey('a'), isFalse);
          expect(r.queue.pending, 1);
          async.elapse(const Duration(seconds: 6));
          expect(r.started['a'], greaterThanOrEqualTo(_window));
          expect(r.started['a'], lessThan(_window + const Duration(seconds: 5)));
          expect(r.results['a'], BuzzDelivery.complete);
          expect(r.wrote, ['a']);
        });
      });
    }

    test('several wait in order and play a minimum gap apart, though the '
        'window frees for all of them at once', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(30, clock.now()); // all 30 leave together at 120 s
        r.plain('a');
        r.plain('b');
        r.plain('c');
        async.elapse(const Duration(seconds: 119));
        expect(r.started, isEmpty);
        async.elapse(const Duration(seconds: 20));
        expect(r.results, {
          'a': BuzzDelivery.complete,
          'b': BuzzDelivery.complete,
          'c': BuzzDelivery.complete,
        });
        expect(r.wrote, ['a', 'b', 'c'], reason: 'first in, first out');
        expect(r.started['a'], greaterThanOrEqualTo(_window));
        expect(r.started['b']! - r.started['a']!, greaterThanOrEqualTo(_s));
        expect(r.started['c']! - r.started['b']!, greaterThanOrEqualTo(_s));
      });
    });

    test('after a gesture used up the window, a later non-gesture job waits '
        'for it and then plays', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(26, clock.now());
        r.gesture('g', 'start', commands: 2);
        async.flushMicrotasks();
        r.gesture('g', 'f1', commands: 2);
        r.gesture('g', 'confirm', commands: 2);
        async.elapse(const Duration(seconds: 10));
        expect(r.results['confirm'], BuzzDelivery.complete);
        r.plain('n');
        async.elapse(const Duration(seconds: 100));
        expect(r.started.containsKey('n'), isFalse,
            reason: 'the window is spent until the first writes leave');
        expect(r.results.containsKey('n'), isFalse, reason: 'and it is not dropped');
        async.elapse(const Duration(seconds: 30));
        expect(r.started['n'], greaterThanOrEqualTo(_window));
        expect(r.results['n'], BuzzDelivery.complete);
      });
    });

    test('a non-gesture job behind a window-waiting one keeps its place', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(28, clock.now()); // 2 left
        r.plain('big', commands: 3); // cannot fit: waits for the window
        r.plain('small'); // would fit now, but FIFO: behind big
        async.elapse(const Duration(seconds: 10));
        expect(r.started, isEmpty, reason: 'first in, first out');
        async.elapse(const Duration(minutes: 3));
        expect(r.wrote, ['big', 'big', 'big', 'small']);
        expect(r.results['big'], BuzzDelivery.complete);
        expect(r.results['small'], BuzzDelivery.complete);
      });
    });
  });

  group('rule 5: a gesture larger than the allowance never overdraws', () {
    test('plays everything; the ledger counts exactly the limit and the '
        'counted writes leave on the normal schedule', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(25, clock.now()); // at t0: leaves at 120 s
        async.elapse(const Duration(seconds: 10));
        // 2 + 1 + 1 + 3 = 7 commands, 5 slots left.
        r.gesture('g', 'start', commands: 2);
        async.flushMicrotasks();
        r.gesture('g', 'f1');
        r.gesture('g', 'f2');
        r.gesture('g', 'confirm', commands: 3);
        async.elapse(const Duration(seconds: 20));
        expect(r.results.values, everyElement(BuzzDelivery.complete));
        expect(r.wrote.length, 7, reason: 'all of it was written');
        expect(r.ledger.commandsLeft(clock.now()), 0,
            reason: 'spent equals the limit, not more');

        // A second gesture now finds the window spent.
        r.gesture('g2', 'next');
        async.flushMicrotasks();
        expect(r.results['next'], BuzzDelivery.rejected);

        // 25 of t0 are gone at 121 s; only the 5 counted gesture writes (made
        // at 10 s and after) remain, so 25 are free. An overdraw that counted
        // all 7 would leave 23.
        expect(r.leftAt(const Duration(seconds: 121)), 25);
        // And all of them are gone once they have left too.
        expect(r.leftAt(const Duration(seconds: 200)), 30);
      });
    });

    test('with no slot left at all, the rest of a started gesture plays and '
        'records nothing', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(29, clock.now());
        async.elapse(const Duration(seconds: 10));
        r.gesture('g', 'start'); // takes the last slot
        async.flushMicrotasks();
        r.gesture('g', 'f1');
        r.gesture('g', 'confirm');
        async.elapse(const Duration(seconds: 10));
        expect(r.wrote, ['start', 'f1', 'confirm']);
        expect(r.ledger.commandsLeft(clock.now()), 0);
        // 29 of t0 gone at 121 s; one counted write (the start's) remains.
        expect(r.leftAt(const Duration(seconds: 121)), 29,
            reason: 'two uncounted writes would not be here; an overdraw '
                'would leave 27');
        expect(r.leftAt(const Duration(seconds: 200)), 30);
      });
    });

    test('a gesture with allowance for only part of its first haptic still '
        'starts and plays all of that haptic', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(28, clock.now()); // 2 left
        async.elapse(const Duration(seconds: 10));
        r.gesture('g', 'start', commands: 4); // 4 commands against 2 left
        async.elapse(const Duration(seconds: 5));
        expect(r.results['start'], BuzzDelivery.complete);
        expect(r.wrote.length, 4);
        expect(r.ledger.commandsLeft(clock.now()), 0);
        expect(r.leftAt(const Duration(seconds: 121)), 28,
            reason: 'only 2 of the 4 were counted');
      });
    });
  });

  group('rule 6: the limit is configurable', () {
    test('the default is 30', () {
      fakeAsync((async) {
        expect(BandCommandLedger().commandsLeft(clock.now()), 30);
        expect(kBandCommandLimitDefault, 30);
        expect(kBandCommandLimitMin, 10);
        expect(kBandCommandLimitMax, 60);
      });
    });

    test('10 and 60 are allowed as they are', () {
      fakeAsync((async) {
        expect(BandCommandLedger(limit: () => 10).commandsLeft(clock.now()), 10);
        expect(BandCommandLedger(limit: () => 60).commandsLeft(clock.now()), 60);
        expect(BandCommandLedger(limit: () => 45).commandsLeft(clock.now()), 45);
      });
    });

    test('below 10 and above 60 are clamped', () {
      fakeAsync((async) {
        for (final v in const [9, 5, 0, -3]) {
          expect(BandCommandLedger(limit: () => v).commandsLeft(clock.now()), 10,
              reason: '$v clamps to 10');
        }
        for (final v in const [61, 100, 5000]) {
          expect(BandCommandLedger(limit: () => v).commandsLeft(clock.now()), 60,
              reason: '$v clamps to 60');
        }
      });
    });

    test('reserve and waitFor use the limit', () {
      fakeAsync((async) {
        final low = BandCommandLedger(limit: () => 10);
        expect(low.reserve(11, clock.now()), isNull);
        expect(() => low.waitFor(11, clock.now()), throwsArgumentError);
        expect(low.reserve(10, clock.now()), isNotNull);
        expect(low.reserve(1, clock.now()), isNull);
        final high = BandCommandLedger(limit: () => 60);
        expect(() => high.waitFor(60, clock.now()), returnsNormally);
        expect(high.reserve(60, clock.now()), isNotNull);
        expect(high.reserve(1, clock.now()), isNull);
      });
    });

    test('it is read at every use: a change takes effect without a new '
        'ledger', () {
      fakeAsync((async) {
        var limit = 30;
        final l = BandCommandLedger(limit: () => limit);
        l.record(20, clock.now());
        expect(l.commandsLeft(clock.now()), 10);
        limit = 15;
        expect(l.commandsLeft(clock.now()), 0, reason: 'never below zero');
        limit = 60;
        expect(l.commandsLeft(clock.now()), 40);
        limit = 10;
        expect(l.commandsLeft(clock.now()), 0);
      });
    });

    test('a job over the limit in force never fits and is rejected at once; '
        'the largest job is the limit itself', () {
      fakeAsync((async) {
        final low = _Rig(async, limit: () => 10);
        low.plain('too big', commands: 11);
        async.flushMicrotasks();
        expect(low.results['too big'], BuzzDelivery.rejected);
        low.plain('fits', commands: 10);
        async.elapse(const Duration(seconds: 5));
        expect(low.results['fits'], BuzzDelivery.complete);
        expect(low.wrote.length, 10);

        final high = _Rig(async, limit: () => 60);
        high.plain('sixty', commands: 60);
        async.elapse(const Duration(seconds: 5));
        expect(high.results['sixty'], BuzzDelivery.complete);
        expect(high.wrote.where((w) => w == 'sixty').length, 60);
        high.plain('sixty one', commands: 61);
        async.flushMicrotasks();
        expect(high.results['sixty one'], BuzzDelivery.rejected);
      });
    });

    test('lowering it below what is spent makes a non-gesture job wait for '
        'the window; the queue uses the limit in force', () {
      fakeAsync((async) {
        var limit = 30;
        final r = _Rig(async, limit: () => limit);
        r.ledger.record(20, clock.now());
        limit = 15;
        r.plain('a');
        async.elapse(const Duration(seconds: 100));
        expect(r.started, isEmpty, reason: '20 spent against a limit of 15');
        async.elapse(const Duration(seconds: 25));
        expect(r.results['a'], BuzzDelivery.complete);
        expect(r.started['a'], greaterThanOrEqualTo(_window));
      });
    });

    test('a gesture finds the window spent at the limit in force, and plays '
        'once the limit is raised', () {
      fakeAsync((async) {
        var limit = 10;
        final r = _Rig(async, limit: () => limit);
        r.ledger.record(10, clock.now());
        r.gesture('g1', 'first');
        async.flushMicrotasks();
        expect(r.results['first'], BuzzDelivery.rejected);
        limit = 20;
        r.gesture('g2', 'second');
        async.elapse(const Duration(seconds: 5));
        expect(r.results['second'], BuzzDelivery.complete);
      });
    });
  });

  group('what already held keeps holding', () {
    test('one job at a time, a minimum gap apart, for a gesture\'s own jobs '
        'too', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.gesture('g', 'one', takes: const Duration(seconds: 2));
        async.flushMicrotasks();
        r.gesture('g', 'two');
        async.elapse(const Duration(seconds: 10));
        expect(r.started['one'], Duration.zero);
        expect(r.started['two']!, greaterThanOrEqualTo(const Duration(seconds: 3)),
            reason: 'after the first ended (2 s) and the 1 s gap');
        expect(r.results.values, everyElement(BuzzDelivery.complete));
      });
    });

    test('a gesture\'s lab job still goes ahead of a waiting alert', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.plain('playing', takes: const Duration(seconds: 3));
        async.elapse(const Duration(milliseconds: 500));
        r.plain('alert');
        async.elapse(const Duration(milliseconds: 500));
        // The Device lab's gestures are lab jobs; they are gesture jobs too.
        unawaited(r.queue.asLab(() => r.queue.asGesture(
              'lab-g',
              () => r.queue
                  .run(r._job('lab cue', 1, Duration.zero),
                      commands: 1, timeout: const Duration(seconds: 30))
                  .then((v) => r.results['lab cue'] = v),
            )));
        async.elapse(const Duration(seconds: 20));
        expect(r.wrote, ['playing', 'lab cue', 'alert']);
      });
    });

    test('the open lab still holds a non-gesture job until it closes', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.queue.beginLab();
        r.plain('alert');
        async.elapse(const Duration(minutes: 5));
        expect(r.started, isEmpty);
        expect(r.results, isEmpty, reason: 'held, not dropped');
        r.queue.endLab();
        async.elapse(const Duration(seconds: 5));
        expect(r.results['alert'], BuzzDelivery.complete);
      });
    });
  });
}
