// The in-memory exposure a "taken daily" setup period stands for.
import '../data/track_model.dart';

/// Answers, for a track and a local day, "what does the wearer's setup history
/// say they took that day?" as a TrackEvent that exists only in memory.
///
/// Reason: the owner can say "daily since March, around 08:00, 50 mg" without
/// logging each dose; learning needs those days as exposures, but timeline,
/// exports and storage must keep showing real logs only. Without this, every
/// done range is an untimed, amountless marker and its nights are unusable.
///
/// Invariants:
/// - never persisted and never shown: [kRangeExposureSource] marks every event;
/// - a real log on the date overrides the period entirely (CLAIM(range-override));
/// - an explicit "none today" and any not-done period carve the date out, even
///   when restored data overlaps a done period (CLAIM(range-carve-out));
/// - the time is the local wall-clock minute on that date (DateTime(y, m, d, h,
///   min)), so a DST day still reads 08:00, not 09:00;
/// - no time and/or no amount stay null (unknown), never 0.
///
/// Errors: none thrown; a date that is not a covered day returns null.
/// Mating parts: learning_worker.dart (feeds nights), TrackEffectEstimator
/// (reads kRangeExposureSource events), track_model.dart (the ranges).
// CLAIM(range-exposure): a done period's day equals one real log at its
// approximate time with its amount and unit, except where the estimator's
// documented approximations apply [tracks_range_exposure_test].
class RangeExposures {
  RangeExposures({
    required Iterable<TrackSetupRange> ranges,
    required Iterable<TrackEvent> realEvents,
    required Iterable<({String trackId, String date})> absences,
  }) {
    for (final range in ranges) {
      switch (range) {
        case DoneRange():
          _done.putIfAbsent(range.trackId, () => []).add(range);
        case NotDoneRange():
          _notDone.putIfAbsent(range.trackId, () => []).add(range);
      }
    }
    for (final event in realEvents) {
      if (event.sourceKind != kRangeExposureSource) {
        _carved.add('${event.trackId}|${event.date}');
      }
    }
    for (final absence in absences) {
      _carved.add('${absence.trackId}|${absence.date}');
    }
  }

  final Map<String, List<DoneRange>> _done = {};
  final Map<String, List<NotDoneRange>> _notDone = {};
  final Set<String> _carved = {};

  static bool _covers(TrackSetupRange range, String date) =>
      range.startDate.compareTo(date) <= 0 && range.endDate.compareTo(date) >= 0;

  static bool _sameIntake(DailyIntake a, DailyIntake b) =>
      a.approxMinute == b.approxMinute &&
      a.amount?.value == b.amount?.value &&
      a.amount?.unit.trim().toLowerCase() == b.amount?.unit.trim().toLowerCase();

  /// The in-memory exposure for [trackId] on local day [date] (`YYYY-MM-DD`),
  /// or null when no done period covers it or the day is carved out.
  // ↳ CLAIM(range-override) ↳ CLAIM(range-carve-out)
  TrackEvent? on(String trackId, String date) {
    if (_carved.contains('$trackId|$date')) return null;
    if (_notDone[trackId]?.any((r) => _covers(r, date)) ?? false) return null;
    final covering = [
      for (final candidate in _done[trackId] ?? const <DoneRange>[])
        if (_covers(candidate, date)) candidate,
    ];
    if (covering.isEmpty) return null;
    final range = covering.first;
    // CLAIM(range-overlap): merged backups can leave several done periods on one
    // date. If they disagree the dose is ambiguous, so the date is UNKNOWN (an
    // exposure whose amount is NaN, which every estimator path reads as an
    // unknown amount), never "the first row" [review P8a-P4;
    // tracks_range_exposure_test]. Agreeing periods are not ambiguous.
    if (covering.any((other) => !_sameIntake(range.intake, other.intake))) {
      return TrackEvent(
        id: 'history:$trackId:$date',
        trackId: trackId,
        date: date,
        amount: double.nan,
        sourceKind: kRangeExposureSource,
      );
    }
    final minute = range.intake.approxMinute;
    final day = DateTime.parse(date);
    return TrackEvent(
      id: 'history:$trackId:$date',
      trackId: trackId,
      date: date,
      atMs: minute == null
          ? null
          // ↳ CLAIM(range-exposure): wall-clock, not midnight + minutes.
          : DateTime(
              day.year,
              day.month,
              day.day,
              minute ~/ 60,
              minute % 60,
            ).millisecondsSinceEpoch,
      amount: range.intake.amount?.value,
      unit: range.intake.amount?.unit,
      sourceKind: kRangeExposureSource,
    );
  }
}
