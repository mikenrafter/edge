// 8AF.6 addendum F.2, compile level (red first). compile() no longer takes
// `extended:`: it always considers the profile's unstable phrases and gaps,
// and prefers stable ones through a small cost per unstable part, so an
// unstable choice wins only when it fits meaningfully better.
//
// This file does not build until the `extended` argument is removed from
// compile(). It is separate from no_extended_mode_test.dart so that file's
// widget, JSON and planForTaps tests fail on their own assertions today.
//
// Contracts these tests pin that the spec leaves open:
//  - `compile(target, profile, ...)` with no `extended`.
//  - plan.exact is not asserted for plans with an unstable part (the small
//    cost may or may not count towards it); the steps are.
//  - "small" means below one mismatched cell (4): a target that only an
//    unstable part fits (a 1-sixteenth rest, two soft notes) still takes it.

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/gestures/pattern_transcript.dart';
import 'package:openstrap_edge/haptics/haptic_compiler.dart';
import 'package:openstrap_edge/haptics/haptic_profile.dart';

final HapticDeviceProfile _mg = HapticDeviceProfile.whoopMg;

List<PatternEntry> _c(String code) => PatternTranscript.parseCode(code).entries;

HapticPhrase _phrase(String id) => _mg.phrases.firstWhere((p) => p.id == id);

List<String> _ids(HapticPlan p) => [for (final s in p.steps) s.phrase.id];

void main() {
  group('unstable parts are always on the table', () {
    test('N4ff R1 N4ff needs the unstable 100 ms gap row, and takes it', () {
      final plan = compile(_c('N4ff R1 N4ff'), _mg)!;
      expect(plan.steps, hasLength(2));
      expect(plan.steps[1].delayMs, 100);
      expect(plan.steps[1].gapStable, isFalse);
      expect(plan.usesUnstable, isTrue);
    });

    test('a target only click1soft matches takes click1soft', () {
      final soft = _phrase('click1soft');
      expect(soft.stable, isFalse);
      final plan = compile(soft.min, _mg)!;
      expect(_ids(plan), ['click1soft']);
      expect(plan.usesUnstable, isTrue);
    });
  });

  group('stable stays preferred', () {
    test('every stable phrase\'s own renditions compile to stable parts '
        'only, one step, nothing lost', () {
      for (final p in _mg.phrases.where((p) => p.stable)) {
        for (final target in [p.min, p.max]) {
          final plan = compile(target, _mg)!;
          expect(plan.usesUnstable, isFalse, reason: p.id);
          // 8AI: the pair's N2 R2 N2 rendition would shorten the rest in its
          // other rendition, so it takes two commands (stable ones).
          if (p.id == 'pair' && target == p.min) {
            expect(plan.steps.length, greaterThan(1));
            for (final s in plan.steps) {
              expect(s.phrase.stable && s.gapStable, isTrue);
            }
            continue;
          }
          expect(plan.steps, hasLength(1), reason: p.id);
          expect(plan.steps.single.phrase.stable, isTrue, reason: p.id);
          expect(plan.cost, 0, reason: p.id);
          expect(plan.exact, isTrue, reason: p.id);
        }
      }
    });

    test('N4ff R6 N4f stays on the stable 700 ms row (cost 2)', () {
      // The 300 ms row feels 4..6 and would shorten a written rest of 6 (8AI).
      final plan = compile(_c('N4ff R6 N4f'), _mg)!;
      expect(_ids(plan), ['buzz47', 'buzz14']);
      expect(plan.steps[1].delayMs, 700);
      expect(plan.steps[1].gapStable, isTrue);
      expect(plan.cost, 2);
      expect(plan.usesUnstable, isFalse);
    });

    test('where loudness is free (weight 0) click1soft\'s cells are met by '
        'the stable click1 instead', () {
      final plan = compile(_phrase('click1soft').min, _mg, dynamicWeight: 0)!;
      expect(plan.usesUnstable, isFalse);
      expect(plan.steps.single.phrase.stable, isTrue);
    });

    test('a request for any loudness is met by stable parts', () {
      final plan = compile(_c('N1* N1*'), _mg)!;
      expect(plan.usesUnstable, isFalse);
    });
  });
}
