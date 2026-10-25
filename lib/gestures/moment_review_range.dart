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
import 'package:sqflite/sqflite.dart' show Transaction;

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
/// future (an overlap with [existingNaps] is allowed: it extends). Workout: `validateManualWindow`
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
  // A nap that overlaps a saved nap or sleep is no error: keeping it extends
  // that block to the union (see nap_resolution.dart). [existingNaps] stays for
  // callers; only a workout overlap is still refused.
  return null;
}

/// [validateReviewRange] against what [w] already holds, plus [alsoNaps] /
/// [alsoSpans] (windows written earlier in the same Save). May throw (the reads
/// can fail).
///
/// Nothing existing is exempt, with one exception: when [ownAttempt] is true
/// (Save recorded that it was about to write this window, then was cut off) the
/// row that is EXACTLY this window (same start and end, and for a workout the id
/// derived from its start) is the operation's own and is ignored. A saved entry
/// that merely starts at the same minute is somebody else's and is an overlap.
Future<ManualWindowError?> checkReviewRange(
  ReviewRangeWriter w, {
  required MomentChoice choice,
  required DateTime start,
  required DateTime end,
  required DateTime now,
  List<NapMap> alsoNaps = const [],
  List<SessionSpan> alsoSpans = const [],
  bool ownAttempt = false,
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
        final same = ownAttempt &&
            (n['start'] as num).toInt() == startSec &&
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
          if (!(ownAttempt &&
              sp.id == own &&
              sp.startSec == startSec &&
              sp.endSec == endSec))
            sp
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
  const ReviewRangeWriter({this.repo, this.app, this.transaction,
      this.preparedWorkouts = const {}, this.reopened});

  final Transaction? transaction;
  final Map<int, Map<String, dynamic>> preparedWorkouts;
  final Set<String>? reopened;

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
    // Nap overlaps extend through putNapEdit; only workout overlaps refuse.
    if (transaction != null) return [];
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
  Future<List<SessionSpan>> sessionSpans() async {
    if (transaction == null) return _repo().savedSessionSpans();
    return [for (final row in await transaction!.query('sessions',
        columns: ['id', 'start_ts', 'end_ts']))
      SessionSpan(row['id'] as String, row['start_ts'] as int,
          (row['end_ts'] as int?) ?? DateTime.now().millisecondsSinceEpoch ~/ 1000)];
  }

  /// `putNapEdit(dayId, startSec, endSec, source: 'manual')`. [dayId] is the
  /// START's local day label. Keyed on (day, start): writing it twice is one row.
  Future<void> logNap(
      {required String dayId, required int startSec, required int endSec}) async {
    final r = await LocalDb.putNapEdit(
        dayId: dayId, startTs: startSec, endTs: endSec, source: 'manual', transaction: transaction);
    // A main sleep the nap extended is re-derived like any sleep edit.
    final main = r?.extended.where((b) => b.kind == 'main_sleep').lastOrNull;
    if (main != null) {
      if (transaction != null) { reopened?.add(main.day); }
      else { await app?.sleepOperations.recalculate(main.day); }
    }
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
    if (transaction != null) {
      final row = preparedWorkouts[startSec];
      if (row == null) throw StateError('Range must be scored before commit');
      await LocalDb.putSession(row, transaction: transaction);
      return;
    }
    final r = await _repo()
        .logManualWorkout(startTs: startSec, endTs: endSec, type: type);
    await HealthExporter.exportWorkoutId(r['workout_id'] as String?);
    app?.insightsRevision.value++;
  }
}
