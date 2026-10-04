// What the band plays for a compiled haptic plan, as the calm lines under a
// pattern (8AC): the command summary, whether it plays as written, the
// timing-variation and pause warnings. Shared by the tap sheet and the notes
// editor so the two cannot word it differently.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../gestures/pattern_transcript.dart';
import '../../haptics/haptic_compiler.dart';
import '../ui2.dart';

/// "May not play exactly as written. The band plays: N4mf R1 N4mf to ...".
/// Also the line for a plan that scores exact but is felt as a range.
String hapticNotExactLine(HapticPlan plan) {
  final lo = plan.feltMin.join(' ');
  final hi = plan.feltMax.join(' ');
  return 'May not play exactly as written. The band plays: '
      '${lo == hi ? lo : '$lo to $hi'}.';
}

// The cells of [cells] from [from] for [len] sixteenths as entries: runs of the
// same loudness (or rest), each run split into allowed lengths, largest first.
// Cells past the end of the list are rests.
List<PatternEntry> _felt(List<PatternDynamic?> cells, int from, int len) {
  final out = <PatternEntry>[];
  var i = 0;
  while (i < len) {
    final d = from + i < cells.length ? cells[from + i] : null;
    var run = 1;
    while (i + run < len &&
        (from + i + run < cells.length ? cells[from + i + run] : null) == d) {
      run++;
    }
    if (d == null) {
      out.addAll(restEntries(run));
    } else {
      var left = run;
      for (final l in kPatternLengths.reversed) {
        while (left >= l) {
          out.add(PatternEntry(note: true, length: l, dynamic: d));
          left -= l;
        }
      }
    }
    i += run;
  }
  return out;
}

bool _cellDiffers(PatternDynamic? want, PatternDynamic? got) {
  if (want == null || got == null) return want != got;
  return want != PatternDynamic.any && want != got;
}

/// "Plays N4ff where you wrote N4mf": the written notes the band will not play
/// as written, with what it plays over each (at most the first two, then an
/// ellipsis). Null when the plan is exact or no written note differs. A note
/// written as any loudness is never named for its loudness. Judged on
/// whichever of the shortest and longest felt rendition is closer to the
/// written cells.
String? hapticChangesLine(List<PatternEntry> written, HapticPlan plan) {
  if (plan.exact) return null;
  final all = timeline(written);
  final first = all.indexWhere((c) => c != null);
  if (first < 0) return null;
  final want = all.sublist(first);

  int off(List<PatternDynamic?> felt) {
    var n = 0;
    for (var i = 0; i < want.length; i++) {
      if (_cellDiffers(want[i], i < felt.length ? felt[i] : null)) n++;
    }
    return n;
  }

  final lo = timeline(plan.feltMin);
  final hi = timeline(plan.feltMax);
  final felt = off(lo) <= off(hi) ? lo : hi;

  final parts = <String>[];
  var at = -first;
  for (final e in written) {
    final from = at;
    at += e.length;
    if (!e.note || from < 0) continue;
    var differs = false;
    for (var i = 0; i < e.length; i++) {
      if (_cellDiffers(
        want[from + i],
        from + i < felt.length ? felt[from + i] : null,
      )) {
        differs = true;
      }
    }
    if (!differs) continue;
    parts.add(
      '${_felt(felt, from, e.length).join(' ')} where you wrote $e',
    );
  }
  if (parts.isEmpty) return null;
  return 'Plays ${parts.take(2).join('; ')}${parts.length > 2 ? ' …' : ''}';
}

/// The lines for [plan]. A null plan says why there is none: [tooLong] is the
/// 10 s cap, anything else (the cap is lifted, or the band cannot play it at
/// any length) is that nothing the band can play matches.
///
/// With [written] (the entries the plan was compiled from) a plan that is not
/// as written also names the notes that changed.
List<Widget> hapticPlanLines(
  P p,
  HapticPlan? plan, {
  required bool tooLong,
  List<PatternEntry>? written,
}) {
  if (plan == null) {
    return [
      Text(
        tooLong
            ? 'Too long for the band: keep it under '
                '${kMaxHapticRuntime.inSeconds} seconds.'
            : 'Nothing the band can play matches this.',
        style: F.cap.copyWith(color: p.ink2),
      ),
    ];
  }
  return [
    Text(plan.summary, style: F.cap.copyWith(color: p.ink2)),
    if (plan.asWritten)
      Text('Plays as written.', style: F.cap.copyWith(color: p.ink2))
    else
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.info, size: 14, color: p.ink3),
          const SizedBox(width: S.x1),
          Expanded(
            child: Text(
              hapticNotExactLine(plan),
              style: F.cap.copyWith(color: p.ink3),
            ),
          ),
        ],
      ),
    if (written != null && hapticChangesLine(written, plan) != null)
      Text(
        hapticChangesLine(written, plan)!,
        key: const ValueKey('pattern-editor-changes'),
        style: F.cap.copyWith(color: p.ink3),
      ),
    if (plan.usesUnstable)
      Text(
        'This uses a command whose timings may vary unexpectedly.',
        style: F.cap.copyWith(color: p.ink3),
      ),
    if (plan.steps.length > 1)
      Text(
        'Pauses between buzzes can vary a little.',
        style: F.cap.copyWith(color: p.ink3),
      ),
  ];
}
