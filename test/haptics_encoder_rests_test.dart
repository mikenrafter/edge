// 8AI G4 (red): the encoder honours rests.
//
// Spec: "when compiling a pattern to band buzzes, a rest the user wrote is kept
// as a rest. If the band's minimum spacing forces it, lengthen the rest rather
// than merge or drop it, so two patterns that differ only by a rest never play
// identically. Dynamics nuance is what gets dropped first, not rests."
//
// ASSUMED API: none new. This pins `compile` (lib/haptics/haptic_compiler.dart)
// and `planForTaps` (lib/haptics/tap_notes.dart) as they are called today, on
// the MG profile (HapticDeviceProfile.whoopMg), so every failure is a
// behavioural one. How the fix is done (a hard rest constraint in the dynamic
// program, a rest penalty, a post-pass that lengthens a delay) is the green
// phase's choice; these tests only look at what is FELT.
//
// What "kept as a rest" means here, precisely:
//  * Read the felt timeline of a plan twice, shortest (HapticPlan.feltMin) and
//    longest (feltMax). Between the first and the last note, the rest runs of
//    the plan are the "interior rests".
//  * Kept: the plan has as many interior rests as the pattern has written
//    rests between pulses (nothing merged, nothing dropped, no pulse split).
//  * Never shortened: each interior rest, in BOTH renditions, is at least as
//    long as the rest written in the same position (the encoder may lengthen).
//
// Failure mode today (measured on the current compiler): "N2* R2 N2*" is
// played as the `pair` command whose longest rendition has a 1-sixteenth rest;
// "N4* R4 N4*" as two commands at a 0 ms wait whose shortest rest is 3; "N1*
// R1 N1* R1 N1*" is played as one effect-14 buzz with BOTH rests dropped; and
// "N4* R1 N4*" and "N4* R2 N4*" compile to the identical plan.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/tap_notes.dart';
import 'package:openstrap_edge/notify/buzz_sequence.dart';

import 'support/haptics_screen_support.dart';

/// Both renditions' interior rests of [p].
(List<int>, List<int>) feltRests(HapticPlan p) =>
    (interiorRests(timeline(p.feltMin)), interiorRests(timeline(p.feltMax)));

/// The rests written between pulses in [code].
List<int> written(String code) =>
    restsBetween(PatternTranscript.parseCode(code).entries);

void expectRestsKept(String code, HapticPlan? plan, {String? why}) {
  expect(plan, isNotNull, reason: '$code must compile on the MG');
  if (plan == null) return;
  final want = written(code);
  final (lo, hi) = feltRests(plan);
  final felt = 'shortest rendition: ${plan.feltMin.join(' ')}; longest: '
      '${plan.feltMax.join(' ')}; ${plan.summary}';
  for (final (name, got) in [('shortest', lo), ('longest', hi)]) {
    expect(got, hasLength(want.length),
        reason: '$code: a written rest was merged or dropped in the $name '
            'rendition ($felt)${why == null ? '' : ' ($why)'}');
    if (got.length != want.length) continue;
    for (var i = 0; i < want.length; i++) {
      expect(got[i], greaterThanOrEqualTo(want[i]),
          reason: '$code: rest ${i + 1} was written as ${want[i]} sixteenths '
              'but the $name rendition plays ${got[i]} ($felt)');
    }
  }
}

void main() {
  group('a written rest is kept, and never shortened', () {
    // Two pulses and one rest, over note lengths 1, 2 and 4 and the rests the
    // grid offers up to a half note. 18 cases.
    for (final n in [1, 2, 4]) {
      for (final r in [1, 2, 3, 4, 6, 8]) {
        final code = 'N$n* R$r N$n*';
        test(code, () => expectRestsKept(code, compileCode(code)));
      }
    }

    // Three pulses, two rests, the rests unequal in both orders.
    for (final (a, b) in [(1, 1), (1, 3), (2, 4), (4, 2), (3, 3), (2, 8)]) {
      final code = 'N2* R$a N2* R$b N2*';
      test(code, () => expectRestsKept(code, compileCode(code)));
    }

    test('a rest of one sixteenth between two pulses is lengthened, not '
        'merged: the band cannot space two commands that close, so the rest '
        'grows rather than the pulses fusing into one', () {
      final plan = compileCode('N2* R1 N2*');
      expectRestsKept('N2* R1 N2*', plan);
      expect(plan!.steps.length, greaterThan(1),
          reason: 'one command cannot hold a 1-sixteenth rest between two '
              'pulses on this band; two commands with a wait can');
    });
  });

  group('dynamics are given up before rests', () {
    // Loudness is wrong on purpose (ff pp ff), and under dynamics priority a
    // loudness step outweighs a one-cell shift. Neither may cost a rest.
    for (final priority in HapticPriority.values) {
      test('N2ff R2 N2pp R2 N2ff under ${priority.name} priority', () {
        const code = 'N2ff R2 N2pp R2 N2ff';
        expectRestsKept(
          code,
          compileCode(code, weight: 1, priority: priority),
          why: 'a dynamics nuance may be flattened; a rest may not',
        );
      });
    }

    test('five pulses in the rhythm priority keep all four rests', () {
      const code = 'N1* R1 N1* R1 N1* R1 N1* R1 N1*';
      expectRestsKept(code, compileCode(code));
    });
  });

  group('patterns that differ only by a rest never play identically', () {
    // Each pair is the same notes with one rest removed or changed to a length
    // the band's measured waits can tell apart (0 ms gives a rest of 3 or
    // more, 300 ms 4 or more, 700 ms 6 or more, 1200 ms 12 or more).
    final pairs = <(String, String)>[
      // A rest present versus absent. The second pattern's adjacent notes are
      // one longer note; the first must still play its rests.
      ('N1* R1 N1* R1 N1*', 'N1* N1* N1*'),
      ('N1* R1 N1* R1 N1*', 'N1* R1 N1* N1*'),
      ('N2* R1 N2* R1 N2*', 'N2* R1 N2* N2*'),
      ('N2* R1 N2* R1 N2*', 'N2* N2* N2*'),
      // A rest of one length versus another.
      ('N4* R1 N4*', 'N4* R4 N4*'),
      ('N4* R2 N4*', 'N4* R4 N4*'),
      ('N2* R3 N2*', 'N2* R4 N2*'),
      ('N4* R4 N4*', 'N4* R8 N4*'),
      ('N2* R1 N2*', 'N2* R8 N2*'),
    ];
    for (final (a, b) in pairs) {
      test('$a  vs  $b', () {
        final pa = compileCode(a);
        final pb = compileCode(b);
        expect(pa, isNotNull, reason: a);
        expect(pb, isNotNull, reason: b);
        if (pa == null || pb == null) return;
        expect(planSignature(pa), isNot(planSignature(pb)),
            reason: 'both play as: ${planSignature(pa)}');
      });
    }
  });

  group('rests from taps', () {
    test('a tapped rhythm with unequal pauses keeps both pauses', () {
      // Three 250 ms presses; pauses of 250 ms and 500 ms: N2 R2 N2 R4 N2.
      final taps = BuzzSequence(
        const [0, 500, 1250],
        durationsMs: const [250, 250, 250],
      );
      final plan = planForTaps(taps, kMg);
      expect(plan, isNotNull);
      if (plan == null) return;
      final (lo, hi) = feltRests(plan);
      for (final got in [lo, hi]) {
        expect(got, hasLength(2),
            reason: 'two pauses were tapped; ${plan.summary}');
        if (got.length == 2) {
          expect(got[0], greaterThanOrEqualTo(2));
          expect(got[1], greaterThanOrEqualTo(4));
        }
      }
    });
  });
}
