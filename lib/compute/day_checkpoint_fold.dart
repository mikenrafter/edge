import 'dart:typed_data';

import 'day_curve_states.dart';
import 'day_resume_state.dart';
import 'minute_bills.dart';

/// Index of the first element of the ascending [sorted] that is >= [value]
/// (`sorted.length` when there is none).
int firstIndexAtOrAfter(List<int> sorted, int value) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid] < value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}

/// The beats of the day that follow a checkpoint, from the beats [rrMs] /
/// [rrTsMs] read after it (those of the rows from a little before its boundary).
///
/// The day's beat axis is the running maximum of the beats' own times (a held
/// beat sits no earlier than the one before it), and that maximum began at the
/// day's first beat, long before these. [floorMs], the last beat the checkpoint
/// folded, carries it in: every time is raised to at least it. The tail is then
/// every beat at or after [edgeMs] (what the checkpoint did not fold), and only
/// those, so a beat the state already holds is not folded twice.
({List<double> rrMs, List<double> rrTsMs}) rrTailBeats(
  List<double> rrMs,
  List<double> rrTsMs, {
  required double? floorMs,
  required double edgeMs,
}) {
  final rr = <double>[], ts = <double>[];
  var run = floorMs ?? double.negativeInfinity;
  for (var i = 0; i < rrMs.length; i++) {
    if (rrTsMs[i] > run) run = rrTsMs[i];
    if (run >= edgeMs) {
      rr.add(rrMs[i]);
      ts.add(run);
    }
  }
  return (rrMs: rr, rrTsMs: ts);
}

/// The packed state after folding the samples that follow the first
/// [alreadyFolded] seconds of the day into [base] (a stored checkpoint blob;
/// null starts the day from its first second, [alreadyFolded] 0). Takes only
/// the new samples, so a resume copies and folds the tail and nothing else.
/// Pure and isolate-safe: plain lists in, bytes out.
///
/// The beats reach the streaming RR state and the three day curves, which the
/// rows' accelerometer seconds also feed (see `DayRrState`, `DayCurveStates`).
///
/// The sleep window does not matter to the result (it is accepted only so a
/// caller that holds it need not drop it): the same days give the same bytes
/// under any window. [bills] replace the base's, which priced an earlier part of
/// the day; null drops them.
///
/// Null when the result cannot be trusted as a continuation: [base] is not a
/// readable blob, it did not fold exactly [alreadyFolded] seconds, or it was
/// folded under another age or counter modulus than the one asked for. The
/// caller then writes nothing and the next pass folds from the start. Also null
/// for beats that cannot be folded (unequal lists, a non-finite interval, one
/// older than the seconds the curves still buffer) and for a base folded under
/// another quiet cut.
Uint8List? foldDayCheckpoint({
  required Uint8List? base,
  required int alreadyFolded,
  required List<int> ts,
  required List<int> hr,
  required List<double> ax,
  required List<double> ay,
  required List<double> az,
  required List<int> stepCounter,
  int sleepOnsetSec = 0,
  int sleepOffsetSec = 0,
  required int? age,
  required int? stepModulus,
  MinuteBills? bills,
  // The day's RR beats this call adds ([rrMs] ms, [rrTsMs] epoch ms, in beat
  // order, each beat once across the calls that build one blob). [throughSec] is
  // the second every accelerometer row below which has now been given (the
  // checkpoint boundary; a beat at or past it waits for its second), and
  // [quietCutG] the family's quiet-second cut for the day curves. Without
  // [throughSec] the rows given are taken as everything up to their last second.
  List<double> rrMs = const [],
  List<double> rrTsMs = const [],
  int? throughSec,
  double quietCutG = 0.02,
}) {
  final DayResumeState state;
  if (base == null) {
    if (alreadyFolded != 0) return null;
    state = DayResumeState(curves: DayCurveStates(cut: quietCutG));
  } else {
    final decoded = decodeDayResumeState(base);
    if (decoded == null || decoded.folded != alreadyFolded) return null;
    if (decoded.curves.cut != quietCutG) return null;
    state = decoded;
  }
  final ok = state.appendTail(
    ts: ts,
    hr: hr,
    ax: ax,
    ay: ay,
    az: az,
    stepCounter: stepCounter,
    sleepOnsetSec: sleepOnsetSec,
    sleepOffsetSec: sleepOffsetSec,
    age: age,
    stepModulus: stepModulus,
  );
  if (!ok) return null;
  if (rrMs.length != rrTsMs.length) return null;
  // A resumed fold of the first beats of a day: the rows those beats read were
  // given to an earlier call that kept none of them (see `DayCurveStates`).
  if (alreadyFolded > 0 && !state.curves.continuesWith(rrTsMs, ts)) return null;
  try {
    state.rr.fold(rrMs, rrTsMs);
  } on ArgumentError {
    return null;
  } on StateError {
    return null;
  }
  final through = throughSec ?? (ts.isEmpty ? 0 : ts.last + 1);
  if (!state.curves.fold(rrMs, rrTsMs, ts, ax, ay, az, through)) return null;
  state.bills = bills;
  return encodeDayResumeState(state);
}
