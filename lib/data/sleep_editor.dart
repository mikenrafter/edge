// sleep_editor.dart — the checked types of the sleep editor's write contract.
//
// Phase 2 of the structural Sleep work (spec §5.1-§5.3). Invalid states are
// unrepresentable here: a command names an entry by identity (never by list
// index), history is a sealed state (known / explicitly absent / unavailable),
// and every outcome is one of four named results, never a bool plus a log.
//
// CLAIM(sleep-editor-receipt): a committed receipt stays Saved even when later
// export, refresh or calculation fails; that remaining work is reported apart.

import 'package:flutter/foundation.dart';

import '../models/activity_suggestion.dart' show ActivityReviewException;

/// Two sleep blocks must be at least this far apart (owner, 2026-11-17).
/// Exactly this is allowed; anything shorter needs an explicit Merge.
const int kMinSleepGapSec = 30 * 60;

enum SleepBlockKind { main, nap }

/// One live sleep block: the main night owned by [day], or a nap row.
@immutable
class SleepBlock {
  const SleepBlock({
    required this.kind,
    required this.day,
    required this.startTs,
    required this.endTs,
    this.id,
    this.revision = 0,
    this.ownerRule,
    this.provenance = SleepEntryProvenance.automatic,
  });

  final String? id;
  final int revision;
  /// Null for an automatic window that has not been stored as an assertion.
  final int? ownerRule;
  final SleepEntryProvenance provenance;
  String get ownerDay => day;
  final SleepBlockKind kind;

  /// The `day_id` that owns the block (the wake date for a main sleep).
  final String day;
  final int startTs, endTs;

  /// Stored blocks keep their id after a move; automatic windows use a day key.
  String get key => id ?? (kind == SleepBlockKind.main
      ? 'main:$day'
      : 'nap:$day:$startTs');

  @override
  bool operator ==(Object other) =>
      other is SleepBlock &&
      other.id == id &&
      other.revision == revision &&
      other.ownerRule == ownerRule &&
      other.provenance == provenance &&
      other.kind == kind &&
      other.day == day &&
      other.startTs == startTs &&
      other.endTs == endTs;

  @override
  int get hashCode => Object.hash(id, revision, ownerRule, provenance, kind, day, startTs, endTs);

  @override
  String toString() => '$key..$endTs';
}

/// What the person approved when they chose Merge: the union range and every
/// participating block. A write that finds a different set refuses and asks
/// again, so a block that arrived meanwhile is never absorbed silently.
@immutable
class SleepMergeAuthorization {
  const SleepMergeAuthorization({
    required this.startTs,
    required this.endTs,
    required this.keys,
  });

  final int startTs, endTs;
  final Set<String> keys;

  @override
  bool operator ==(Object other) =>
      other is SleepMergeAuthorization &&
      other.startTs == startTs &&
      other.endTs == endTs &&
      setEquals(other.keys, keys);

  @override
  int get hashCode => Object.hash(startTs, endTs, Object.hashAllUnordered(keys));
}

/// "This change would merge these sleep blocks": the survivor, everything it
/// absorbs and the resulting range. UI preflight and commit refusal use this
/// same type, so neither copies the gap arithmetic.
@immutable
class SleepMergeProposal {
  const SleepMergeProposal({
    required this.survivor,
    required this.absorbed,
    required this.startTs,
    required this.endTs,
  });

  final SleepBlock survivor;
  final List<SleepBlock> absorbed;
  final int startTs, endTs;

  Iterable<SleepBlock> get participants => [survivor, ...absorbed];

  /// Every ownership date a confirmed merge touches.
  Set<String> get affectedDays => {for (final b in participants) b.day};

  SleepMergeAuthorization get authorization => SleepMergeAuthorization(
        startTs: startTs,
        endTs: endTs,
        keys: {for (final b in participants) b.key},
      );
}

/// Thrown by a table writer that was not given an explicit merge approval for
/// a change that creates or narrows a gap under [kMinSleepGapSec]. Nothing was
/// written. It is an [ActivityReviewException] so screens that only show the
/// message keep working.
class SleepMergeRequiredException extends ActivityReviewException {
  SleepMergeRequiredException(this.proposal, {this.suggestionId})
      : super('This change would merge these sleep blocks.');

  final SleepMergeProposal proposal;
  final String? suggestionId;
}

// ── Detection history and retained stages ─────────────────────────────────────────

/// What the app knows of the detection an entry started from.
sealed class DetectedHistory {
  const DetectedHistory();
}

/// The detector's original window, captured before the first accepted edit.
@immutable
class DetectedKnown extends DetectedHistory {
  const DetectedKnown({
    required this.startTs,
    required this.endTs,
    required this.sourceDay,
    this.measures = const {},
  });
  final int startTs, endTs;
  final String sourceDay;

  /// Retained measurement keys of the detection (asleep minutes, ...).
  final Map<String, Object?> measures;
}

/// The entry never had a detection (typed by the person). Reset to detected is
/// not offered; this is a fact, not missing data.
class DetectedAbsent extends DetectedHistory {
  const DetectedAbsent();
}

/// The history could not be read (blank, malformed, unknown version). Safe
/// scalar bounds stay visible; history-dependent actions are disabled.
class DetectedUnavailable extends DetectedHistory {
  const DetectedUnavailable(this.reason);
  final String reason;
}

/// Stages measured for exactly [startTs]..[endTs]; reused only when the
/// entry's bounds still equal them.
@immutable
class StageResult {
  const StageResult({
    required this.startTs,
    required this.endTs,
    required this.payload,
  });
  final int startTs, endTs;
  final Map<String, Object?> payload;
}

// ── Editor read, plan, commands and outcome ─────────────────────────────────

enum SleepEntryProvenance { automatic, manual, confirmed, retained, legacy, unknown }

sealed class SleepBlockRef { const SleepBlockRef(); }
final class StoredBlockRef extends SleepBlockRef {
  const StoredBlockRef(this.id,this.expectedRevision);
  final String id;
  final int expectedRevision;
}
final class DetectedMainRef extends SleepBlockRef {
  const DetectedMainRef(this.day,this.expectedStartTs,this.expectedEndTs);
  final String day;
  final int expectedStartTs,expectedEndTs;
}
final class NoDetectionMainRef extends SleepBlockRef {
  const NoDetectionMainRef(this.day);
  final String day;
}
final class DetectedNapRef extends SleepBlockRef {
  const DetectedNapRef(this.day,this.expectedStartTs,this.expectedEndTs);
  final String day;
  final int expectedStartTs,expectedEndTs;
}

sealed class SleepEditorCommand {
  const SleepEditorCommand();
}

/// Changes the bounds of an existing stored or served entry.
class SetIntervals extends SleepEditorCommand {
  const SetIntervals(this.target, this.startTs, this.endTs);
  final SleepBlockRef target;
  final int startTs, endTs;
}

class CalculateStages extends SleepEditorCommand {
  const CalculateStages(this.target);
  final SleepBlockRef target;
}

class ResetToDetected extends SleepEditorCommand {
  const ResetToDetected(this.target);
  final SleepBlockRef target;
}

enum SleepBoundary { start, end }

class ResetBoundary extends SleepEditorCommand {
  const ResetBoundary(this.target, this.boundary);
  final SleepBlockRef target;
  final SleepBoundary boundary;
}

class RemoveBlock extends SleepEditorCommand {
  const RemoveBlock(this.target);
  final SleepBlockRef target;
}

class RestoreRemoved extends SleepEditorCommand {
  const RestoreRemoved(this.target);
  final SleepBlockRef target;
}

class AddMain extends SleepEditorCommand {
  const AddMain(this.day, this.startTs, this.endTs);
  final String day;
  final int startTs, endTs;
}
class AddNap extends SleepEditorCommand {
  const AddNap(this.startTs, this.endTs, {this.source = 'manual', this.payload, this.suggestionId});
  final int startTs, endTs;
  final String source;
  final String? payload, suggestionId;
}
class ConfirmMain extends SleepEditorCommand {
  const ConfirmMain(this.day, this.startTs, this.endTs);
  final String day;
  final int startTs, endTs;
}
class ClearMain extends SleepEditorCommand {
  const ClearMain(this.day);
  final String day;
}
class AutoLogNap extends AddNap {
  const AutoLogNap(String suggestionId, super.startTs, super.endTs, String payload)
    : super( source: 'confirmed', payload: payload, suggestionId: suggestionId);
}

/// Explicit merge: the approved set from a [SleepMergeProposal].
class MergeBlocks extends SleepEditorCommand {
  const MergeBlocks(this.proposal);
  final SleepMergeProposal proposal;
}

/// Everything one Save submits for [dayId]. Absence is an explicit revision
/// state: a null expected revision means "this day had no row".
@immutable
class SleepEditorPlan {
  const SleepEditorPlan({
    required this.dayId,
    required this.commands,
    required this.expectedRevisions,
    required this.draftGeneration,
  });

  final String dayId;
  final List<SleepEditorCommand> commands;

  /// `sleep_edit_job.revision` per affected day; null value = no job row yet.
  final Map<String, int?> expectedRevisions;

  /// The app-level draft generation the plan was built under; deletion or
  /// import advances it, so an add-only plan cannot outlive its dataset.
  final int draftGeneration;
}

enum SleepRefusalReason {
  staleEntry,
  staleDraft,
  mergeRequired,
  missingHistory,
  invalidInterval,
  unsupportedSource,
  importPaused,
  mainExists,
}

/// The editor's read model for one day: the entries it may act on.
@immutable
class SleepEditorRead {
  const SleepEditorRead({
    required this.dayId,
    required this.entries,
    required this.revision,
    required this.draftGeneration,
    this.neighbors = const [],
  });
  final String dayId;
  final List<SleepEditorEntry> entries;

  /// Live blocks owned by OTHER days near this day's span: read-only context
  /// that still takes part in spacing validation.
  final List<SleepBlock> neighbors;

  /// `sleep_edit_job.revision` of [dayId]; null when the day has no job row.
  final int? revision;
  final int draftGeneration;
}

@immutable
class SleepEditorEntry {
  const SleepEditorEntry({
    required this.ref,
    required this.kind,
    required this.day,
    required this.startTs,
    required this.endTs,
    required this.provenance,
    required this.history,
    required this.removed,
    this.id,
    this.revision = 0,
    this.ownerRule,
    this.mergedInto,
  });
  final String? id, mergedInto;
  final int revision;
  final int? ownerRule;
  final SleepBlockRef ref;
  final SleepBlockKind kind;
  final String day;
  final int startTs, endTs;
  final SleepEntryProvenance provenance;
  final DetectedHistory history;

  /// A removed block stays selectable as a dashed outline.
  final bool removed;
}

sealed class SleepEditorOutcome {
  const SleepEditorOutcome();
}

/// The plan changed nothing; no job, revision or timestamp was written.
class SleepNoChange extends SleepEditorOutcome {
  const SleepNoChange();
}

/// Durably committed. [days] are the ownership dates queued for calculation.
class SleepSaved extends SleepEditorOutcome {
  const SleepSaved(this.days);
  final Set<String> days;
}

class SleepRefused extends SleepEditorOutcome {
  const SleepRefused(this.reason, {this.target, this.proposal});
  final SleepRefusalReason reason;
  final SleepBlockRef? target;
  final SleepMergeProposal? proposal;
}

class SleepFailed extends SleepEditorOutcome {
  const SleepFailed(this.error);
  final Object error;
}

/// What the writer says about a plan before it commits.
sealed class SleepEditorProposal {
  const SleepEditorProposal();
}

class SleepProposalClear extends SleepEditorProposal {
  const SleepProposalClear();
}

class SleepProposalMergeRequired extends SleepEditorProposal {
  const SleepProposalMergeRequired(this.proposal);
  final SleepMergeProposal proposal;
}

class SleepProposalInvalid extends SleepEditorProposal {
  const SleepProposalInvalid(this.reason, {this.target});
  final SleepRefusalReason reason;
  final SleepBlockRef? target;
}

/// Legacy UI actions throw their typed refusal before any follow-up work.
void requireSleepSaved(SleepEditorOutcome outcome) {
  switch(outcome) {
    case SleepSaved() || SleepNoChange(): return;
    case SleepRefused(:final proposal) when proposal!=null:
      throw SleepMergeRequiredException(proposal);
    case SleepRefused(:final reason): throw ActivityReviewException('Sleep change refused: ${reason.name}.');
    case SleepFailed(:final error): throw error;
  }
}
