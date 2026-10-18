// Alarm-class band jobs (the snooze's re-alarm and its confirms): waking the
// user outranks our own 30-commands-in-2-minutes precaution.
//
//   * with the window exhausted, an alarm job starts at once; a plain job
//     waits for room as ever
//   * it is COUNTED (so what follows sees the cost) but clamped: the ledger
//     never counts more than the limit, nothing is overdrawn
//   * it still waits its turn for the band (one thing plays at a time), is
//     held by the Device lab like any non-lab job, and an alarm of more
//     commands than the limit is not dropped
//   * a plain job queued behind a waiting plain job does not hold an alarm up
//
// Times are fake (fake_async): the queue reads `clock`, never DateTime.now.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

class _Rig {
  _Rig(this.async, {int Function()? limit})
      : ledger = BandCommandLedger(limit: limit) {
    queue = BandHapticQueue(ledger: ledger);
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
      {int commands = 1, Duration takes = Duration.zero}) {
    unawaited(queue
        .run(_job(name, commands, takes),
            commands: commands, timeout: const Duration(seconds: 60))
        .then((v) => results[name] = v));
  }

  void alarm(String name,
      {int commands = 1, Duration takes = Duration.zero}) {
    unawaited(queue.asAlarm(() => queue
        .run(_job(name, commands, takes),
            commands: commands, timeout: const Duration(seconds: 60))
        .then((v) => results[name] = v)));
  }
}

void main() {
  test('with the window exhausted an alarm job plays at once; a plain job '
      'waits for room', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ledger.record(30, clock.now());
      r.alarm('realarm', commands: 6);
      r.plain('other', commands: 2);
      async.elapse(const Duration(seconds: 5));
      expect(r.started['realarm'], Duration.zero,
          reason: 'waking the user outranks the precaution');
      expect(r.results['realarm'], BuzzDelivery.complete);
      expect(r.results.containsKey('other'), isFalse,
          reason: 'a plain job still waits for room');
      async.elapse(const Duration(minutes: 3));
      expect(r.results['other'], BuzzDelivery.complete);
    });
  });

  test('an alarm job is counted but never overdraws the ledger', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ledger.record(28, clock.now());
      r.alarm('realarm', commands: 6);
      async.elapse(const Duration(seconds: 2));
      expect(r.results['realarm'], BuzzDelivery.complete);
      // 28 written + only the 2 that fit were counted of its 6.
      expect(r.ledger.commandsLeft(clock.now()), 0);
      r.ledger.record(0, clock.now());
      expect(r.ledger.limitNow, 30);
      async.elapse(const Duration(minutes: 3));
      expect(r.ledger.commandsLeft(clock.now()), 30,
          reason: 'every count leaves the window two minutes after it');
    });
  });

  test('it still waits for the band: one thing plays at a time', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.plain('first', takes: const Duration(seconds: 4));
      r.alarm('realarm');
      async.elapse(const Duration(seconds: 1));
      expect(r.started.containsKey('realarm'), isFalse);
      async.elapse(const Duration(seconds: 5));
      expect(r.started['realarm'], greaterThanOrEqualTo(const Duration(seconds: 4)));
    });
  });

  test('an alarm of more commands than the limit is not dropped', () {
    fakeAsync((async) {
      final r = _Rig(async, limit: () => 10);
      r.alarm('long', commands: 14);
      async.elapse(const Duration(seconds: 3));
      expect(r.results['long'], BuzzDelivery.complete);
    });
  });

  test('a plain job waiting for room does not hold an alarm up', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ledger.record(30, clock.now());
      r.plain('waiting', commands: 3);
      async.elapse(const Duration(seconds: 2));
      r.alarm('realarm', commands: 4);
      async.elapse(const Duration(seconds: 3));
      expect(r.results['realarm'], BuzzDelivery.complete);
      expect(r.results.containsKey('waiting'), isFalse);
    });
  });

  test('the Device lab still holds it, like any non-lab job (and releases it)',
      () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.queue.beginLab();
      r.alarm('realarm');
      async.elapse(const Duration(seconds: 20));
      expect(r.started.containsKey('realarm'), isFalse);
      r.queue.endLab();
      async.elapse(const Duration(seconds: 3));
      expect(r.results['realarm'], BuzzDelivery.complete);
    });
  });
}
