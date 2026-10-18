// Streaming RR and the day curves in the checkpoint (phase 1, ALL RED), pure
// layer. The day pass today runs `correctRr` + `irregularBeatScreen` over every
// beat of the day on every pass, and `dayHrvCurve` / `dayRespCurve` /
// `_daytimeHrv` over the whole day's RR and accelerometer columns; a resumed
// pass still redoes all of it. This file pins what replaces it, against the
// batch functions as the oracle, at every prefix, with a restart from bytes
// between chunks (a headless wake, a cold start):
//
//  * `DayRrState` (lib/compute/day_rr_state.dart): `RrCorrector` +
//    `IrregularScreenState` (analytics aa67997). Its `irregular24hDetailedHeavy().metric` equals the
//    batch screen AS PERSISTED (`toJson`, which rounds to 6 places) at every
//    prefix, and the state's bytes do not depend on how the day was chunked.
//  * `DayCurveStates` (lib/compute/day_curve_states.dart): the three curves as
//    one resumable state. Bit-identical to `DerivationEngine.dayHrvCurve` /
//    `dayRespCurve` / `daytimeHrv` at every prefix, including the case where the
//    accelerometer is 400 s behind the beats, and `daytimeHrv` under ANY window
//    given at read time (the checkpoint is window-free: the sleep window moves
//    on most passes, see test/day_checkpoint_window_free_test.dart; the research
//    prototype fixed the window at construction and refolded on a change, which
//    would refold on every overnight pass).
//  * the checkpoint blob: `foldDayCheckpoint(rrMs:, rrTsMs:, throughSec:,
//    quietCutG:)` folds the beats and accelerometer rows of the same closed
//    span, `DayResumeState.rr` / `.curves` read back what the batch gives for
//    the whole day, folding in random pieces with a restart from the blob gives
//    the same bytes as folding at once, and the layout version moved.
//
// STUBS this phase adds (all throw `UnimplementedError`, except the ignored
// parameters of `foldDayCheckpoint`): `DayRrState`, `DayCurveStates`,
// `DayResumeState.rr` / `.curves`, and `foldDayCheckpoint`'s four new optional
// parameters. `kDayCheckpointFmt` is still 2.
//
// PERSISTED-OUTPUT FLAG for the owner (kAlgoVersion): `IrregularScreenState`
// keeps running (Welford) sums where the batch screen does two passes, so the
// raw doubles agree only to about 1e-13. The persisted form rounds to six
// places, so it is identical except where a value sits within 1e-13 of a
// rounding boundary (about one in 1e7 per field). This file pins the persisted
// text; it cannot rule that boundary case out.
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_curve_states.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/day_rr_state.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/compute/substrate.dart';

import 'support/day_stream_fixture.dart';

const _start = 1760000000;

// ── helpers ─────────────────────────────────────────────────────────────────

/// The batch screen exactly as `deriveDayBundle` computes it for the day.
ana.Metric<ana.IrregularRhythm> _batchIrregular(Beats b) {
  final c = ana.correctRr(b.rr, rrTsMs: b.ts.isEmpty ? null : b.ts);
  return ana.irregularBeatScreen(
    c.nn,
    nnTimesMs: c.nnTimesMs,
    artifactFraction: (1.0 - c.cleanFraction).clamp(0.0, 1.0),
  );
}

String _irregularText(ana.Metric<ana.IrregularRhythm> m) =>
    jsonEncode(m.toJson((v) => v.toJson()));

DayRrState _restartRr(DayRrState s) {
  final w = ResumeWriter();
  s.write(w);
  final r = ResumeReader(w.takeBytes());
  final back = DayRrState.read(r);
  expect(r.remaining, 0, reason: 'the reader consumed exactly what was written');
  return back;
}

DayCurveStates _restartCurves(DayCurveStates s) {
  final w = ResumeWriter();
  s.write(w);
  final r = ResumeReader(w.takeBytes());
  final back = DayCurveStates.read(r);
  expect(r.remaining, 0, reason: 'the reader consumed exactly what was written');
  return back;
}

Uint8List _bytesOfRr(DayRrState s) {
  final w = ResumeWriter();
  s.write(w);
  return w.takeBytes();
}

/// Wall-clock cut points (seconds) like derive passes: mostly 15 minutes, some
/// odd ones.
List<int> _cutSecs(int first, int last, math.Random r) {
  final cuts = <int>[];
  var t = first;
  while (t < last) {
    t += [60, 300, 900, 900, 900, 1800, 3600][r.nextInt(7)] + r.nextInt(7);
    cuts.add(math.min(t, last + 1));
  }
  return cuts;
}

void main() {
  // ── DayRrState ────────────────────────────────────────────────────────────

  group('DayRrState equals the batch day screen at every prefix', () {
    final days = <String, Beats>{
      'a mixed day': synthBeats(const SynthBeats(
          seed: 7, seconds: 5 * 3600, irregularBurst: (7200, 10800))),
      'a flagged day': synthBeats(const SynthBeats(
          seed: 3,
          seconds: 3 * 3600,
          ectopicPerMin: 0.05,
          missedPerMin: 0,
          extraPerMin: 0,
          noiseRunPerMin: 0,
          gapPerHour: 0,
          irregularBurst: (0, 3 * 3600),
          irregularRangeMs: (600, 1000))),
    };

    for (final e in days.entries) {
      test('${e.key}: beat-sized chunks through the first 700 beats, then '
          'wall-clock passes, restarting from bytes each time', () {
        final day = e.value;
        var st = DayRrState();
        var at = 0;
        var sawAbsent = false, sawPresent = false;
        final r = math.Random(11);
        void check(String why) {
          final got = st.irregular24hDetailedHeavy().metric;
          final want = _batchIrregular(
              Beats(day.rr.sublist(0, at), day.ts.sublist(0, at)));
          expect(_irregularText(got), _irregularText(want), reason: why);
          if (want.present) {
            sawPresent = true;
          } else {
            sawAbsent = true;
          }
        }

        // The thin region: every chunk of a few beats.
        while (at < 700) {
          final n = math.min(day.length, at + 1 + r.nextInt(25));
          st.fold(day.rr.sublist(at, n), day.ts.sublist(at, n));
          at = n;
          st = _restartRr(st);
          check('after $at beats');
        }
        // Then passes by the wall clock.
        final cuts = _cutSecs(day.ts[at] ~/ 1000, day.ts.last ~/ 1000, r);
        for (final t in cuts) {
          var n = at;
          while (n < day.length && day.ts[n] < t * 1000.0) {
            n++;
          }
          st.fold(day.rr.sublist(at, n), day.ts.sublist(at, n));
          at = n;
          st = _restartRr(st);
          expect(st.beats, at);
          check('pass to $t');
        }
        expect(at, day.length);
        expect(sawAbsent, isTrue, reason: 'fixture: the early prefixes abstain');
        expect(sawPresent, isTrue, reason: 'fixture: the day reaches a screen');
        if (e.key == 'a flagged day') {
          expect(st.irregular24hDetailedHeavy().metric.value!.flag, isTrue,
              reason: 'fixture: sustained irregular rhythm flags');
        }
      });
    }

    test('no beats, one beat, two beats: the same abstention as the batch', () {
      final day = days['a mixed day']!;
      final st = DayRrState();
      expect(_irregularText(st.irregular24hDetailedHeavy().metric),
          _irregularText(_batchIrregular(Beats([], []))));
      for (var n = 1; n <= 3; n++) {
        st.fold(day.rr.sublist(n - 1, n), day.ts.sublist(n - 1, n));
        expect(_irregularText(st.irregular24hDetailedHeavy().metric),
            _irregularText(_batchIrregular(
                Beats(day.rr.sublist(0, n), day.ts.sublist(0, n)))),
            reason: '$n beats');
      }
    });

    test('an empty fold changes nothing', () {
      final day = days['a mixed day']!;
      final st = DayRrState()..fold(day.rr.sublist(0, 900), day.ts.sublist(0, 900));
      final before = _bytesOfRr(st);
      st.fold(const [], const []);
      expect(_bytesOfRr(st), before);
    });

    test('the bytes do not depend on how the day was chunked', () {
      final day = days['a mixed day']!;
      final once = DayRrState()..fold(day.rr, day.ts);
      for (final seed in [1, 2, 3, 4]) {
        final r = math.Random(seed);
        var st = DayRrState();
        var at = 0;
        while (at < day.length) {
          final n = math.min(day.length, at + 1 + r.nextInt(r.nextBool() ? 40 : 4000));
          st.fold(day.rr.sublist(at, n), day.ts.sublist(at, n));
          at = n;
          st = _restartRr(st);
        }
        expect(_bytesOfRr(st), _bytesOfRr(once), reason: 'seed $seed');
        expect(_irregularText(st.irregular24hDetailedHeavy().metric), _irregularText(once.irregular24hDetailedHeavy().metric));
      }
    });

    test('the state is bounded: a day of beats does not grow the blob with the day',
        () {
      final day = days['a mixed day']!;
      final half = DayRrState()..fold(day.rr.sublist(0, day.length ~/ 2),
          day.ts.sublist(0, day.length ~/ 2));
      final whole = DayRrState()..fold(day.rr, day.ts);
      expect(_bytesOfRr(whole).length,
          lessThan(_bytesOfRr(half).length * 2 + 4096),
          reason: 'the unsettled window and running sums, not the series');
      expect(_bytesOfRr(whole).length, lessThan(day.length * 2),
          reason: 'under two bytes per beat of a day that has ${day.length}');
    });
  });

  // ── DayCurveStates ────────────────────────────────────────────────────────

  group('DayCurveStates equal the batch curves at every prefix', () {
    final beats = synthBeats(const SynthBeats(seed: 7, seconds: 5 * 3600));
    final accel = synthAccel(5, _start - 2, _start + 5 * 3600 + 400);
    final first = beats.ts.first ~/ 1000, last = beats.ts.last ~/ 1000;

    // The onset/offset windows asked at read time, a different one each chunk.
    final windows = <(int, int)>[
      (0, 0),
      (_start + 1800, _start + 1800 + 7 * 3600),
      (_start + 3600, _start + 7200),
      (_start - 100, _start + 900),
      (_start + 9000, _start + 8000), // offset before onset: no window
    ];

    test('fixture: the batch curves are not empty (the pins mean something)', () {
      final s = substrateOf(beats, accel);
      expect(DerivationEngine.dayHrvCurve(s), isNotEmpty);
      expect(DerivationEngine.dayRespCurve(s), isNotEmpty);
      expect(DerivationEngine.daytimeHrv(s, 0, 0)['n_buckets'], greaterThan(5));
      final win = DerivationEngine.daytimeHrv(s, windows[1].$1, windows[1].$2);
      expect(win['n_buckets'],
          lessThan(DerivationEngine.daytimeHrv(s, 0, 0)['n_buckets'] as int),
          reason: 'the window really removes buckets');
    });

    for (final lag in [0, 400]) {
      test('wall-time chunks, accelerometer $lag s behind the beats, restart '
          'each chunk, every window', () {
        final r = math.Random(3 + lag);
        var st = DayCurveStates();
        var rrAt = 0, accAt = 0;
        var maxPending = 0;
        final cuts = _cutSecs(first, last + 3, r);
        for (var k = 0; k < cuts.length; k++) {
          final t = cuts[k];
          var rrTo = rrAt, accTo = accAt;
          while (rrTo < beats.length && beats.ts[rrTo] < t * 1000.0) {
            rrTo++;
          }
          while (accTo < accel.length && accel.tsSec[accTo] < t - lag) {
            accTo++;
          }
          st.fold(
            beats.rr.sublist(rrAt, rrTo),
            beats.ts.sublist(rrAt, rrTo),
            accel.tsSec.sublist(accAt, accTo),
            accel.ax.sublist(accAt, accTo),
            accel.ay.sublist(accAt, accTo),
            accel.az.sublist(accAt, accTo),
            t - lag,
          );
          rrAt = rrTo;
          accAt = accTo;
          st = _restartCurves(st);
          maxPending = math.max(maxPending, st.pending);
          if (k % 4 == 0 || k == cuts.length - 1) {
            final acc = Accel(accel.tsSec.sublist(0, accTo), accel.ax.sublist(0, accTo),
                accel.ay.sublist(0, accTo), accel.az.sublist(0, accTo));
            // The HRV curve reads no accelerometer: every beat delivered.
            expect(
                curveText(st.hrvCurve()),
                curveText(DerivationEngine.dayHrvCurve(substrateOf(
                    Beats(beats.rr.sublist(0, rrTo), beats.ts.sublist(0, rrTo)),
                    acc))),
                reason: 'hrv curve, chunk $k');
            // The two accelerometer-dependent curves see what was delivered AND
            // processed: a beat whose accelerometer second is not reported yet
            // is held back from both, and is not in the oracle's prefix.
            final processed = rrTo - st.pending;
            final sub = substrateOf(
                Beats(beats.rr.sublist(0, processed), beats.ts.sublist(0, processed)),
                acc);
            expect(curveText(st.respCurve()),
                curveText(DerivationEngine.dayRespCurve(sub)),
                reason: 'resp curve, chunk $k');
            final (on, off) = windows[k % windows.length];
            expect(jsonEncode(st.daytimeHrv(onsetSec: on, offsetSec: off)),
                jsonEncode(DerivationEngine.daytimeHrv(sub, on, off)),
                reason: 'daytime HRV, chunk $k, window $on..$off');
          }
        }
        if (lag > 0) {
          expect(maxPending, greaterThan(0),
              reason: 'with the accelerometer behind, beats wait');
        }
        // The accelerometer catches up: nothing is pending, and the state reads
        // as the batch over the whole run under every window (a moving night).
        st.fold(const [], const [], accel.tsSec.sublist(accAt), accel.ax.sublist(accAt),
            accel.ay.sublist(accAt), accel.az.sublist(accAt), last + 10000);
        expect(st.pending, 0);
        final sub = substrateOf(beats, accel);
        expect(curveText(st.hrvCurve()), curveText(DerivationEngine.dayHrvCurve(sub)));
        expect(curveText(st.respCurve()), curveText(DerivationEngine.dayRespCurve(sub)));
        for (final (on, off) in windows) {
          expect(jsonEncode(st.daytimeHrv(onsetSec: on, offsetSec: off)),
              jsonEncode(DerivationEngine.daytimeHrv(sub, on, off)),
              reason: 'final state, window $on..$off');
        }
      });
    }

    test('the whole day folded at once equals the batch, whatever the window',
        () {
      final st = DayCurveStates()
        ..fold(beats.rr, beats.ts, accel.tsSec, accel.ax, accel.ay, accel.az,
            last + 10);
      final sub = substrateOf(beats, accel);
      expect(st.pending, 0);
      expect(curveText(st.hrvCurve()), curveText(DerivationEngine.dayHrvCurve(sub)));
      expect(curveText(st.respCurve()), curveText(DerivationEngine.dayRespCurve(sub)));
      for (final (on, off) in windows) {
        expect(jsonEncode(st.daytimeHrv(onsetSec: on, offsetSec: off)),
            jsonEncode(DerivationEngine.daytimeHrv(sub, on, off)),
            reason: 'window $on..$off');
      }
    });

    test('a window that moves between passes does not need a refold: the same '
        'blob read under the next pass\'s window equals a batch under it', () {
      final st = DayCurveStates()
        ..fold(beats.rr, beats.ts, accel.tsSec, accel.ax, accel.ay, accel.az,
            last + 10);
      final sub = substrateOf(beats, accel);
      final blob = _restartCurves(st);
      // The night grows by half an hour per pass, its onset slips.
      for (var i = 0; i < 6; i++) {
        final on = _start + 600 * i, off = _start + 3600 + 1800 * i;
        expect(jsonEncode(blob.daytimeHrv(onsetSec: on, offsetSec: off)),
            jsonEncode(DerivationEngine.daytimeHrv(sub, on, off)),
            reason: 'pass $i');
      }
    });

    test('thin input: fewer than 10 gated beats gives no HRV curve, fewer than '
        '60 no breathing curve', () {
      final few = Beats(beats.rr.sublist(0, 9), beats.ts.sublist(0, 9));
      final st = DayCurveStates()
        ..fold(few.rr, few.ts, accel.tsSec.sublist(0, 400), accel.ax.sublist(0, 400),
            accel.ay.sublist(0, 400), accel.az.sublist(0, 400), _start + 400);
      expect(st.hrvCurve(), isEmpty);
      expect(st.respCurve(), isEmpty);
      final sub = substrateOf(few, Accel(accel.tsSec.sublist(0, 400),
          accel.ax.sublist(0, 400), accel.ay.sublist(0, 400), accel.az.sublist(0, 400)));
      expect(jsonEncode(st.daytimeHrv(onsetSec: 0, offsetSec: 0)),
          jsonEncode(DerivationEngine.daytimeHrv(sub, 0, 0)));
    });

    test('timestamps that step backwards (a counter reset) fold as the batch '
        'reads them', () {
      final b = synthBeats(const SynthBeats(
          seed: 81, seconds: 6 * 3600, backwardsPerHour: 10));
      final r = math.Random(2);
      var st = DayCurveStates();
      var at = 0;
      while (at < b.length) {
        final n = math.min(b.length, at + 1 + r.nextInt(r.nextBool() ? 10 : 3000));
        st.fold(b.rr.sublist(at, n), b.ts.sublist(at, n), const [], const [],
            const [], const [], 0);
        at = n;
        st = _restartCurves(st);
      }
      // No accelerometer was given: only the HRV curve is a function of beats
      // alone, and it must equal the batch on beats alone.
      final sub = substrateOf(b, Accel(const [], const [], const [], const []));
      expect(curveText(st.hrvCurve()), curveText(DerivationEngine.dayHrvCurve(sub)));
    });
  });

  // ── the checkpoint blob ───────────────────────────────────────────────────

  group('the checkpoint carries the RR state and the curves', () {
    final beatsAll = synthBeats(const SynthBeats(
        seed: 21, seconds: 3 * 3600, irregularBurst: (1800, 5400)));
    final accel = synthAccel(9, _start - 2, _start + 3 * 3600 + 120);
    final ts = accel.tsSec;
    final hr = [for (var i = 0; i < ts.length; i++) 60 + (i ~/ 90) % 40];

    /// Folds the first [total] rows of the day in pieces of [sizes] rows (the
    /// boundary of a piece being the first second of the next), restarting from
    /// the blob between pieces. The beats of a piece are those of its seconds.
    Uint8List fold(Iterable<int> sizes, {int? total}) {
      final end = total ?? ts.length;
      final it = sizes.iterator;
      Uint8List? blob;
      var at = 0, lowSec = 0;
      while (at < end) {
        final n = it.moveNext() ? it.current : end;
        final hi = math.min(end, at + n);
        final through = hi == ts.length ? ts.last + 1 : ts[hi];
        final rr = beatsAll.between(lowSec, through);
        blob = foldDayCheckpoint(
          base: blob,
          alreadyFolded: at,
          ts: ts.sublist(at, hi),
          hr: hr.sublist(at, hi),
          ax: accel.ax.sublist(at, hi),
          ay: accel.ay.sublist(at, hi),
          az: accel.az.sublist(at, hi),
          stepCounter: List.filled(hi - at, -1),
          age: 35,
          stepModulus: null,
          rrMs: rr.rr,
          rrTsMs: rr.ts,
          throughSec: through,
          quietCutG: 0.02,
        );
        expect(blob, isNotNull, reason: 'piece [$at,$hi) folded');
        at = hi;
        lowSec = through;
      }
      return blob!;
    }

    /// The day as the batch reads it, up to row [rows].
    (Beats, Substrate) batchDay(int rows) {
      final through = rows == ts.length ? ts.last + 1 : ts[rows];
      final cut = rows;
      final a = Accel(ts.sublist(0, cut), accel.ax.sublist(0, cut),
          accel.ay.sublist(0, cut), accel.az.sublist(0, cut));
      final b = beatsAll.between(0, through);
      return (b, substrateOf(b, a));
    }

    test('the layout version moved: a blob written before RR was carried is '
        'not read', () {
      expect(kDayCheckpointFmt, greaterThan(2));
    });

    test('folding in random pieces, restarting from the blob, gives the same '
        'bytes as folding at once', () {
      final once = fold([ts.length]);
      expect(decodeDayResumeState(once)!.rr.beats,
          beatsAll.between(0, ts.last + 1).length,
          reason: 'the blob carries the day\'s beats (not just equal bytes)');
      for (final seed in [1, 2, 3, 4, 5]) {
        final r = math.Random(seed);
        final sizes = [
          for (var i = 0; i < 4000; i++) 1 + r.nextInt(r.nextBool() ? 40 : 3000),
        ];
        expect(fold(sizes), once, reason: 'seed $seed');
      }
    });

    test('the decoded state reads what the batch gives for the whole day', () {
      final state = decodeDayResumeState(fold([2500, 1, 4000, 777]))!;
      expect(state.folded, ts.length);
      final (b, sub) = batchDay(ts.length);
      expect(_irregularText(state.rr.irregular24hDetailedHeavy().metric), _irregularText(_batchIrregular(b)));
      expect(curveText(state.curves.hrvCurve()),
          curveText(DerivationEngine.dayHrvCurve(sub)));
      expect(curveText(state.curves.respCurve()),
          curveText(DerivationEngine.dayRespCurve(sub)));
      for (final (on, off) in [(0, 0), (_start + 1000, _start + 6000)]) {
        expect(jsonEncode(state.curves.daytimeHrv(onsetSec: on, offsetSec: off)),
            jsonEncode(DerivationEngine.daytimeHrv(sub, on, off)),
            reason: 'window $on..$off');
      }
    });

    test('a checkpoint reads like the batch over the day up to its seam, '
        'seams everywhere', () {
      for (final rows in [1, 899, 900, 5400, 5401, ts.length - 1]) {
        final state = decodeDayResumeState(fold([rows], total: rows))!;
        expect(state.folded, rows);
        final (b, sub) = batchDay(rows);
        expect(_irregularText(state.rr.irregular24hDetailedHeavy().metric), _irregularText(_batchIrregular(b)),
            reason: 'rows $rows');
        expect(curveText(state.curves.hrvCurve()),
            curveText(DerivationEngine.dayHrvCurve(sub)),
            reason: 'rows $rows');
        expect(curveText(state.curves.respCurve()),
            curveText(DerivationEngine.dayRespCurve(sub)),
            reason: 'rows $rows');
      }
    });

    test('a refused append (another age) is still refused with RR in the blob',
        () {
      final base = fold([5000], total: 5000);
      expect(decodeDayResumeState(base)!.rr.beats, greaterThan(0));
      Uint8List? more({int? age = 35}) => foldDayCheckpoint(
            base: base,
            alreadyFolded: 5000,
            ts: [ts[5000]],
            hr: [70],
            ax: [accel.ax[5000]],
            ay: [accel.ay[5000]],
            az: [accel.az[5000]],
            stepCounter: const [-1],
            age: age,
            stepModulus: null,
            rrMs: const [],
            rrTsMs: const [],
            throughSec: ts[5000] + 1,
            quietCutG: 0.02,
          );
      expect(more(), isNotNull);
      expect(more(age: 36), isNull);
    });
  });
}
