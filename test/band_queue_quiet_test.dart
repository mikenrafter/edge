// Quiet window of the band queue (snooze, rounds 8 and 10). Plain jobs are
// HELD around the native alarm, never dropped; all time here is fake
// (fakeAsync's clock, which `package:clock` follows).
//
//  round 10, 1  time spent held by a quiet window does not count toward the
//               dispatcher's freshness: a preview or relay job held for 35 s is
//               delivered afterwards, not rejected as stale (a LAB hold still
//               drops a job that went stale: band_queue_lab_test.dart)
//  round 10, 3  a plain job that could still be PLAYING when the window opens
//               is held too: `expectQuiet(W)` says when the next window opens,
//               and a plain job whose planned end (timeout + settle + write
//               grace) would pass W waits for the window to end

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

Future<BuzzDelivery> Function(BandJobToken) _buzz(
  FakeAsync async,
  List<(String, int)> writes,
  String who,
) =>
    (t) async {
      await t.write(() async {
        writes.add((who, async.elapsed.inSeconds));
        return true;
      });
      return BuzzDelivery.complete;
    };

const Duration _s = Duration(seconds: 1);

void main() {
  group('1 a quiet hold never makes a job stale', () {
    AlertRule rule(Duration stale) => AlertRule(
          id: 'buzz_preview',
          kind: 'buzzPreview',
          destinations: AlertRule.band,
          executionMode: AlertExecutionMode.phoneLive,
          staleAfter: stale,
          channelPolicyId: 'buzz_preview',
        );

    ({
      Future<AlertDeliveryOutcome> Function(Duration stale, String id) send,
      BandHapticQueue queue,
      List<(String, int)> writes,
    }) rig(FakeAsync async) {
      final queue = BandHapticQueue(ledger: BandCommandLedger());
      final writes = <(String, int)>[];
      final d = AlertDispatcher(
        phone: () async => false,
        band: () async => true,
        isConnected: () => true,
        now: clock.now,
        ledger: MemoryAlertDeliveryLedger(),
        bandQueueWait: kBandQueueWait,
      );
      return (
        queue: queue,
        writes: writes,
        send: (stale, id) => d.dispatch(
              rule(stale),
              eventId: id,
              sourceTime: clock.now(),
              historical: false,
              bandDelivery: () => queue.run(_buzz(async, writes, id),
                  commands: 1,
                  timeout: const Duration(seconds: 5),
                  settle: Duration.zero),
            ),
      );
    }

    test('a preview (10 s freshness) held 35 s by the quiet window is '
        'delivered when it ends', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginQuiet();
        AlertDeliveryOutcome? out;
        r.send(const Duration(seconds: 10), 'preview').then((o) => out = o);
        async.elapse(_s * 35);
        expect(out, isNull, reason: 'held, not answered');
        r.queue.endQuiet();
        async.elapse(_s * 5);
        expect(out!.targets, ['band'],
            reason: 'rejected as stale after a hold that is not its fault');
        expect(r.writes, hasLength(1));
      });
    });

    test('a relay job (30 s freshness) held 45 s is delivered', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginQuiet();
        AlertDeliveryOutcome? out;
        r.send(const Duration(seconds: 30), 'relay').then((o) => out = o);
        async.elapse(_s * 45);
        r.queue.endQuiet();
        async.elapse(_s * 5);
        expect(out!.targets, ['band']);
        expect(r.writes, hasLength(1));
      });
    });

    test('control: held by the LAB, it still goes stale by its own rule',
        () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginLab();
        AlertDeliveryOutcome? out;
        r.send(const Duration(seconds: 10), 'preview').then((o) => out = o);
        async.elapse(_s * 35);
        r.queue.endLab();
        async.elapse(_s * 5);
        expect(out!.targets, isEmpty);
        expect(r.writes, isEmpty);
      });
    });

    test('control: a lab hold followed by a quiet hold keeps the lab\'s '
        'staleness rule', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginQuiet();
        r.queue.beginLab();
        AlertDeliveryOutcome? out;
        r.send(const Duration(seconds: 10), 'preview').then((o) => out = o);
        async.elapse(_s * 35);
        r.queue.endLab();
        r.queue.endQuiet();
        async.elapse(_s * 5);
        expect(out!.targets, isEmpty);
      });
    });
  });

  group('3 a job that could still be playing when the window opens waits', () {
    // W = 100 s. A job's planned end is now + timeout + settle + the write
    // grace (3 s).
    test('a long rhythm (timeout 30 s) requested at 80 s waits for the '
        'window to end; it never runs across the alarm', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        final w = clock.now().add(_s * 100);
        q.expectQuiet(w);
        async.elapse(_s * 80);
        BuzzDelivery? out;
        q.run(_buzz(async, writes, 'long'),
                commands: 1,
                timeout: const Duration(seconds: 30),
                settle: Duration.zero)
            .then((v) => out = v);
        async.elapse(_s * 5);
        expect(writes, isEmpty, reason: 'it would still be playing at W');
        expect(out, isNull, reason: 'held, not rejected');

        async.elapse(_s * 15); // W: the window opens
        q.beginQuiet(); // (it ends the expectation itself)
        async.elapse(_s * 40);
        expect(writes, isEmpty, reason: 'held through the window');
        q.endQuiet();
        async.elapse(_s * 5);
        expect(writes, [('long', 140)]);
        expect(out, BuzzDelivery.complete);
      });
    });

    test('a short cue (timeout 3 s) requested at 80 s plays at once '
        '(control)', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 80);
        q.run(_buzz(async, writes, 'short'),
            commands: 1,
            timeout: const Duration(seconds: 3),
            settle: Duration.zero);
        async.elapse(_s);
        expect(writes, [('short', 80)]);
      });
    });

    test('the same long rhythm requested at 50 s (done long before W) plays '
        'at once (control)', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 50);
        q.run(_buzz(async, writes, 'long'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero);
        async.elapse(_s);
        expect(writes, [('long', 50)]);
      });
    });

    test('withdrawing the expectation (alarm disarmed, snooze off) releases '
        'what waited', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 90);
        q.run(_buzz(async, writes, 'long'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero);
        async.elapse(_s * 5);
        expect(writes, isEmpty);
        q.expectQuiet(null);
        async.elapse(_s);
        expect(writes, hasLength(1));
      });
    });

    test('alarm, gesture and lab jobs are never deferred', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 90);
        q.asAlarm(() => q.run(_buzz(async, writes, 'alarm'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero));
        q.asGesture('g', () => q.run(_buzz(async, writes, 'gesture'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero));
        q.run(_buzz(async, writes, 'lab'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero,
            lab: true);
        async.elapse(_s * 10);
        expect(writes.map((w) => w.$1).toSet(), {'alarm', 'gesture', 'lab'});
      });
    });
  });

  group('C an immediate (must-start-now) cue is rejected near an expected '
      'window, never deferred', () {
    test('its planned end passes the window start: rejected at admission',
        () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 95);
        BuzzDelivery? out;
        q.asImmediate(() => q.run(_buzz(async, writes, 'phase'),
            commands: 1,
            timeout: const Duration(seconds: 3),
            settle: Duration.zero)).then((v) => out = v);
        async.elapse(_s * 200);
        expect(out, BuzzDelivery.rejected,
            reason: 'admitted, then held until the alarm window ended: it '
                'would play in a later phase');
        expect(writes, isEmpty);
        expect(q.pending, 0);
      });
    });

    test('far from the window it starts at once (control)', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.expectQuiet(clock.now().add(_s * 100));
        async.elapse(_s * 50);
        BuzzDelivery? out;
        q.asImmediate(() => q.run(_buzz(async, writes, 'phase'),
            commands: 1,
            timeout: const Duration(seconds: 3),
            settle: Duration.zero)).then((v) => out = v);
        async.elapse(_s);
        expect(out, BuzzDelivery.complete);
        expect(writes, [('phase', 50)]);
      });
    });

    test('with the window open it is rejected (control)', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        q.beginQuiet();
        BuzzDelivery? out;
        q.asImmediate(() => q.run(_buzz(async, [], 'phase'),
            commands: 1,
            timeout: const Duration(seconds: 3),
            settle: Duration.zero)).then((v) => out = v);
        async.elapse(_s);
        expect(out, BuzzDelivery.rejected);
      });
    });
  });

  group('B the expectation is re-read against the planning clock', () {
    test('a job deferred, then the planning clock moves back an hour: the '
        'same expectation, told again, releases it (it has time now)', () {
      fakeAsync((async) {
        var now = clock.now();
        final base = now;
        final q = BandHapticQueue(
            ledger: BandCommandLedger(), planningNow: () => now);
        final writes = <(String, int)>[];
        q.expectQuiet(base.add(_s * 10));
        q.run(_buzz(async, writes, 'p'),
            commands: 1,
            timeout: const Duration(seconds: 30),
            settle: Duration.zero);
        async.elapse(_s * 2);
        expect(writes, isEmpty, reason: 'precondition: deferred');
        now = base.subtract(const Duration(hours: 1));
        q.expectQuiet(base.add(_s * 10)); // told again on the next sync
        async.elapse(_s);
        expect(writes, hasLength(1));
      });
    });
  });
}
