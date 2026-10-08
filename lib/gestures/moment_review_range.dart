// moment_review_range.dart — validating and writing a REVIEW RANGE.
//
// Nap range  -> the existing nap edit (`LocalDb.putNapEdit`, source 'manual',
//               filed under the START's local day — the same way the Naps screen
//               files a nap it logs, and the way the derivation attributes a nap
//               that spans midnight: by where it starts), then the day is
//               re-analysed once. Exactly the two marked minutes: never a wider
//               sleep window.
// Workout    -> the existing `LocalRepository.logManualWorkout` (type 'other'
//               unless the wearer picked one in the pairing sheet).

import 'package:flutter/foundation.dart';

import '../compute/manual_session.dart';
import '../compute/nap_edits.dart';
import '../data/day_label.dart' show dayLabelOf;
import '../data/db.dart';
import '../data/local_repository.dart';
import '../health/health_export.dart';
import '../state/app_state.dart';
import 'moment_follow_ups.dart';
import 'moment_review_queue.dart' show isRangeChoice;

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
}) {
  if (!isRangeChoice(choice)) {
    throw ArgumentError.value(choice, 'choice', 'cannot form a range');
  }
  final s = start.millisecondsSinceEpoch ~/ 1000;
  final e = end.millisecondsSinceEpoch ~/ 1000;
  final nowSec = now.millisecondsSinceEpoch ~/ 1000;
  if (choice == MomentChoice.workout) {
    return validateManualWindow(
        startSec: s, endSec: e, nowSec: nowSec, existing: existingSpans);
  }
  if (e <= s) return ManualWindowError.endNotAfterStart;
  if (e - s < kMinManualNapSec) return ManualWindowError.tooShort;
  if (e - s > kMaxManualNapSec) return ManualWindowError.tooLong;
  if (e > nowSec) return ManualWindowError.inFuture;
  if (napOverlapsExisting(s, e, existingNaps)) {
    return ManualWindowError.overlapsExisting;
  }
  return null;
}

/// [validateReviewRange] against what [w] already holds, plus [alsoNaps] /
/// [alsoSpans] (windows written earlier in the same Save). The window itself is
/// never an obstacle: a retry after a failed label finds what the first try
/// wrote and rewrites the same row. May throw (the reads can fail).
Future<ManualWindowError?> checkReviewRange(
  ReviewRangeWriter w, {
  required MomentChoice choice,
  required DateTime start,
  required DateTime end,
  required DateTime now,
  List<NapMap> alsoNaps = const [],
  List<SessionSpan> alsoSpans = const [],
}) async {
  final startSec = start.millisecondsSinceEpoch ~/ 1000;
  final endSec = end.millisecondsSinceEpoch ~/ 1000;
  final naps = <NapMap>[];
  final spans = <SessionSpan>[];
  if (choice == MomentChoice.nap) {
    // The nap's own day and the day before it (a nap that began last night)
    // through the day it ends on.
    final first = DateTime(start.year, start.month, start.day - 1);
    for (var d = first;
        !d.isAfter(DateTime(end.year, end.month, end.day));
        d = DateTime(d.year, d.month, d.day + 1)) {
      for (final n in await w.existingNaps(dayLabelOf(d))) {
        final same = (n['start'] as num).toInt() == startSec &&
            (n['end'] as num).toInt() == endSec;
        if (!same) naps.add(n);
      }
    }
    naps.addAll(alsoNaps);
  } else {
    final own = manualSessionId(startSec);
    spans
      ..addAll([
        for (final sp in await w.sessionSpans())
          if (sp.id != own) sp
      ])
      ..addAll(alsoSpans);
  }
  return validateReviewRange(
      choice: choice,
      start: start,
      end: end,
      now: now,
      existingNaps: naps,
      existingSpans: spans);
}

/// Where a range lands. Subclassed by fakes in tests; the real one talks to
/// `LocalDb` / `LocalRepository` / `AppState`.
class ReviewRangeWriter {
  const ReviewRangeWriter({this.repo, this.app});

  /// The read/write seam (`getDayNaps`, `savedSessionSpans`, `logManualWorkout`).
  final LocalRepository? repo;

  /// Re-derives after nap edits and bumps the insights revision after a
  /// workout. Null: neither happens (the edit still applies on the next
  /// analysis).
  final AppState? app;

  LocalRepository _repo() =>
      repo ?? (throw StateError('no repository to write a range with'));

  /// The merged naps (detected + edits) of the local day [dayId], plus the
  /// manual nap edits stored for it (a day not yet re-analysed shows them only
  /// here).
  Future<List<NapMap>> existingNaps(String dayId) async {
    final d = await _repo().getDayNaps(dayId);
    final out = <NapMap>[
      for (final n in (d['naps'] as List?) ?? const [])
        if (n is Map && n['start'] is num && n['end'] is num)
          {'start': (n['start'] as num).toInt(), 'end': (n['end'] as num).toInt()},
      for (final r in await LocalDb.napEdits(dayId))
        if (r['source'] == 'manual')
          {
            'start': (r['start_ts'] as num).toInt(),
            'end': (r['end_ts'] as num).toInt()
          },
    ];
    return out;
  }

  /// Every saved session window.
  Future<List<SessionSpan>> sessionSpans() => _repo().savedSessionSpans();

  /// `putNapEdit(dayId, startSec, endSec, source: 'manual')`. [dayId] is the
  /// START's local day label. Keyed on (day, start): writing it twice is one row.
  Future<void> logNap(
      {required String dayId, required int startSec, required int endSec}) {
    return LocalDb.putNapEdit(
        dayId: dayId, startTs: startSec, endTs: endSec, source: 'manual');
  }

  /// Re-analyse the nap days once after a batch of [logNap]s. A failure here
  /// leaves the edits stored; they apply on the next analysis.
  Future<void> finishNaps() async {
    try {
      await app?.reanalyzeForNapEdit();
    } catch (e) {
      debugPrint('[moment-review] nap re-analysis failed: $e');
    }
  }

  /// `logManualWorkout(startTs, endTs, type)`, then the Health export. The row
  /// id comes from the start second, so writing it twice is one row.
  Future<void> logWorkout(
      {required int startSec, required int endSec, String type = 'other'}) async {
    final r = await _repo()
        .logManualWorkout(startTs: startSec, endTs: endSec, type: type);
    await HealthExporter.exportWorkoutId(r['workout_id'] as String?);
    app?.insightsRevision.value++;
  }
}
