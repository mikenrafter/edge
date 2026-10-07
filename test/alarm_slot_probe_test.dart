// The Device lab's alarm-slot probe: can the band hold MORE THAN ONE alarm?
//
// The probe arms alarm A (2 min out) and alarm B (3 min out) on top of the
// wearer's real alarm, reads each slot back, watches the fired events, and
// ALWAYS puts the real alarm back and clears its own slots, on success, on
// cancel (which is also what leaving the screen does) and on failure.
//
// Pinned here: that restore on every exit, the refusals (developer mode off,
// band family unknown, a real alarm within 10 minutes, a write in progress,
// the haptic budget, an alarm the app does not know about), the haptic
// budget accounting, that the probe's own alarm events cannot reach the real
// alarm's state, and the verdict from fake readbacks and events.
//
// Time is fake (fake_async): the probe's 2/3 minute waits are elapsed, not
// slept.

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' show AlarmStatus;
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/gestures/alarm_slot_probe.dart';
import 'package:openstrap_edge/gestures/lab_log.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';

import 'support/alarm_slot_rig.dart';

final DateTime _t0 = kAlarmSlotT0;
int _sec(DateTime t) => slotSec(t);
StrapEvent _ev(int id, int ts, [DateTime? at]) => slotEvent(id, ts, at);
typedef _Rig = AlarmSlotRig;

/// Starts the run and lets [elapse] of fake time pass; returns whether the run
/// finished.
bool _runFor(FakeAsync async, _Rig rig, Duration elapse) {
  var done = false;
  unawaited(rig.runner.run().whenComplete(() => done = true));
  async.elapse(elapse);
  return done;
}

const _six = Duration(minutes: 6);

void main() {
  group('a full run', () {
    test('gen5, two slots held: both fire, the band ends on the real alarm',
        () {
      fakeAsync((async) {
        final rig = _Rig();
        expect(_runFor(async, rig, _six), isTrue);

        // A at +2 min, B at +3 min, in the strap frame, written once each.
        expect(rig.calls.where((c) => c.startsWith('arm')), ['arm0', 'arm1']);
        final v = rig.runner.verdict!;
        expect(v.outcome, AlarmSlotOutcome.multi);
        expect(v.headline, 'The band holds 2 alarms at once');
        expect(v.evidence.join('\n'), contains('57'));

        // The clear precedes the restore; A shares the real slot, so only B
        // is cleared.
        expect(rig.calls, contains('clear1'));
        expect(rig.calls, isNot(contains('clear0')));
        final held = rig.held!;
        expect(rig.calls, contains('restore:$held'));
        expect(rig.calls.indexOf('clear1'),
            lessThan(rig.calls.indexOf('restore:$held')));
        expect(rig.stored, {0: held}, reason: 'only the real alarm is armed');
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('the probe alarms are armed at +2 and +3 minutes', () {
      fakeAsync((async) {
        final writes = <(int, int)>[];
        final rig = _Rig();
        rig.onArm = (slot, when) async {
          writes.add((slot, when.difference(clock.now()).inSeconds));
          return AlarmSlotWrite(
            written: true,
            answered: true,
            rejected: false,
            resultStatus: 1,
            alarmStatus: 1,
            wallSec: _sec(when),
            strapSec: _sec(when),
          );
        };
        _runFor(async, rig, _six);
        expect(writes, [(0, 120), (1, 180)]);
      }, initialTime: _t0);
    });

    test('capacity one: B replaces A, and the verdict says so', () {
      fakeAsync((async) {
        final rig = _Rig(capacity: 1);
        expect(_runFor(async, rig, _six), isTrue);
        final v = rig.runner.verdict!;
        expect(v.outcome, AlarmSlotOutcome.single);
        expect(v.headline, 'Only one alarm is kept (B replaced A)');
        expect(rig.stored, {0: rig.held!});
      }, initialTime: _t0);
    });

    test('the lab log and dev log get every step, tagged [alarm]', () {
      fakeAsync((async) {
        final rig = _Rig();
        _runFor(async, rig, _six);
        expect(rig.logs, isNotEmpty);
        expect(rig.logs.every((l) => l.startsWith('[alarm] ')), isTrue,
            reason: 'always-on dev log lines carry the [alarm] tag');
        final text = rig.logs.join('\n');
        expect(text, contains('remembered'));
        expect(text, contains('armed A'));
        expect(text, contains('armed B'));
        expect(text, contains('readback'));
        expect(text, contains('restored'));
      }, initialTime: _t0);
    });

    test('gen4: one index-less disable, then the real alarm is re-armed', () {
      fakeAsync((async) {
        final rig = _Rig(family: 'gen4');
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls.where((c) => c.startsWith('clear')), ['clear1']);
        expect(rig.calls, contains('restore:${rig.held}'));
        // One readback can only name one alarm; the verdict leans on events.
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.multi);
      }, initialTime: _t0);
    });

    test('no real alarm: both probe slots are cleared, nothing is restored',
        () {
      fakeAsync((async) {
        final rig = _Rig(heldIn: null);
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls, containsAll(['clear0', 'clear1']));
        expect(rig.calls.any((c) => c.startsWith('restore')), isFalse);
        expect(rig.stored, isEmpty);
      }, initialTime: _t0);
    });

    test('the haptic budget: counted per band write, nothing left reserved',
        () {
      fakeAsync((async) {
        final rig = _Rig();
        unawaited(rig.runner.run());
        // Stopped at 30 s so every write is still inside the 2 minute window.
        async.elapse(const Duration(seconds: 30));
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 5));
        expect(rig.runner.running, isFalse);
        expect(rig.bandWrites, 8);
        expect(rig.ledger.commandsLeft(clock.now()),
            BandCommandLedger.maxCommands - rig.bandWrites,
            reason: 'run writes taken from the reservation, clean-up writes '
                'recorded, the rest released');
      }, initialTime: _t0);
    });
  });

  group('restore, on every exit', () {
    test('cancel while watching restores and clears', () {
      fakeAsync((async) {
        final rig = _Rig();
        var done = false;
        unawaited(rig.runner.run().whenComplete(() => done = true));
        async.elapse(const Duration(seconds: 90)); // A and B armed, none fired yet
        expect(done, isFalse);
        expect(rig.stored.keys, containsAll([0, 1]));
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 5));
        expect(done, isTrue);
        expect(rig.calls, contains('clear1'));
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.stored, {0: rig.held!}, reason: 'no probe alarm left');
        expect(rig.runner.running, isFalse);
        expect(rig.runner.verdict, isNotNull);
      }, initialTime: _t0);
    });

    test('cancel, leave and a second cancel are the same, and safe to repeat',
        () {
      fakeAsync((async) {
        final rig = _Rig();
        unawaited(rig.runner.run());
        async.elapse(const Duration(seconds: 150));
        rig.runner.cancel();
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 10));
        rig.runner.cancel(); // after the run: nothing to do
        expect(rig.calls.where((c) => c.startsWith('restore')), hasLength(1));
      }, initialTime: _t0);
    });

    test('a failed arm of B still clears and restores', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.onArm = (slot, when) async {
          rig.calls.add('arm$slot');
          if (slot == 1) throw StateError('link dropped');
          rig.stored[slot] = _sec(when);
          return AlarmSlotWrite(
            written: true,
            answered: true,
            rejected: false,
            resultStatus: 1,
            alarmStatus: 1,
            wallSec: _sec(when),
            strapSec: _sec(when),
          );
        };
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls, contains('clear1'));
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.stored, {0: rig.held!});
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.inconclusive);
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('an arm of A that throws may still have landed: still restores', () {
      fakeAsync((async) {
        final rig = _Rig();
        rig.onArm = (slot, when) async {
          rig.calls.add('arm$slot');
          rig.stored[slot] = _sec(when); // it landed, the reply never did
          throw TimeoutException('no reply');
        };
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls, isNot(contains('arm1')));
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.stored, {0: rig.held!});
      }, initialTime: _t0);
    });

    test('readbacks that throw are just unanswered: the run still restores',
        () {
      fakeAsync((async) {
        final rig = _Rig()..readThrows = true;
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.stored, {0: rig.held!});
        expect(rig.runner.verdict, isNotNull);
      }, initialTime: _t0);
    });

    test('a restore that the band refuses is reported, never hidden', () {
      fakeAsync((async) {
        final rig = _Rig(restoreOk: false);
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.runner.restoreOk, isFalse);
        expect(rig.calls, contains('clear1'), reason: 'cleared regardless');
        expect(rig.runner.verdict!.evidence.join('\n'),
            contains('NOT restored'));
        expect(rig.logs.join('\n'), contains('NOT restored'));
      }, initialTime: _t0);
    });

    test('a restore that throws is reported, and the run still ends', () {
      fakeAsync((async) {
        final rig = _Rig()..restoreThrows = StateError('link dropped');
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.runner.restoreOk, isFalse);
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('a clear that throws does not skip the restore', () {
      fakeAsync((async) {
        final rig = _Rig();
        final runner = AlarmSlotProbeRunner(
          lab: DeviceLabLog(),
          family: () => 'gen5',
          developerMode: () => true,
          isConnected: () => true,
          heldEpoch: () => rig.held,
          armBusy: () => false,
          arm: rig.arm,
          read: rig.read,
          clear: (slot) async => throw StateError('link dropped'),
          restore: rig.restore,
          log: rig.logs.add,
          ledger: rig.ledger,
        );
        var done = false;
        unawaited(runner.run().whenComplete(() => done = true));
        async.elapse(_six);
        expect(done, isTrue);
        expect(rig.calls, contains('restore:${rig.held}'));
      }, initialTime: _t0);
    });
  });

  group('refusals: nothing is written', () {
    void expectRefused(_Rig Function() make, Pattern reason) {
      fakeAsync((async) {
        final rig = make();
        expect(rig.runner.blockedReason, matches(reason));
        _runFor(async, rig, _six);
        expect(rig.calls, isEmpty);
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    }

    test('developer mode off', () {
      expectRefused(() => _Rig()..dev = false, RegExp('[Dd]eveloper mode'));
    });

    test('band family unknown', () {
      expectRefused(() => _Rig(family: null), RegExp('family'));
    });

    test('band not connected', () {
      expectRefused(() => _Rig()..connected = false, RegExp('[Cc]onnect'));
    });

    test('a real arm pass is in flight', () {
      expectRefused(() => _Rig()..armBusy = true, RegExp('alarm write'));
    });

    test('the haptic budget has no room', () {
      expectRefused(
        () => _Rig(ledger: BandCommandLedger()..record(28, clock.now())),
        RegExp('resting'),
      );
    });

    test('the real alarm is within 10 minutes (9:59 refused, 10:01 not)', () {
      fakeAsync((async) {
        final near = _Rig(heldIn: const Duration(minutes: 9, seconds: 59));
        expect(near.runner.blockedReason, contains('10 minutes'));
        final far = _Rig(heldIn: const Duration(minutes: 10, seconds: 1));
        expect(far.runner.blockedReason, isNull);
        _runFor(async, near, _six);
        expect(near.calls, isEmpty);
      }, initialTime: _t0);
    });

    test('a real alarm that just went off is also too close', () {
      fakeAsync((async) {
        final rig = _Rig(heldIn: const Duration(minutes: -4));
        expect(rig.runner.blockedReason, contains('10 minutes'));
      }, initialTime: _t0);
    });

    test('an alarm on the band the app does not know about is not overwritten',
        () {
      fakeAsync((async) {
        final rig = _Rig(heldIn: null);
        rig.stored[0] = _sec(_t0.add(const Duration(hours: 5)));
        expect(_runFor(async, rig, _six), isTrue);
        expect(rig.calls, ['read0'], reason: 'looked, then stopped');
        expect(rig.stored[0], _sec(_t0.add(const Duration(hours: 5))));
        expect(rig.runner.verdict, isNull);
        expect(rig.runner.note, contains('does not know'));
      }, initialTime: _t0);
    });

    test('a second run while one runs does nothing', () {
      fakeAsync((async) {
        final rig = _Rig();
        unawaited(rig.runner.run());
        async.elapse(const Duration(seconds: 1));
        expect(rig.runner.blockedReason, contains('running'));
        unawaited(rig.runner.run());
        async.elapse(_six);
        expect(rig.calls.where((c) => c == 'arm0'), hasLength(1));
      }, initialTime: _t0);
    });

    test('it runs inside the exclusive slot it is given, or not at all', () {
      fakeAsync((async) {
        final rig = _Rig();
        var entered = false;
        final runner = AlarmSlotProbeRunner(
          lab: DeviceLabLog(),
          family: () => 'gen5',
          developerMode: () => true,
          isConnected: () => true,
          heldEpoch: () => rig.held,
          armBusy: () => false,
          arm: rig.arm,
          read: rig.read,
          clear: rig.clear,
          restore: rig.restore,
          log: rig.logs.add,
          ledger: rig.ledger,
          runExclusive: (body) async {
            entered = true;
            return false; // the band could not be had
          },
        );
        unawaited(runner.run());
        async.elapse(_six);
        expect(entered, isTrue);
        expect(rig.calls, isEmpty);
        expect(runner.running, isFalse);
        expect(runner.note, contains('busy'));
      }, initialTime: _t0);
    });
  });

  group('events of the probe stay out of the real alarm', () {
    test('while running, alarm events are swallowed; others are not', () {
      fakeAsync((async) {
        final rig = _Rig();
        unawaited(rig.runner.run());
        async.elapse(const Duration(seconds: 5));
        for (final id in [56, 57, 58, 59, 60]) {
          expect(rig.runner.swallowsEvent(_ev(id, _sec(clock.now()))), isTrue,
              reason: 'event $id');
        }
        expect(rig.runner.swallowsEvent(_ev(100, _sec(clock.now()))), isFalse);
        expect(rig.runner.swallowsEvent(_ev(3, _sec(clock.now()))), isFalse);
      }, initialTime: _t0);
    });

    test('after the restore, an old probe event is swallowed, a new one not',
        () {
      fakeAsync((async) {
        final rig = _Rig();
        _runFor(async, rig, _six);
        // The restore starts when the watch ends, 60 s after B (T0 + 240 s).
        final t0 = _sec(_t0);
        expect(rig.runner.swallowsEvent(_ev(59, t0 + 200)), isTrue,
            reason: 'the probe alarm auto-disabling, replayed late');
        expect(rig.runner.swallowsEvent(_ev(56, t0 + 241)), isFalse,
            reason: 'the real alarm latching after the restore');
      }, initialTime: _t0);
    });

    test('with no probe ever run, nothing is swallowed', () {
      final rig = _Rig();
      expect(rig.runner.swallowsEvent(_ev(57, 1)), isFalse);
    });
  });

  group('felt ticks', () {
    test('felt A and felt B are evidence when no event arrived (gen4)', () {
      fakeAsync((async) {
        final rig = _Rig(family: 'gen4')..fires = false;
        _runFor(async, rig, _six);
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.inconclusive);
        rig.runner.markFelt(0, true);
        rig.runner.markFelt(1, true);
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.multi);
        // B felt, A explicitly not felt: B replaced A.
        rig.runner.markFelt(0, false);
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.single);
        // B felt, A never answered: silence is not evidence of absence.
        rig.runner.markFelt(0, null);
        expect(rig.runner.verdict!.outcome, AlarmSlotOutcome.inconclusive);
      }, initialTime: _t0);
    });
  });

  group('classifyAlarmSlots', () {
    const aSec = 1790000120, bSec = 1790000180;

    AlarmSlotWrite ok(int sec, {bool answered = true}) => AlarmSlotWrite(
          written: true,
          answered: answered,
          rejected: false,
          resultStatus: answered ? 1 : null,
          alarmStatus: answered ? 1 : null,
          alarmStatusName: answered ? 'valid_input_pattern' : null,
          wallSec: sec,
          strapSec: sec,
        );
    AlarmSlotRead has(int sec, {bool active = true}) =>
        AlarmSlotRead(answered: true, epoch: sec, active: active);
    AlarmSlotEvent fired(int sec, {int id = 57}) => AlarmSlotEvent(
        id: id, tsEpoch: sec, receivedAt: DateTime.utc(2026, 10, 7, 3, 2));

    AlarmSlotEvidence base({String family = 'gen5'}) =>
        AlarmSlotEvidence(family: family)
          ..armA = ok(aSec)
          ..armB = ok(bSec)
          ..watched = true;

    test('gen5 readbacks hold both: 2 alarms', () {
      final ev = base()
        ..readA = has(aSec)
        ..readB = has(bSec);
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.multi);
      expect(v.headline, 'The band holds 2 alarms at once');
    });

    test('gen5 id 1 now reads B: B replaced A', () {
      final ev = base()
        ..readA = has(bSec)
        ..readB = has(bSec);
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.single);
      expect(v.headline, 'Only one alarm is kept (B replaced A)');
    });

    test('gen5 id 1 inactive after B was armed: B replaced A', () {
      final ev = base()
        ..readA = has(aSec, active: false)
        ..readB = has(bSec);
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.single);
    });

    test('readbacks say both held but only B fired: conflict, inconclusive',
        () {
      final ev = base()
        ..readA = has(aSec)
        ..readB = has(bSec)
        ..events.add(fired(bSec));
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('readbacks say B replaced A but A fired: conflict, inconclusive', () {
      final ev = base()
        ..readA = has(bSec)
        ..readB = has(bSec)
        ..events.add(fired(aSec));
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('both fired near their own epochs: 2 alarms, whatever the readback',
        () {
      final ev = base()
        ..readA = const AlarmSlotRead.silent()
        ..readB = const AlarmSlotRead.silent()
        ..events.addAll([fired(aSec + 1), fired(bSec, id: 58)]);
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.multi);
    });

    test('only B fired, no readback, window over: B replaced A', () {
      final ev = base(family: 'gen4')..events.add(fired(bSec));
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.single);
      expect(v.headline, 'Only one alarm is kept (B replaced A)');
    });

    test('only B fired but the window is not over yet: inconclusive', () {
      final ev = base(family: 'gen4')
        ..watched = false
        ..events.add(fired(bSec));
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('only A fired: inconclusive, never "held" or "replaced"', () {
      final ev = base(family: 'gen4')..events.add(fired(aSec));
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('nothing fired, nothing read: inconclusive', () {
      final ev = base(family: 'gen4');
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.inconclusive);
      expect(v.headline.toLowerCase(), contains('inconclusive'));
    });

    test('an event far from either epoch is not attributed to a slot', () {
      final ev = base(family: 'gen4')..events.addAll([fired(aSec - 45)]);
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('events 56, 59, 60 and 100 are evidence lines, not fires', () {
      final ev = base(family: 'gen4')
        ..events.addAll([
          fired(aSec, id: 56),
          fired(aSec, id: 60),
          fired(bSec, id: 59),
          fired(bSec, id: 100),
        ]);
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.inconclusive);
      final text = v.evidence.join('\n');
      for (final id in ['56', '59', '60', '100']) {
        expect(text, contains(id));
      }
    });

    test('the band refusing B means one alarm', () {
      final ev = base()
        ..armB = AlarmSlotWrite(
          written: true,
          answered: true,
          rejected: true,
          resultStatus: 1,
          alarmStatus: AlarmStatus.invalidAlarmId,
          alarmStatusName: 'invalid_alarm_id',
          wallSec: bSec,
          strapSec: bSec,
        );
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.single);
      expect(v.headline, 'Only one alarm is kept (the band refused B)');
      expect(v.evidence.join('\n'), contains('invalid_alarm_id'));
    });

    test('the band refusing A is inconclusive', () {
      final ev = base()
        ..armA = AlarmSlotWrite(
          written: true,
          answered: true,
          rejected: true,
          resultStatus: 0,
          alarmStatus: AlarmStatus.invalidAlarmTime,
          alarmStatusName: 'invalid_alarm_time',
          wallSec: aSec,
          strapSec: aSec,
        );
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('an arm that never reached the band is inconclusive', () {
      final ev = base()
        ..armB = AlarmSlotWrite(
            written: false,
            answered: false,
            rejected: false,
            wallSec: bSec,
            strapSec: bSec);
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.inconclusive);
    });

    test('an unanswered arm still counts as taken, and says it was unconfirmed',
        () {
      final ev = base()
        ..armA = ok(aSec, answered: false)
        ..armB = ok(bSec, answered: false)
        ..readA = has(aSec)
        ..readB = has(bSec);
      final v = classifyAlarmSlots(ev);
      expect(v.outcome, AlarmSlotOutcome.multi);
      expect(v.evidence.join('\n'), contains('no reply'));
    });

    test('felt A and felt B count as fired', () {
      final ev = base(family: 'gen4')
        ..feltA = true
        ..feltB = true;
      expect(classifyAlarmSlots(ev).outcome, AlarmSlotOutcome.multi);
    });

    test('the evidence carries raw epochs, readbacks and felt answers', () {
      final ev = base()
        ..readA = has(aSec)
        ..readB = has(bSec)
        ..feltA = true
        ..events.add(fired(aSec));
      final text = classifyAlarmSlots(ev).evidence.join('\n');
      expect(text, contains('$aSec'));
      expect(text, contains('$bSec'));
      expect(text, contains('valid_input_pattern'));
      expect(text, contains('Felt A: yes'));
    });
  });
}
