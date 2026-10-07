// Patterns that are easy to mistake for each other, by ear on the wrist.
//
// Some cues are never heard side by side but one after another, and the wearer
// has to tell them apart without looking: the gesture start against the alarm
// snooze and wake confirmations; the four breathing cues against each other.
// A pair in the same confusable set that has the same number of beats, or a
// total length within half a second, is flagged. A warning NEVER blocks an
// assignment; the Haptics screen only says so on the slot.
//
// Beats: a run of adjacent notes is one beat. A pattern with a `notes` code is
// measured on it (125 ms per sixteenth, from the first note's start to the last
// note's end, so leading and trailing rests count for nothing); one without
// (a tapped rhythm) by its presses and `playTime`, to the millisecond. Pure
// Dart.
//
// STUB (red phase): everything below `kConfusableSets` throws.

import '../notify/buzz_sequence.dart';

/// Why two slots were flagged. [sameBeats] wins when both apply.
enum SimilarityReason { sameBeats, closeDuration }

/// Total lengths this close or closer (inclusive) are confusable.
const Duration kCloseDuration = Duration(milliseconds: 500);

class SimilarityWarning {
  const SimilarityWarning({
    required this.slotA,
    required this.slotB,
    required this.reason,
    this.beats,
  });

  /// The pair, in the order the slots are listed in [kConfusableSets].
  final String slotA, slotB;
  final SimilarityReason reason;

  /// The shared beat count; set for [SimilarityReason.sameBeats], else null.
  final int? beats;
}

/// The sets of slots that must stay distinguishable, by slot key. Patterns in
/// different sets never warn against each other.
///
///  1. The one-shot confirmations: the gesture start cue, and the alarm snooze
///     and wake confirmations. The alarm keys are the ones of the unmerged
///     alarm-snooze branch (set, dismissed / "you're up", cancelled,
///     re-alarm); they are listed by key and harmless while no slot has them.
///     Natural wake plays a fixed plan in code and has no stored slot.
///  2. The four breathing cues. The interval timer uses them (work = inhale,
///     rest = exhale), and there are no separate HIIT slots, so this set is
///     also the interval set.
const List<List<String>> kConfusableSets = [
  [
    'gesture.start',
    'alarm.snooze.confirm',
    'alarm.dismiss.confirm',
    'alarm.snooze.cancelled',
    'alarm.snooze.realarm',
  ],
  ['breath.inhale', 'breath.exhale', 'breath.hold', 'breath.done'],
];

/// How many beats [s] has.
int patternBeats(BuzzSequence s) => throw UnimplementedError('patternBeats');

/// How long [s] is felt from first beat to last, exactly.
Duration patternDuration(BuzzSequence s) =>
    throw UnimplementedError('patternDuration');

/// Every flagged pair among [slots] (slot key -> what it plays). A slot that is
/// not in the map, or not in a set, is never flagged. One warning per pair,
/// ordered by set, then by the first slot's place in the set, then the
/// second's.
List<SimilarityWarning> similarityWarnings(Map<String, BuzzSequence> slots) =>
    throw UnimplementedError('similarityWarnings');

/// The line a slot shows for [w]: "Feels like Gesture start (same 2 beats)"
/// ("same 1 beat"), or "Feels like Gesture start (within 0.5 s)" for
/// [SimilarityReason.closeDuration]. [other] is the label of the OTHER slot
/// of the pair.
String similarityLine(SimilarityWarning w, {required String other}) =>
    throw UnimplementedError('similarityLine');
