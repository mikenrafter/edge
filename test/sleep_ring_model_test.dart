// The Home sleep ring's rules, as a pure function of fixed dates.
//
// Two states, one function (`sleepRingModel`):
//
//   SLEPT   today has a scored night. The ring is that night's stages as
//           contiguous arcs grouped Deep, REM, Light, then Awake; the total
//           sweep of the asleep stages is asleep / target, capped at a full
//           circle. Stage totals absent => ONE solid arc, never an invented
//           split. Sub-line percentage is asleep / target.
//   UNSLEPT no scored night yet. Value is an ESTIMATE = wake - max(start, now).
//           start: coach bedtime > typical schedule onset > learned onset.
//           wake : next armed alarm > typical schedule wake > learned wake.
//           No wake => no estimate (phase `none`), ring empty. One grey arc.
//
// TARGET: the learned need when there is one, otherwise the owner's explicit
// default of 8 h (5 cycles + 30 min), flagged `targetIsDefault`.
//
// Every instant is injected. No test here reads the system clock. The DST
// cases move the PROCESS timezone with libc setenv/tzset (same idiom as
// day_window_dst_test.dart) and put it back afterwards; elapsed time across a
// transition is real elapsed time, not wall-clock subtraction.

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/state/control_operations.dart'
    show ExpectedSleepSchedule;
import 'package:openstrap_edge/ui2/sleep_ring_model.dart';

typedef _SetenvNative = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetenvDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _UnsetenvNative = Int32 Function(Pointer<Utf8>);
typedef _UnsetenvDart = int Function(Pointer<Utf8>);
typedef _TzsetNative = Void Function();
typedef _TzsetDart = void Function();

void _setProcessTz(String? tz) {
  final lib = DynamicLibrary.process();
  final key = 'TZ'.toNativeUtf8();
  try {
    if (tz == null) {
      lib.lookupFunction<_UnsetenvNative, _UnsetenvDart>('unsetenv')(key);
    } else {
      final value = tz.toNativeUtf8();
      lib.lookupFunction<_SetenvNative, _SetenvDart>('setenv')(key, value, 1);
      calloc.free(value);
    }
    lib.lookupFunction<_TzsetNative, _TzsetDart>('tzset')();
  } finally {
    calloc.free(key);
  }
}

const _h23 = 23 * 60; // 23:00
const _h07 = 7 * 60; // 07:00

const _schedule = ExpectedSleepSchedule(onsetMinute: _h23, wakeMinute: _h07);

SleepRingModel _unslept({
  required DateTime now,
  num? need,
  num? bedtime,
  ExpectedSleepSchedule? schedule,
  DateTime? alarm,
  int? learnedOnset,
  int? learnedWake,
  int? cycleLen,
}) =>
    sleepRingModel(
      now: now,
      needMin: need,
      coachBedtimeMinOfDay: bedtime,
      schedule: schedule,
      nextAlarm: alarm,
      learnedOnsetMin: learnedOnset,
      learnedWakeMin: learnedWake,
      cycleLenMin: cycleLen,
    );

// The evening before the night under test.
final _evening = DateTime(2026, 10, 8, 22, 0);

SleepRingModel _slept({
  num duration = 442,
  SleepStageMin? stages = const SleepStageMin(
    deep: 70,
    rem: 95,
    light: 277,
    awake: 30,
  ),
  num? need,
  DateTime? now,
}) =>
    sleepRingModel(
      now: now ?? DateTime(2026, 10, 9, 9, 0),
      durationMin: duration,
      stages: stages,
      needMin: need,
    );

void main() {
  group('target', () {
    test('no learned need => the 8 h default, flagged as a default', () {
      final m = _slept();
      expect(m.targetMin, 480);
      expect(m.targetIsDefault, isTrue);
      expect(kDefaultSleepTargetMin, 480);
    });

    test('a learned need is the target and is NOT flagged', () {
      final m = _slept(need: 462);
      expect(m.targetMin, 462);
      expect(m.targetIsDefault, isFalse);
    });

    test('a zero or negative need is no need at all (default, flagged)', () {
      for (final bad in [0, -30]) {
        final m = _slept(need: bad);
        expect(m.targetMin, 480, reason: 'need $bad');
        expect(m.targetIsDefault, isTrue, reason: 'need $bad');
      }
    });
  });

  group('slept', () {
    test('phase, asleep minutes and whole-percent of the default target', () {
      final m = _slept();
      expect(m.phase, SleepRingPhase.slept);
      expect(m.asleepMin, 442);
      // 442 / 480 = 92.08 %
      expect(m.pct, 92);
    });

    test('percent is against the LEARNED need when there is one', () {
      // 442 / 462 = 95.67 %
      expect(_slept(need: 462).pct, 96);
    });

    test('percent may exceed 100 even though the ring is capped', () {
      final m = _slept(
        duration: 540,
        stages: const SleepStageMin(deep: 90, rem: 120, light: 330),
      );
      expect(m.pct, 113);
      expect(m.sweep, closeTo(1.0, 1e-9));
    });

    test('arcs are grouped Deep, REM, Light, Awake — in that order', () {
      final m = _slept();
      expect(
        [for (final a in m.arcs) a.kind],
        [
          SleepArcKind.deep,
          SleepArcKind.rem,
          SleepArcKind.light,
          SleepArcKind.awake,
        ],
      );
    });

    test('each stage is its minutes / target of the full circle', () {
      final m = _slept();
      expect(m.arcs[0].fraction, closeTo(70 / 480, 1e-9));
      expect(m.arcs[1].fraction, closeTo(95 / 480, 1e-9));
      expect(m.arcs[2].fraction, closeTo(277 / 480, 1e-9));
      expect(m.arcs[3].fraction, closeTo(30 / 480, 1e-9));
    });

    test('the ASLEEP arcs together sweep exactly asleep / target', () {
      final m = _slept();
      final asleep = m.arcs
          .where((a) => a.kind != SleepArcKind.awake)
          .fold<double>(0, (s, a) => s + a.fraction);
      expect(asleep, closeTo(442 / 480, 1e-9));
    });

    test('stage totals that disagree with the duration by rounding are '
        'rescaled so the sweep still equals asleep / target', () {
      // 70 + 95 + 270 = 435, but the night's duration is 442.
      final m = _slept(
        stages: const SleepStageMin(deep: 70, rem: 95, light: 270),
      );
      final asleep = m.arcs.fold<double>(0, (s, a) => s + a.fraction);
      expect(asleep, closeTo(442 / 480, 1e-9));
      // Proportions between stages are untouched.
      expect(m.arcs[0].fraction / m.arcs[1].fraction, closeTo(70 / 95, 1e-9));
      expect(m.arcs[2].fraction / m.arcs[1].fraction, closeTo(270 / 95, 1e-9));
    });

    test('Awake is drawn after Light with its own length, and never pushes the '
        'ring past a full circle', () {
      // Asleep covers 0.9208 of the circle; 38 min awake would be 0.0792
      // more, which is exactly the room left. 60 min awake must be clipped.
      final m = _slept(
        stages: const SleepStageMin(
          deep: 70,
          rem: 95,
          light: 277,
          awake: 60,
        ),
      );
      expect(m.arcs.last.kind, SleepArcKind.awake);
      expect(m.sweep, closeTo(1.0, 1e-9));
      expect(m.arcs.last.fraction, closeTo(1 - 442 / 480, 1e-9));
    });

    test('asleep >= target: the circle is full of sleep and Awake gets no arc',
        () {
      final m = _slept(
        duration: 540,
        stages: const SleepStageMin(
          deep: 90,
          rem: 120,
          light: 330,
          awake: 20,
        ),
      );
      expect(m.arcs.any((a) => a.kind == SleepArcKind.awake), isFalse);
      expect(m.sweep, closeTo(1.0, 1e-9));
      // Proportions are preserved when scaled down to the circle.
      expect(m.arcs[0].fraction, closeTo(90 / 540, 1e-9));
      expect(m.arcs[1].fraction, closeTo(120 / 540, 1e-9));
      expect(m.arcs[2].fraction, closeTo(330 / 540, 1e-9));
    });

    test('no awake figure => no awake arc (not a zero-length one)', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 70, rem: 95, light: 277),
      );
      expect(
        [for (final a in m.arcs) a.kind],
        [SleepArcKind.deep, SleepArcKind.rem, SleepArcKind.light],
      );
    });

    test('NO stage totals => ONE solid arc, never an invented split', () {
      final m = _slept(stages: null);
      expect(m.phase, SleepRingPhase.slept);
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
      expect(m.arcs.single.fraction, closeTo(442 / 480, 1e-9));
    });

    test('a PARTIAL split (a stage missing) is also one solid arc', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 70, light: 277, awake: 30),
      );
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
      expect(m.arcs.single.fraction, closeTo(442 / 480, 1e-9));
    });

    test('stage totals that are all zero are no split either', () {
      final m = _slept(
        stages: const SleepStageMin(deep: 0, rem: 0, light: 0, awake: 0),
      );
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.solid);
    });

    test('a solid arc is capped at a full circle', () {
      final m = _slept(duration: 600, stages: null);
      expect(m.arcs.single.fraction, closeTo(1.0, 1e-9));
      expect(m.sweep, closeTo(1.0, 1e-9));
    });

    test('a scored night wins over every schedule/alarm input', () {
      final m = sleepRingModel(
        now: _evening,
        durationMin: 442,
        schedule: _schedule,
        nextAlarm: DateTime(2026, 10, 9, 6, 30),
        coachBedtimeMinOfDay: 1350,
        learnedOnsetMin: _h23,
        learnedWakeMin: _h07,
      );
      expect(m.phase, SleepRingPhase.slept);
      expect(m.estimateMin, isNull);
      expect(m.cycles, isNull);
    });
  });

  group('unslept estimate', () {
    test('wake - start from the typical schedule; cycles = floor(est / 90)', () {
      final m = _unslept(now: _evening, schedule: _schedule);
      expect(m.phase, SleepRingPhase.estimate);
      expect(m.windowStart, DateTime(2026, 10, 8, 23, 0));
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 0));
      expect(m.estimateMin, 480);
      expect(m.cycleLenMin, 90);
      expect(m.cycles, 5); // 480 / 90 = 5.33
      expect(m.startSource, WindowStartSource.schedule);
      expect(m.wakeSource, WakeSource.schedule);
      expect(m.asleepMin, isNull);
      expect(m.pct, isNull);
    });

    test('ONE grey (estimate) arc: estimate / target of the circle', () {
      final m = _unslept(now: _evening, schedule: _schedule, need: 540);
      expect(m.arcs, hasLength(1));
      expect(m.arcs.single.kind, SleepArcKind.estimate);
      expect(m.arcs.single.fraction, closeTo(480 / 540, 1e-9));
      expect(m.targetMin, 540);
      expect(m.targetIsDefault, isFalse);
    });

    test('the estimate arc is capped at a full circle', () {
      final m = _unslept(
        now: _evening,
        schedule: const ExpectedSleepSchedule(
          onsetMinute: 22 * 60,
          wakeMinute: 9 * 60,
        ),
      );
      expect(m.estimateMin, 11 * 60); // 22:00 -> 09:00, now is 22:00
      expect(m.arcs.single.fraction, closeTo(1.0, 1e-9));
    });

    test('with no learned need the estimate is measured against the flagged '
        'default', () {
      final m = _unslept(now: _evening, schedule: _schedule);
      expect(m.targetMin, 480);
      expect(m.targetIsDefault, isTrue);
      expect(m.arcs.single.fraction, closeTo(1.0, 1e-9));
    });

    test('NEXT ARMED ALARM beats the schedule wake', () {
      final m = _unslept(
        now: _evening,
        schedule: _schedule,
        alarm: DateTime(2026, 10, 9, 6, 30),
      );
      expect(m.wakeAt, DateTime(2026, 10, 9, 6, 30));
      expect(m.wakeSource, WakeSource.alarm);
      expect(m.estimateMin, 450); // 23:00 -> 06:30
      expect(m.cycles, 5);
    });

    test('schedule wake beats learned wake', () {
      final m = _unslept(
        now: _evening,
        schedule: _schedule,
        learnedOnset: _h23,
        learnedWake: 7 * 60 + 30,
      );
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 0));
      expect(m.wakeSource, WakeSource.schedule);
    });

    test('learned wake is used when there is no alarm and no schedule', () {
      final m = _unslept(
        now: _evening,
        learnedOnset: 23 * 60 + 30,
        learnedWake: 7 * 60 + 30,
      );
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 30));
      expect(m.wakeSource, WakeSource.learned);
      expect(m.windowStart, DateTime(2026, 10, 8, 23, 30));
      expect(m.startSource, WindowStartSource.learned);
      expect(m.estimateMin, 480);
    });

    test('COACH BEDTIME beats the schedule onset', () {
      final m = _unslept(
        now: _evening,
        bedtime: 22 * 60 + 30,
        schedule: _schedule,
      );
      expect(m.windowStart, DateTime(2026, 10, 8, 22, 30));
      expect(m.startSource, WindowStartSource.coach);
      expect(m.estimateMin, 510); // 22:30 -> 07:00
      expect(m.cycles, 5);
    });

    test('schedule onset beats learned onset', () {
      final m = _unslept(
        now: _evening,
        schedule: _schedule,
        learnedOnset: 23 * 60 + 30,
      );
      expect(m.windowStart, DateTime(2026, 10, 8, 23, 0));
      expect(m.startSource, WindowStartSource.schedule);
    });

    test('the coach bedtime is a clock minute, so it can fall after midnight',
        () {
      final m = _unslept(
        now: DateTime(2026, 10, 8, 21, 0),
        bedtime: 30, // 00:30
        schedule: _schedule,
      );
      expect(m.windowStart, DateTime(2026, 10, 9, 0, 30));
      expect(m.estimateMin, 390); // 00:30 -> 07:00
      expect(m.cycles, 4); // 390 / 90 = 4.33
    });

    test('a fractional coach bedtime minute still resolves to a clock time',
        () {
      final m = _unslept(
        now: _evening,
        bedtime: 1350.4,
        schedule: _schedule,
      );
      expect(m.windowStart, DateTime(2026, 10, 8, 22, 30));
    });

    test('estimate runs from NOW once the window has started (max(start, now))',
        () {
      final now = DateTime(2026, 10, 9, 2, 0);
      final m = _unslept(now: now, schedule: _schedule);
      expect(m.windowStart, now);
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 0));
      expect(m.estimateMin, 300);
      expect(m.cycles, 3);
      expect(m.startSource, WindowStartSource.schedule);
    });

    test('estimate runs from the window start while it is still in the future',
        () {
      final m = _unslept(now: DateTime(2026, 10, 8, 18, 0), schedule: _schedule);
      expect(m.windowStart, DateTime(2026, 10, 8, 23, 0));
      expect(m.estimateMin, 480);
    });

    test('no onset from any source => the estimate runs from now, saying so',
        () {
      final m = _unslept(
        now: _evening,
        alarm: DateTime(2026, 10, 9, 7, 0),
      );
      expect(m.phase, SleepRingPhase.estimate);
      expect(m.windowStart, _evening);
      expect(m.startSource, isNull);
      expect(m.estimateMin, 540);
      expect(m.cycles, 6);
    });

    test('an alarm that has already passed is not a wake', () {
      final m = _unslept(
        now: _evening,
        schedule: _schedule,
        alarm: _evening.subtract(const Duration(minutes: 1)),
      );
      expect(m.wakeSource, WakeSource.schedule);
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 0));
    });

    test('an alarm more than 24 h away is not tonight\'s wake', () {
      final m = _unslept(
        now: _evening,
        schedule: _schedule,
        alarm: DateTime(2026, 10, 10, 7, 0), // a weekday alarm, 33 h away
      );
      expect(m.wakeSource, WakeSource.schedule);
      expect(m.wakeAt, DateTime(2026, 10, 9, 7, 0));
    });

    test('a wake at exactly now rolls to the next day\'s wake', () {
      final now = DateTime(2026, 10, 9, 7, 0);
      final m = _unslept(now: now, schedule: _schedule);
      expect(m.wakeAt, DateTime(2026, 10, 10, 7, 0));
      expect(m.windowStart, DateTime(2026, 10, 9, 23, 0));
      expect(m.estimateMin, 480);
    });

    test('NO WAKE FROM ANY SOURCE => no estimate, empty ring, never a guess',
        () {
      final m = _unslept(
        now: _evening,
        bedtime: 1350,
        learnedOnset: _h23, // an onset alone is not a wake
      );
      expect(m.phase, SleepRingPhase.none);
      expect(m.estimateMin, isNull);
      expect(m.cycles, isNull);
      expect(m.wakeAt, isNull);
      expect(m.arcs, isEmpty);
      expect(m.sweep, 0);
    });

    test('nothing at all is also no estimate', () {
      final m = _unslept(now: _evening);
      expect(m.phase, SleepRingPhase.none);
      expect(m.arcs, isEmpty);
    });

    test('cycle length is injectable: 100 min => floor(480 / 100) = 4', () {
      final m = _unslept(now: _evening, schedule: _schedule, cycleLen: 100);
      expect(m.cycleLenMin, 100);
      expect(m.cycles, 4);
    });

    test('an implausible cycle length falls back to 90', () {
      for (final bad in [0, -5, 20, 400]) {
        final m = _unslept(now: _evening, schedule: _schedule, cycleLen: bad);
        expect(m.cycleLenMin, 90, reason: 'cycleLen $bad');
        expect(m.cycles, 5, reason: 'cycleLen $bad');
      }
    });

    test('under one cycle is zero cycles, not one', () {
      final m = _unslept(
        now: DateTime(2026, 10, 9, 6, 0),
        schedule: _schedule,
      );
      expect(m.estimateMin, 60);
      expect(m.cycles, 0);
    });
  });

  group('DST: elapsed time, not wall-clock subtraction', () {
    final originalTz = Platform.environment['TZ'];

    setUp(() {
      if (Platform.isWindows) markTestSkipped('POSIX-only (libc setenv)');
      _setProcessTz('America/Denver');
    });
    tearDown(() => _setProcessTz(originalTz));

    test('spring forward 2026-03-08: 23:00 -> 07:00 is 7 h, not 8', () {
      final now = DateTime(2026, 3, 7, 22, 0);
      final m = _unslept(now: now, schedule: _schedule);
      expect(m.windowStart, DateTime(2026, 3, 7, 23, 0));
      expect(m.wakeAt, DateTime(2026, 3, 8, 7, 0));
      expect(m.estimateMin, 420);
      expect(m.cycles, 4); // 420 / 90 = 4.67
    });

    test('spring forward, wake given as a UTC alarm instant', () {
      final now = DateTime(2026, 3, 7, 22, 0);
      final m = _unslept(
        now: now,
        schedule: _schedule,
        alarm: DateTime.utc(2026, 3, 8, 13, 0), // 07:00 MDT
      );
      expect(m.wakeSource, WakeSource.alarm);
      expect(m.estimateMin, 420);
    });

    test('fall back 2026-11-01: 23:00 -> 07:00 is 9 h, not 8', () {
      final now = DateTime(2026, 10, 31, 22, 0);
      final m = _unslept(now: now, schedule: _schedule);
      expect(m.windowStart, DateTime(2026, 10, 31, 23, 0));
      expect(m.wakeAt, DateTime(2026, 11, 1, 7, 0));
      expect(m.estimateMin, 540);
      expect(m.cycles, 6);
    });

    test('now inside the transition night still measures real elapsed time',
        () {
      // 00:30 MDT on spring-forward day, before the 02:00 jump: 7:00 MDT is
      // 5.5 real hours away, not 6.5.
      final now = DateTime(2026, 3, 8, 0, 30);
      final m = _unslept(now: now, schedule: _schedule);
      expect(m.windowStart, now);
      expect(m.estimateMin, 330);
    });
  });

  group('learnedClockMinutes', () {
    int sec(int y, int mo, int d, int h, int mi) =>
        DateTime(y, mo, d, h, mi).millisecondsSinceEpoch ~/ 1000;

    Map<String, dynamic> night(int day, (int, int)? onset, (int, int)? wake) =>
        {
          'date': '2026-09-${day.toString().padLeft(2, '0')}',
          'onset_ts': onset == null
              ? null
              : (onset.$1 >= 12
                  ? sec(2026, 9, day - 1, onset.$1, onset.$2)
                  : sec(2026, 9, day, onset.$1, onset.$2)),
          'wake_ts': wake == null ? null : sec(2026, 9, day, wake.$1, wake.$2),
        };

    test('median local clock minute of onsets and of wakes', () {
      final r = learnedClockMinutes([
        night(10, (23, 0), (7, 0)),
        night(11, (23, 0), (7, 0)),
        night(12, (23, 0), (7, 30)),
        night(13, (23, 30), (6, 45)),
        night(14, (0, 10), (7, 15)),
      ]);
      expect(r.onsetMin, 23 * 60);
      expect(r.wakeMin, 7 * 60);
    });

    test('onsets straddling midnight do not average to midday', () {
      final r = learnedClockMinutes([
        night(10, (23, 10), (7, 0)),
        night(11, (23, 30), (7, 0)),
        night(12, (23, 50), (7, 0)),
        night(13, (0, 10), (7, 0)),
        night(14, (0, 30), (7, 0)),
      ]);
      expect(r.onsetMin, 23 * 60 + 50);
    });

    test('all-after-midnight onsets stay after midnight', () {
      final r = learnedClockMinutes([
        night(10, (0, 10), (8, 0)),
        night(11, (0, 20), (8, 0)),
        night(12, (0, 30), (8, 0)),
      ]);
      expect(r.onsetMin, 20);
    });

    test('fewer than the minimum usable nights => null, not a guess', () {
      final r = learnedClockMinutes([
        night(10, (23, 0), (7, 0)),
        night(11, (23, 0), (7, 0)),
      ]);
      expect(r.onsetMin, isNull);
      expect(r.wakeMin, isNull);
    });

    test('nights with no window are skipped, and each side counts its own',
        () {
      final r = learnedClockMinutes([
        night(10, null, null),
        night(11, (23, 0), (7, 0)),
        night(12, (23, 0), null),
        night(13, (23, 0), (7, 0)),
        night(14, null, (7, 0)),
      ]);
      expect(r.onsetMin, 23 * 60); // 3 onsets
      expect(r.wakeMin, 7 * 60); // 3 wakes
    });

    test('empty input is null on both sides', () {
      final r = learnedClockMinutes(const []);
      expect(r.onsetMin, isNull);
      expect(r.wakeMin, isNull);
    });
  });

  group('source guard', () {
    test('the model reads no clock — now is always injected', () {
      final src = File('lib/ui2/sleep_ring_model.dart').readAsStringSync();
      final code = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      expect(code.contains('DateTime.now('), isFalse);
      expect(code.contains('clock.now('), isFalse);
      expect(code.contains('package:clock'), isFalse);
    });
  });
}
