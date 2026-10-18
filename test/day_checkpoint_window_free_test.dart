// Incremental phase 3b, part 1: the resume state does not depend on the sleep
// window.
//
// 3a keyed the checkpoint on the sleep window (it sits in `dayContextSig` and in
// every summary), so on the one night when resuming pays most, the window moves
// on every overnight pass (the offset follows the data) and again at the morning
// scoring pass, and every one of those passes refolds the whole day. 3b keeps
// only what the window does not touch: per-minute heart-rate and movement
// vectors and the step-counter fold, all keyed by time. Anything that does
// depend on the window (wake HR, wake active minutes, the asleep/awake split) is
// read from those vectors under the window of the pass that asks.
//
//  * pure layer: the stored state is the same bytes whatever window it was
//    folded under; readers given a window equal the batch summary folded under
//    that window, edges mid-minute included; a live summary does not refold when
//    the window moves; `dayContextSig` ignores the window and still moves for
//    every other part;
//  * engine layer (`debugDerivePreparedDay`, hand-built days, no staging):
//    passes whose window moves every time RESUME, restart between passes, and
//    store exactly what a full pass stores; every other invalidation row of the
//    design (report 3.4) still forces a full pass.
//
// RED until 3b lands. API assumed (stubs exist and throw): the window readers
// `DayHrSummary.wakeMinutesFor/wakeHrFor` and `DayMotionSummary.activeMinutesFor`.
// The window parameters of `appendTail` / `foldDayCheckpoint` / `sync` /
// `dayContextSig` are still passed here; once they are dropped from the
// signatures, delete those arguments (nothing else changes).
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/ble/adapters/signals.dart';
import 'package:openstrap_edge/compute/day_activity_state.dart';
import 'package:openstrap_edge/compute/day_calculation_state.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/derive_prepare.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// ── pure layer ──────────────────────────────────────────────────────────────

typedef _Window = ({int on, int off});

class _Day {
  _Day(this.ts, this.hr, this.ax, this.ay, this.az, this.step);
  final List<int> ts, hr, step;
  final List<double> ax, ay, az;
  int get length => ts.length;
}

/// Same shapes as the 3a fixture: no-HR seconds, spikes the plausibility
/// ceiling rejects, off-wrist gaps, seconds with no gravity vector, and a step
/// counter that wraps, resets (at i == 3001) and goes missing.
_Day _synthDay({required int start, required int seconds, int seed = 7}) {
  final rnd = math.Random(seed);
  final ts = <int>[], hr = <int>[], step = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  var t = start;
  var c = 65500;
  for (var i = 0; i < seconds; i++) {
    if (i > 0 && i % 4001 == 0) t += 180;
    ts.add(t++);
    final r = rnd.nextInt(100);
    hr.add(r < 4 ? 0 : (r < 6 ? 250 : 55 + (i ~/ 90) % 70 + rnd.nextInt(5)));
    if (rnd.nextInt(50) == 0) {
      ax.add(0);
      ay.add(0);
      az.add(0);
    } else {
      ax.add(.3 * math.sin(i * .21) + rnd.nextDouble() * .05);
      ay.add(.2 * math.cos(i * .13));
      az.add(1 + .05 * math.sin(i * .07));
    }
    if (i % 997 > 900) {
      step.add(-1);
    } else {
      if (i == 3001) {
        c = 40000;
      } else if (i == 3002) {
        c = 0;
      } else {
        c = (c + rnd.nextInt(3)) % 65536;
      }
      step.add(c);
    }
  }
  return _Day(ts, hr, ax, ay, az, step);
}

Substrate _substrate(_Day d) => Substrate(
      tsSec: d.ts,
      hr: d.hr,
      rrTsMs: const [],
      rrMs: const [],
      ax: d.ax,
      ay: d.ay,
      az: d.az,
      spo2Red: List.filled(d.length, 0),
      spo2Ir: List.filled(d.length, 0),
      skinTemp: List.filled(d.length, 0),
      skinContact: List.filled(d.length, 0),
      stepCount: d.step,
      deviceFamily: 'gen5',
    );

List<int> _chunks(math.Random r, int total) {
  final out = <int>[];
  var left = total;
  while (left > 0) {
    final n = 1 + r.nextInt(r.nextBool() ? 40 : 7000);
    out.add(n);
    left -= n;
  }
  return out;
}

/// A different window for every call, in every shape the engine produces:
/// none, a night that follows the data, odd seconds, reversed, past both ends.
_Window _randomWindow(math.Random r, int start, int seconds) {
  switch (r.nextInt(6)) {
    case 0:
      return (on: 0, off: 0);
    case 1:
      final on = start - 3600 + r.nextInt(7200);
      return (on: on, off: on + r.nextInt(seconds));
    case 2:
      return (on: start + r.nextInt(seconds), off: start + r.nextInt(seconds));
    case 3:
      return (on: start - 7200, off: start + seconds + 7200);
    default:
      final on = start + r.nextInt(seconds ~/ 2);
      return (on: on + 7, off: on + 600 + r.nextInt(seconds ~/ 2) + 13);
  }
}

/// Folds [d] in the given pieces, each under the window [windowOf] gives for
/// it, writing the state out and reading it back between pieces (a restart
/// between passes). Every fold must be accepted.
Uint8List _foldMoving(
  _Day d,
  Iterable<int> sizes,
  _Window Function(int piece) windowOf, {
  int? modulus = 65536,
}) {
  Uint8List? blob;
  var at = 0, piece = 0;
  for (final n in sizes) {
    if (at >= d.length) break;
    final hi = math.min(d.length, at + n);
    final w = windowOf(piece++);
    final next = foldDayCheckpoint(
      base: blob,
      alreadyFolded: at,
      ts: d.ts.sublist(at, hi),
      hr: d.hr.sublist(at, hi),
      ax: d.ax.sublist(at, hi),
      ay: d.ay.sublist(at, hi),
      az: d.az.sublist(at, hi),
      stepCounter: d.step.sublist(at, hi),
      sleepOnsetSec: w.on,
      sleepOffsetSec: w.off,
      age: 35,
      stepModulus: modulus,
    );
    expect(next, isNotNull,
        reason: 'piece [$at,$hi) under window ${w.on}..${w.off} is accepted: '
            'the window is not part of the state');
    blob = next;
    at = hi;
  }
  expect(at, d.length);
  return blob!;
}

Uint8List _foldOnce(_Day d, {_Window w = (on: 0, off: 0), int? modulus = 65536}) =>
    _foldMoving(d, [d.length], (_) => w, modulus: modulus);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the stored state does not depend on the sleep window', () {
    test('the same bytes whatever window the day was folded under', () {
      final day = _synthDay(start: 1760000000, seconds: 9000);
      final base = _foldOnce(day);
      for (final w in <_Window>[
        (on: 1760001013, off: 1760005071),
        (on: 1760000003, off: 1760000030),
        (on: 1759990000, off: 1760020000),
        (on: 1760004000, off: 1760002000),
      ]) {
        expect(_foldOnce(day, w: w), base, reason: 'window ${w.on}..${w.off}');
      }
    });

    test('random chunking, the window moving on every piece, restart between',
        () {
      for (final seed in [1, 2, 3, 4, 5, 6]) {
        final day = _synthDay(start: 1760000000, seconds: 21000, seed: seed);
        final r = math.Random(seed * 17);
        final windows = math.Random(seed * 29);
        final moving = _foldMoving(
          day,
          _chunks(r, day.length),
          (_) => _randomWindow(windows, 1760000000, 21000),
        );
        expect(moving, _foldOnce(day), reason: 'seed $seed');
      }
    });

    test('the offset following the data, as on an overnight pass', () {
      // The night's window grows with the data; its onset never changes.
      final day = _synthDay(start: 1760000000, seconds: 20000);
      const onset = 1760000000 + 600;
      final seen = <int>[];
      final blob = _foldMoving(day, [3000, 4100, 5200, 7700], (piece) {
        seen.add(piece);
        return (on: onset, off: 1760000000 + 3000 * (piece + 1));
      });
      expect(seen, hasLength(4));
      expect(blob, _foldOnce(day));
    });

    test('a 23 h and a 25 h day, the window moving across the clock change', () {
      for (final hours in [23, 25]) {
        final seconds = hours * 3600;
        final start = 1773000000 - (1773000000 % kRevBucketSec);
        final ts = [for (var i = 0; i < seconds; i += 5) start + i];
        final n = ts.length;
        final rnd = math.Random(hours);
        final day = _Day(
          ts,
          [for (var i = 0; i < n; i++) 55 + rnd.nextInt(60)],
          [for (var i = 0; i < n; i++) .2 * math.sin(i * .3)],
          [for (var i = 0; i < n; i++) .1 * math.cos(i * .2)],
          List.filled(n, 1.0),
          List.filled(n, -1),
        );
        final moving = _foldMoving(
          day,
          _chunks(math.Random(hours), n),
          // The clock change sits two hours into the day; the window straddles it.
          (piece) => (on: start + 3600, off: start + 3 * 3600 + piece * 1200),
        );
        expect(moving, _foldOnce(day), reason: '$hours h day');
      }
    });

    test('a counter reset overnight credits what the batch credits, window moving',
        () {
      // 100 healthy seconds, a reset to 0 across the seam, 100 more, with the
      // sleep window changing on every piece around it.
      final ts = [for (var i = 0; i < 200; i++) 1760000000 + i];
      final step = [
        for (var i = 0; i < 100; i++) 20000 + i,
        for (var i = 0; i < 100; i++) i,
      ];
      final day = _Day(ts, List.filled(200, 70), List.filled(200, .1),
          List.filled(200, .1), List.filled(200, 1.0), step);
      final want = hardwareStepsFromCounter(_substrate(day),
          cumulativeCounterModulus: 65536);
      expect(want, 99 + 99);
      for (final seam in [99, 100, 101]) {
        final blob = _foldMoving(
          day,
          [seam, 200 - seam],
          (piece) => (on: 1760000000 + 10 * piece, off: 1760000150 + 20 * piece),
        );
        expect(decodeDayResumeState(blob)!.steps.steps, want, reason: 'seam $seam');
      }
      // And over a long, gappy day with a reset, whatever the windows.
      final long = _synthDay(start: 1760000000, seconds: 9000, seed: 3);
      final wantLong = hardwareStepsFromCounter(_substrate(long),
          cumulativeCounterModulus: 65536);
      expect(wantLong, isNotNull);
      final windows = math.Random(5);
      final blob = _foldMoving(long, _chunks(math.Random(4), long.length),
          (_) => _randomWindow(windows, 1760000000, 9000));
      expect(decodeDayResumeState(blob)!.steps.steps, wantLong);
    });

    test('age and counter modulus still refuse an append', () {
      final day = _synthDay(start: 1760000000, seconds: 3000);
      final blob = _foldOnce(day);
      Uint8List? more({int? age = 35, int? mod = 65536}) => foldDayCheckpoint(
            base: blob,
            alreadyFolded: 3000,
            ts: [day.ts.last + 1],
            hr: [70],
            ax: [0.0],
            ay: [0.0],
            az: [1.0],
            stepCounter: [5],
            sleepOnsetSec: 123,
            sleepOffsetSec: 456,
            age: age,
            stepModulus: mod,
          );
      expect(more(), isNotNull,
          reason: 'a window that differs from the one it was folded under');
      expect(more(age: 36), isNull);
      expect(more(mod: null), isNull);
    });
  });

  group('readers take the window and read the stored vectors', () {
    final day = _synthDay(start: 1760000000, seconds: 9000);
    final windows = <_Window>[
      (on: 0, off: 0),
      (on: 1760001000, off: 1760005000), // minute aligned
      (on: 1760001013, off: 1760005071), // both edges mid-minute
      (on: 1760000003, off: 1760000030), // inside one minute
      (on: 1759990000, off: 1760000400), // starts before the day
      (on: 1760008000, off: 1760020000), // ends after the data
      (on: 1760004500, off: 1760004500), // empty
      (on: 1760004000, off: 1760002000), // reversed: no window
      (on: 1760003900, off: 1760004300), // across the 180 s off-wrist gap
    ];

    DayHrSummary hrOracle(_Window w) => DayHrSummary()
      ..sync(day.ts, day.hr, sleepOnsetSec: w.on, sleepOffsetSec: w.off, age: 35);
    DayMotionSummary motionOracle(_Window w) => DayMotionSummary()
      ..sync(day.ts, day.ax, day.ay, day.az,
          sleepOnsetSec: w.on, sleepOffsetSec: w.off);

    void expectReads(DayResumeState state, _Window w, String reason) {
      final hr = hrOracle(w), motion = motionOracle(w);
      for (final slot in [state.hrPipeline, state.hrActivity]) {
        final got = slot.wakeMinutesFor(sleepOnsetSec: w.on, sleepOffsetSec: w.off);
        final want = hr.wakeMinutes();
        expect(got.keys, want.keys, reason: '$reason: wake minutes');
        expect(got.hr, want.hr, reason: '$reason: wake minute means');
        expect(slot.wakeHrFor(sleepOnsetSec: w.on, sleepOffsetSec: w.off),
            hr.wakeHr, reason: '$reason: wake HR');
        expect(slot.hrStats(), hr.hrStats(), reason: '$reason: stats');
      }
      expect(
          state.motion.activeMinutesFor(sleepOnsetSec: w.on, sleepOffsetSec: w.off),
          motion.activeMinutes(),
          reason: '$reason: active minutes');
      expect(jsonEncode(state.motion.activityCurve()),
          jsonEncode(motion.activityCurve()),
          reason: '$reason: curve');
      expect(state.motion.wearRuns(), motion.wearRuns(), reason: '$reason: runs');
    }

    test('equal the batch summary folded under that window', () {
      // The state is folded under one window per piece and read under another.
      final foldW = math.Random(11);
      final blob = _foldMoving(day, _chunks(math.Random(2), day.length),
          (_) => _randomWindow(foldW, 1760000000, 9000));
      for (final w in windows) {
        expectReads(decodeDayResumeState(blob)!, w, 'window ${w.on}..${w.off}');
      }
    });

    test('a fresh fold of the day reads the same under every window', () {
      final state = decodeDayResumeState(_foldOnce(day))!;
      for (final w in windows) {
        expectReads(state, w, 'window ${w.on}..${w.off}');
      }
    });

    test('a live summary does not refold when the window moves', () {
      const cut = 5500;
      final hr = DayHrSummary();
      final motion = DayMotionSummary();
      var step = 0;
      for (final n in [cut, day.length]) {
        final w = windows[1 + step++];
        hr.sync(day.ts.sublist(0, n), day.hr.sublist(0, n),
            sleepOnsetSec: w.on, sleepOffsetSec: w.off, age: 35);
        motion.sync(day.ts.sublist(0, n), day.ax.sublist(0, n),
            day.ay.sublist(0, n), day.az.sublist(0, n),
            sleepOnsetSec: w.on, sleepOffsetSec: w.off);
      }
      // Moved again, and back to none, with nothing new to fold.
      for (final w in [windows[2], windows[0], windows[5]]) {
        hr.sync(day.ts, day.hr,
            sleepOnsetSec: w.on, sleepOffsetSec: w.off, age: 35);
        motion.sync(day.ts, day.ax, day.ay, day.az,
            sleepOnsetSec: w.on, sleepOffsetSec: w.off);
        final r = hr.wakeMinutesFor(sleepOnsetSec: w.on, sleepOffsetSec: w.off);
        expect(r.keys, hrOracle(w).wakeMinutes().keys);
        expect(motion.activeMinutesFor(sleepOnsetSec: w.on, sleepOffsetSec: w.off),
            motionOracle(w).activeMinutes());
      }
      expect(hr.processedSamples, day.length,
          reason: 'each second folded once, however often the window moved');
      expect(motion.processedSamples, day.length);
    });

    test('the engine state keeps its summaries when the window moves', () {
      final state = DayCalculationState();
      var seconds = 0;
      for (final (n, w) in [
        (4000, windows[1]),
        (6500, windows[2]),
        (9000, windows[0]),
      ]) {
        state.hrSummary('pipeline', day.ts.sublist(0, n), day.hr.sublist(0, n),
            sleepOnsetSec: w.on,
            sleepOffsetSec: w.off,
            age: 35,
            mode: ana.CalculationMode.periodicAwake);
        state.hrSummary('activity', day.ts.sublist(0, n), day.hr.sublist(0, n),
            sleepOnsetSec: w.on,
            sleepOffsetSec: w.off,
            age: 35,
            mode: ana.CalculationMode.periodicAwake);
        state.motionSummary(day.ts.sublist(0, n), day.ax.sublist(0, n),
            day.ay.sublist(0, n), day.az.sublist(0, n),
            sleepOnsetSec: w.on,
            sleepOffsetSec: w.off,
            mode: ana.CalculationMode.periodicAwake);
        seconds = n;
      }
      expect(state.processedHrSamples, 2 * seconds);
      expect(state.processedOrientationSamples, seconds);
    });
  });

  group('the context signature', () {
    String sig({
      String profile = 'p',
      String priority = 'a>b',
      String? family = 'gen4',
      int start = 1000,
      int end = 1000 + 86400,
      int offStart = 0,
      int offEnd = 0,
      int onset = 10,
      int offset = 20,
      String? source = 'auto',
      double? floor = .03,
    }) =>
        dayContextSig(
          profileSig: profile,
          priorityKey: priority,
          deviceFamily: family,
          dayStartSec: start,
          dayEndSec: end,
          tzOffsetAtStartMin: offStart,
          tzOffsetAtEndMin: offEnd,
          sleepOnsetSec: onset,
          sleepOffsetSec: offset,
          sleepSource: source,
          dynFloorG: floor,
        );

    test('does not move when only the sleep window moves, and moves for every other part',
        () {
      final base = sig();
      expect(sig(onset: 11), base);
      expect(sig(offset: 21), base);
      expect(sig(onset: 0, offset: 0), base);
      expect(sig(onset: 5000, offset: 90000), base);
      // ...and nothing else became free with it.
      for (final other in [
        sig(profile: 'q'),
        sig(priority: 'b>a'),
        sig(family: 'gen5'),
        sig(family: null),
        sig(start: 1001),
        sig(end: 1000 + 86400 + 1),
        sig(end: 1000 + 23 * 3600, offEnd: 60),
        sig(end: 1000 + 25 * 3600, offEnd: -60),
        sig(offStart: 60),
        sig(offEnd: 60),
        sig(floor: .04),
        sig(floor: null),
      ]) {
        expect(other, isNot(base));
      }
    });
  });

  // ── engine layer ──────────────────────────────────────────────────────────

  group('engine resume across a night with a moving window', () {
    const profile = Profile(
      ageYears: 35,
      weightKg: 75,
      heightCm: 178,
      sex: 'male',
      restingHrManual: 54,
    );

    late DateTime mid;
    late String label;
    late int dayStart, dayEnd;
    late Substrate all;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      LocalDb.dbName = 'day_checkpoint_window_free_test.db';
    });

    Future<void> wipe() async {
      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    }

    /// Hours after the day's local midnight, as epoch seconds.
    int h(double hours) => dayStart + (hours * 3600).round();

    /// Yesterday's night and morning at 1 Hz from two hours before midnight:
    /// asleep (still, low HR) from -1:00 to 06:30, then awake. A no-HR second
    /// now and then, and the step counter restarts at 03:00 (a strap reboot in
    /// the middle of the night).
    Substrate fixture() {
      final from = h(-2), to = h(10);
      final ts = <int>[], hr = <int>[], step = <int>[];
      final ax = <double>[], ay = <double>[], az = <double>[];
      var counter = 61000;
      for (var t = from; t < to; t++) {
        final i = t - from;
        final asleep = t >= h(-1) && t < h(6.5);
        ts.add(t);
        hr.add(i % 97 == 0
            ? 0
            : asleep
                ? 50 + (t ~/ 600) % 6 + t % 3
                : 76 + (t ~/ 60) % 25 + t % 4);
        ax.add(asleep ? .001 * (t % 3) : .3 * math.sin(t * .21));
        ay.add(asleep ? 0.0 : .2 * math.cos(t * .13));
        az.add(asleep ? 1.0 : 1 + .05 * math.sin(t * .07));
        if (t == h(3)) {
          counter = 0;
        } else if (t % (asleep ? 40 : 7) == 0) {
          counter = (counter + 1) % 65536;
        }
        step.add(counter);
      }
      return Substrate(
        tsSec: ts,
        hr: hr,
        rrTsMs: const [],
        rrMs: const [],
        ax: ax,
        ay: ay,
        az: az,
        spo2Red: List.filled(ts.length, 1),
        spo2Ir: List.filled(ts.length, 1),
        skinTemp: List.filled(ts.length, 3000),
        skinContact: List.filled(ts.length, 1),
        stepCount: step,
        deviceFamily: 'gen5',
      );
    }

    /// The `input_rev` of each 15-minute bucket as the table's triggers would
    /// hold it: one bump per row written.
    Map<int, int> revsOf(Substrate day) {
      final out = <int, int>{};
      for (final t in day.tsSec) {
        out.update(t ~/ kRevBucketSec, (v) => v + 1, ifAbsent: () => 1);
      }
      return out;
    }

    /// The day as the engine would hand it over after the data reached [upTo],
    /// with the night window [on]..[off] (0..0 = none found).
    PreparedDerivationDay prepared(
      double upTo,
      double on,
      double off, {
      Map<InputSignal, List<String>> priority = const {},
      Map<int, int> Function(Map<int, int>)? revisions,
    }) {
      final onSec = on == 0 && off == 0 ? 0 : h(on);
      final offSec = on == 0 && off == 0 ? 0 : h(off);
      final daySub = all.slice(dayStart, h(upTo));
      final revs = revsOf(daySub);
      return PreparedDerivationDay(
        date: label,
        endSec: dayEnd,
        confidence: .8,
        flags: const [],
        sleepJson: const {},
        hypnoStages: const [],
        sleepOnsetSec: onSec,
        sleepOffsetSec: offSec,
        daySub: daySub,
        napSub: daySub,
        sleepSub: offSec > onSec ? all.slice(onSec, offSec) : Substrate.empty,
        priority: priority,
        inputRevs: revisions == null ? revs : revisions(revs),
      );
    }

    Future<void> derive(
      DerivationEngine engine,
      PreparedDerivationDay day,
    ) =>
        engine.debugDerivePreparedDay(day, profile, day.daySub.tsSec.last + 1);

    Future<Map<String, dynamic>> stored() async {
      final row = (await LocalDb.dayResult(label))!;
      final payload =
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
      payload.remove('computed_at');
      return {
        'payload': payload,
        for (final k in ['rhr', 'rmssd', 'readiness', 'partial', 'finalized'])
          k: row[k],
      };
    }

    List<String> ckptLines(List<String> log) => [
          for (final l in log)
            if (l.contains('[perf] checkpoint $label'))
              l.substring(l.indexOf('[perf] checkpoint')),
        ];

    /// Rows before the newest closed 15-minute boundary of a day whose data
    /// ends before [upTo] hours: what a checkpoint written then has folded.
    int foldedAt(double upTo) => ((h(upTo) - 1) ~/ kRevBucketSec) * kRevBucketSec - dayStart;

    setUp(() async {
      await wipe();
      final now = DateTime.now();
      mid = DateTime(now.year, now.month, now.day - 1);
      label = dayLabelOf(mid);
      dayStart = mid.millisecondsSinceEpoch ~/ 1000;
      dayEnd = DateTime(mid.year, mid.month, mid.day + 1).millisecondsSinceEpoch ~/ 1000;
      all = fixture();
    });
    tearDownAll(wipe);

    test('the offset follows the data and the next pass resumes, storing what a full pass stores',
        () async {
      final first = <String>[];
      await derive(DerivationEngine(log: first.add), prepared(3.7, -1, 3.7));
      expect(ckptLines(first), ['[perf] checkpoint $label full none']);
      expect((await LocalDb.dayCheckpoint(label, kAlgoVersion))!.cpRecTs,
          h(3.5), reason: 'newest closed 15-minute boundary');

      // A fresh engine (a headless wake): the night has grown by an hour and a
      // half, so has its window.
      final log = <String>[];
      final resumed = DerivationEngine(log: log.add);
      await derive(resumed, prepared(5.3, -1, 5.3));
      expect(ckptLines(log),
          ['[perf] checkpoint $label resume folded=${foldedAt(3.7)}'],
          reason: 'the window moved; nothing else did');
      final tail = h(5.3) - h(3.5);
      final s = resumed.debugCalculationState(label)!;
      expect(s.hrSamples, lessThanOrEqualTo(2 * tail),
          reason: 'only the tail was folded');
      expect(s.orientationSamples, tail);
      expect(s.stepSamples, tail);
      final got = await stored();
      final cp = (await LocalDb.dayCheckpoint(label, kAlgoVersion))!;
      expect(cp.cpRecTs, h(5.25));

      // The oracle: no checkpoint, a fresh engine, the same day.
      await LocalDb.deleteDayCheckpoints(label);
      final full = DerivationEngine();
      await derive(full, prepared(5.3, -1, 5.3));
      expect(await stored(), equals(got),
          reason: 'resuming changes no stored figure');
      expect((await LocalDb.dayCheckpoint(label, kAlgoVersion))!.state, cp.state,
          reason: 'resumed-then-advanced is byte-identical to folded at once');

    });

    test('a resumed pass prices the tail, not the day (design 3b)', () async {
      // Data to 09:00, then to 09:24 with the wake moved from 06:30 to 06:00:
      // thirty minutes of history change side, and 24 minutes plus the open
      // bucket are new. The day's wake side is 06:30..09:24, 174 minutes.
      await derive(DerivationEngine(), prepared(9.0, -1, 6.5));
      final log = <String>[];
      final resumed = DerivationEngine(log: log.add);
      await derive(resumed, prepared(9.4, -1, 6.0));
      expect(ckptLines(log).single, contains('resume folded=${foldedAt(9.0)}'));
      final tail = h(9.4) - (dayStart + foldedAt(9.0));
      final s = resumed.debugCalculationState(label)!;
      expect(s.minutes, lessThanOrEqualTo(tail ~/ 60 + 30 + 3),
          reason: 'minutes priced: the tail and the thirty that changed side');
      expect(s.motionPoints, lessThanOrEqualTo(tail + 300),
          reason: 'motion points: the tail (the window does not touch them)');
    });

    test('six passes, a fresh engine each, the window moving every time', () async {
      // (data reaches, onset, offset): the night grows, its onset moves earlier
      // and later, the morning pass fixes the wake, the detector retracts the
      // night, then finds it again.
      final steps = <(double, double, double)>[
        (3.7, -1, 3.7),
        (5.3, -1, 5.3),
        (6.8, -1.6, 6.5),
        (7.7, -0.3, 6.5),
        (8.5, 0, 0),
        (9.2, -1, 6.5),
      ];
      var reached = steps.first.$1;
      for (final (i, (upTo, on, off)) in steps.indexed) {
        final log = <String>[];
        await derive(DerivationEngine(log: log.add), prepared(upTo, on, off));
        expect(
          ckptLines(log),
          [
            i == 0
                ? '[perf] checkpoint $label full none'
                : '[perf] checkpoint $label resume folded=${foldedAt(reached)}',
          ],
          reason: 'pass $i, window $on..$off',
        );
        reached = upTo;
      }
      final got = await stored();
      final cp = (await LocalDb.dayCheckpoint(label, kAlgoVersion))!;

      await LocalDb.deleteDayCheckpoints(label);
      await derive(DerivationEngine(), prepared(9.2, -1, 6.5));
      expect(await stored(), equals(got),
          reason: 'the whole chain stores what one full pass stores');
      expect((await LocalDb.dayCheckpoint(label, kAlgoVersion))!.state, cp.state,
          reason: 'and leaves the same state');
    });

    test('only the window is free: every other invalidation row still forces a full pass',
        () async {
      await derive(DerivationEngine(), prepared(3.7, -1, 3.7));
      final base = (await LocalDb.dayCheckpoint(label, kAlgoVersion))!;

      // One pass in a fresh engine from the stored base, the data grown and the
      // window moved at the same time, with [change] applied; the checkpoint
      // line it logs.
      Future<String> outcome(
        Future<void> Function()? change, {
        Profile? who,
        Map<InputSignal, List<String>> priority = const {},
        Map<int, int> Function(Map<int, int>)? revisions,
      }) async {
        await LocalDb.deleteDayCheckpoints(label);
        await LocalDb.putDayCheckpoint(base);
        if (change != null) await change();
        final log = <String>[];
        final day = prepared(5.3, -1, 5.3,
            priority: priority, revisions: revisions);
        await DerivationEngine(log: log.add)
            .debugDerivePreparedDay(day, who ?? profile, day.daySub.tsSec.last + 1);
        final lines = ckptLines(log);
        expect(lines, hasLength(1));
        return lines.single.replaceFirst('[perf] checkpoint $label ', '');
      }

      Future<void> tweakBase(
        Uint8List Function(DayCheckpoint) state,
      ) async {
        final cp = (await LocalDb.dayCheckpoint(label, kAlgoVersion))!;
        await LocalDb.putDayCheckpoint(DayCheckpoint(
          dayId: cp.dayId,
          algoVersion: cp.algoVersion,
          fmt: cp.fmt,
          ctxSig: cp.ctxSig,
          cpRecTs: cp.cpRecTs,
          revVec: cp.revVec,
          state: state(cp),
          nightRef: cp.nightRef,
          computedAt: cp.computedAt,
        ));
      }

      final got = <String, String>{
        'window only': await outcome(null),
        'profile': await outcome(null,
            who: const Profile(
                ageYears: 36,
                weightKg: 75,
                heightCm: 178,
                sex: 'male',
                restingHrManual: 54)),
        'priority': await outcome(null, priority: {
          InputSignal.hr1Hz: ['', 'other-strap'],
        }),
        'earlier second replaced': await outcome(null,
            revisions: (r) => {...r, h(0) ~/ kRevBucketSec: 999}),
        'rows evicted': await outcome(null,
            revisions: (r) => {...r}..remove(h(0) ~/ kRevBucketSec)),
        'layout version': await outcome(() async {
          final db = await LocalDb.instance;
          await db.update('day_checkpoint', {'fmt': kDayCheckpointFmt + 1});
        }),
        'algorithm version': await outcome(() async {
          final db = await LocalDb.instance;
          await db.update('day_checkpoint', {'algo_version': kAlgoVersion - 1});
        }),
        'unreadable blob': await outcome(() => tweakBase((cp) {
              final bad = Uint8List.fromList(cp.state);
              bad[bad.length ~/ 2] ^= 1;
              return bad;
            })),
        'folded a different number of seconds': await outcome(() => tweakBase(
            (cp) => encodeDayResumeState(DayResumeState()
              ..appendTail(
                ts: [for (var i = 0; i < 1799; i++) dayStart + i],
                hr: List.filled(1799, 70),
                ax: List.filled(1799, 0.0),
                ay: List.filled(1799, 0.0),
                az: List.filled(1799, 1.0),
                stepCounter: List.filled(1799, -1),
                sleepOnsetSec: 0,
                sleepOffsetSec: 0,
                age: 35,
                stepModulus: 65536,
              )))),
      };
      expect(got['window only'], 'resume folded=${foldedAt(3.7)}');
      expect(got['profile'], 'full context');
      expect(got['priority'], 'full context');
      expect(got['earlier second replaced'], startsWith('full revised:'));
      expect(got['rows evicted'], startsWith('full lost:'));
      expect(got['layout version'], 'full fmt');
      expect(got['algorithm version'], 'full none');
      expect(got['unreadable blob'], 'full unreadable_state');
      expect(got['folded a different number of seconds'], 'full folded');
      // (A device-family change cannot be staged from the stored day alone, the
      // fixture's family is fixed; the signature test above covers it.)
    });
  });
}
