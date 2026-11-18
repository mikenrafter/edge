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
    this.provenance = SleepEntryProvenance.automatic,
  });

  final String? id;
  final int revision;
  final SleepEntryProvenance provenance;
  String get ownerDay => day;
  final SleepBlockKind kind;

  /// The `day_id` that owns the block (the wake date for a main sleep).
  final String day;
  final int startTs, endTs;

  /// Stable identity while the block exists. A main is one per day; a nap is
  /// the `(day, start)` key the table enforces.
  String get key => kind == SleepBlockKind.main
      ? 'main:$day'
      : 'nap:$day:$startTs';

  @override
  bool operator ==(Object other) =>
      other is SleepBlock &&
      other.kind == kind &&
      other.day == day &&
      other.startTs == startTs &&
      other.endTs == endTs;

  @override
  int get hashCode => Object.hash(kind, day, startTs, endTs);

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
  SleepMergeRequiredException(this.proposal)
      : super('This change would merge these sleep blocks.');

  final SleepMergeProposal proposal;
}

// ── History and the stored envelope ─────────────────────────────────────────

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

/// An interval a removed or replaced entry still suppresses.
@immutable
class SuppressedInterval {
  const SuppressedInterval(this.day, this.startTs, this.endTs);
  final String day;
  final int startTs, endTs;
}

/// Where an entry came from: the intervals it suppresses and, for an absorbed
/// entry, the survivor that now contains it.
@immutable
class OriginRef {
  const OriginRef({this.suppressed = const [], this.mergedInto});
  final List<SuppressedInterval> suppressed;
  final String? mergedInto;
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

@immutable
class SleepEditEnvelope {
  const SleepEditEnvelope({
    this.version = kSleepEditEnvelopeVersion,
    this.origin = const OriginRef(),
    this.detected = const DetectedAbsent(),
    this.stages,
  });
  final int version;
  final OriginRef origin;
  final DetectedHistory detected;
  final StageResult? stages;
}

const int kSleepEditEnvelopeVersion = 1;

/// A decoded stored payload: the retained measurement keys, kept verbatim, and
/// the namespaced envelope when it is present and valid.
sealed class EnvelopeRead {
  const EnvelopeRead(this.retained);
  final Map<String, Object?> retained;
}

class EnvelopeOk extends EnvelopeRead {
  const EnvelopeOk(super.retained, this.envelope);
  final SleepEditEnvelope envelope;
}

/// No usable envelope: history is unavailable, [retained] is still served.
class EnvelopeUnavailable extends EnvelopeRead {
  const EnvelopeUnavailable(super.retained, this.reason);
  final String reason;
}

// ── Editor read, plan, commands and outcome ─────────────────────────────────

enum SleepEntryProvenance { automatic, manual, confirmed, retained, legacy, unknown }

/// Names one entry. [expectedEndTs] and [expectedSource] pin the row the plan
/// was built against, so a changed row is a stale refusal, not a lost edit.
@immutable
class SleepEntryRef {
  const SleepEntryRef({
    required this.kind,
    required this.day,
    this.startTs,
    this.expectedEndTs,
    this.expectedSource,
  });

  final SleepBlockKind kind;
  final String day;

  /// A nap's start (the key); null for a main sleep, which one day owns once.
  final int? startTs;
  final int? expectedEndTs;
  final String? expectedSource;

  String get key => kind == SleepBlockKind.main ? 'main:$day' : 'nap:$day:$startTs';
}

sealed class SleepEditorCommand {
  const SleepEditorCommand();
}

/// Moves or creates an interval. A null [SleepEntryRef.startTs] on a nap is an
/// Add; [startTs]/[endTs] are the new bounds.
class SetIntervals extends SleepEditorCommand {
  const SetIntervals(this.target, this.startTs, this.endTs);
  final SleepEntryRef target;
  final int startTs, endTs;
}

class CalculateStages extends SleepEditorCommand {
  const CalculateStages(this.target);
  final SleepEntryRef target;
}

class ResetToDetected extends SleepEditorCommand {
  const ResetToDetected(this.target);
  final SleepEntryRef target;
}

enum SleepBoundary { start, end }

class ResetBoundary extends SleepEditorCommand {
  const ResetBoundary(this.target, this.boundary);
  final SleepEntryRef target;
  final SleepBoundary boundary;
}

class RemoveBlock extends SleepEditorCommand {
  const RemoveBlock(this.target);
  final SleepEntryRef target;
}

class RestoreRemoved extends SleepEditorCommand {
  const RestoreRemoved(this.target);
  final SleepEntryRef target;
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
    required this.startTs,
    required this.endTs,
    required this.provenance,
    required this.history,
    required this.removed,
    this.id,
    this.revision = 0,
    this.mergedInto,
  });
  final String? id, mergedInto;
  final int revision;
  final SleepEntryRef ref;
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
  final SleepEntryRef? target;
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
  final SleepEntryRef? target;
}
