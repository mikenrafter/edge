// Discarded review items and their Restore (pilot day-timeline spec §4,
// "Discarded items: never deleted ... offer filters with Restore").
//
// DATA-SAFETY CHECK (spec §4, done before the UI work), per detected type:
//
//  • Activity suggestions, every kind (nap, workout, meal, track): Discard
//    sets status 'discarded' and keeps the row. Reversible: ActivityStore.
//    restore sets it back to pending. Its one side effect, a track question's
//    `track_absence` row, was not attributable (other flows write absences),
//    so the Discard now records in the row's own details_json
//    ([kDiscardAbsence]) that it wrote it, and Restore removes only that. No
//    schema change was needed: every type already had a durable state.
//  • Marked moments: Discard stores a `moment_label` row with a NULL label (a
//    skip) and nothing else. Reversible: deleting that row returns the moment
//    to the follow-up list. A moment with a real label is never touched.
//  • Assumed glasses: Discard ("Remove") subtracts exactly the row's ml from
//    the day's water and keeps the row as a 'removed' tombstone WITH its ml.
//    Reversible: the ml goes back (clamped to the field's max, and the row
//    keeps what was really added, so a later Remove takes back exactly that)
//    and the row is 'assumed' again. A tombstone with ml 0 is a glass that
//    never added anything (the day was full): not a discard, not restorable.
//  • Pairs (ranges) have no Discard. Naps the detector found and the user
//    removed on the Naps screen keep their 'rejected' sleep_nap row (Naps'
//    own Restore); they are not Activities items.
//
// Every restore runs inside the caller's transaction and returns false,
// writing nothing, when the item is no longer discarded.

import 'package:sqflite/sqflite.dart';

import 'journal_fields.dart' show kJournalFieldsByKey;
import '../models/activity_suggestion.dart';
import 'activity_store.dart';
import 'assumed_water.dart';

const String _waterField = 'water_ml';

/// A marked moment answered with Discard: no label.
class SkippedMoment {
  const SkippedMoment(this.date, this.hhmm);
  final String date, hhmm;
  String get key => '$date $hhmm';
}

/// A glass the user removed, with what it had added.
class RemovedGlass {
  const RemovedGlass(this.date, this.atMin, this.ml);
  final String date;
  final int atMin;
  final double ml;
}

/// Everything discarded on [day].
class DiscardedItems {
  const DiscardedItems({this.activities = const [], this.moments = const [],
      this.glasses = const []});
  final List<ActivitySuggestion> activities;
  final List<SkippedMoment> moments;
  final List<RemovedGlass> glasses;
  bool get isEmpty => activities.isEmpty && moments.isEmpty && glasses.isEmpty;
  int get count => activities.length + moments.length + glasses.length;
}

Future<DiscardedItems> discardedOn(DatabaseExecutor db, String day) async =>
    DiscardedItems(
      activities: await ActivityStore.discardedOn(db, day),
      moments: [
        for (final r in await db.query('moment_label',
            columns: ['date', 'hhmm'],
            where: 'date = ? AND label IS NULL', whereArgs: [day],
            orderBy: 'hhmm ASC'))
          SkippedMoment(r['date'] as String, r['hhmm'] as String),
      ],
      glasses: [
        for (final r in await db.query('assumed_water',
            where: 'date = ? AND state = ? AND ml > 0',
            whereArgs: [day, AssumedState.removed.name], orderBy: 'at_min ASC'))
          RemovedGlass(r['date'] as String, (r['at_min'] as num).toInt(),
              (r['ml'] as num).toDouble()),
      ],
    );

/// The skip goes; the moment is unanswered again. A labelled answer is never
/// deleted here.
Future<bool> restoreSkippedMoment(Transaction tx, SkippedMoment m) async =>
    await tx.delete('moment_label',
        where: 'date = ? AND hhmm = ? AND label IS NULL',
        whereArgs: [m.date, m.hhmm]) > 0;

/// The glass's ml back on the day (clamped to the field's max), the row
/// 'assumed' again with what was really added.
Future<bool> restoreRemovedGlass(Transaction tx, RemovedGlass g) async {
  final rows = await tx.query('assumed_water',
      where: 'date = ? AND at_min = ?', whereArgs: [g.date, g.atMin], limit: 1);
  if (rows.isEmpty || rows.single['state'] != AssumedState.removed.name) return false;
  final ml = (rows.single['ml'] as num).toDouble();
  if (ml <= 0) return false;
  final max = kJournalFieldsByKey[_waterField]!.max;
  final cur = await tx.query('journal_metric',
      where: 'date = ? AND field = ?', whereArgs: [g.date, _waterField], limit: 1);
  final oldVal = cur.isEmpty ? 0.0 : (cur.single['value'] as num).toDouble();
  final oldAt = cur.isEmpty ? null : (cur.single['at_min'] as num?)?.toInt();
  final newVal = (oldVal + ml).clamp(0.0, max).toDouble();
  final added = newVal - oldVal;
  if (added > 0) {
    await tx.insert('journal_metric', {
      'date': g.date,
      'field': _waterField,
      'value': newVal,
      'at_min': oldAt != null && oldAt > g.atMin ? oldAt : g.atMin,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  await tx.update('assumed_water',
      {'state': AssumedState.assumed.name, 'ml': added > 0 ? added : 0.0},
      where: 'date = ? AND at_min = ?', whereArgs: [g.date, g.atMin]);
  return true;
}
