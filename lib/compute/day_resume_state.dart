import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'day_activity_state.dart';
import 'day_checkpoint_policy.dart' show kDayCheckpointFmt;
import 'day_curve_states.dart';
import 'day_rr_state.dart';
import 'minute_bills.dart';
import 'resume_bytes.dart';
import '../util/heavy.dart';

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
    DayRrState? rr,
    DayCurveStates? curves,
    this.nightJson,
    this.cardioRowsJson,
  })  : rr = rr ?? DayRrState(),
        curves = curves ?? DayCurveStates(),
        hrPipeline = hrPipeline ?? DayHrSummary(),
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

  /// The streaming RR half (corrector + irregular screen) and the three day
  /// curves. Folded from the day's BEATS, not its 1 Hz rows, so [folded] does not
  /// count them (see `foldDayCheckpoint`), and none of it depends on the sleep
  /// window.
  final DayRrState rr;
  final DayCurveStates curves;

  /// Optional suffix sections, apart from the window-independent day part: the
  /// night's incremental RR / spectral state and the cardio feature rows of the
  /// day's staging window, each as its UTF-8 JSON text and NOTHING MORE. The UI
  /// isolate moves these bytes between the checkpoint row and the workers and
  /// never parses, merges or encodes them (AGENTS.md 3.10); a worker that
  /// cannot read one rebuilds the night / recomputes the rows, so a damaged
  /// section costs time, never a wrong figure. Either may be absent without
  /// touching the day part.
  Uint8List? nightJson;
  Uint8List? cardioRowsJson;

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

/// `u8 present | (if 1) i32 byteLength | UTF-8 JSON`.
void _section(ResumeWriter w, Uint8List? json) {
  w.bool_(json != null);
  if (json == null) return;
  w.i32(json.length);
  w.bytes(json, json.length);
}

Uint8List? _readSection(ResumeReader r) {
  if (!r.bool_()) return null;
  return r.bytes(r.i32());
}

/// The rows of [all] whose key's `startSec` lies in [loSec, hiSec) as a new
/// cache (what the engine stores for one day's staging window); [all] is left
/// untouched. Heavy (copies and filters the rows); the public name is pinned by
/// the checkpoint tests.
@heavy
ana.CardioRowCache restrictCardioRows(
  ana.CardioRowCache all, {
  required int loSec,
  required int hiSec,
}) =>
    ana.CardioRowCache()
      ..merge(all)
      ..retainWhere((k) => k.startSec >= loSec && k.startSec < hiSec);

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
  state.rr.write(w);
  state.curves.write(w);
  _section(w, state.nightJson);
  _section(w, state.cardioRowsJson);
  final body = w.takeBytes();
  final out = Uint8List(body.length + 4)..setRange(0, body.length, body);
  ByteData.sublistView(out).setUint32(body.length, checksum32(body, body.length));
  return out;
}

/// The number of seconds [bytes] say they folded, read from the 16-byte header
/// alone (magic, layout, folded); null when the header is not a
/// [kDayCheckpointFmt] blob's. O(1): the checksum and the parts are NOT read, so
/// this is a gate's figure, never a licence to use the blob. Whatever decodes
/// the blob for use ([decodeDayResumeState], in a worker for a streamed tail)
/// still finds a damaged one and refuses it.
int? peekDayResumeFolded(Uint8List bytes) {
  if (bytes.length < 4 + 4 + 4 + 8) return null;
  final d = ByteData.sublistView(bytes);
  if (d.getInt32(0) != _magic || d.getInt32(4) != kDayCheckpointFmt) return null;
  return d.getInt64(8);
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
    final hrPipeline = DayHrSummary.read(r);
    final hrActivity = DayHrSummary.read(r);
    final motion = DayMotionSummary.read(r);
    final steps = StepCounterFold.read(r);
    final dyn = DayDynMinutes.read(r);
    final bills = r.bool_() ? MinuteBills.read(r) : null;
    final state = DayResumeState(
      hrPipeline: hrPipeline,
      hrActivity: hrActivity,
      motion: motion,
      steps: steps,
      dyn: dyn,
      bills: bills,
      rr: DayRrState.read(r),
      curves: DayCurveStates.read(r),
    );
    // Framing damage fails the blob; a section's own damage is the worker's to
    // find (see [DayResumeState.nightJson]).
    state.nightJson = _readSection(r);
    state.cardioRowsJson = _readSection(r);
    if (r.remaining != 0) return null;
    if (state.folded != folded || !state._consistent) return null;
    return state;
  } on FormatException {
    return null;
  }
}
