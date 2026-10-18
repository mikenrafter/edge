// Lab mode of the band queue. While the Device lab is open, its probes
// (and the touch counter's buzzes) are lab jobs that go first, and every real
// alert is held, not dropped: its start deadline is suspended, the
// dispatcher's delivery deadline does not run, and both start over when the lab
// closes. A job already playing is never preempted. The 30-per-2-minutes
// ledger stays shared.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/hardware_probe_runner.dart';
import 'package:openstrap_edge/gestures/hardware_probes.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';
import 'package:openstrap_edge/notify/alert_dispatcher.dart';
import 'package:openstrap_edge/notify/alert_rule.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';
import 'package:openstrap_edge/ui2/profile/device_lab.dart';

const Duration _s = Duration(seconds: 1);

// A one-command job that notes when it wrote.
Future<BuzzDelivery> Function(BandJobToken) _buzz(
  FakeAsync async,
  List<(String, int)> writes,
  String who, {
  Duration takes = Duration.zero,
}) =>
    (t) async {
      await t.write(() async {
        writes.add((who, async.elapsed.inMilliseconds));
        if (takes > Duration.zero) await Future<void>.delayed(takes);
        return true;
      });
      return BuzzDelivery.complete;
    };

int _busiestWindow(List<DateTime> writes) {
  var most = 0;
  for (final at in writes) {
    final n = writes
        .where((w) =>
            !w.isAfter(at) && w.add(BandCommandLedger.window).isAfter(at))
        .length;
    if (n > most) most = n;
  }
  return most;
}

void main() {
  group('BandHapticQueue lab mode', () {
    test('an alert queued while the lab is open is not written until the lab '
        'closes, then it is; the log says so', () {
      fakeAsync((async) {
        final log = <String>[];
        final q = BandHapticQueue(ledger: BandCommandLedger(), log: log.add);
        final writes = <(String, int)>[];
        q.beginLab();
        BuzzDelivery? out;
        q.run(_buzz(async, writes, 'alert'),
                commands: 1, timeout: const Duration(seconds: 5))
            .then((v) => out = v);
        async.elapse(const Duration(minutes: 10));
        expect(writes, isEmpty, reason: 'held the whole time');
        expect(out, isNull, reason: 'neither rejected nor answered');
        expect(q.pending, 1);
        q.endLab();
        async.elapse(_s);
        expect(writes, [('alert', 600000)]);
        expect(out, BuzzDelivery.complete);
        expect(log, contains('Band queue: lab open, holding 0 alerts'));
        expect(log, contains('Band queue: lab closed, releasing 1 alerts'));
      });
    });

    test('an alert already waiting when the lab opens is held, its start '
        'deadline suspended and restarted when the lab closes', () {
      fakeAsync((async) {
        final log = <String>[];
        final q = BandHapticQueue(ledger: BandCommandLedger(), log: log.add);
        final writes = <(String, int)>[];
        // A playing job keeps the alert waiting.
        q.run(_buzz(async, writes, 'a', takes: const Duration(seconds: 5)),
            commands: 1, timeout: const Duration(seconds: 10));
        BuzzDelivery? out;
        q.run(_buzz(async, writes, 'alert'),
                commands: 1,
                timeout: const Duration(seconds: 5),
                startBy: const Duration(seconds: 15))
            .then((v) => out = v);
        async.elapse(_s);
        q.beginLab();
        expect(log, contains('Band queue: lab open, holding 1 alerts'));
        // A lab job runs while the alert is held: busy past its 15 s.
        q.runLab(() => Future<void>.delayed(const Duration(seconds: 100)));
        async.elapse(const Duration(seconds: 99));
        expect(out, isNull, reason: 'held, not dropped at 15 s');
        q.endLab(); // at 100 s; the lab job runs until about 106 s
        async.elapse(const Duration(seconds: 14));
        expect(out, BuzzDelivery.complete,
            reason: 'its 15 s wait began again at 100 s');
        expect(writes.last.$1, 'alert');
        expect(writes.last.$2, greaterThanOrEqualTo(100000));
      });
    });

    test('a lab job goes ahead of a waiting alert, never ahead of one playing',
        () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.run(_buzz(async, writes, 'playing', takes: const Duration(seconds: 3)),
            commands: 1,
            timeout: const Duration(seconds: 10),
            settle: Duration.zero);
        q.run(_buzz(async, writes, 'waiting'),
            commands: 1, timeout: const Duration(seconds: 5), settle: Duration.zero);
        q.run(_buzz(async, writes, 'lab'),
            commands: 1,
            timeout: const Duration(seconds: 5),
            settle: Duration.zero,
            lab: true);
        async.elapse(const Duration(seconds: 10));
        expect(writes.map((w) => w.$1).toList(), ['playing', 'lab', 'waiting']);
        expect(writes[1].$2, 3000, reason: 'after the playing job finished');
      });
    });

    test('lab jobs keep their order among themselves', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.run(_buzz(async, writes, 'playing', takes: _s),
            commands: 1, timeout: const Duration(seconds: 10), settle: Duration.zero);
        q.run(_buzz(async, writes, 'alert'),
            commands: 1, timeout: _s * 5, settle: Duration.zero);
        for (final n in ['lab1', 'lab2']) {
          q.run(_buzz(async, writes, n),
              commands: 1, timeout: _s * 5, settle: Duration.zero, lab: true);
        }
        async.elapse(const Duration(seconds: 10));
        expect(writes.map((w) => w.$1).toList(),
            ['playing', 'lab1', 'lab2', 'alert']);
      });
    });

    test('with the lab open a lab job starts at once while a plain job stays '
        'held', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.beginLab();
        q.run(_buzz(async, writes, 'alert'),
            commands: 1, timeout: _s * 5, settle: Duration.zero);
        q.run(_buzz(async, writes, 'lab'),
            commands: 1, timeout: _s * 5, settle: Duration.zero, lab: true);
        async.elapse(_s * 3);
        expect(writes.map((w) => w.$1).toList(), ['lab']);
        q.endLab();
        async.elapse(_s * 3);
        expect(writes.map((w) => w.$1).toList(), ['lab', 'alert']);
      });
    });

    test('work inside asLab is queued as lab work (the touch counter\'s and '
        'the gestures\' buzzes while the lab is open)', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        final writes = <(String, int)>[];
        q.beginLab();
        q.run(_buzz(async, writes, 'alert'),
            commands: 1, timeout: _s * 5, settle: Duration.zero);
        q.asLab(() => q.run(_buzz(async, writes, 'ecg'),
            commands: 1, timeout: _s * 5, settle: Duration.zero));
        async.elapse(_s * 3);
        expect(writes.map((w) => w.$1).toList(), ['ecg']);
        q.endLab();
        async.elapse(_s * 3);
        expect(writes.map((w) => w.$1).toList(), ['ecg', 'alert']);
      });
    });

    test('runLab runs its body alone, has no timeout, and says whether it ran',
        () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        var ran = false;
        bool? out;
        q.runLab(() async {
          await Future<void>.delayed(const Duration(minutes: 20));
          ran = true;
        }).then((v) => out = v);
        async.elapse(const Duration(minutes: 19));
        expect(out, isNull, reason: 'the wearer may take their time');
        async.elapse(const Duration(minutes: 2));
        expect(ran, isTrue);
        expect(out, isTrue);
        expect(q.pending, 0);
      });
    });

    test('runLab is false when the band could not be had in time', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        q.run((t) => Completer<BuzzDelivery>().future,
            commands: 0, timeout: const Duration(minutes: 5));
        var ran = false;
        bool? out;
        q.runLab(() async => ran = true, startBy: _s * 10)
            .then((v) => out = v);
        async.elapse(_s * 20);
        expect(out, isFalse);
        expect(ran, isFalse);
      });
    });

    test('endLab is counted and safe to repeat', () {
      fakeAsync((async) {
        final q = BandHapticQueue(ledger: BandCommandLedger());
        q.endLab(); // never opened: nothing
        expect(q.labOpen, isFalse);
        q.beginLab();
        q.beginLab();
        q.endLab();
        expect(q.labOpen, isTrue, reason: 'a second lab screen is still open');
        q.endLab();
        expect(q.labOpen, isFalse);
        q.endLab();
        expect(q.labOpen, isFalse);
      });
    });
  });

  group('the dispatcher and a job held by the lab', () {
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

    test('an alert held for a minute is delivered after the lab, not '
        'reported unknown at the dispatcher\'s deadline', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginLab();
        AlertDeliveryOutcome? out;
        r.send(const Duration(minutes: 10), 'water').then((o) => out = o);
        async.elapse(const Duration(seconds: 60));
        expect(out, isNull, reason: 'still held; the 25 s deadline is paused');
        expect(r.writes, isEmpty);
        r.queue.endLab();
        async.elapse(const Duration(seconds: 10));
        expect(out!.targets, ['band']);
        expect(out!.suppressionReason, isNull);
        expect(r.writes, hasLength(1));
      });
    });

    test('the delivery deadline starts again after the lab: a delivery that '
        'then stalls is still unconfirmed', () {
      fakeAsync((async) {
        final queue = BandHapticQueue(ledger: BandCommandLedger());
        final d = AlertDispatcher(
          phone: () async => false,
          band: () async => true,
          isConnected: () => true,
          now: clock.now,
          ledger: MemoryAlertDeliveryLedger(),
          bandQueueWait: kBandQueueWait,
        );
        queue.beginLab();
        AlertDeliveryOutcome? out;
        d.dispatch(rule(const Duration(minutes: 10)),
            eventId: 'x',
            sourceTime: clock.now(),
            historical: false,
            bandDelivery: () => queue.run(
                (t) => Completer<BuzzDelivery>().future,
                commands: 1,
                timeout: const Duration(minutes: 5))).then((o) => out = o);
        async.elapse(const Duration(minutes: 5));
        queue.endLab();
        async.elapse(const Duration(seconds: 20));
        expect(out, isNull, reason: 'a fresh 25 s from the end of the lab');
        async.elapse(const Duration(seconds: 10));
        expect(out!.suppressionReason, 'deliveryUnconfirmed');
      });
    });

    test('an alert that goes stale while held is dropped by its own rule, '
        'nothing written, claim given back', () {
      fakeAsync((async) {
        final r = rig(async);
        r.queue.beginLab();
        AlertDeliveryOutcome? out;
        r.send(const Duration(seconds: 30), 'tap').then((o) => out = o);
        async.elapse(const Duration(minutes: 2));
        expect(out, isNull, reason: 'the hold itself drops nothing');
        r.queue.endLab();
        async.elapse(const Duration(seconds: 5));
        expect(out!.targets, isEmpty);
        expect(out!.suppressionReason, 'deliveryFailed');
        expect(r.writes, isEmpty);
      });
    });
  });

  group('the probes run as lab jobs', () {
    const one = PatternTest(
      waveform: BuzzWaveform('effect 47 alone', [47]),
      style: BuzzStyle.repeat,
      count: 2,
    );
    const three = PatternTest(
      waveform: BuzzWaveform('effect 47 alone', [47]),
      style: BuzzStyle.paced,
      count: 3,
    );

    test('a pattern play goes ahead of an alert that is waiting, after the '
        'one that is playing', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        final q = BandHapticQueue(ledger: ledger);
        final writes = <(String, int)>[];
        q.run(_buzz(async, writes, 'playing', takes: const Duration(seconds: 3)),
            commands: 1, timeout: _s * 10, settle: Duration.zero);
        q.run(_buzz(async, writes, 'waiting'),
            commands: 1, timeout: _s * 5, settle: Duration.zero);
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            writes.add(('probe', async.elapsed.inMilliseconds));
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [one],
          ledger: ledger,
          runLab: q.runLab,
        );
        probe.play(one);
        async.elapse(const Duration(seconds: 30));
        expect(writes.map((w) => w.$1).toList(),
            ['playing', 'probe', 'waiting']);
      });
    });

    test('the probe still has to reserve: refused with no room, nothing '
        'queued', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(29, clock.now());
        final q = BandHapticQueue(ledger: ledger);
        var sent = 0;
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            sent++;
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [three],
          ledger: ledger,
          runLab: q.runLab,
        );
        probe.play(three);
        async.flushMicrotasks();
        expect(probe.lastRefusal, PatternRefusal.resting);
        expect(sent, 0);
        expect(q.pending, 0);
      });
    });

    test('lab open, 27 used: the probe plays, the held alert follows after the '
        'lab and the limit of 30 is never passed', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger()..record(27, clock.now());
        final written = <DateTime>[for (var i = 0; i < 27; i++) clock.now()];
        final q = BandHapticQueue(ledger: ledger);
        q.beginLab();
        q.run(
          (t) async {
            for (var i = 0; i < 2; i++) {
              await t.write(() async {
                written.add(clock.now());
                return true;
              });
            }
            return BuzzDelivery.complete;
          },
          commands: 2,
          timeout: _s * 10,
          startBy: const Duration(minutes: 5),
          settle: Duration.zero,
        );
        final probe = PatternProbe(
          sendPattern: (e, l, onReply) async {
            written.add(clock.now());
            return true;
          },
          isConnected: () => true,
          now: clock.now,
          tests: [three],
          ledger: ledger,
          runLab: q.runLab,
        );
        PatternTestResult? r;
        probe.play(three).then((v) => r = v);
        async.elapse(const Duration(seconds: 30));
        expect(r, isNotNull);
        expect(written, hasLength(30));
        q.endLab();
        async.elapse(const Duration(minutes: 4));
        expect(written, hasLength(32), reason: 'the alert played once room came');
        expect(_busiestWindow(written), lessThanOrEqualTo(30));
      });
    });

    test('the buzz probe runs as a lab job too', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        final q = BandHapticQueue(ledger: ledger);
        final writes = <(String, int)>[];
        q.beginLab();
        q.run(_buzz(async, writes, 'alert'),
            commands: 1, timeout: _s * 5, settle: Duration.zero);
        final probe = HapticProbe(
          sendOne: (onReply) async {
            writes.add(('probe', async.elapsed.inMilliseconds));
            return true;
          },
          askFelt: (t, i) async => null,
          isConnected: () => true,
          now: clock.now,
          wait: (d) => Future<void>.delayed(d),
          trials: const [HapticTrial(300, commands: 2)],
          ledger: ledger,
          runLab: q.runLab,
        );
        probe.run();
        async.elapse(const Duration(seconds: 30));
        expect(writes.map((w) => w.$1).toList(), ['probe', 'probe'],
            reason: 'the alert waits for the lab');
        q.endLab();
        async.elapse(_s * 3);
        expect(writes.last.$1, 'alert');
      });
    });
  });

  group('the lab screen drives lab mode', () {
    HardwareProbeRunner runner(List<String> calls) => HardwareProbeRunner(
          lab: DeviceLabLog(),
          sendBuzz: (onReply) async => true,
          sendPattern: (e, l, onReply) async => true,
          isConnected: () => true,
          ecgSupported: () => true,
          ecgBusy: () => false,
          beginEcg: () async => false,
          endEcg: () async {},
          isEcgAlive: () => false,
          beginLab: () => calls.add('begin'),
          endLab: () => calls.add('end'),
        );

    testWidgets('open on entering, closed when the screen goes away',
        (t) async {
      final calls = <String>[];
      final r = runner(calls);
      await t.pumpWidget(MaterialApp(
        home: LabSession(runner: r, child: const Text('lab')),
      ));
      expect(calls, ['begin']);
      await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
      expect(calls, ['begin', 'end']);
    });

    testWidgets('a rebuild does not reopen it, and closing twice ends once',
        (t) async {
      final calls = <String>[];
      final r = runner(calls);
      Widget app() => MaterialApp(
            home: LabSession(runner: r, child: const Text('lab')),
          );
      await t.pumpWidget(app());
      await t.pumpWidget(app());
      expect(calls, ['begin']);
      r.closeLab();
      r.closeLab();
      expect(calls, ['begin', 'end']);
      await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
      expect(calls, ['begin', 'end']);
    });

    testWidgets('the queue sees it: alerts held while the screen is up, '
        'released when it goes', (t) async {
      final q = BandHapticQueue(ledger: BandCommandLedger());
      final r = HardwareProbeRunner(
        lab: DeviceLabLog(),
        sendBuzz: (onReply) async => true,
        sendPattern: (e, l, onReply) async => true,
        isConnected: () => true,
        ecgSupported: () => true,
        ecgBusy: () => false,
        beginEcg: () async => false,
        endEcg: () async {},
        isEcgAlive: () => false,
        beginLab: q.beginLab,
        endLab: q.endLab,
      );
      await t.pumpWidget(MaterialApp(
        home: LabSession(runner: r, child: const Text('lab')),
      ));
      expect(q.labOpen, isTrue);
      await t.pumpWidget(const MaterialApp(home: Text('elsewhere')));
      expect(q.labOpen, isFalse);
    });
  });
}
