// sleep_editor_write.dart — the editor's single transaction: validate a typed
// plan against the stored rows, apply the spacing rule, write, and queue the
// canonical calculation, all or nothing (spec §5.1-§5.3).
//
// CLAIM(sleep-editor-final-blocks): the plan is checked against the FINAL block
// set including unchanged stored neighbours.
// CLAIM(sleep-editor-draft-generation): a plan captured before a deletion or
// import is refused even when it only adds.

import 'package:sqflite/sqflite.dart';

import 'activity_store.dart';
import 'day_label.dart';
import 'sleep_block_writer.dart';
import 'sleep_draft_fence.dart';
import 'sleep_edit_store.dart';
import 'sleep_editor.dart';
import 'sleep_spacing.dart';
import '../models/activity_suggestion.dart' show ActivityKind;

export 'sleep_edit_codec.dart';

/// One entry while a plan is being applied.
class _Work {
  _Work({
    required this.kind,
    required this.day,
    required this.origKey,
    required this.origStart,
    required this.origEnd,
    required this.start,
    required this.end,
    required this.source,
    required this.row,
    this.isNew = false,
  });

  final SleepBlockKind kind;
  final String day;

  /// Identity before the plan (null for an Add).
  final String? origKey;
  final int origStart, origEnd;
  int start, end;
  final String source;
  final StoredSleepRow? row;
  final bool isNew;
  bool removed = false;
  bool restored = false;
  bool stages = false;
  bool reset = false;

  bool get wasRemoved => row != null && row!.source == 'rejected';
  bool get dirty =>
      isNew ||
      removed != wasRemoved ||
      restored ||
      start != origStart ||
      end != origEnd;
}

class SleepEditorWrite {
  const SleepEditorWrite._();

  /// UI preflight on a read model: the same spacing proposal [apply] would
  /// carry, without a database. Entries on other days enter as context.
  static SleepEditorProposal propose(
      SleepEditorRead read, SleepEditorPlan plan) {
    final stored = <SleepBlock>[
      for (final e in read.entries)
        if (!e.removed)
          SleepBlock(
              kind: e.ref.kind,
              day: e.ref.day,
              startTs: e.startTs,
              endTs: e.endTs),
      ...read.neighbors,
    ];
    final changes = <BlockChange>[];
    for (final c in plan.commands) {
      switch (c) {
        case SetIntervals(:final target, :final startTs, :final endTs):
          if (endTs <= startTs) {
            return SleepProposalInvalid(SleepRefusalReason.invalidInterval,
                target: target);
          }
          changes.add(BlockChange(
            beforeKey: target.startTs == null ? null : target.key,
            after: SleepBlock(
                kind: target.kind,
                day: target.kind == SleepBlockKind.nap
                    ? dayLabelOf(DateTime.fromMillisecondsSinceEpoch(
                        startTs * 1000))
                    : target.day,
                startTs: startTs,
                endTs: endTs),
          ));
        case RemoveBlock(:final target):
          changes.add(BlockChange(beforeKey: target.key));
        default:
          break;
      }
    }
    final merge = SleepSpacing.evaluate(
        stored: stored, changes: changes, editingDay: plan.dayId);
    return merge == null
        ? const SleepProposalClear()
        : SleepProposalMergeRequired(merge);
  }

  static Future<SleepEditorOutcome> apply(SleepEditorPlan plan,
      {required Transaction transaction}) async {
    final tx = transaction;
    // The app-level generation: deleting a day or importing advanced it.
    if (plan.draftGeneration !=
        SleepDraftFence.shared.generationOf(plan.dayId)) {
      return const SleepRefused(SleepRefusalReason.staleDraft);
    }
    // Absence is an explicit revision state: null means "no job row yet".
    for (final e in plan.expectedRevisions.entries) {
      final rows = await tx.query('sleep_edit_job',
          columns: ['revision'], where: 'day_id = ?', whereArgs: [e.key]);
      final current = rows.isEmpty ? null : rows.single['revision'] as int;
      if (current != e.value) {
        return const SleepRefused(SleepRefusalReason.staleEntry);
      }
    }

    final work = <String, _Work>{};
    SleepMergeProposal? approved;
    final stageDays = <String>{};

    Future<SleepEditorOutcome?> bind(SleepBlockRef t, {bool add = false}) async {
      if (add) return null;
      if (work.containsKey(t.key)) return null;
      final StoredSleepRow? row = t.kind == SleepBlockKind.main
          ? await SleepBlockWriter.mainRow(tx, t.day)
          : await SleepBlockWriter.napRow(tx, t.day, t.startTs!);
      if (row == null) {
        if (t.kind == SleepBlockKind.main && t.expectedSource == 'automatic') {
          // An automatic main has no row: its served window is its identity.
          final near = await SleepBlockWriter.liveNear(
              tx, (t.expectedEndTs ?? 0) - 1, t.expectedEndTs ?? 0);
          final b = near
              .where((b) => b.kind == SleepBlockKind.main && b.day == t.day)
              .firstOrNull;
          if (b == null || b.endTs != t.expectedEndTs) {
            return SleepRefused(SleepRefusalReason.staleEntry, target: t);
          }
          work[t.key] = _Work(
              kind: t.kind,
              day: t.day,
              origKey: t.key,
              origStart: b.startTs,
              origEnd: b.endTs,
              start: b.startTs,
              end: b.endTs,
              source: 'automatic',
              row: null);
          return null;
        }
        return SleepRefused(SleepRefusalReason.staleEntry, target: t);
      }
      if ((t.expectedEndTs != null && t.expectedEndTs != row.endTs) ||
          (t.expectedSource != null && t.expectedSource != row.source)) {
        return SleepRefused(SleepRefusalReason.staleEntry, target: t);
      }
      work[t.key] = _Work(
          kind: t.kind,
          day: t.day,
          origKey: t.key,
          origStart: row.startTs,
          origEnd: row.endTs,
          start: row.startTs,
          end: row.endTs,
          source: row.source,
          row: row);
      return null;
    }

    for (final c in plan.commands) {
      switch (c) {
        case SetIntervals(:final target, :final startTs, :final endTs):
          if (endTs <= startTs ||
              (target.kind == SleepBlockKind.nap &&
                  (endTs - startTs < 5 * 60 && target.startTs == null))) {
            return SleepRefused(SleepRefusalReason.invalidInterval,
                target: target);
          }
          if (target.startTs == null && target.kind == SleepBlockKind.nap) {
            final day = dayLabelOf(
                DateTime.fromMillisecondsSinceEpoch(startTs * 1000));
            final key = 'nap:$day:$startTs';
            work[key] = _Work(
                kind: SleepBlockKind.nap,
                day: day,
                origKey: null,
                origStart: startTs,
                origEnd: endTs,
                start: startTs,
                end: endTs,
                source: 'manual',
                row: null,
                isNew: true);
          } else {
            final bad = await bind(target);
            if (bad != null) return bad;
            final w = work[target.key]!;
            if (w.removed) {
              return SleepRefused(SleepRefusalReason.staleEntry, target: target);
            }
            w.start = startTs;
            w.end = endTs;
          }
        case RemoveBlock(:final target):
          // A just-added entry vanishes without a tombstone or a job.
          final added = work.values
              .where((w) =>
                  w.isNew &&
                  w.kind == target.kind &&
                  w.day == target.day &&
                  w.start == target.startTs)
              .firstOrNull;
          if (added != null) {
            work.removeWhere((_, w) => identical(w, added));
            break;
          }
          final bad = await bind(target);
          if (bad != null) return bad;
          work[target.key]!.removed = true;
        case RestoreRemoved(:final target):
          final bad = await bind(target);
          if (bad != null) return bad;
          final w = work[target.key]!;
          if (!w.wasRemoved) {
            return SleepRefused(SleepRefusalReason.staleEntry, target: target);
          }
          w.removed = false;
          w.restored = true;
        case ResetToDetected(:final target):
          final bad = await bind(target);
          if (bad != null) return bad;
          final w = work[target.key]!;
          final h = w.row == null
              ? null
              : (await SleepBlockWriter.historyOf(w.row!)).envelope.detected;
          if (h is! DetectedKnown) {
            return SleepRefused(SleepRefusalReason.missingHistory,
                target: target);
          }
          w.start = h.startTs;
          w.end = h.endTs;
          w.reset = true;
        case ResetBoundary(:final target, :final boundary):
          final bad = await bind(target);
          if (bad != null) return bad;
          final w = work[target.key]!;
          final h = w.row == null
              ? null
              : (await SleepBlockWriter.historyOf(w.row!)).envelope.detected;
          if (h is! DetectedKnown) {
            return SleepRefused(SleepRefusalReason.missingHistory,
                target: target);
          }
          if (boundary == SleepBoundary.start) {
            w.start = h.startTs;
          } else {
            w.end = h.endTs;
          }
          w.reset = true;
        case CalculateStages(:final target):
          final bad = await bind(target);
          if (bad != null) return bad;
          work[target.key]!.stages = true;
          stageDays.add(target.day);
        case MergeBlocks(:final proposal):
          approved = proposal;
        case AddMain() || AddNap() || ConfirmMain() || ClearMain():
          return const SleepRefused(SleepRefusalReason.unsupportedSource);
      }
    }

    final dirty = [for (final w in work.values) if (w.dirty) w];
    if (dirty.isEmpty && stageDays.isEmpty) return const SleepNoChange();

    // The FINAL block set: every live stored block (unchanged neighbours
    // included) against the changed ones, by the shared spacing function.
    final changes = <BlockChange>[
      for (final w in dirty)
        if (w.removed && !w.isNew)
          BlockChange(beforeKey: w.origKey)
        else
          BlockChange(
            beforeKey: w.wasRemoved || w.isNew ? null : w.origKey,
            after: SleepBlock(
              kind: w.kind,
              day: w.kind == SleepBlockKind.nap && w.start != w.origStart
                  ? dayLabelOf(
                      DateTime.fromMillisecondsSinceEpoch(w.start * 1000))
                  : w.day,
              startTs: w.start,
              endTs: w.end,
            ),
          ),
    ];
    final proposal = await SleepBlockWriter.preflight(tx,
        changes: changes, editingDay: plan.dayId);
    SleepMergeProposal? merge;
    if (proposal != null) {
      if (approved != null && approved.authorization == proposal.authorization) {
        merge = proposal;
      } else {
        return SleepRefused(SleepRefusalReason.mergeRequired,
            proposal: proposal);
      }
    }
    final inMerge = <String>{
      if (merge != null) for (final b in merge.participants) b.key,
    };

    final days = <String>{...stageDays};
    for (final w in dirty) {
      if (w.origKey != null && inMerge.contains(w.origKey)) continue;
      // An edit or Add that lies inside the approved union is part of it: the
      // survivor already carries those bounds, so no second row is written.
      if (merge != null &&
          w.start >= merge.startTs &&
          w.end <= merge.endTs) {
        continue;
      }
      final r = await _write(tx, w);
      days.addAll(r);
    }
    if (merge != null) days.addAll(await SleepBlockWriter.applyMerge(tx, merge));
    for (final d in days) {
      await ActivityStore.markDayChanged(tx, d);
      await SleepEditStore.enqueue(tx, d);
    }
    return SleepSaved(days);
  }

  /// Measurements follow the bounds they were measured for: a reset to the
  /// detected window brings the detection's measurements back, a moved entry
  /// carries none.
  static Map<String, Object?> _retainedAfter(_Work w,
      Map<String, Object?> retained, SleepEditEnvelope env, bool boundsChanged) {
    final d = env.detected;
    if (w.reset &&
        d is DetectedKnown &&
        w.start == d.startTs &&
        w.end == d.endTs) {
      return {...d.measures, 'source': 'confirmed'};
    }
    return boundsChanged ? const {} : retained;
  }

  /// Writes one changed entry; returns the ownership days it touches.
  static Future<Set<String>> _write(Transaction tx, _Work w) async {
    final newDay = w.kind == SleepBlockKind.nap
        ? dayLabelOf(DateTime.fromMillisecondsSinceEpoch(w.start * 1000))
        : w.day;
    if (w.kind == SleepBlockKind.main) {
      if (w.removed) {
        await SleepBlockWriter.putMainRow(tx,
            day: w.day,
            onsetTs: w.origStart,
            offsetTs: w.origEnd,
            source: 'rejected');
      } else {
        await SleepBlockWriter.putMainRow(tx,
            day: w.day,
            onsetTs: w.start,
            offsetTs: w.end,
            source: w.reset ? 'confirmed' : 'manual');
      }
      return {w.day};
    }
    // Nap rows.
    if (w.isNew) {
      await SleepBlockWriter.putNapRow(tx,
          day: newDay,
          startTs: w.start,
          endTs: w.end,
          source: 'manual',
          envelope: const SleepEditEnvelope(detected: DetectedAbsent()));
      await ActivityStore.supersede(tx, ActivityKind.nap, w.start, w.end);
      return {newDay};
    }
    if (w.removed) {
      await SleepBlockWriter.tombstoneNap(tx, day: w.day, startTs: w.origStart);
      await ActivityStore.supersede(tx, ActivityKind.nap, w.origStart, w.origEnd);
      return {w.day};
    }
    final row = w.row!;
    final h = await SleepBlockWriter.historyOf(row);
    if (w.restored) {
      final source = h.retained['source'];
      final back = source == 'confirmed' || source == 'legacy'
          ? 'confirmed'
          : 'manual';
      await SleepBlockWriter.putNapRow(tx,
          day: w.day,
          startTs: w.origStart,
          endTs: w.origEnd,
          source: back,
          retained: back == 'confirmed' ? {...h.retained, 'source': 'confirmed'} : const {},
          envelope: h.envelope);
      return {w.day};
    }
    final movedKey = w.start != w.origStart || newDay != w.day;
    var env = h.envelope;
    if (movedKey && env.detected is DetectedKnown) {
      env = SleepBlockWriter.suppressing(
          env, SuppressedInterval(w.day, w.origStart, w.origEnd));
    }
    if (movedKey) {
      await tx.delete('sleep_nap',
          where: 'day_id = ? AND start_ts = ?',
          whereArgs: [w.day, w.origStart]);
    }
    final boundsChanged = w.start != w.origStart || w.end != w.origEnd;
    await SleepBlockWriter.putNapRow(tx,
        day: newDay,
        startTs: w.start,
        endTs: w.end,
        source: w.reset && env.detected is DetectedKnown ? 'confirmed' : 'manual',
        // Measurements belong to the bounds they were measured for.
        retained: _retainedAfter(w, h.retained, env, boundsChanged),
        envelope: env);
    await ActivityStore.supersede(tx, ActivityKind.nap, w.start, w.end);
    return {w.day, newDay};
  }
}
