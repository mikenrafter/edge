import 'dart:convert';
import 'dart:typed_data';

import 'package:openstrap_analytics/onehz.dart' as ana;

import 'day_activity_state.dart';
import 'day_checkpoint_policy.dart' show kDayCheckpointFmt;
import 'day_curve_states.dart';
import 'day_rr_state.dart';
import 'minute_bills.dart';
import 'night_resume_part.dart';
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
    DayRrState? rr,
    DayCurveStates? curves,
    this.night,
    this.cardioRows,
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
  /// day's staging window. Either may be absent (or dropped by the decoder when
  /// damaged) without touching the day part; the night then rebuilds and the
  /// rows recompute.
  NightResumePart? night;
  ana.CardioRowCache? cardioRows;

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
void _section(ResumeWriter w, String? json) {
  w.bool_(json != null);
  if (json == null) return;
  final bytes = Uint8List.fromList(utf8.encode(json));
  w.i32(bytes.length);
  w.bytes(bytes, bytes.length);
}

T? _readSection<T>(ResumeReader r, T Function(Map<String, dynamic>) build) {
  if (!r.bool_()) return null;
  final len = r.i32();
  final raw = r.bytes(len);
  try {
    final j = jsonDecode(utf8.decode(raw));
    if (j is! Map<String, dynamic>) return null;
    return build(j);
  } catch (_) {
    // Syntax, version or content damage: this section only.
    return null;
  }
}

/// The rows of [all] whose key's `startSec` lies in [loSec, hiSec) as a new
/// cache (what the engine stores for one day's staging window); [all] is left
/// untouched.
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
  final night = state.night;
  _section(w, night == null ? null : jsonEncode(night.toJson()));
  final rows = state.cardioRows;
  _section(w, rows == null ? null : jsonEncode(rows.toJson()));
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
    // A damaged section is dropped alone; framing damage fails the blob.
    state.night = _readSection(
      r,
      (j) => NightResumePart.fromJson(j),
    );
    state.cardioRows = _readSection(r, (j) => ana.CardioRowCache.fromJson(j));
    if (r.remaining != 0) return null;
    if (state.folded != folded || !state._consistent) return null;
    return state;
  } on FormatException {
    return null;
  }
}
