// Round 3 (Sol, alarm-snooze-sol-review2-2026-10-07.md, new defect 6): the
// command ledger records EVERY actual write, even past the limit. RED.
//
// An alarm job (the re-alarm) is never held for the 30-in-2-minutes budget,
// but the commands it writes are real: the ledger used to count only the part
// that fitted under the limit (BandCommandLedger.reserveUpTo clamps), so six
// alarm writes beside 30 old ones that were about to expire were not counted at
// all, and one second later an ordinary 30-command job ran on top of them.
// The ledger must hold the real count; later ordinary jobs wait for it.
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

  Future<BuzzDelivery> Function(BandJobToken) _job(String name, int writes) =>
      (t) async {
        started[name] = async.elapsed;
        for (var i = 0; i < writes; i++) {
          await t.write(() async => true);
        }
        return BuzzDelivery.complete;
      };

  void plain(String name, {int commands = 1}) {
    unawaited(queue
        .run(_job(name, commands),
            commands: commands, timeout: const Duration(seconds: 60))
        .then((v) => results[name] = v));
  }

  void alarm(String name, {int commands = 1}) {
    unawaited(queue.asAlarm(() => queue
        .run(_job(name, commands),
            commands: commands, timeout: const Duration(seconds: 60))
        .then((v) => results[name] = v)));
  }
}

void main() {
  test('the review\'s case: 30 old writes about to expire, six alarm writes '
      'beside them, then an ordinary 30-command job: it waits for the six',
      () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ledger.record(30, clock.now()); // t = 0
      async.elapse(const Duration(seconds: 119));
      r.alarm('realarm', commands: 6); // never held: plays at t = 119 s
      async.elapse(const Duration(seconds: 2)); // t = 121 s: the old 30 left
      expect(r.results['realarm'], BuzzDelivery.complete);
      expect(r.ledger.commandsLeft(clock.now()), 24,
          reason: 'six real writes are in the window; the clamped count '
              'said none');

      r.plain('ordinary', commands: 30);
      async.elapse(const Duration(seconds: 10));
      expect(r.started.containsKey('ordinary'), isFalse,
          reason: '30 more on top of 6 fresh writes is 36 in two minutes');
      async.elapse(const Duration(minutes: 3));
      expect(r.started['ordinary'],
          greaterThanOrEqualTo(const Duration(seconds: 239)),
          reason: 'only once the alarm\'s own writes left the window');
      expect(r.results['ordinary'], BuzzDelivery.complete);
    });
  });

  test('every write is counted, also past the limit', () {
    fakeAsync((async) {
      final r = _Rig(async);
      r.ledger.record(28, clock.now());
      async.elapse(const Duration(seconds: 60));
      r.alarm('realarm', commands: 6); // 28 + 6 = 34 written, limit 30
      async.elapse(const Duration(seconds: 2));
      expect(r.results['realarm'], BuzzDelivery.complete);
      expect(r.ledger.commandsLeft(clock.now()), 0);

      async.elapse(const Duration(seconds: 59)); // t = 121 s: the 28 left
      expect(r.ledger.commandsLeft(clock.now()), 24,
          reason: 'the six alarm writes are all still there');
      r.plain('later', commands: 26);
      async.elapse(const Duration(seconds: 5));
      expect(r.started.containsKey('later'), isFalse,
          reason: '26 + 6 > 30');
      async.elapse(const Duration(minutes: 3));
      expect(r.results['later'], BuzzDelivery.complete);
    });
  });

  test('an alarm of more commands than the limit is played whole, and all of '
      'it is counted', () {
    fakeAsync((async) {
      final r = _Rig(async, limit: () => 10);
      r.alarm('long', commands: 14);
      async.elapse(const Duration(seconds: 3));
      expect(r.results['long'], BuzzDelivery.complete);
      r.plain('after', commands: 1);
      async.elapse(const Duration(seconds: 60));
      expect(r.started.containsKey('after'), isFalse,
          reason: '14 writes in a limit of 10: nothing ordinary until they '
              'leave');
      async.elapse(const Duration(minutes: 2));
      expect(r.results['after'], BuzzDelivery.complete);
    });
  });
}
