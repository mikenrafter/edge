import 'dart:typed_data';

import 'day_activity_state.dart';
import 'day_checkpoint_policy.dart' show kDayCheckpointFmt;
import 'minute_bills.dart';
import 'resume_bytes.dart';

/// The folded part of a day that a stored `day_checkpoint` resumes: the two
/// heart-rate summaries (each carrying the day's valid seconds, so the wake side
/// can be read under any sleep window), the orientation/presence summary, the
/// per-minute motion buckets and the step-counter triple, all folded over the
/// same first [folded] seconds of the day (every row before the checkpoint's
/// `cp_rec_ts`). None of it depends on the sleep window.
///
/// [bills] is the one part that is not a fold of the rows: the priced wake
/// minutes of the pass that wrote the checkpoint, a cache that lets the next
/// pass price only the minutes that differ (see [MinuteBills]).
///
/// Disposable, like the row that holds it: [decodeDayResumeState] returns null
/// for anything it cannot read exactly (another layout version, a torn or
/// damaged blob, parts that disagree about how much they folded), and null
/// means "fold the day from its first second", never "use what could be read".
class DayResumeState {
  DayResumeState({
    DayHrSummary? hrPipeline,
    DayHrSummary? hrActivity,
    DayMotionSummary? motion,
    StepCounterFold? steps,
    DayDynMinutes? dyn,
    this.bills,
  })  : hrPipeline = hrPipeline ?? DayHrSummary(),
        hrActivity = hrActivity ?? DayHrSummary(),
        motion = motion ?? DayMotionSummary(),
        steps = steps ?? StepCounterFold(),
        dyn = dyn ?? DayDynMinutes();

  /// The summary the pure day pipeline reads, and the one the activity half
  /// reads. They fold the same samples under the same age; each is kept as its
  /// own object because each is synced (and rebuilt on a mismatch) on its own.
  final DayHrSummary hrPipeline;
  final DayHrSummary hrActivity;
  final DayMotionSummary motion;
  final StepCounterFold steps;
  final DayDynMinutes dyn;
  MinuteBills? bills;

  /// Seconds of the day folded so far.
  int get folded => motion.length;

  bool get _consistent =>
      hrPipeline.length == folded &&
      hrActivity.length == folded &&
      steps.length == folded &&
      dyn.length == folded;

  /// Folds the samples that follow the ones already folded. False when a part
  /// was folded under a different age or counter modulus than the one asked
  /// for; the state is then partly folded and must be thrown away. The sleep
  /// window is accepted only to set the window the argument-less readers use;
  /// it never changes what is folded.
  bool appendTail({
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
  }) {
    if (!_consistent) return false;
    if (!(hrPipeline.appendTail(ts, hr,
            sleepOnsetSec: sleepOnsetSec,
            sleepOffsetSec: sleepOffsetSec,
            age: age) &&
        hrActivity.appendTail(ts, hr,
            sleepOnsetSec: sleepOnsetSec,
            sleepOffsetSec: sleepOffsetSec,
            age: age) &&
        motion.appendTail(ts, ax, ay, az,
            sleepOnsetSec: sleepOnsetSec, sleepOffsetSec: sleepOffsetSec) &&
        steps.appendTail(ts, stepCounter, modulus: stepModulus))) {
      return false;
    }
    dyn.appendTail(ts, hr, ax, ay, az);
    return true;
  }
}

const int _magic = 0x4f534443; // 'OSDC'

/// Packs [state] as `magic | fmt | folded | parts | checksum`.
Uint8List encodeDayResumeState(DayResumeState state) {
  final w = ResumeWriter()
    ..i32(_magic)
    ..i32(kDayCheckpointFmt)
    ..i64(state.folded);
  state.hrPipeline.write(w);
  state.hrActivity.write(w);
  state.motion.write(w);
  state.steps.write(w);
  state.dyn.write(w);
  final bills = state.bills;
  w.bool_(bills != null);
  bills?.write(w);
  final body = w.takeBytes();
  final out = Uint8List(body.length + 4)..setRange(0, body.length, body);
  ByteData.sublistView(out).setUint32(body.length, checksum32(body, body.length));
  return out;
}

/// The state [bytes] hold, or null when they are not exactly a
/// [kDayCheckpointFmt] blob this code wrote.
DayResumeState? decodeDayResumeState(Uint8List bytes) {
  try {
    if (bytes.length < 4 + 4 + 4 + 8) return null;
    final end = bytes.length - 4;
    if (ByteData.sublistView(bytes).getUint32(end) != checksum32(bytes, end)) {
      return null;
    }
    final r = ResumeReader(Uint8List.sublistView(bytes, 0, end));
    if (r.i32() != _magic) return null;
    if (r.i32() != kDayCheckpointFmt) return null;
    final folded = r.i64();
    final state = DayResumeState(
      hrPipeline: DayHrSummary.read(r),
      hrActivity: DayHrSummary.read(r),
      motion: DayMotionSummary.read(r),
      steps: StepCounterFold.read(r),
      dyn: DayDynMinutes.read(r),
      bills: null,
    );
    if (r.bool_()) state.bills = MinuteBills.read(r);
    if (r.remaining != 0) return null;
    if (state.folded != folded || !state._consistent) return null;
    return state;
  } on FormatException {
    return null;
  }
}
