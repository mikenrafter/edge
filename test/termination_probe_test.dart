// The Device lab's termination probe: how does the WHOOP 5 / MG band report
// that haptics STOPPED (event 100 HAPTICS_TERMINATED, event 14 double tap, the
// alarm EXECUTED events)?
//
// Pinned here, all pure Dart over a fake band on fake time:
//   slot       the probe's alarm slot is never the wearer's (gen5 id 1)
//   recorder   the timeline: label, cause, raw stamp (sub-second too),
//              converted time, receipt, delta; an unbelievable stamp and an
//              undecoded cause stay absent, never guessed
//   verdicts   one plain-English line per scenario, only what the timeline
//              shows; the stamp summary
//   report     the text the page saves as a log file
//   run        each scenario's flow on the fake band, and that the alarm
//              scenarios clear their slot and put the real alarm back on EVERY
//              exit (finish, cancel, arm throws, pattern throws, restore
//              fails), while the app-only scenarios never touch an alarm
//   guards     refusals; the probe's alarm events never reach the real alarm's
//              handler; a tap during a run is the probe's

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';
import 'package:openstrap_edge/gestures/strap_event.dart';
import 'package:openstrap_edge/gestures/termination_probe.dart';
import 'package:openstrap_edge/haptics/band_queue.dart';

import 'support/alarm_slot_rig.dart' show kAlarmSlotT0, slotEvent, slotSec;
import 'support/termination_probe_rig.dart';

typedef _S = TerminationScenario;

final DateTime _t0 = kAlarmSlotT0;
final DateTime _utc0 = DateTime.utc(2026, 10, 7, 3, 0, 0);
int get _utc0Sec => _utc0.millisecondsSinceEpoch ~/ 1000;

StrapEvent _strapEvent(int id,
        {int? ts,
        int subsec = 0,
        int msAfterStart = 1700,
        int? code,
        bool decoded = true}) =>
    StrapEvent(
      eventId: id,
      tsEpoch: ts ?? _utc0Sec,
      tsSubsec: subsec,
      receivedAt: _utc0.add(Duration(milliseconds: msAfterStart)),
      hex: '',
      deviceId: 'd',
      decoded: id == 100 && code != null && decoded
          ? {
              'haptics_termination_code': code,
              'haptics_termination':
                  const {0: 'expired', 1: 'error', 2: 'user_double_tap'}[code] ??
                      'code_$code',
            }
          : const {},
    );

TimelineEntry _entry(
  String label, {
  int? id,
  String? cause,
  int? rawEpoch,
  int? rawSubsec,
  int sinceMs = 0,
  int? deltaMs,
}) =>
    TimelineEntry(
      label: label,
      eventId: id,
      cause: cause,
      rawEpoch: rawEpoch,
      rawSubsec: rawSubsec,
      convertedAt: rawEpoch == null
          ? null
          : _utc0.add(Duration(seconds: rawEpoch - _utc0Sec)),
      receivedAt: _utc0.add(Duration(milliseconds: sinceMs)),
      sinceStartMs: sinceMs,
      deltaMs: deltaMs,
    );

TimelineEntry _term(String cause, {int sec = 0, int sub = 0, int ms = 1000}) =>
    _entry('HAPTICS_TERMINATED',
        id: 100,
        cause: cause,
        rawEpoch: _utc0Sec + sec,
        rawSubsec: sub,
        sinceMs: ms,
        deltaMs: 0);
TimelineEntry _tap({int sec = 0, int ms = 900}) => _entry('DOUBLE_TAP',
    id: 14, rawEpoch: _utc0Sec + sec, rawSubsec: 0, sinceMs: ms, deltaMs: 0);
TimelineEntry _exec({int sec = 0, int id = 57, int ms = 500}) => _entry(
    id == 57 ? 'ALARM_EXECUTED (strap)' : 'ALARM_EXECUTED (app)',
    id: id,
    rawEpoch: _utc0Sec + sec,
    rawSubsec: 0,
    sinceMs: ms,
    deltaMs: 0);

/// Runs [s] and lets [elapse] of fake time pass; whether the run finished.
bool _runFor(FakeAsync async, TerminationRig rig, _S s,
    [Duration elapse = const Duration(minutes: 2)]) {
  var done = false;
  rig.clockZero = clock.now();
  unawaited(rig.runner.run(s).whenComplete(() => done = true));
  async.elapse(elapse);
  return done;
}

const _alarmScenarios = [
  _S.alarmExpires,
  _S.alarmDoubleTap,
  _S.overlap,
];

void main() {
  group('the probe slot', () {
    test('is never the wearer\'s slot (index 0 = gen5 id 1)', () {
      final slot = pickTerminationProbeSlot();
      expect(slot, isNot(0));
      expect(slot, inInclusiveRange(0, 1), reason: 'the engine has slots 0, 1');
      expect(AlarmPayloads.gen5Slot + slot, isNot(AlarmPayloads.gen5Slot));
      expect(AlarmPayloads.gen5Slot + slot, isNot(AlarmPayloads.gen5AllSlots));
    });

    for (final s in _alarmScenarios) {
      test('${s.name}: only the probe slot is armed, read for arming or '
          'cleared; the wearer\'s slot is only read', () {
        fakeAsync((async) {
          final rig = TerminationRig();
          if (s == _S.alarmDoubleTap) rig.tapAfter = const Duration(seconds: 2);
          expect(_runFor(async, rig, s), isTrue);
          final slot = pickTerminationProbeSlot();
          expect(rig.calls.where((c) => c.startsWith('arm')), ['arm$slot']);
          expect(rig.calls.where((c) => c.startsWith('clear')),
              ['clear$slot']);
          expect(rig.calls, isNot(contains('arm0')));
          expect(rig.calls, isNot(contains('clear0')));
        }, initialTime: _t0);
      });
    }
  });

  group('scenario facts', () {
    test('six scenarios, titled, the right ones tap and arm', () {
      expect(_S.values, hasLength(6));
      expect(_S.values.map((s) => s.title).toSet(), hasLength(6));
      expect(_S.appFinishes.title, startsWith('1.'));
      expect(_S.stampPrecision.title, startsWith('6.'));
      expect(_S.values.where((s) => s.usesAlarm),
          [_S.alarmExpires, _S.alarmDoubleTap, _S.overlap]);
      expect(_S.values.where((s) => s.wearerTaps),
          [_S.appDoubleTap, _S.alarmDoubleTap]);
      for (final s in _S.values) {
        expect(s.instruction, isNotEmpty);
      }
    });
  });

  group('timeline recorder', () {
    test('HAPTICS_TERMINATED: cause, raw stamp, converted time, receipt, delta',
        () {
      final rec = TimelineRecorder(start: _utc0);
      final e = rec.addEvent(_strapEvent(100, subsec: 16384, code: 0))!;
      expect(e.label, 'HAPTICS_TERMINATED');
      expect(e.eventId, 100);
      expect(e.cause, 'expired');
      expect(e.causeCode, 0);
      expect(e.rawEpoch, _utc0Sec);
      expect(e.rawSubsec, 16384);
      expect(e.convertedAt!.toUtc(),
          _utc0.add(const Duration(milliseconds: 500)));
      expect(e.sinceStartMs, 1700);
      expect(e.deltaMs, 1200, reason: 'receipt 1700 ms minus stamp 500 ms');
      expect(rec.entries, [e]);
    });

    test('drift moves the converted time into the phone frame', () {
      final rec = TimelineRecorder(start: _utc0, driftSec: 7);
      final e = rec.addEvent(_strapEvent(100, subsec: 16384, code: 2))!;
      expect(e.cause, 'user_double_tap');
      expect(e.causeCode, 2);
      expect(e.convertedAt!.toUtc(),
          _utc0.add(const Duration(milliseconds: 7500)));
      expect(e.deltaMs, 1700 - 7500);
    });

    test('an unbelievable strap stamp keeps the raw numbers, no converted '
        'time, no delta', () {
      final rec = TimelineRecorder(start: _utc0);
      final e = rec.addEvent(_strapEvent(100, ts: 0, code: 0))!;
      expect(e.rawEpoch, 0);
      expect(e.rawSubsec, 0);
      expect(e.convertedAt, isNull);
      expect(e.deltaMs, isNull);
      expect(e.line, contains('no stamp'));
      expect(e.line, contains('delta —'));
    });

    test('a termination with no decoded cause stays undecoded, never guessed',
        () {
      final rec = TimelineRecorder(start: _utc0);
      final e = rec.addEvent(_strapEvent(100, decoded: false, code: 0))!;
      expect(e.label, 'HAPTICS_TERMINATED');
      expect(e.cause, isNull);
      expect(e.causeCode, isNull);
      expect(e.line, contains('cause not decoded'));
    });

    test('names for the double tap and the alarm lifecycle', () {
      final rec = TimelineRecorder(start: _utc0);
      final names = {
        14: 'DOUBLE_TAP',
        56: 'ALARM_SET',
        57: 'ALARM_EXECUTED (strap)',
        58: 'ALARM_EXECUTED (app)',
        59: 'ALARM_DISABLED',
        60: 'HAPTICS_FIRED',
      };
      names.forEach((id, label) {
        final e = rec.addEvent(_strapEvent(id))!;
        expect(e.label, label, reason: 'event $id');
        expect(e.eventId, id);
        expect(e.cause, isNull);
      });
    });

    test('only 14, 56..60 and 100 are recorded', () {
      for (final id in [14, 56, 57, 58, 59, 60, 100]) {
        expect(TimelineRecorder.watches(id), isTrue, reason: '$id');
      }
      for (final id in [1, 9, 13, 15, 55, 61, 63, 96, 99, 101]) {
        expect(TimelineRecorder.watches(id), isFalse, reason: '$id');
      }
      final rec = TimelineRecorder(start: _utc0);
      expect(rec.addEvent(_strapEvent(63)), isNull);
      expect(rec.entries, isEmpty);
    });

    test('a mark is a phone-side line with no strap fields', () {
      final rec = TimelineRecorder(start: _utc0);
      final m = rec.mark('pattern written', _utc0.add(const Duration(seconds: 2)));
      expect(m.label, 'pattern written');
      expect(m.eventId, isNull);
      expect(m.rawEpoch, isNull);
      expect(m.convertedAt, isNull);
      expect(m.deltaMs, isNull);
      expect(m.sinceStartMs, 2000);
    });

    test('entries keep arrival order and cannot be edited from outside', () {
      final rec = TimelineRecorder(start: _utc0);
      rec.mark('a', _utc0);
      rec.addEvent(_strapEvent(100, code: 0));
      rec.mark('c', _utc0);
      expect(rec.entries.map((e) => e.label), ['a', 'HAPTICS_TERMINATED', 'c']);
      expect(() => rec.entries.add(rec.entries.first), throwsUnsupportedError);
    });

    test('a line shows label, cause, raw stamp, converted time, receipt, delta',
        () {
      final rec = TimelineRecorder(start: _utc0);
      final l = rec.addEvent(_strapEvent(100, subsec: 16384, code: 2))!.line;
      expect(l, contains('HAPTICS_TERMINATED'));
      expect(l, contains('cause user_double_tap'));
      expect(l, contains('raw $_utc0Sec+16384/32768'));
      expect(l, contains('recv +1700 ms'));
      expect(l, contains('delta 1200 ms'));
    });
  });

  group('verdicts', () {
    test('1. a termination arrives: the cause and the delta are named', () {
      final v = terminationVerdict(
          _S.appFinishes, [_entry('pattern written'), _term('expired')]);
      expect(v, contains('HAPTICS_TERMINATED arrived'));
      expect(v, contains('cause expired'));
    });

    test('1. none arrives: it says none arrived', () {
      final v = terminationVerdict(_S.appFinishes, [_entry('pattern written')]);
      expect(v, contains('No HAPTICS_TERMINATED arrived'));
      expect(v, isNot(contains('cause')));
    });

    test('1. a cause that is not decoded is said to be undecoded', () {
      final v = terminationVerdict(_S.appFinishes, [
        _entry('HAPTICS_TERMINATED', id: 100, rawEpoch: _utc0Sec, rawSubsec: 0),
      ]);
      expect(v, contains('arrived'));
      expect(v, contains('cause not decoded'));
    });

    test('2. a double tap with its termination and a gesture event', () {
      final v = terminationVerdict(_S.appDoubleTap,
          [_entry('pattern written'), _tap(), _term('user_double_tap')]);
      expect(v, contains('user_double_tap'));
      expect(v, contains('A double-tap event (14) also arrived'));
    });

    test('2. a double tap with a termination but no gesture event', () {
      final v = terminationVerdict(_S.appDoubleTap,
          [_entry('pattern written'), _term('user_double_tap')]);
      expect(v, contains('user_double_tap'));
      expect(v, contains('No separate double-tap event (14) arrived'));
    });

    test('2. the pattern ended another way: the tap did not stop it', () {
      final v = terminationVerdict(
          _S.appDoubleTap, [_entry('pattern written'), _term('expired')]);
      expect(v, contains('cause expired'));
      expect(v, isNot(contains('user_double_tap')));
      expect(v, contains('did not'));
    });

    test('2. nothing at all: no tap was seen, run it again', () {
      final v = terminationVerdict(_S.appDoubleTap, [_entry('pattern written')]);
      expect(v, contains('No HAPTICS_TERMINATED arrived'));
      expect(v, contains('again'));
    });

    test('3. the alarm reports EXECUTED then ends with its cause', () {
      final v = terminationVerdict(
          _S.alarmExpires, [_entry('alarm armed'), _exec(), _term('expired')]);
      expect(v, contains('alarm reported EXECUTED'));
      expect(v, contains('HAPTICS_TERMINATED'));
      expect(v, contains('cause expired'));
    });

    test('3. an alarm that never reports EXECUTED says so', () {
      final v = terminationVerdict(_S.alarmExpires, [_entry('alarm armed')]);
      expect(v, contains('never reported EXECUTED'));
    });

    test('3. executed but no termination: says no termination arrived', () {
      final v = terminationVerdict(
          _S.alarmExpires, [_entry('alarm armed'), _exec()]);
      expect(v, contains('alarm reported EXECUTED'));
      expect(v, contains('No HAPTICS_TERMINATED arrived'));
    });

    test('4. the tap stops the alarm: user_double_tap', () {
      final v = terminationVerdict(_S.alarmDoubleTap, [
        _entry('alarm armed'),
        _exec(),
        _tap(sec: 2),
        _term('user_double_tap', sec: 2),
      ]);
      expect(v, contains('alarm reported EXECUTED'));
      expect(v, contains('user_double_tap'));
      expect(v, contains('A double-tap event (14) also arrived'));
    });

    test('5. overlap: the pattern ended before the alarm stamp', () {
      final v = terminationVerdict(_S.overlap, [
        _entry('pattern written'),
        _term('error', sec: 0),
        _exec(sec: 1),
        _term('expired', sec: 4),
      ]);
      expect(v, contains('2 HAPTICS_TERMINATED arrived'));
      expect(v, contains('error, then expired'));
      expect(v, contains('before the alarm'));
    });

    test('5. overlap: the pattern kept playing through the alarm start', () {
      final v = terminationVerdict(_S.overlap, [
        _entry('pattern written'),
        _exec(sec: 1),
        _term('expired', sec: 6),
      ]);
      expect(v, contains('1 HAPTICS_TERMINATED arrived'));
      expect(v, contains('kept playing through the alarm start'));
    });

    test('5. overlap: no alarm EXECUTED means no overlap was shown', () {
      final v = terminationVerdict(
          _S.overlap, [_entry('pattern written'), _term('expired', sec: 6)]);
      expect(v, contains('never reported EXECUTED'));
      expect(v, contains('overlap was not shown'));
    });

    test('6. stamp precision uses the stamp summary', () {
      final t = [_term('expired', sub: 100), _term('expired', sub: 0)];
      expect(terminationVerdict(_S.stampPrecision, t), stampVerdict(t));
    });

    test('stamp summary: all sub-second zero means whole seconds', () {
      final v = stampVerdict([_term('expired'), _term('expired', sec: 5)]);
      expect(v, contains('whole seconds'));
      expect(v, contains('every one of 2'));
    });

    test('stamp summary: some sub-second set, with the spread', () {
      final a = TimelineEntry(
          label: 'HAPTICS_TERMINATED',
          eventId: 100,
          cause: 'expired',
          rawEpoch: _utc0Sec,
          rawSubsec: 16384,
          convertedAt: _utc0,
          receivedAt: _utc0,
          sinceStartMs: 0,
          deltaMs: 300);
      final b = TimelineEntry(
          label: 'HAPTICS_TERMINATED',
          eventId: 100,
          cause: 'expired',
          rawEpoch: _utc0Sec,
          rawSubsec: 0,
          convertedAt: _utc0,
          receivedAt: _utc0,
          sinceStartMs: 0,
          deltaMs: 900);
      final v = stampVerdict([a, b]);
      expect(v, contains('sub-second'));
      expect(v, contains('1 of 2'));
      expect(v, contains('300'));
      expect(v, contains('900'));
    });

    test('stamp summary: no stamped events says so (marks and unbelievable '
        'stamps do not count)', () {
      expect(stampVerdict([_entry('pattern written')]),
          contains('No stamped events'));
      expect(stampVerdict(const []), contains('No stamped events'));
    });
  });

  group('report text', () {
    TerminationResult res(_S s, List<TimelineEntry> t, {bool done = true}) =>
        TerminationResult(
            scenario: s,
            startedAt: _utc0,
            timeline: t,
            verdict: terminationVerdict(s, t),
            completed: done);

    test('header, each scenario in page order with verdict and every line, '
        'not-run ones say so', () {
      final r1 = res(_S.appFinishes, [_entry('pattern written'), _term('expired')]);
      final r2 = res(_S.appDoubleTap, [_tap(), _term('user_double_tap')]);
      final text = terminationReport([r2, r1], family: 'gen5', at: _utc0);
      expect(text, contains('gen5'));
      expect(text, contains('2026-10-07'));
      for (final s in _S.values) {
        expect(text, contains(s.title));
      }
      expect(text.indexOf(_S.appFinishes.title),
          lessThan(text.indexOf(_S.appDoubleTap.title)),
          reason: 'page order, not run order');
      expect(text, contains(r1.verdict));
      expect(text, contains(r2.verdict));
      for (final e in [...r1.timeline, ...r2.timeline]) {
        expect(text, contains(e.line));
      }
      expect(text, contains('not run'));
      expect(text, contains('cause user_double_tap'));
    });

    test('a stopped scenario is marked as stopped', () {
      final text = terminationReport(
          [res(_S.overlap, [_entry('pattern written')], done: false)],
          family: 'gen5',
          at: _utc0);
      expect(text, contains('stopped'));
    });

    test('ends with the stamp summary over every stamped event', () {
      final t1 = [_term('expired', sub: 5)];
      final t2 = [_term('user_double_tap', sub: 0)];
      final text = terminationReport(
          [res(_S.appFinishes, t1), res(_S.appDoubleTap, t2)],
          family: 'gen5',
          at: _utc0);
      expect(text.trimRight(), endsWith(stampVerdict([...t1, ...t2])));
    });

    test('with nothing run it still reads, all scenarios not run', () {
      final text = terminationReport(const [], family: 'gen5', at: _utc0);
      expect('not run'.allMatches(text), hasLength(6));
    });
  });

  group('the app-only scenarios', () {
    test('1. one short pattern, the timeline and verdict, no alarm touched',
        () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.appFinishes), isTrue);
        expect(rig.calls, ['pattern:2x1']);
        final r = rig.runner.resultOf(_S.appFinishes)!;
        expect(r.completed, isTrue);
        final term = r.timeline.where((e) => e.eventId == 100).single;
        expect(term.cause, 'expired');
        expect(term.rawSubsec, kRigSubsec);
        expect(r.timeline.first.eventId, isNull, reason: 'a write mark first');
        expect(r.verdict, contains('cause expired'));
        expect(rig.runner.running, isFalse);
        expect(rig.runner.current, isNull);
      }, initialTime: _t0);
    });

    test('1. a band that never says it stopped: the verdict says none arrived '
        'after the window', () {
      fakeAsync((async) {
        final rig = TerminationRig()..sendsTerminated = false;
        expect(_runFor(async, rig, _S.appFinishes), isTrue);
        final r = rig.runner.resultOf(_S.appFinishes)!;
        expect(r.verdict, contains('No HAPTICS_TERMINATED arrived'));
        expect(r.completed, isTrue);
      }, initialTime: _t0);
    });

    test('2. a long pattern, the wearer taps mid-play: tap and termination',
        () {
      fakeAsync((async) {
        final rig = TerminationRig()..tapAfter = const Duration(seconds: 4);
        expect(_runFor(async, rig, _S.appDoubleTap), isTrue);
        expect(rig.calls, ['pattern:8x3']);
        final r = rig.runner.resultOf(_S.appDoubleTap)!;
        expect(r.timeline.map((e) => e.eventId), contains(14));
        expect(
            r.timeline.where((e) => e.eventId == 100).single.cause,
            'user_double_tap');
        expect(r.verdict, contains('user_double_tap'));
        expect(r.verdict, contains('A double-tap event (14) also arrived'));
        expect(rig.alarmWrites, 0);
      }, initialTime: _t0);
    });

    test('2. the wearer never taps: the pattern runs out and the verdict says '
        'the tap did not stop it', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.appDoubleTap), isTrue);
        final r = rig.runner.resultOf(_S.appDoubleTap)!;
        expect(r.verdict, contains('cause expired'));
        expect(r.verdict, isNot(contains('user_double_tap')));
      }, initialTime: _t0);
    });

    test('6. several short plays, each with a stamp; no alarm touched', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.stampPrecision), isTrue);
        expect(rig.patternWrites, hasLength(rig.runner.stampPlays));
        for (var i = 1; i < rig.patternWrites.length; i++) {
          expect(
              rig.patternWrites[i].$1 - rig.patternWrites[i - 1].$1,
              greaterThanOrEqualTo(rig.runner.stampGap));
        }
        final r = rig.runner.resultOf(_S.stampPrecision)!;
        expect(r.timeline.where((e) => e.eventId == 100),
            hasLength(rig.runner.stampPlays));
        expect(r.verdict, contains('sub-second'));
        expect(r.verdict, contains('${rig.runner.stampPlays} of '
            '${rig.runner.stampPlays}'));
        expect(rig.alarmWrites, 0);
      }, initialTime: _t0);
    });

    test('an app-only scenario runs even with the real alarm 5 minutes away',
        () {
      fakeAsync((async) {
        final rig = TerminationRig(heldIn: const Duration(minutes: 5));
        expect(rig.runner.blockedReason(_S.appFinishes), isNull);
        expect(_runFor(async, rig, _S.appFinishes), isTrue);
        expect(rig.calls, ['pattern:2x1']);
      }, initialTime: _t0);
    });
  });

  group('the alarm scenarios', () {
    test('3. arms the probe slot 20 s ahead, sees EXECUTED then the end, then '
        'clears and restores', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.armLeads, [20]);
        final r = rig.runner.resultOf(_S.alarmExpires)!;
        expect(r.completed, isTrue);
        expect(r.timeline.map((e) => e.eventId), containsAllInOrder([57, 100]));
        expect(r.verdict, contains('alarm reported EXECUTED'));
        expect(r.verdict, contains('cause expired'));
        final held = rig.held!;
        expect(rig.calls.indexOf('clear1'),
            lessThan(rig.calls.indexOf('restore:$held')));
        expect(rig.stored, {0: held}, reason: 'only the wearer\'s alarm is armed');
        expect(rig.runner.needsRecovery, isFalse);
        expect(rig.runner.running, isFalse);
        expect(rig.calls.where((c) => c.startsWith('pattern')), isEmpty);
      }, initialTime: _t0);
    });

    test('4. the wearer taps the alarm off: tap and user_double_tap', () {
      fakeAsync((async) {
        final rig = TerminationRig()..tapAfter = const Duration(seconds: 2);
        expect(_runFor(async, rig, _S.alarmDoubleTap), isTrue);
        final r = rig.runner.resultOf(_S.alarmDoubleTap)!;
        expect(r.timeline.map((e) => e.eventId), containsAll([57, 14, 100]));
        expect(r.verdict, contains('user_double_tap'));
        expect(rig.stored, {0: rig.held!});
      }, initialTime: _t0);
    });

    test('5. the long pattern starts 4 s before the alarm; the order and the '
        'causes are in the timeline and the verdict', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.overlap), isTrue);
        expect(rig.armLeads, [20]);
        expect(rig.patternWrites, [(const Duration(seconds: 16), 8, 3)]);
        final r = rig.runner.resultOf(_S.overlap)!;
        final ids = r.timeline.map((e) => e.eventId).whereType<int>().toList();
        expect(ids, containsAllInOrder([100, 57, 100]));
        expect(r.verdict, contains('2 HAPTICS_TERMINATED arrived'));
        expect(r.verdict, contains('error, then expired'));
        expect(rig.stored, {0: rig.held!});
      }, initialTime: _t0);
    });

    test('5. a band where the alarm does not cut the pattern', () {
      fakeAsync((async) {
        final rig = TerminationRig()
          ..alarmEndsPatternWith = null
          ..longPattern = const Duration(seconds: 30);
        expect(_runFor(async, rig, _S.overlap), isTrue);
        final r = rig.runner.resultOf(_S.overlap)!;
        expect(r.verdict, contains('kept playing through the alarm start'));
      }, initialTime: _t0);
    });

    test('no real alarm: the probe slot is cleared, nothing is restored', () {
      fakeAsync((async) {
        final rig = TerminationRig(heldIn: null);
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.calls, contains('clear1'));
        expect(rig.calls.any((c) => c.startsWith('restore')), isFalse);
        expect(rig.stored, isEmpty);
      }, initialTime: _t0);
    });

    test('a band that keeps one alarm: the wearer\'s alarm is put back', () {
      fakeAsync((async) {
        final rig = TerminationRig(capacity: 1);
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.stored, {0: rig.held!});
      }, initialTime: _t0);
    });
  });

  group('clean-up on every exit', () {
    for (final s in _alarmScenarios) {
      test('${s.name}: cancel mid-wait clears the slot and restores', () {
        fakeAsync((async) {
          final rig = TerminationRig();
          var done = false;
          unawaited(rig.runner.run(s).whenComplete(() => done = true));
          async.elapse(const Duration(seconds: 8));
          expect(rig.runner.running, isTrue);
          expect(rig.stored.keys, contains(1));
          rig.runner.cancel();
          rig.runner.cancel(); // twice is safe
          async.elapse(const Duration(seconds: 5));
          expect(done, isTrue);
          expect(rig.runner.running, isFalse);
          expect(rig.calls, contains('clear1'));
          expect(rig.calls, contains('restore:${rig.held}'));
          expect(rig.stored, {0: rig.held!});
          expect(rig.runner.resultOf(s)!.completed, isFalse);
        }, initialTime: _t0);
      });

      test('${s.name}: the arm throws (it may have landed): still cleared and '
          'restored, the flag does not stick', () {
        fakeAsync((async) {
          final rig = TerminationRig()
            ..onArm = (slot, when) async => throw StateError('link dropped');
          expect(_runFor(async, rig, s), isTrue);
          expect(rig.calls, contains('clear1'));
          expect(rig.calls, contains('restore:${rig.held}'));
          expect(rig.runner.running, isFalse);
          expect(rig.runner.current, isNull);
          expect(rig.runner.holdsTaps, isFalse);
        }, initialTime: _t0);
      });

      test('${s.name}: the band refuses the arm: still cleared and restored',
          () {
        fakeAsync((async) {
          final rig = TerminationRig()
            ..onArm = (slot, when) async => AlarmSlotWrite(
                  written: true,
                  answered: true,
                  rejected: true,
                  wallSec: slotSec(when),
                  strapSec: slotSec(when),
                );
          expect(_runFor(async, rig, s), isTrue);
          expect(rig.calls, contains('clear1'));
          expect(rig.calls, contains('restore:${rig.held}'));
          expect(rig.runner.resultOf(s)!.verdict, isNotEmpty);
        }, initialTime: _t0);
      });
    }

    test('overlap: the pattern write throws after the arm: still cleaned up',
        () {
      fakeAsync((async) {
        final rig = TerminationRig()
          ..onPattern = (e, l) async => throw StateError('write failed');
        expect(_runFor(async, rig, _S.overlap), isTrue);
        expect(rig.calls, containsAllInOrder(['arm1', 'clear1']));
        expect(rig.calls, contains('restore:${rig.held}'));
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('an app-only scenario whose write throws ends cleanly and touches no '
        'alarm', () {
      fakeAsync((async) {
        final rig = TerminationRig()
          ..onPattern = (e, l) async => throw StateError('write failed');
        expect(_runFor(async, rig, _S.appFinishes), isTrue);
        expect(rig.runner.running, isFalse);
        expect(rig.alarmWrites, 0);
        expect(rig.runner.resultOf(_S.appFinishes), isNotNull);
      }, initialTime: _t0);
    });

    test('cancelling an app-only scenario ends it and touches no alarm', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        var done = false;
        unawaited(
            rig.runner.run(_S.appDoubleTap).whenComplete(() => done = true));
        async.elapse(const Duration(seconds: 2));
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
        expect(rig.runner.running, isFalse);
        expect(rig.alarmWrites, 0);
      }, initialTime: _t0);
    });

    test('the restore throws: the slot was cleared first, recovery is flagged',
        () {
      fakeAsync((async) {
        final rig = TerminationRig()..restoreThrows = StateError('no link');
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.calls.indexOf('clear1'), isNonNegative);
        expect(rig.runner.needsRecovery, isTrue);
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('the restore is refused: recovery is flagged', () {
      fakeAsync((async) {
        final rig = TerminationRig(restoreOk: false);
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.runner.needsRecovery, isTrue);
      }, initialTime: _t0);
    });

    test('the clear fails: recovery is flagged, the restore still runs', () {
      fakeAsync((async) {
        final rig = TerminationRig()..clearOk = false;
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.runner.needsRecovery, isTrue);
        expect(rig.calls, contains('restore:${rig.held}'));
      }, initialTime: _t0);
    });

    test('a clean run does not flag recovery; a new run resets the flag', () {
      fakeAsync((async) {
        final rig = TerminationRig(restoreOk: false);
        _runFor(async, rig, _S.alarmExpires);
        expect(rig.runner.needsRecovery, isTrue);
        rig.restoreOk = true;
        rig.held = slotSec(clock.now().add(const Duration(hours: 4)));
        _runFor(async, rig, _S.alarmExpires);
        expect(rig.runner.needsRecovery, isFalse);
      }, initialTime: _t0);
    });

    test('exactly the reserved budget is enough: the clean-up is never refused '
        'by the ledger', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        final spend = ledger.commandsLeft(clock.now()) - kTerminationProbeCommands;
        ledger.record(spend, clock.now());
        final rig = TerminationRig(ledger: ledger);
        expect(_runFor(async, rig, _S.overlap), isTrue);
        expect(rig.calls, contains('clear1'));
        expect(rig.calls, contains('restore:${rig.held}'));
      }, initialTime: _t0);
    });
  });

  group('refusals', () {
    String? why(TerminationRig rig, [_S s = _S.alarmExpires]) =>
        rig.runner.blockedReason(s);

    test('developer mode off', () {
      fakeAsync((async) {
        expect(why(TerminationRig()..dev = false), contains('Developer mode'));
      }, initialTime: _t0);
    });

    test('not connected', () {
      fakeAsync((async) {
        expect(why(TerminationRig()..connected = false, _S.appFinishes),
            contains('Connect the band'));
      }, initialTime: _t0);
    });

    test('gen4 and unknown families: the probe is for the WHOOP 5 / MG', () {
      fakeAsync((async) {
        expect(why(TerminationRig(family: 'gen4'), _S.appFinishes),
            contains('WHOOP 5'));
        expect(why(TerminationRig(family: null), _S.appFinishes),
            isNotNull);
      }, initialTime: _t0);
    });

    test('the alarm scenarios refuse when the real alarm is within 10 minutes',
        () {
      fakeAsync((async) {
        final rig = TerminationRig(heldIn: const Duration(minutes: 6));
        for (final s in _alarmScenarios) {
          expect(why(rig, s), contains('10 minutes'), reason: s.name);
        }
      }, initialTime: _t0);
    });

    test('the alarm scenarios refuse during a real arm pass; app-only do not',
        () {
      fakeAsync((async) {
        final rig = TerminationRig()..armBusy = true;
        expect(why(rig, _S.overlap), contains('alarm write'));
        expect(why(rig, _S.appFinishes), isNull);
      }, initialTime: _t0);
    });

    test('the band is resting (ledger lacks the reserved commands)', () {
      fakeAsync((async) {
        final ledger = BandCommandLedger();
        ledger.record(ledger.commandsLeft(clock.now()) - 3, clock.now());
        expect(why(TerminationRig(ledger: ledger), _S.appFinishes),
            contains('resting'));
      }, initialTime: _t0);
    });

    test('a refused run writes nothing and says why in the note', () {
      fakeAsync((async) {
        final rig = TerminationRig()..dev = false;
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.calls, isEmpty);
        expect(rig.runner.note, contains('Developer mode'));
        expect(rig.runner.resultOf(_S.alarmExpires), isNull);
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('an alarm on the band the app does not know about is never '
        'overwritten', () {
      fakeAsync((async) {
        final rig = TerminationRig(
            heldIn: null, bandOnlyAlarmIn: const Duration(hours: 3));
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        expect(rig.calls.where((c) => c.startsWith('arm')), isEmpty);
        expect(rig.calls.where((c) => c.startsWith('clear')), isEmpty);
        expect(rig.runner.note, contains('does not know about'));
        expect(rig.runner.running, isFalse);
      }, initialTime: _t0);
    });

    test('a second run while one runs is refused', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        unawaited(rig.runner.run(_S.alarmExpires));
        async.elapse(const Duration(seconds: 2));
        expect(why(rig, _S.appFinishes), contains('running'));
        unawaited(rig.runner.run(_S.appFinishes));
        async.elapse(const Duration(seconds: 1));
        expect(rig.calls.where((c) => c.startsWith('pattern')), isEmpty);
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 5));
      }, initialTime: _t0);
    });
  });

  group('events and taps', () {
    test('while it runs: events 56..60 are swallowed from the real alarm '
        'handler; the tap and the termination are not', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        unawaited(rig.runner.run(_S.alarmExpires));
        async.elapse(const Duration(seconds: 2));
        for (final id in [56, 57, 58, 59, 60]) {
          expect(rig.runner.swallowsEvent(slotEvent(id, slotSec(clock.now()))),
              isTrue,
              reason: '$id');
        }
        for (final id in [14, 100, 63]) {
          expect(rig.runner.swallowsEvent(slotEvent(id, slotSec(clock.now()))),
              isFalse,
              reason: '$id');
        }
        rig.runner.cancel();
        async.elapse(const Duration(seconds: 5));
      }, initialTime: _t0);
    });

    test('after it ends: a late probe alarm event is still swallowed, a real '
        'one later is not', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(_runFor(async, rig, _S.alarmExpires), isTrue);
        final now = slotSec(clock.now());
        expect(rig.runner.swallowsEvent(slotEvent(57, now - 30)), isTrue);
        expect(rig.runner.swallowsEvent(slotEvent(57, now + 3600)), isFalse);
      }, initialTime: _t0);
    });

    test('a tap during a run is held for the probe, and only then', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        expect(rig.runner.holdsTaps, isFalse);
        unawaited(rig.runner.run(_S.appDoubleTap));
        async.elapse(const Duration(seconds: 1));
        expect(rig.runner.holdsTaps, isTrue);
        async.elapse(const Duration(minutes: 2));
        expect(rig.runner.holdsTaps, isFalse);
      }, initialTime: _t0);
    });

    test('events outside a run are not recorded', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        rig.emit(100, code: 0);
        rig.emit(14);
        expect(rig.runner.results, isEmpty);
        expect(_runFor(async, rig, _S.appFinishes), isTrue);
        expect(
            rig.runner.resultOf(_S.appFinishes)!.timeline
                .where((e) => e.eventId == 14),
            isEmpty);
      }, initialTime: _t0);
    });

    test('unwatched events during a run are ignored', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        unawaited(rig.runner.run(_S.appFinishes));
        async.elapse(const Duration(seconds: 1));
        rig.emit(63);
        rig.emit(1);
        async.elapse(const Duration(minutes: 1));
        expect(
            rig.runner.resultOf(_S.appFinishes)!.timeline
                .where((e) => e.eventId == 63 || e.eventId == 1),
            isEmpty);
      }, initialTime: _t0);
    });
  });

  group('results, lab log, report', () {
    test('the latest run of a scenario replaces the earlier; results are in '
        'page order', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        _runFor(async, rig, _S.appDoubleTap);
        _runFor(async, rig, _S.appFinishes);
        final first = rig.runner.resultOf(_S.appFinishes)!;
        rig.clockZero = clock.now();
        _runFor(async, rig, _S.appFinishes);
        expect(rig.runner.resultOf(_S.appFinishes), isNot(same(first)));
        expect(rig.runner.results.map((r) => r.scenario),
            [_S.appFinishes, _S.appDoubleTap]);
      }, initialTime: _t0);
    });

    test('the lab log gets a session with the verdict, and every timeline '
        'line; the dev log lines are tagged [termination]', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        _runFor(async, rig, _S.appFinishes);
        final lab = rig.runner.lab;
        expect(lab.sessionSummaries.first, contains('Termination probe'));
        expect(lab.sessionSummaries.first, contains('cause expired'));
        expect(lab.steps.join('\n'), contains('HAPTICS_TERMINATED'));
        expect(rig.logs, isNotEmpty);
        expect(rig.logs.every((l) => l.startsWith('[termination] ')), isTrue);
      }, initialTime: _t0);
    });

    test('reportText has every result, and is not "copy" text', () {
      fakeAsync((async) {
        final rig = TerminationRig();
        _runFor(async, rig, _S.appFinishes);
        final text = rig.runner.reportText();
        expect(text, contains(_S.appFinishes.title));
        expect(text, contains('HAPTICS_TERMINATED'));
        expect(text, contains(rig.runner.resultOf(_S.appFinishes)!.verdict));
        expect('not run'.allMatches(text), hasLength(5));
      }, initialTime: _t0);
    });
  });
}
