// Immediate mode of the band queue: a job queued inside asImmediate starts now
// or is rejected on the spot. It never waits behind another job, the open
// lab or the rolling command budget, and a rejection leaves nothing queued.

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

Future<BuzzDelivery> Function(BandJobToken) _buzz(List<String> writes) =>
    (t) async {
      await t.write(() async {
        writes.add('buzz');
        return true;
      });
      return BuzzDelivery.complete;
    };

void main() {
  const timeout = Duration(seconds: 5);

  test('an idle band starts an immediate job', () {
    fakeAsync((async) {
      final q = BandHapticQueue(ledger: BandCommandLedger());
      final writes = <String>[];
      BuzzDelivery? out;
      q.asImmediate(() => q
          .run(_buzz(writes), commands: 1, timeout: timeout)
          .then((v) => out = v));
      async.elapse(const Duration(seconds: 1));
      expect(writes, ['buzz']);
      expect(out, BuzzDelivery.complete);
    });
  });

  test('a busy band, an open lab or a spent budget reject it with nothing '
      'queued or written', () {
    fakeAsync((async) {
      final ledger = BandCommandLedger();
      final q = BandHapticQueue(ledger: ledger);
      final writes = <String>[];
      BuzzDelivery? out;
      void tryIt() => q.asImmediate(() => q
          .run(_buzz(writes), commands: 1, timeout: timeout)
          .then((v) => out = v));

      q.run((t) async {
        await t.write(() async {
          await Future<void>.delayed(const Duration(seconds: 2));
          writes.add('buzz');
          return true;
        });
        return BuzzDelivery.complete;
      }, commands: 1, timeout: timeout);
      async.elapse(const Duration(seconds: 1));
      tryIt();
      async.flushMicrotasks();
      expect(out, BuzzDelivery.rejected, reason: 'busy');
      expect(q.pending, 1, reason: 'only the first job');
      async.elapse(const Duration(seconds: 10));

      out = null;
      q.beginLab();
      tryIt();
      async.flushMicrotasks();
      expect(out, BuzzDelivery.rejected, reason: 'lab open');
      expect(q.pending, 0);
      q.endLab();

      out = null;
      ledger.record(BandCommandLedger.maxCommands, clock.now());
      tryIt();
      async.flushMicrotasks();
      expect(out, BuzzDelivery.rejected, reason: 'budget spent');
      expect(q.pending, 0);
      async.elapse(const Duration(minutes: 5));
      expect(writes, ['buzz'], reason: 'the rejected jobs never wrote');
    });
  });

  test('work outside asImmediate still waits as before', () {
    fakeAsync((async) {
      final q = BandHapticQueue(ledger: BandCommandLedger());
      final writes = <String>[];
      q.run(_buzz(writes), commands: 1, timeout: timeout);
      BuzzDelivery? out;
      q
          .run(_buzz(writes), commands: 1, timeout: timeout)
          .then((v) => out = v);
      async.elapse(const Duration(seconds: 10));
      expect(writes, hasLength(2));
      expect(out, BuzzDelivery.complete);
    });
  });
}
