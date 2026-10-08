// moment_review_range.dart — validating and writing a REVIEW RANGE. RED stubs.
//
// Nap range  -> the existing nap edit (`LocalDb.putNapEdit`, source 'manual' on
//               the START's local day, then the day is re-analysed). Exactly the
//               two marked minutes: never a wider sleep window.
// Workout    -> the existing `LocalRepository.logManualWorkout` (type 'other':
//               a marked moment does not say which sport).

import '../compute/manual_session.dart';
import '../compute/nap_edits.dart';
import 'moment_follow_ups.dart';

/// Null when [start]..[end] can be written as a [choice] range.
///
/// Nap: end after start, 5 min..6 h (`manualNapWindowIsValid`), not in the
/// future, no overlap with [existingNaps]. Workout: `validateManualWindow`
/// against [existingSpans]. Only Nap and Workout are range choices
/// (ArgumentError otherwise). Pure; wall-clock DateTimes in, epoch seconds out.
ManualWindowError? validateReviewRange({
  required MomentChoice choice,
  required DateTime start,
  required DateTime end,
  required DateTime now,
  List<NapMap> existingNaps = const [],
  List<SessionSpan> existingSpans = const [],
}) =>
    throw UnimplementedError('RED stub');

/// Where a range lands. Subclassed by fakes in tests; the real one talks to
/// `LocalDb` / `LocalRepository` / `AppState`.
class ReviewRangeWriter {
  const ReviewRangeWriter();

  /// The merged naps (detected + edits) of the local day [dayId].
  Future<List<NapMap>> existingNaps(String dayId) =>
      throw UnimplementedError('RED stub');

  /// Every saved session window.
  Future<List<SessionSpan>> sessionSpans() =>
      throw UnimplementedError('RED stub');

  /// `putNapEdit(dayId, startSec, endSec, source: 'manual')`, then re-analyse
  /// the day. [dayId] is the START's local day label.
  Future<void> logNap(
          {required String dayId,
          required int startSec,
          required int endSec}) =>
      throw UnimplementedError('RED stub');

  /// `logManualWorkout(startTs, endTs, type: 'other')`, then the Health export.
  Future<void> logWorkout({required int startSec, required int endSec}) =>
      throw UnimplementedError('RED stub');
}
