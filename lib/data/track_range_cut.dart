// Cutting setup periods by day.
import 'package:uuid/uuid.dart';
import 'day_label.dart';
import 'track_model.dart';

/// Where new setup-period ids come from (an interface, not a callback, so the
/// heavy-calc guard can resolve the call). Production uses [RandomRangeIds];
/// tests inject a counter.
abstract interface class RangeIdSource {
  String next();
}

/// UUID v4 ids: unique without looking at any other row.
final class RandomRangeIds implements RangeIdSource {
  const RandomRangeIds();
  @override
  String next() => const Uuid().v4();
}

/// Reason: a period's days are only trustworthy together with the overrides
/// (real logs, "none today", not-done periods) of those days. Two paths remove
/// some of those overrides, so they must also remove the days from the period:
/// - deleteDays drops the deleted days' logs and absences: [rangesWithoutDays];
/// - a selected-day export carries only the selected days' overrides:
///   [rangesOnDays].
/// A day that leaves a period is simply unstated (learning reads it as unknown,
/// never as the nominal dose or as a clean control) [review P8a-P2, P8a-P3].
///
/// Invariants: intake and the done/not-done kind are kept; every new piece has a
/// fresh id and an uncut period keeps its own;
/// an ongoing period stays ongoing only in [rangesWithoutDays]; [rangesOnDays]
/// returns bounded pieces. Errors: none; days outside a period are ignored.
/// Mating parts: restore.dart (the two callers), TrackSetupRange.
// CLAIM(range-cut): the cut pieces cover exactly the original days minus the
// removed ones (or exactly the original days among the kept ones)
// [tracks_range_cut_test; tracks_history_schema_test].
List<TrackSetupRange> rangesWithoutDays(
  Iterable<TrackSetupRange> ranges,
  Set<String> days, {
  required RangeIdSource newId,
}) {
  final out = <TrackSetupRange>[];
  for (final range in ranges) {
    final inside = _inside(range, days);
    if (inside.isEmpty) {
      out.add(range);
      continue;
    }
    var cursor = range.startDate;
    for (final day in inside) {
      if (cursor.compareTo(day) < 0) out.add(_piece(range, cursor, _shift(day, -1), newId));
      cursor = _shift(day, 1);
    }
    if (cursor.compareTo(range.endDate) <= 0) {
      out.add(_piece(range, cursor, range.endDate, newId));
    }
  }
  return out;
}

List<TrackSetupRange> rangesOnDays(
  Iterable<TrackSetupRange> ranges,
  Set<String> days, {
  required RangeIdSource newId,
}) {
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
      out.add(_piece(range, runStart, previous, newId, bounded: true));
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

// CLAIM(range-fresh-id) [review R4-1, R4-2]: a newly created piece always gets
// a FRESH id from [newId] (a UUID in production). Ids are never derived from
// another id (`<id>@...`, `<id>~...`): a derived id can equal one the wearer's
// edit or an earlier restore already made, and the insert then replaces or
// ignores a row. Restore is by coverage, so ids carry no cross-device meaning.
// A period that is not cut keeps its own id (it is not a new piece).
TrackSetupRange _piece(
  TrackSetupRange range,
  String start,
  String end,
  RangeIdSource newId, {
  bool bounded = false,
}) {
  final id = newId.next();
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

/// Folds periods that overlap AND agree (same kind, same intake, compared like
/// RangeExposures) into one: the earliest-starting id survives with the union
/// of coverage. Conflicting overlaps (different intake, or done vs not-done) are
/// kept untouched, and adjacent periods are left alone.
/// Reason: restoring a day export beside the full period leaves an agreeing
/// piece; the editor re-saves what history() returns, and overlap validation
/// would reject its own rows [review R2-3]. Read-time only: nothing is rewritten
/// until the wearer saves.
// CLAIM(range-overlap) [tracks_range_cut_test; tracks_setup_range_test]
List<TrackSetupRange> mergeAgreeingOverlaps(Iterable<TrackSetupRange> ranges) {
  final sorted = [...ranges]
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  final out = <TrackSetupRange>[];
  for (final range in sorted) {
    final index = out.lastIndexWhere(
      (kept) =>
          kept.endDate.compareTo(range.startDate) >= 0 && _agree(kept, range),
    );
    if (index < 0) {
      out.add(range);
      continue;
    }
    final kept = out[index];
    if (range.endDate.compareTo(kept.endDate) > 0) {
      out[index] = switch (kept) {
        DoneRange() => DoneRange(
          id: kept.id,
          trackId: kept.trackId,
          startDate: kept.startDate,
          untilDate: range is DoneRange && range.ongoing ? null : range.endDate,
          intake: kept.intake,
        ),
        NotDoneRange() => NotDoneRange(
          id: kept.id,
          trackId: kept.trackId,
          startDate: kept.startDate,
          endDate: range.endDate,
        ),
      };
    }
  }
  return out;
}

bool _agree(TrackSetupRange a, TrackSetupRange b) => switch ((a, b)) {
  (DoneRange a, DoneRange b) =>
    a.intake.approxMinute == b.intake.approxMinute &&
        a.intake.amount?.value == b.intake.amount?.value &&
        a.intake.amount?.unit.trim().toLowerCase() ==
            b.intake.amount?.unit.trim().toLowerCase(),
  (NotDoneRange(), NotDoneRange()) => true,
  _ => false,
};

/// What a restore adds, by COVERAGE and never by id: for each incoming period,
/// the days an agreeing local period (same track, kind and intake) already
/// covers are no-ops; the uncovered days become new rows. Conflicting local
/// rows are not coverage, so both are kept and learning abstains on those dates
/// (CLAIM(range-overlap)). Every added row gets a fresh id (CLAIM(range-fresh-id)).
/// Local rows are never touched, so an import cannot shrink coverage,
/// and a second import of the same file adds nothing.
/// Reason: REPLACE-by-id let an old export overwrite a longer period the editor
/// had saved under the same id [review R3-1]; ids carry no meaning across
/// devices or exports, coverage does.
// CLAIM(range-restore-coverage) [tracks_range_cut_test; tracks_history_schema_test]
List<TrackSetupRange> rangesToAdd({
  required Iterable<TrackSetupRange> local,
  required Iterable<TrackSetupRange> incoming,
  required RangeIdSource newId,
}) {
  final known = [...local];
  final added = <TrackSetupRange>[];
  final ordered = [...incoming]
    ..sort((a, b) => a.startDate.compareTo(b.startDate));
  for (final range in ordered) {
    var gaps = [(range.startDate, range.endDate)];
    for (final other in known) {
      if (other.trackId != range.trackId || !_agree(other, range)) continue;
      gaps = [
        for (final gap in gaps)
          ..._without(gap, other.startDate, other.endDate),
      ];
    }
    for (final (start, end) in gaps) {
      final id = newId.next();
      final piece = switch (range) {
        DoneRange() => DoneRange(
          id: id,
          trackId: range.trackId,
          startDate: start,
          untilDate: end == kOngoingEndDate ? null : end,
          intake: range.intake,
        ),
        NotDoneRange() => NotDoneRange(
          id: id,
          trackId: range.trackId,
          startDate: start,
          endDate: end,
        ),
      };
      known.add(piece);
      added.add(piece);
    }
  }
  return added;
}

// [gap] minus [coverStart, coverEnd]; an end that is shifted is never the
// ongoing sentinel (it is strictly before the gap's end).
List<(String, String)> _without((String, String) gap, String coverStart, String coverEnd) {
  final (start, end) = gap;
  if (coverEnd.compareTo(start) < 0 || coverStart.compareTo(end) > 0) {
    return [gap];
  }
  return [
    if (coverStart.compareTo(start) > 0) (start, _shift(coverStart, -1)),
    if (coverEnd.compareTo(end) < 0) (_shift(coverEnd, 1), end),
  ];
}
