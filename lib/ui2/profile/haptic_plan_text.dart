// What the band plays for a compiled haptic plan, as the calm lines under a
// pattern (8AC): the command summary, whether it plays as written, the
// extended opset and pause warnings. Shared by the tap sheet and the notes
// editor so the two cannot word it differently.

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../haptics/haptic_compiler.dart';
import '../ui2.dart';

/// "May not play exactly as written. The band plays: N4mf R1 N4mf to ...".
String hapticNotExactLine(HapticPlan plan) {
  final lo = plan.feltMin.join(' ');
  final hi = plan.feltMax.join(' ');
  return 'May not play exactly as written. The band plays: '
      '${lo == hi ? lo : '$lo to $hi'}.';
}

/// The lines for [plan]. A null plan says why there is none: [tooLong] is the
/// 10 s cap, anything else (the cap is lifted, or the band cannot play it at
/// any length) is that nothing the band can play matches.
List<Widget> hapticPlanLines(P p, HapticPlan? plan, {required bool tooLong}) {
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
    if (plan.exact)
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
    if (plan.usesUnstable)
      Text(
        'Extended haptics: timings may vary unexpectedly.',
        style: F.cap.copyWith(color: p.ink3),
      ),
    if (plan.steps.length > 1)
      Text(
        'Pauses between buzzes can vary a little.',
        style: F.cap.copyWith(color: p.ink3),
      ),
  ];
}
