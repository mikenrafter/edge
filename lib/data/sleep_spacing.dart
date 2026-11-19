// sleep_spacing.dart — the 30-minute rule between ANY two sleep blocks, as one
// pure decision (owner, 2026-11-17).
//
// A change creates or narrows a gap under [kMinSleepGapSec] -> the caller must
// ask for an explicit Merge. A kept or widened historical gap saves normally,
// exactly 30:00 is allowed, and removals only ever widen gaps. UI preflight and
// every table writer call this same function, so the arithmetic is never
// copied. CLAIM(sleep-block-separation).

import 'dart:math' as math;

import 'sleep_editor.dart';

/// One change to the live block set. [beforeKey] names the stored block being
/// changed (null for a brand-new block); [after] is the block it becomes (null
/// for a removal).
class BlockChange {
  const BlockChange({this.beforeKey, this.after});
  final String? beforeKey;
  final SleepBlock? after;
}

class SleepSpacing {
  const SleepSpacing._();

  /// Seconds between two blocks; negative when they overlap.
  static int gap(SleepBlock a, SleepBlock b) =>
      math.max(a.startTs, b.startTs) - math.min(a.endTs, b.endTs);

  /// The merge a change needs, or null when it is clear. [stored] is the live
  /// block set before the change. [editingDay] chooses the surviving main when
  /// a merge reaches several.
  static SleepMergeProposal? evaluate({
    required List<SleepBlock> stored,
    required List<BlockChange> changes,
    required String editingDay,
  }) {
    final before = {for (final b in stored) b.key: b};
    final after = Map<String, SleepBlock>.of(before);
    final touched = <String>{};
    var fresh = 0;
    for (final c in changes) {
      final id = c.beforeKey ?? 'new:${fresh++}';
      touched.add(id);
      after.remove(c.beforeKey);
      if (c.after != null) after[id] = c.after!;
    }
    final ids = after.keys.toList();
    final violating = <String>{};
    for (var i = 0; i < ids.length; i++) {
      for (var j = i + 1; j < ids.length; j++) {
        final a = ids[i], b = ids[j];
        if (!touched.contains(a) && !touched.contains(b)) continue;
        final g = gap(after[a]!, after[b]!);
        if (g >= kMinSleepGapSec) continue;
        final was = before[a] != null && before[b] != null
            ? gap(before[a]!, before[b]!)
            : null;
        if (was == null || g < was) violating.addAll([a, b]);
      }
    }
    if (violating.isEmpty) return null;

    // Transitive connected set over every pair under the minimum gap.
    final component = <String>{...violating};
    var grew = true;
    while (grew) {
      grew = false;
      for (final a in ids) {
        if (component.contains(a)) continue;
        if (component.any((b) => gap(after[a]!, after[b]!) < kMinSleepGapSec)) {
          component.add(a);
          grew = true;
        }
      }
    }
    final union = component.map((id) => after[id]!);
    final start = union.map((b) => b.startTs).reduce(math.min);
    final end = union.map((b) => b.endTs).reduce(math.max);
    // Stored participants (a brand-new block is represented by the range).
    // An incoming MAIN has no stored row yet but must be a survivor candidate
    // ("keep a participating main"); an incoming nap is just the range.
    final participants = [
      for (final id in component)
        if (before[id] != null)
          before[id]!
        else if (after[id]!.kind == SleepBlockKind.main)
          after[id]!,
    ]..sort((a, b) => a.startTs.compareTo(b.startTs));
    if (participants.isEmpty) return null;
    final mains = participants.where((b) => b.kind == SleepBlockKind.main);
    final SleepBlock survivor;
    if (mains.isNotEmpty) {
      survivor = mains.firstWhere((b) => b.day == editingDay,
          orElse: () => mains.first);
    } else {
      survivor = participants.first;
    }
    return SleepMergeProposal(
      survivor: survivor,
      absorbed: [
        for (final b in participants)
          if (b.key != survivor.key) b,
      ],
      startTs: start,
      endTs: end,
    );
  }
}
