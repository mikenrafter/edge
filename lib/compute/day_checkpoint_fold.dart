import 'dart:typed_data';

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

/// The packed state after folding the samples that follow the first
/// [alreadyFolded] seconds of the day into [base] (a stored checkpoint blob;
/// null starts the day from its first second, [alreadyFolded] 0). Takes only
/// the new samples, so a resume copies and folds the tail and nothing else.
/// Pure and isolate-safe: plain lists in, bytes out.
///
/// The sleep window does not matter to the result (it is accepted only so a
/// caller that holds it need not drop it): the same days give the same bytes
/// under any window. [bills] replace the base's, which priced an earlier part of
/// the day; null drops them.
///
/// Null when the result cannot be trusted as a continuation: [base] is not a
/// readable blob, it did not fold exactly [alreadyFolded] seconds, or it was
/// folded under another age or counter modulus than the one asked for. The
/// caller then writes nothing and the next pass folds from the start.
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
}) {
  final DayResumeState state;
  if (base == null) {
    if (alreadyFolded != 0) return null;
    state = DayResumeState();
  } else {
    final decoded = decodeDayResumeState(base);
    if (decoded == null || decoded.folded != alreadyFolded) return null;
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
  state.bills = bills;
  return encodeDayResumeState(state);
}
