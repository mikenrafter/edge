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
