// 8AC: a tapped rhythm as notes. Each press becomes a note whose length is the
// allowed length nearest its hold (a quick tap is a sixteenth) at mf, and each
// release gap becomes rests. Pure Dart.

import '../gestures/pattern_transcript.dart';
import '../notify/buzz_sequence.dart';
import 'haptic_compiler.dart';
import 'haptic_profile.dart';

int _nearestLength(int units) {
  var best = kPatternLengths.first;
  for (final l in kPatternLengths) {
    if ((l - units).abs() < (best - units).abs()) best = l;
  }
  return best;
}

/// The notes and rests of [s] on a grid of [unitMs] per sixteenth.
List<PatternEntry> notesFromTaps(BuzzSequence s, {int unitMs = 125}) {
  final out = <PatternEntry>[];
  for (var i = 0; i < s.length; i++) {
    final hold = (s.durationsMs[i] / unitMs).round();
    out.add(PatternEntry(
      note: true,
      length: _nearestLength(hold < 1 ? 1 : hold),
      dynamic: PatternDynamic.mf,
    ));
    if (i + 1 < s.length) {
      final gap = s.offsetsMs[i + 1] - s.offsetsMs[i] - s.durationsMs[i];
      out.addAll(restEntries((gap / unitMs).round()));
    }
  }
  return out;
}

/// The commands that play [s] on a band with profile [p]. Taps carry no
/// loudness, so dynamics cost nothing. A rhythm that would run longer than
/// [maxRuntime] gives null; pass null to lift the cap.
HapticPlan? planForTaps(
  BuzzSequence s,
  HapticDeviceProfile p, {
  Duration? maxRuntime = kMaxHapticRuntime,
}) =>
    compile(
      notesFromTaps(s, unitMs: p.unitMs),
      p,
      extended: s.extended,
      dynamicWeight: 0,
      maxRuntimeMs: maxRuntime?.inMilliseconds,
    );

/// The presses and gaps of [notes] as a [BuzzSequence] on a grid of [unitMs]
/// per sixteenth: a run of notes is one press as long as it, a run of rests
/// the gap between presses, leading and trailing rests nothing. Notes that a
/// [BuzzSequence] cannot hold (over its press count, or a gap outside its
/// limits) give the minimal valid one-press sequence instead: delivery of a
/// rule with a baked plan plays the plan, and this only keeps the saved value
/// valid.
BuzzSequence tapsFromNotes(List<PatternEntry> notes, {int unitMs = 125}) {
  final presses = <(int start, int length)>[];
  var at = 0;
  for (final e in notes) {
    if (e.note) {
      if (presses.isNotEmpty && presses.last.$1 + presses.last.$2 == at) {
        presses.last = (presses.last.$1, presses.last.$2 + e.length);
      } else {
        presses.add((at, e.length));
      }
    }
    at += e.length;
  }
  BuzzSequence one() => BuzzSequence(
        const [0],
        durationsMs: [(presses.isEmpty ? 1 : presses.first.$2) * unitMs],
      );
  if (presses.isEmpty || presses.length > BuzzSequence.maxBuzzes) return one();
  for (var i = 1; i < presses.length; i++) {
    final gap = (presses[i].$1 - presses[i - 1].$1 - presses[i - 1].$2) * unitMs;
    if (gap > BuzzSequence.maxGapMs) return one();
  }
  final first = presses.first.$1;
  return BuzzSequence(
    [for (final p in presses) (p.$1 - first) * unitMs],
    durationsMs: [for (final p in presses) p.$2 * unitMs],
  );
}
