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
import '../gestures/pattern_transcript.dart';
import '../l10n/app_localizations.dart';
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
///  3. The six ECG cues: how a reading ended is told by feel alone, on the
///     wrist, with the phone often out of sight.
const List<List<String>> kConfusableSets = [
  [
    'gesture.start',
    'alarm.snooze.confirm',
    'alarm.dismiss.confirm',
    'alarm.snooze.cancelled',
    'alarm.snooze.realarm',
  ],
  ['breath.inhale', 'breath.exhale', 'breath.hold', 'breath.done'],
  [
    'ecg.started',
    'ecg.complete',
    'ecg.inconclusive',
    'ecg.inconclusiveRetry',
    'ecg.failed',
    'ecg.attention',
  ],
];

/// Milliseconds per sixteenth for a pattern written as notes.
const int _unitMs = 125;

// The notes of [s] as entries, or null for a tapped rhythm (or unreadable
// notes), which is measured by its presses.
List<PatternEntry>? _entries(BuzzSequence s) {
  final code = s.notes;
  if (code == null) return null;
  try {
    return PatternTranscript.parseCode(code).entries;
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// How many beats [s] has.
int patternBeats(BuzzSequence s) {
  final es = _entries(s);
  if (es == null) return s.length;
  var beats = 0;
  var inNote = false;
  for (final e in es) {
    if (e.note && !inNote) beats++;
    inNote = e.note;
  }
  return beats;
}

/// How long [s] is felt from first beat to last, exactly.
Duration patternDuration(BuzzSequence s) {
  final es = _entries(s);
  if (es == null) return s.playTime;
  var at = 0;
  int? first, end;
  for (final e in es) {
    if (e.note) {
      first ??= at;
      end = at + e.length;
    }
    at += e.length;
  }
  if (first == null || end == null) return Duration.zero;
  return Duration(milliseconds: (end - first) * _unitMs);
}

/// Every flagged pair among [slots] (slot key -> what it plays). A slot that is
/// not in the map, or not in a set, is never flagged. One warning per pair,
/// ordered by set, then by the first slot's place in the set, then the
/// second's.
List<SimilarityWarning> similarityWarnings(Map<String, BuzzSequence> slots) {
  final out = <SimilarityWarning>[];
  for (final set in kConfusableSets) {
    final present = [
      for (final k in set)
        if (slots[k] != null) k,
    ];
    for (var i = 0; i < present.length; i++) {
      for (var j = i + 1; j < present.length; j++) {
        final a = slots[present[i]]!, b = slots[present[j]]!;
        final beats = patternBeats(a);
        if (beats == patternBeats(b)) {
          out.add(SimilarityWarning(
            slotA: present[i],
            slotB: present[j],
            reason: SimilarityReason.sameBeats,
            beats: beats,
          ));
        } else if ((patternDuration(a) - patternDuration(b)).abs() <=
            kCloseDuration) {
          out.add(SimilarityWarning(
            slotA: present[i],
            slotB: present[j],
            reason: SimilarityReason.closeDuration,
          ));
        }
      }
    }
  }
  return out;
}

/// The line a slot shows for [w]: "Feels like Gesture start (same 2 beats)"
/// ("same 1 beat"), or "Feels like Gesture start (within 0.5 s)" for
/// [SimilarityReason.closeDuration]. [other] is the label of the OTHER slot
/// of the pair. Translated through [l10n]; English when there is none.
String similarityLine(
  SimilarityWarning w, {
  required String other,
  AppLocalizations? l10n,
}) {
  if (w.reason == SimilarityReason.closeDuration) {
    return l10n?.hapticSimilarCloseLength(other) ??
        'Feels like $other (within 0.5 s)';
  }
  final n = w.beats ?? 0;
  return l10n?.hapticSimilarSameBeats(other, n) ??
      'Feels like $other (same $n ${n == 1 ? 'beat' : 'beats'})';
}
