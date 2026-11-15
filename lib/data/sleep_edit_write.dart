// The sleep timeline editor's Save (pilot day-timeline spec §3 "Save"): the
// night's window and its naps, in ONE transaction, durable when it returns.
// The recalculation is the caller's, after (responsiveness stage 2's shape:
// the save is acknowledged at the durable write).
//
// Naps are written as plain rows, never through the nap-extension resolver:
// the resolver reads the main sleep from the stored day result, which is the
// window this very Save replaces, so it would merge a nap into the OLD night.
// The editor has already made the blocks non-overlapping; that is checked
// again here before anything is written.

import 'package:sqflite/sqflite.dart';

import '../compute/nap_edits.dart' show manualNapWindowIsValid;
import '../models/activity_suggestion.dart' show ActivityKind;
import 'activity_store.dart';
import 'day_label.dart';
import 'db.dart';
import 'nap_resolution.dart';

/// One nap as the editor leaves it. [fromStart]/[fromSource] describe the
/// stored nap it was dragged from (null: a new nap). [fromSource] null is a
/// detected nap; anything else names its `sleep_nap` row.
class NapWrite {
  const NapWrite({required this.start, required this.end, this.fromStart,
      this.fromEnd, this.fromSource});
  final int start, end;
  final int? fromStart, fromEnd;
  final String? fromSource;
  bool get isNew => fromStart == null;
  bool get moved => fromStart != start || fromEnd != end;
}

class SleepEditPlan {
  const SleepEditPlan({required this.day, this.window, this.naps = const []});

  /// The night (its wake date).
  final String day;

  /// The main sleep (onset, wake), epoch seconds; null: unchanged.
  final (int, int)? window;

  /// Only naps that are new or moved.
  final List<NapWrite> naps;
  bool get isEmpty => window == null && naps.isEmpty;

  /// The days whose results this plan changes (a nap before the main sleep
  /// can belong to the evening before).
  Set<String> get days => {
        if (window != null) day,
        for (final n in naps) ...[
          _dayOf(n.start),
          if (n.fromStart != null) _dayOf(n.fromStart!),
        ],
      };
}

String _dayOf(int ts) => dayLabelOf(DateTime.fromMillisecondsSinceEpoch(ts * 1000));

class SleepEditInvalid implements Exception {
  const SleepEditInvalid(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Checks [plan] and writes it in one transaction. Throws [SleepEditInvalid]
/// (writing nothing) for a window that ends before it starts, a nap outside
/// 5 minutes to 6 hours, or blocks that overlap.
Future<void> writeSleepEdit(Database db, SleepEditPlan plan) async {
  await db.transaction((tx) => writeSleepEditInTransaction(tx, plan));
  if (plan.window != null) await LocalDb.releaseFrozenHeadline(plan.day);
}

/// Joins the Activities batch; all refusal and writes share its transaction.
Future<void> writeSleepEditInTransaction(Transaction tx, SleepEditPlan plan) async {
  final w = plan.window;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  await _validateSleepEdit(tx, plan);
  if (w != null) {
    await tx.insert('sleep_override', {
      'day_id': plan.day,
      'onset_ts': w.$1,
      'offset_ts': w.$2,
      'source': 'manual',
      'created_at': now,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    // A window edit reopens the night, as putSleepOverride does.
    await tx.delete('wake_confirmation', where: 'day_id = ?', whereArgs: [plan.day]);
    await ActivityStore.markDayChanged(tx, plan.day);
  }
  for (final n in plan.naps) {
    if (!n.isNew && n.moved) {
      final fromDay = _dayOf(n.fromStart!);
      final own = await tx.query('sleep_nap',
          where: "day_id = ? AND start_ts = ? AND source != 'rejected'",
          whereArgs: [fromDay, n.fromStart]);
      if (n.fromSource != null && own.isNotEmpty) {
        // The user's (or a confirmed) row moves: the old row goes.
        await tx.delete('sleep_nap',
            where: 'day_id = ? AND start_ts = ?', whereArgs: [fromDay, n.fromStart]);
      } else {
        // A detected nap is suppressed at its old window, never deleted.
        await LocalDb.putNapEdit(dayId: fromDay, startTs: n.fromStart!,
            endTs: n.fromEnd!, source: 'rejected', transaction: tx);
      }
      await ActivityStore.markDayChanged(tx, fromDay);
    }
    if (!n.moved && !n.isNew) continue;
    final day = _dayOf(n.start);
    await tx.insert('sleep_nap', {
      'day_id': day,
      'start_ts': n.start,
      'end_ts': n.end,
      'source': 'manual',
      'created_at': now,
      'payload_json': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    await ActivityStore.supersede(tx, ActivityKind.nap, n.start, n.end);
    await ActivityStore.markDayChanged(tx, day);
  }
}

/// CLAIM(sleep-edit-final-blocks): validate the final intervals under the same
/// transaction as the write, including unchanged and newly inserted blocks
/// [day_timeline_data_safety_test, review R1 S1]. Touching ends are allowed.
Future<void> _validateSleepEdit(DatabaseExecutor tx, SleepEditPlan plan) async {
  final w = plan.window;
  if (w != null && w.$2 <= w.$1) {
    throw const SleepEditInvalid('Wake time must be after the start of sleep.');
  }
  for (final n in plan.naps) {
    if (!manualNapWindowIsValid(n.start, n.end)) {
      throw const SleepEditInvalid('A nap must last between 5 minutes and 6 hours.');
    }
    if (n.fromStart != null && n.fromSource == null) {
      final saved = await tx.query('sleep_nap',
          where: "day_id = ? AND start_ts = ? AND source != 'rejected'",
          whereArgs: [_dayOf(n.fromStart!), n.fromStart]);
      if (saved.isNotEmpty) {
        throw const SleepEditInvalid('This nap changed while you were editing. Open it again.');
      }
    }
    if (n.fromSource != null) {
      final rows = await tx.query('sleep_nap',
          where: 'day_id = ? AND start_ts = ? AND end_ts = ? AND source = ?',
          whereArgs: [_dayOf(n.fromStart!), n.fromStart, n.fromEnd, n.fromSource]);
      if (rows.isEmpty) {
        throw const SleepEditInvalid('This nap changed while you were editing. Open it again.');
      }
    }
  }
  final replacements = [?plan.window,
    for (final n in plan.naps) (n.start, n.end)];
  if (replacements.isEmpty) return;
  final start = replacements.map((w) => w.$1).reduce((a, b) => a < b ? a : b);
  final end = replacements.map((w) => w.$2).reduce((a, b) => a > b ? a : b);
  final stored = await NapResolver.blocks(tx, start, end, includeDetectedNaps: true);
  final spans = [
    for (final b in stored)
      if (!(b.kind == 'main_sleep' && b.day == plan.day && plan.window != null) &&
          !(b.kind == 'nap' && plan.naps.any((n) =>
              n.fromStart == b.startTs && n.fromEnd == b.endTs &&
              _dayOf(n.fromStart!) == b.day)))
        (b.startTs, b.endTs),
    ...replacements,
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  for (var i = 1; i < spans.length; i++) {
    if (spans[i].$1 < spans[i - 1].$2) {
      throw const SleepEditInvalid('Sleep blocks cannot overlap.');
    }
  }
}
