// day_tail_fold.dart — the resumed day's beat tail folded in a registered
// worker (design 02). Replaces the inline closure `DerivationEngine._foldTail`
// handed to `_runIsolateCancellable`, which was not a registered entry.
//
// The worker is handed the STORED checkpoint blob (the bytes the engine already
// holds: the resumed state was decoded from them and its streaming parts are
// never changed in the calling isolate) and decodes it itself. Nothing O(data)
// is serialised on the calling isolate (AGENTS 3.10; test/day_tail_fold_no_ui_
// serialise_test.dart). The worker folds its own decoded copies, so the caller's
// state is never touched and a fold killed by the dispatcher's timeout leaves
// nothing behind.

import 'dart:typed_data';

import 'day_resume_state.dart';
import '../util/heavy.dart';
import '../util/worker_audit.dart';
import '../util/worker_init.dart';

/// What [foldDayTailHeavy] reads: the stored day checkpoint blob (its streaming
/// RR state and day curves are the states to advance) and the tail they are
/// advanced over.
@sendable
class DayTailInput {
  const DayTailInput({
    required this.checkpoint,
    required this.tailRr,
    required this.tailTs,
    required this.accTs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.onsetSec,
    required this.offsetSec,
  });

  /// The stored `DayCheckpoint.state` the resumed pass was decoded from
  /// (`encodeDayResumeState` bytes), exactly as stored.
  final Uint8List checkpoint;

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
  // Never half read: an unreadable blob is the caller's full pass.
  final state = decodeDayResumeState(input.checkpoint);
  if (state == null) return null;
  final rr = state.rr, curves = state.curves;
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
