// The resumed day's beat tail is folded by ONE registered worker entry
// (design 02, phase 1 RED): `foldDayTailHeavy` in lib/compute/day_tail_fold.dart
// replaces the inline closure `DerivationEngine._foldTail` handed to
// `_runIsolateCancellable` (not a registered entry, so five of its calls became
// new heavy-guard keys when the PRV diagnostics landed, commit 0b428fad).
//
// THE ORACLE is that closure, copied below as [_inline] from the commit above:
//
//     if (!curves.continuesWith(tailTs, accTs)) return null;
//     rr.fold(tailRr, tailTs);
//     if (!curves.fold(tailRr, tailTs, accTs, ax, ay, az, 1 << 60)) return null;
//     -> irregular24hDetailed().toJson(), hrvCurve(), respCurve(),
//        daytimeHrv(onsetSec:, offsetSec:), and the tail it folded
//
// run on this isolate over its own decoded copy of the same checkpoint blob.
// The entry, which gets the states as resume bytes, must answer with the same
// JSON text, byte for byte: the PRV diagnostics (`irregular.diagnostics`) are
// part of it.
//
// What this file pins:
//   * fresh states and a RESUMED (checkpointed) fold both equal the oracle;
//   * the caller's states are never touched, and the entry is deterministic;
//   * the abstentions: a tail that does not continue the state, a state that
//     cannot be trusted, unreadable state bytes -> null (never half read);
//   * CANCELLATION: a fold killed by its timeout leaves nothing behind (the
//     caller's states and the input bytes are what they were, no value comes
//     back), exactly like every other `runCancellableIsolate` worker
//     (test/derive_isolate_lifecycle_test.dart).
//
// The entry's registration, sendability and engine wiring are pinned in
// worker_registry_test, heavy_sendability_helper_test,
// sendable_foldDayTailHeavy_test and day_tail_fold_engine_test.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/day_checkpoint_fold.dart';
import 'package:openstrap_edge/compute/day_checkpoint_policy.dart';
import 'package:openstrap_edge/compute/day_curve_states.dart';
import 'package:openstrap_edge/compute/day_resume_state.dart';
import 'package:openstrap_edge/compute/day_rr_state.dart';
import 'package:openstrap_edge/compute/day_tail_fold.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/resume_bytes.dart';
import 'package:openstrap_edge/util/worker_init.dart';

import 'support/day_stream_fixture.dart';

const _start = 1760000000;
const _boundary = _start + 3 * 3600;
const _inputs = WorkerInputs(nowEpochMs: _start * 1000, zoneId: 'UTC', localeTag: 'en');

Uint8List _rrBytes(DayRrState s) {
  final w = ResumeWriter();
  s.write(w);
  return w.takeBytes();
}

Uint8List _curveBytes(DayCurveStates s) {
  final w = ResumeWriter();
  s.write(w);
  return w.takeBytes();
}

/// The tail a fold is asked to advance over.
typedef _Tail = ({
  List<double> rr,
  List<double> ts,
  List<int> accTs,
  List<double> ax,
  List<double> ay,
  List<double> az,
});

/// The pre-change `_foldTail` closure, verbatim in effect (see the header).
Map<String, Object?>? _inline(
  DayRrState rr,
  DayCurveStates curves,
  _Tail t, {
  required int onsetSec,
  required int offsetSec,
}) {
  if (!curves.continuesWith(t.ts, t.accTs)) return null;
  rr.fold(t.rr, t.ts);
  if (!curves.fold(t.rr, t.ts, t.accTs, t.ax, t.ay, t.az, 1 << 60)) return null;
  return {
    'irregular': rr.irregular24hDetailed().toJson(),
    'hrv': curves.hrvCurve(),
    'resp': curves.respCurve(),
    'daytime': curves.daytimeHrv(onsetSec: onsetSec, offsetSec: offsetSec),
    'tailRr': t.rr,
    'tailTs': t.ts,
  };
}

Map<String, Object?> _fields(DayTailResult r) => {
      'irregular': r.irregular,
      'hrv': r.hrv,
      'resp': r.resp,
      'daytime': r.daytime,
      'tailRr': r.tailRr,
      'tailTs': r.tailTs,
    };

String _text(Map<String, Object?>? m) => jsonEncode(m);

DayTailInput _input(DayRrState rr, DayCurveStates curves, _Tail t,
        {required int onsetSec, required int offsetSec}) =>
    DayTailInput.fromStates(
      rr: rr,
      curves: curves,
      tailRr: t.rr,
      tailTs: t.ts,
      accTs: t.accTs,
      ax: t.ax,
      ay: t.ay,
      az: t.az,
      onsetSec: onsetSec,
      offsetSec: offsetSec,
    );

/// The production dispatcher, the way the engine will call the entry.
Future<DayTailResult?> _viaWorker(DayTailInput input, {Duration? timeout}) =>
    runCancellableIsolate<DayTailResult?>(
      () => foldDayTailHeavy(_inputs, input),
      timeout ?? const Duration(minutes: 2),
      label: 'day-stream test',
    );

void main() {
  // The sleep window the pass reads the curves under (inside the folded span).
  const onset = _start + 1800;
  const offset = _start + 2 * 3600;

  // An irregular burst that crosses the checkpoint boundary, so the diagnostics
  // (flagged windows, an open window) have something to say on both sides.
  final beats = synthBeats(SynthBeats(
    seed: 17,
    startSec: _start,
    seconds: 4 * 3600,
    irregularBurst: (9000, 12600),
  ));
  final accel = synthAccel(23, _start, _start + 4 * 3600 + 60);

  /// A checkpoint blob over the first three hours, built the way the engine
  /// builds it (`foldDayCheckpoint` over the closed rows, the beats up to the
  /// fold edge).
  late final Uint8List blob = () {
    final hi = firstIndexAtOrAfter(accel.tsSec, _boundary);
    final edge = rrFoldEdgeMs(_boundary);
    final rr = <double>[], ts = <double>[];
    for (var i = 0; i < beats.length; i++) {
      if (beats.ts[i] < edge) {
        rr.add(beats.rr[i]);
        ts.add(beats.ts[i]);
      }
    }
    return foldDayCheckpoint(
      base: null,
      alreadyFolded: 0,
      ts: accel.tsSec.sublist(0, hi),
      hr: List.filled(hi, 70),
      ax: accel.ax.sublist(0, hi),
      ay: accel.ay.sublist(0, hi),
      az: accel.az.sublist(0, hi),
      stepCounter: List.filled(hi, -1),
      age: 35,
      stepModulus: null,
      rrMs: rr,
      rrTsMs: ts,
      throughSec: _boundary,
      quietCutG: 0.02,
    )!;
  }();

  /// The tail after that checkpoint, as `_streamDayTail` cuts it.
  _Tail resumedTail(DayResumeState resumed) {
    final tail = rrTailBeats(beats.rr, beats.ts,
        floorMs: resumed.rr.lastTsMs, edgeMs: rrFoldEdgeMs(_boundary));
    final from = resumed.folded;
    return (
      rr: tail.rrMs,
      ts: tail.rrTsMs,
      accTs: accel.tsSec.sublist(from),
      ax: accel.ax.sublist(from),
      ay: accel.ay.sublist(from),
      az: accel.az.sublist(from),
    );
  }

  group('a RESUMED fold (states from a stored checkpoint)', () {
    test('equals the inline fold, byte for byte, PRV diagnostics included',
        () async {
      final mine = decodeDayResumeState(blob)!;
      final tail = resumedTail(mine);
      expect(tail.rr, isNotEmpty, reason: 'fixture: there is a tail to fold');
      expect(mine.rr.beats, greaterThan(1000), reason: 'fixture: a real state');
      final want = _inline(mine.rr, mine.curves, tail,
          onsetSec: onset, offsetSec: offset);
      expect(want, isNotNull, reason: 'fixture: the inline fold continues');

      final theirs = decodeDayResumeState(blob)!;
      final got = await _viaWorker(_input(theirs.rr, theirs.curves, tail,
          onsetSec: onset, offsetSec: offset));
      expect(got, isNotNull);
      expect(_text(_fields(got!)), _text(want));

      // The diagnostics are the evidence behind the verdict, not just a flag.
      final diag = got.irregular['diagnostics'] as Map;
      expect(diag, isNotEmpty);
      expect((diag['beats'] as Map)['rr_raw'], mine.rr.beats,
          reason: 'raw beats counted = every beat folded, checkpoint + tail');
      expect(diag['windows'], isNotNull);
      expect(got.hrv, isNotEmpty);
      expect(got.resp, isNotEmpty);
      expect(got.tailRr, tail.rr);
      expect(got.tailTs, tail.ts);
    });

    test('is the same on a second run (same inputs, same output)', () async {
      final s = decodeDayResumeState(blob)!;
      final tail = resumedTail(s);
      final input =
          _input(s.rr, s.curves, tail, onsetSec: onset, offsetSec: offset);
      final a = await _viaWorker(input);
      final b = await _viaWorker(input);
      expect(a, isNotNull);
      expect(_text(_fields(b!)), _text(_fields(a!)));
    });

    test("never touches the caller's states or the bytes it was given",
        () async {
      final s = decodeDayResumeState(blob)!;
      final tail = resumedTail(s);
      final rrBefore = _rrBytes(s.rr);
      final curvesBefore = _curveBytes(s.curves);
      final input =
          _input(s.rr, s.curves, tail, onsetSec: onset, offsetSec: offset);
      final sentRr = Uint8List.fromList(input.rrState);
      final sentCurves = Uint8List.fromList(input.curvesState);

      expect(await _viaWorker(input), isNotNull);

      expect(_rrBytes(s.rr), rrBefore);
      expect(_curveBytes(s.curves), curvesBefore);
      expect(input.rrState, sentRr);
      expect(input.curvesState, sentCurves);
    });

    test('a tail the state cannot continue abstains (null), as inline does',
        () async {
      final mine = decodeDayResumeState(blob)!;
      // Beats from before the seconds the curves still buffer: `fold` refuses.
      final behind = (
        rr: <double>[800, 810],
        ts: <double>[(_start + 60) * 1000.0, (_start + 61) * 1000.0],
        accTs: <int>[_boundary + 1],
        ax: <double>[0],
        ay: <double>[0],
        az: <double>[1],
      );
      expect(
          _inline(mine.rr, mine.curves, behind, onsetSec: onset, offsetSec: offset),
          isNull,
          reason: 'fixture: the inline fold abstains on this tail');

      final theirs = decodeDayResumeState(blob)!;
      expect(
          await _viaWorker(_input(theirs.rr, theirs.curves, behind,
              onsetSec: onset, offsetSec: offset)),
          isNull);
    });

    test('unreadable state bytes abstain (null), never half read', () async {
      final s = decodeDayResumeState(blob)!;
      final tail = resumedTail(s);
      final ok = _input(s.rr, s.curves, tail, onsetSec: onset, offsetSec: offset);
      DayTailInput with_({Uint8List? rr, Uint8List? curves}) => DayTailInput(
            rrState: rr ?? ok.rrState,
            curvesState: curves ?? ok.curvesState,
            tailRr: ok.tailRr,
            tailTs: ok.tailTs,
            accTs: ok.accTs,
            ax: ok.ax,
            ay: ok.ay,
            az: ok.az,
            onsetSec: ok.onsetSec,
            offsetSec: ok.offsetSec,
          );
      expect(await _viaWorker(with_(rr: Uint8List.fromList([1, 2, 3]))), isNull);
      expect(await _viaWorker(with_(curves: Uint8List(0))), isNull);
      expect(
          await _viaWorker(
              with_(rr: Uint8List.sublistView(ok.rrState, 0, ok.rrState.length - 5))),
          isNull,
          reason: 'a truncated state');
    });
  });

  group('a FRESH fold (empty states, the whole day as the tail)', () {
    test('equals the inline fold, byte for byte', () async {
      final hi = firstIndexAtOrAfter(accel.tsSec, _boundary);
      final tail = (
        rr: beats.rr,
        ts: beats.ts,
        accTs: accel.tsSec.sublist(0, hi),
        ax: accel.ax.sublist(0, hi),
        ay: accel.ay.sublist(0, hi),
        az: accel.az.sublist(0, hi),
      );
      final want = _inline(DayRrState(), DayCurveStates(cut: 0.02), tail,
          onsetSec: onset, offsetSec: offset);
      expect(want, isNotNull);
      final got = await _viaWorker(_input(
          DayRrState(), DayCurveStates(cut: 0.02), tail,
          onsetSec: onset, offsetSec: offset));
      expect(got, isNotNull);
      expect(_text(_fields(got!)), _text(want));
    });

    test('a first beat that reaches back before the first row abstains',
        () async {
      final tail = (
        rr: <double>[800],
        ts: <double>[(_start - 10) * 1000.0],
        accTs: <int>[_start],
        ax: <double>[0],
        ay: <double>[0],
        az: <double>[1],
      );
      expect(
          _inline(DayRrState(), DayCurveStates(cut: 0.02), tail,
              onsetSec: onset, offsetSec: offset),
          isNull,
          reason: 'fixture: `continuesWith` refuses it');
      expect(
          await _viaWorker(_input(DayRrState(), DayCurveStates(cut: 0.02), tail,
              onsetSec: onset, offsetSec: offset)),
          isNull);
    });
  });

  group('CANCELLATION: a fold killed by its timeout leaves nothing behind', () {
    test('TimeoutException, no value, the caller\'s states and bytes unchanged',
        () async {
      final s = decodeDayResumeState(blob)!;
      final tail = resumedTail(s);
      final rrBefore = _rrBytes(s.rr);
      final curvesBefore = _curveBytes(s.curves);
      final input =
          _input(s.rr, s.curves, tail, onsetSec: onset, offsetSec: offset);
      final sentRr = Uint8List.fromList(input.rrState);
      final sentCurves = Uint8List.fromList(input.curvesState);

      // 1 ms cannot cover starting the isolate, decoding two multi-hour states
      // and folding the tail: the fold is killed mid-way, as the engine's
      // per-day timeout kills it on a throttled background wake.
      await expectLater(
        _viaWorker(input, timeout: const Duration(milliseconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(_rrBytes(s.rr), rrBefore,
          reason: 'the worker folded its own copy, never the caller\'s');
      expect(_curveBytes(s.curves), curvesBefore);
      expect(input.rrState, sentRr);
      expect(input.curvesState, sentCurves);

      // And the very same input folds fine afterwards: nothing was consumed.
      final again = await _viaWorker(input);
      final fresh = decodeDayResumeState(blob)!;
      final want = _inline(fresh.rr, fresh.curves, tail,
          onsetSec: onset, offsetSec: offset);
      expect(_text(_fields(again!)), _text(want));
    });
  });
}
