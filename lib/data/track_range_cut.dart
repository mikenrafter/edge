// Cutting setup periods by day.
import 'day_label.dart';
import 'track_model.dart';

/// Reason: a period's days are only trustworthy together with the overrides
/// (real logs, "none today", not-done periods) of those days. Two paths remove
/// some of those overrides, so they must also remove the days from the period:
/// - deleteDays drops the deleted days' logs and absences: [rangesWithoutDays];
/// - a selected-day export carries only the selected days' overrides:
///   [rangesOnDays].
/// A day that leaves a period is simply unstated (learning reads it as unknown,
/// never as the nominal dose or as a clean control) [review P8a-P2, P8a-P3].
///
/// Invariants: intake and the done/not-done kind are kept; the piece that
/// starts where the original did keeps its id, later pieces are `<id>@<start>`;
/// an ongoing period stays ongoing only in [rangesWithoutDays]; [rangesOnDays]
/// returns bounded pieces. Errors: none; days outside a period are ignored.
/// Mating parts: restore.dart (the two callers), TrackSetupRange.
// CLAIM(range-cut): the cut pieces cover exactly the original days minus the
// removed ones (or exactly the original days among the kept ones)
// [tracks_range_cut_test; tracks_history_schema_test].
List<TrackSetupRange> rangesWithoutDays(
  Iterable<TrackSetupRange> ranges,
  Set<String> days,
) {
  final out = <TrackSetupRange>[];
  for (final range in ranges) {
    final inside = _inside(range, days);
    if (inside.isEmpty) {
      out.add(range);
      continue;
    }
    var cursor = range.startDate;
    for (final day in inside) {
      if (cursor.compareTo(day) < 0) out.add(_piece(range, cursor, _shift(day, -1)));
      cursor = _shift(day, 1);
    }
    if (cursor.compareTo(range.endDate) <= 0) {
      out.add(_piece(range, cursor, range.endDate));
    }
  }
  return out;
}

List<TrackSetupRange> rangesOnDays(
  Iterable<TrackSetupRange> ranges,
  Set<String> days,
) {
  final out = <TrackSetupRange>[];
  for (final range in ranges) {
    final inside = _inside(range, days);
    if (inside.isEmpty) continue;
    var runStart = inside.first, previous = inside.first;
    for (final day in [...inside.skip(1), null]) {
      if (day != null && day == _shift(previous, 1)) {
        previous = day;
        continue;
      }
      out.add(_piece(range, runStart, previous, bounded: true));
      if (day != null) runStart = previous = day;
    }
  }
  return out;
}

List<String> _inside(TrackSetupRange range, Set<String> days) => [
  for (final day in days)
    if (range.startDate.compareTo(day) <= 0 && range.endDate.compareTo(day) >= 0)
      day,
]..sort();

String _shift(String day, int by) {
  final parsed = DateTime.parse(day);
  return dayLabelOf(DateTime(parsed.year, parsed.month, parsed.day + by));
}

TrackSetupRange _piece(
  TrackSetupRange range,
  String start,
  String end, {
  bool bounded = false,
}) {
  final id = start == range.startDate ? range.id : '${range.id}@$start';
  return switch (range) {
    DoneRange() => DoneRange(
      id: id,
      trackId: range.trackId,
      startDate: start,
      untilDate: end == kOngoingEndDate && !bounded ? null : end,
      intake: range.intake,
    ),
    NotDoneRange() => NotDoneRange(
      id: id,
      trackId: range.trackId,
      startDate: start,
      endDate: end,
    ),
  };
}

/// Red-phase stub.
List<TrackSetupRange> mergeAgreeingOverlaps(Iterable<TrackSetupRange> ranges) =>
    throw UnimplementedError('mergeAgreeingOverlaps');
