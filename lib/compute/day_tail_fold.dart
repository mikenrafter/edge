// day_tail_fold.dart — the resumed day's beat tail folded in a registered
// worker (design 02). Replaces the inline closure `DerivationEngine._foldTail`
// handed to `_runIsolateCancellable`, which was not a registered entry.
//
// The states cross as their resume bytes (`ResumeWriter`), so the worker folds
// its own decoded copies: the caller's objects are never touched and a fold
// killed by the dispatcher's timeout leaves nothing behind.

import 'dart:typed_data';

import 'day_curve_states.dart';
import 'resume_bytes.dart';
import 'day_rr_state.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';

/// What [foldDayTailHeavy] reads: the checkpoint's streaming states as their
/// resume bytes (the worker advances its own decoded copies; the caller's
/// objects are never touched) and the tail the states are advanced over.
@sendable
class DayTailInput {
  const DayTailInput({
    required this.rrState,
    required this.curvesState,
    required this.tailRr,
    required this.tailTs,
    required this.accTs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.onsetSec,
    required this.offsetSec,
  });

  /// Packs [rr] and [curves] (their resume bytes) with the tail.
  factory DayTailInput.fromStates({
    required DayRrState rr,
    required DayCurveStates curves,
    required List<double> tailRr,
    required List<double> tailTs,
    required List<int> accTs,
    required List<double> ax,
    required List<double> ay,
    required List<double> az,
    required int onsetSec,
    required int offsetSec,
  }) {
    final rrW = ResumeWriter();
    rr.write(rrW);
    final curvesW = ResumeWriter();
    curves.write(curvesW);
    return DayTailInput(
      rrState: rrW.takeBytes(),
      curvesState: curvesW.takeBytes(),
      tailRr: tailRr,
      tailTs: tailTs,
      accTs: accTs,
      ax: ax,
      ay: ay,
      az: az,
      onsetSec: onsetSec,
      offsetSec: offsetSec,
    );
  }

  /// `DayRrState.write` bytes.
  final Uint8List rrState;

  /// `DayCurveStates.write` bytes.
  final Uint8List curvesState;

  /// Beats after the checkpoint: interval (ms) and stamp (epoch ms).
  final List<double> tailRr;
  final List<double> tailTs;

  /// Accelerometer rows after the checkpoint: second and g.
  final List<int> accTs;
  final List<double> ax;
  final List<double> ay;
  final List<double> az;

  /// The pass's sleep window (seconds), applied when the curves are read.
  final int onsetSec;
  final int offsetSec;
}

/// What a resumed pass takes from the advanced states: the 24/7 irregular-rhythm
/// envelope (with its PRV diagnostics) as persisted, the three day curves read
/// under the pass's sleep window, and the tail they were advanced over.
@SendableShape('persisted JSON envelopes: Map<String, dynamic> irregular '
    'screen and daytime HRV, List<Map<String, num>> curves')
class DayTailResult {
  const DayTailResult({
    required this.irregular,
    required this.hrv,
    required this.resp,
    required this.daytime,
    required this.tailRr,
    required this.tailTs,
  });

  final Map<String, dynamic> irregular;
  final List<Map<String, num>> hrv;
  final List<Map<String, num>> resp;
  final Map<String, dynamic> daytime;
  final List<double> tailRr;
  final List<double> tailTs;
}

/// WORKER ENTRY: advances the states over the tail and reads them. Null when
/// the tail does not continue the state, the curves can no longer be trusted as
/// a continuation, or a state's bytes are unreadable (the caller then reads the
/// day's whole beats).
@heavy
DayTailResult? foldDayTailHeavy(WorkerInputs inputs, DayTailInput input) {
  WorkerInit.ensure(inputs);
  assertWorker();
  WorkerAudit.entered('foldDayTailHeavy');
  final DayRrState rr;
  final DayCurveStates curves;
  try {
    rr = DayRrState.read(ResumeReader(input.rrState));
    curves = DayCurveStates.read(ResumeReader(input.curvesState));
  } on FormatException {
    // Never half read: the caller reads the day's whole beats instead.
    return null;
  }
  final (tailRr, tailTs, accTs) = (input.tailRr, input.tailTs, input.accTs);
  // The first beats of a day, whose rows went with the pass before.
  if (!curves.continuesWith(tailTs, accTs)) return null;
  rr.fold(tailRr, tailTs);
  // Every accelerometer row of the day is in: nothing waits.
  if (!curves.fold(tailRr, tailTs, accTs, input.ax, input.ay, input.az, 1 << 60)) {
    return null;
  }
  return DayTailResult(
    irregular: rr.irregular24hDetailedHeavy().toJson(),
    hrv: curves.hrvCurve(),
    resp: curves.respCurve(),
    daytime: curves.daytimeHrv(
        onsetSec: input.onsetSec, offsetSec: input.offsetSec),
    tailRr: tailRr,
    tailTs: tailTs,
  );
}
