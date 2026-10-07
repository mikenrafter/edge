// What a non-gesture job does when the command limit has no room, and the
// edges of the gesture rules around it (the main rules are pinned in
// band_queue_haptic_budget_test.dart).
//
//   * A plain job is never dropped for waiting: not for the window, not behind
//     a running job. Its alert dispatcher's own delivery deadline does not run
//     while it waits for room, and counts again (as a transport timeout) once
//     the job has started.
//   * Jobs that waited for room play at least a second apart, also on a band
//     with no haptic profile (no vocabulary gap).
//   * Raising the limit while a job waits lets it go on within a second.
//   * A gesture job is never played late: with the Device lab open, or behind a
//     job that outlasts its start deadline, it is rejected.
//   * The queue forgets a gesture id five minutes after its last job.
//
// Times are fake (fake_async): the queue reads `clock`, never DateTime.now.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

const Duration _s = Duration(seconds: 1);

class _Rig {
  _Rig(this.async, {int Function()? limit, Duration Function()? minGap})
      : ledger = BandCommandLedger(limit: limit) {
    queue = BandHapticQueue(ledger: ledger, minGap: minGap);
  }

  final FakeAsync async;
  final BandCommandLedger ledger;
  late final BandHapticQueue queue;
  final started = <String, Duration>{};
  final results = <String, BuzzDelivery>{};

  Future<BuzzDelivery> Function(BandJobToken) _job(
          String name, int writes, Duration takes) =>
      (t) async {
        started[name] = async.elapsed;
        for (var i = 0; i < writes; i++) {
          await t.write(() async => true);
        }
        if (takes > Duration.zero) await Future<void>.delayed(takes);
        return BuzzDelivery.complete;
      };

  void plain(String name,
      {int commands = 1,
      Duration takes = Duration.zero,
      Duration startBy = kBandQueueWait}) {
    unawaited(queue
        .run(_job(name, commands, takes),
            commands: commands,
            timeout: const Duration(seconds: 60),
            startBy: startBy)
        .then((v) => results[name] = v));
  }

  void gesture(String id, String name,
      {int commands = 1, Duration takes = Duration.zero}) {
    unawaited(queue.asGesture(
        id,
        () => queue
            .run(_job(name, commands, takes),
                commands: commands, timeout: const Duration(seconds: 60))
            .then((v) => results[name] = v)));
  }
}

void main() {
  group('a plain job is never dropped for waiting', () {
    test('behind a running job it waits past its start deadline', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.plain('long', takes: const Duration(seconds: 20));
        r.plain('b', startBy: const Duration(seconds: 15));
        async.elapse(const Duration(seconds: 16));
        expect(r.results.containsKey('b'), isFalse,
            reason: 'still waiting, not rejected at 15 s');
        async.elapse(const Duration(seconds: 10));
        expect(r.started['b'], greaterThanOrEqualTo(const Duration(seconds: 20)));
        expect(r.results['b'], BuzzDelivery.complete);
      });
    });

    test('a limit lowered under a waiting job that no longer fits rejects it '
        'instead of throwing', () {
      fakeAsync((async) {
        var limit = 30;
        final r = _Rig(async, limit: () => limit);
        r.ledger.record(25, clock.now());
        r.plain('big', commands: 12); // waits for the window
        async.elapse(const Duration(seconds: 3));
        expect(r.results.containsKey('big'), isFalse);
        limit = 10;
        async.elapse(const Duration(seconds: 3));
        expect(r.results['big'], BuzzDelivery.rejected);
        expect(r.queue.pending, 0);
      });
    });
  });

  group('the alert dispatcher does not give up on a job waiting for room', () {
    const rule = AlertRule(
      id: 'budget_wait',
      kind: 'buzzPreview',
      destinations: AlertRule.band,
      executionMode: AlertExecutionMode.phoneLive,
      staleAfter: Duration(minutes: 30),
      channelPolicyId: 'buzz_preview',
    );

    AlertDispatcher dispatcher() => AlertDispatcher(
          phone: () async => false,
          band: () async => true,
          isConnected: () => true,
          now: clock.now,
          ledger: MemoryAlertDeliveryLedger(),
          bandQueueWait: kBandQueueWait,
        );

    Future<AlertDeliveryOutcome> send(_Rig r, AlertDispatcher d, String id,
            {Future<BuzzDelivery> Function(BandJobToken)? job}) =>
        d.dispatch(
          rule,
          eventId: id,
          sourceTime: clock.now(),
          historical: false,
          bandTimeout: const Duration(seconds: 5),
          bandDelivery: () => r.queue.run(job ?? r._job(id, 1, Duration.zero),
              commands: 1, timeout: const Duration(seconds: 60)),
        );

    test('15 s of queue wait plus the transport time pass while it waits for '
        'the window, and it still plays when the window has room', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(30, clock.now());
        AlertDeliveryOutcome? out;
        send(r, dispatcher(), 'a').then((o) => out = o);
        async.elapse(const Duration(seconds: 119));
        expect(out, isNull, reason: 'well past 15 s + 5 s, still waiting');
        async.elapse(const Duration(seconds: 6));
        expect(out!.targets, ['band']);
        expect(r.started['a'], greaterThanOrEqualTo(const Duration(minutes: 2)));
      });
    });

    test('once the job has started the transport timeout counts again', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(30, clock.now());
        AlertDeliveryOutcome? out;
        send(r, dispatcher(), 'a', job: (t) async {
          r.started['a'] = async.elapsed;
          return Completer<BuzzDelivery>().future; // never answers
        }).then((o) => out = o);
        async.elapse(const Duration(seconds: 125));
        expect(r.started['a'], isNotNull);
        expect(out, isNull, reason: 'its time runs from the start, 120 s');
        async.elapse(const Duration(seconds: 30));
        expect(out!.targets, isEmpty);
        expect(out!.suppressionReason, 'deliveryUnconfirmed');
      });
    });
  });

  group('jobs that waited for room play a gap apart', () {
    test('a band with no haptic profile (no vocabulary gap) still gets a '
        'second', () {
      fakeAsync((async) {
        final r = _Rig(async); // minGap null
        r.ledger.record(30, clock.now());
        r.plain('a');
        r.plain('b');
        r.plain('c');
        async.elapse(const Duration(seconds: 130));
        expect(r.results.length, 3);
        expect(r.started['b']! - r.started['a']!, greaterThanOrEqualTo(_s));
        expect(r.started['c']! - r.started['b']!, greaterThanOrEqualTo(_s));
      });
    });

    test('a shorter vocabulary gap is raised to a second; a longer one stays',
        () {
      fakeAsync((async) {
        final short =
            _Rig(async, minGap: () => const Duration(milliseconds: 300));
        short.ledger.record(30, clock.now());
        short.plain('a');
        short.plain('b');
        final long = _Rig(async, minGap: () => const Duration(seconds: 3));
        long.ledger.record(30, clock.now());
        long.plain('a');
        long.plain('b');
        async.elapse(const Duration(seconds: 130));
        expect(short.started['b']! - short.started['a']!,
            greaterThanOrEqualTo(_s));
        expect(long.started['b']! - long.started['a']!,
            greaterThanOrEqualTo(const Duration(seconds: 3)));
      });
    });

    test('jobs that never waited for room are not spaced by the floor', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.plain('a');
        r.plain('b');
        async.elapse(const Duration(milliseconds: 10));
        expect(r.started['a'], Duration.zero);
        expect(r.started['b'], Duration.zero);
      });
    });
  });

  group('a limit raised while a job waits', () {
    test('lets it go on within a second', () {
      fakeAsync((async) {
        var limit = 10;
        final r = _Rig(async, limit: () => limit);
        r.ledger.record(10, clock.now());
        r.plain('a');
        async.elapse(const Duration(seconds: 5));
        expect(r.started, isEmpty, reason: 'the window is spent');
        limit = 20;
        async.elapse(const Duration(seconds: 1));
        expect(r.started['a'], isNotNull);
        expect(r.started['a']!, lessThanOrEqualTo(const Duration(seconds: 6)));
        expect(r.results['a'], BuzzDelivery.complete);
      });
    });
  });

  group('a gesture haptic is never played late', () {
    test('behind a job that outlasts its start deadline it is rejected at the '
        'deadline, not played afterwards', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.plain('long', takes: const Duration(seconds: 25));
        async.flushMicrotasks();
        r.gesture('g', 'cue');
        async.elapse(const Duration(seconds: 14));
        expect(r.results.containsKey('cue'), isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(r.results['cue'], BuzzDelivery.rejected);
        async.elapse(const Duration(seconds: 30));
        expect(r.started.containsKey('cue'), isFalse);
      });
    });

    test('with the Device lab open it is rejected, and one waiting when the '
        'lab opens is rejected too, while a plain job is held', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.plain('long', takes: const Duration(seconds: 5));
        async.flushMicrotasks();
        r.gesture('g', 'waiting');
        r.queue.beginLab();
        async.flushMicrotasks();
        expect(r.results['waiting'], BuzzDelivery.rejected);
        r.gesture('g2', 'arriving');
        async.flushMicrotasks();
        expect(r.results['arriving'], BuzzDelivery.rejected);
        r.plain('alert');
        async.elapse(const Duration(seconds: 30));
        expect(r.started.containsKey('alert'), isFalse, reason: 'held');
        expect(r.results.containsKey('alert'), isFalse);
        r.queue.endLab();
        async.elapse(const Duration(seconds: 10));
        expect(r.results['alert'], BuzzDelivery.complete);
      });
    });

    test('a gesture queued as already started (the tap ack) plays with no '
        'room at all, and the ledger stays at the limit', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(30, clock.now());
        unawaited(r.queue.asGesture(
            'ack',
            () => r.queue
                .run(r._job('ack', 2, Duration.zero),
                    commands: 2, timeout: const Duration(seconds: 60))
                .then((v) => r.results['ack'] = v),
            started: true));
        async.elapse(const Duration(seconds: 5));
        expect(r.results['ack'], BuzzDelivery.complete);
        expect(r.started['ack'], Duration.zero, reason: 'played now');
        expect(r.ledger.commandsLeft(clock.now()), 0);
        // The 30 of t0 leave at 120 s; nothing the ack wrote was counted.
        expect(r.ledger.commandsLeft(clock.now().add(const Duration(seconds: 121))),
            30);
      });
    });

    test('a gesture id is forgotten five minutes after its last job', () {
      fakeAsync((async) {
        final r = _Rig(async);
        r.ledger.record(29, clock.now());
        r.gesture('g', 'first');
        async.elapse(const Duration(minutes: 1));
        r.ledger.record(r.ledger.commandsLeft(clock.now()), clock.now());
        r.gesture('g', 'within');
        async.elapse(const Duration(seconds: 5));
        expect(r.results['within'], BuzzDelivery.complete,
            reason: 'the gesture started a minute ago: it plays to its end');
        async.elapse(const Duration(minutes: 6));
        r.ledger.record(r.ledger.commandsLeft(clock.now()), clock.now());
        r.gesture('g', 'late');
        async.flushMicrotasks();
        expect(r.results['late'], BuzzDelivery.rejected,
            reason: 'forgotten: it needs room like any gesture start');
      });
    });
  });
}
